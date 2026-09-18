import { existsSync, readFileSync } from 'node:fs';
import { mkdir, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { dirname, join, resolve } from 'node:path';
import { VoiceRegistry, loadVoiceProfileManifest, voiceFingerprint, type VoiceProfileSpec } from './voice-registry.js';

function loadEnvFile() {
  const path = resolve(process.cwd(), '.env');
  if (!existsSync(path)) return;
  for (const line of readFileSync(path, 'utf8').split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const equal = trimmed.indexOf('=');
    if (equal > 0 && !process.env[trimmed.slice(0, equal).trim()]) process.env[trimmed.slice(0, equal).trim()] = trimmed.slice(equal + 1).trim();
  }
}

type CatalogVoice = { voice_id: string; name?: string; high_quality_base_model_ids?: string[] };
type DesignPreview = { generated_voice_id?: string; audio_base_64?: string; duration_secs?: number; transcript?: string };

function argument(name: string) { const index = process.argv.indexOf(name); return index >= 0 ? process.argv[index + 1] : undefined; }
function hasArgument(name: string) { return process.argv.includes(name); }
function words(text: string) { return text.toLowerCase().match(/[a-z0-9]+/g) ?? []; }
function similarity(expected: string, actual?: string) {
  if (!actual) return .5;
  const a = new Set(words(expected));
  const b = new Set(words(actual));
  if (!a.size) return 0;
  return [...a].filter(word => b.has(word)).length / a.size;
}

export function scorePreview(profile: VoiceProfileSpec, preview: DesignPreview) {
  const compatibility = preview.generated_voice_id && preview.audio_base_64 ? 1 : 0;
  const intelligibility = similarity(profile.design?.previewText ?? '', preview.transcript);
  const bytes = preview.audio_base_64 ? Buffer.from(preview.audio_base_64, 'base64').length : 0;
  const duration = Number(preview.duration_secs);
  const quality = bytes >= 4_000 && bytes <= 5_000_000 && Number.isFinite(duration) && duration > .5 && duration < 30 ? 1 : bytes > 0 ? .25 : 0;
  const expectedSeconds = Math.max(1, words(profile.design?.previewText ?? '').length / 2.6);
  const cadence = Number.isFinite(duration) ? Math.max(0, 1 - Math.abs(duration - expectedSeconds) / Math.max(duration, expectedSeconds)) : .25;
  return compatibility * .4 + intelligibility * .3 + quality * .2 + cadence * .1;
}

async function jsonRequest(endpoint: string, key: string, path: string, init?: RequestInit) {
  const response = await fetch(`${endpoint.replace(/\/$/, '')}${path}`, { ...init, headers: { ...(init?.body ? { 'content-type': 'application/json' } : {}), 'xi-api-key': key, ...(init?.headers ?? {}) }, signal: AbortSignal.timeout(30_000) });
  if (!response.ok) throw new Error(`elevenlabs_http_${response.status}`);
  return response.json() as Promise<any>;
}

async function transcribePreviews(endpoint: string, key: string, previews: DesignPreview[], model = 'scribe_v2') {
  for (const preview of previews) {
    if (!preview.audio_base_64 || preview.transcript) continue;
    const form = new FormData();
    form.append('model_id', model);
    form.append('file', new Blob([Buffer.from(preview.audio_base_64, 'base64')], { type: 'audio/mpeg' }), 'preview.mp3');
    try {
      const response = await fetch(`${endpoint.replace(/\/$/, '')}/v1/speech-to-text`, { method: 'POST', headers: { 'xi-api-key': key }, body: form, signal: AbortSignal.timeout(30_000) });
      if (response.ok) preview.transcript = String(((await response.json()) as { text?: string }).text ?? '');
    } catch { /* A missing STT entitlement is reflected by the neutral score. */ }
  }
}

export async function provisionVoices(env: Record<string, string | undefined> = process.env, args = process.argv) {
  const key = env.AI_NPC_TTS_KEY ?? '';
  if (!key) throw new Error('elevenlabs_key_missing');
  if ((env.AI_NPC_TTS_PROVIDER ?? '').toLowerCase() !== 'elevenlabs') throw new Error('elevenlabs_provider_required');
  const endpoint = env.AI_NPC_TTS_ENDPOINT ?? 'https://api.elevenlabs.io';
  const serverId = argumentFrom(args, '--server') ?? '*';
  const dryRun = args.includes('--dry-run');
  const cap = Number(env.AI_NPC_VOICE_PROVISION_MAX ?? 32);
  if (!Number.isSafeInteger(cap) || cap < 1 || cap > 50) throw new Error('voice_provision_cap_invalid');
  if (!serverId || serverId.length > 100 || ['__proto__', 'prototype', 'constructor'].includes(serverId)) throw new Error('voice_registry_scope_invalid');
  const profiles = await loadVoiceProfileManifest(env.AI_NPC_VOICE_PROFILES_PATH);
  const registry = new VoiceRegistry(env.AI_NPC_VOICE_REGISTRY_PATH);
  await registry.initialize();
  const catalog = new Map<string, CatalogVoice>();
  let pageToken: string | undefined;
  const seenPages = new Set<string>();
  do {
    const query = new URLSearchParams({ page_size: '100', ...(pageToken ? { page_token: pageToken } : {}) });
    const page = await jsonRequest(endpoint, key, `/v2/voices?${query}`) as { voices?: CatalogVoice[]; has_more?: boolean; next_page_token?: string };
    for (const voice of page.voices ?? []) catalog.set(voice.voice_id, voice);
    pageToken = page.has_more ? page.next_page_token : undefined;
    if (page.has_more && !pageToken) throw new Error('voice_catalog_pagination_invalid');
    if (pageToken && (seenPages.has(pageToken) || seenPages.size >= 100)) throw new Error('voice_catalog_pagination_invalid');
    if (pageToken) seenPages.add(pageToken);
  } while (pageToken);
  let created = 0;
  let unchanged = 0;
  const missing: string[] = [];
  for (const profile of profiles) {
    const existing = registry.resolve(serverId, profile.voiceProfileId);
    if (existing?.provider === 'elevenlabs' && catalog.has(existing.voiceId)) { unchanged += 1; continue; }
    missing.push(profile.voiceProfileId);
    if (dryRun) continue;
    // A missing provider asset is not permission to change an established person.
    if (existing) throw new Error(`voice_recast_requires_review:${profile.voiceProfileId}`);
    if (created >= cap) throw new Error('voice_provision_cap_reached');
    if (!profile.design || typeof profile.design.description !== 'string' || !profile.design.description.trim()
      || profile.design.description.length > 1000 || typeof profile.design.previewText !== 'string'
      || !profile.design.previewText.trim() || profile.design.previewText.length > 1000) throw new Error(`voice_design_missing:${profile.voiceProfileId}`);
    const auditionRoot = resolve(env.AI_NPC_VOICE_AUDITIONS_PATH ?? join(dirname(registry.file), 'voice-auditions'));
    const scopeHash = createHash('sha256').update(JSON.stringify([serverId, profile.voiceProfileId])).digest('hex');
    const auditionDirectory = join(auditionRoot, scopeHash);
    await mkdir(auditionRoot, { recursive: true, mode: 0o700 });
    try { await mkdir(auditionDirectory, { mode: 0o700 }); }
    catch (error) { if ((error as NodeJS.ErrnoException).code === 'EEXIST') throw new Error(`voice_provision_reconciliation_required:${profile.voiceProfileId}`); throw error; }
    // A failed/lost provider response leaves this fence in place. Never spend again blindly.
    await writeFile(join(auditionDirectory, 'intent.json'), JSON.stringify({ serverId, profileId: profile.voiceProfileId, state: 'pending', startedAt: new Date().toISOString() }), { flag: 'wx', mode: 0o600 });
    const accent = profile.accent ? ` Accent: ${profile.accent}.` : '';
    // Voice Design requires at least 100 characters when auto-generated text is disabled.
    // Keep authored copy intact when it already meets the limit; otherwise extend it with
    // a neutral, in-character cadence sentence rather than failing the whole provisioning run.
    const previewText = profile.design.previewText.length >= 100
      ? profile.design.previewText
      : `${profile.design.previewText.trim()} Keep the delivery natural, clear, and conversational so the character sounds human in live gameplay.`;
    const design = await jsonRequest(endpoint, key, '/v1/text-to-voice/design', { method: 'POST', body: JSON.stringify({ voice_description: `${profile.design.description}${accent}`, text: previewText, auto_generate_text: false }) }) as { previews?: DesignPreview[] };
    const previews = (design.previews ?? []).filter(preview => preview.generated_voice_id && preview.audio_base_64).slice(0, 3);
    if (previews.length !== 3) throw new Error(`voice_design_preview_count:${profile.voiceProfileId}`);
    for (const [index, preview] of previews.entries()) {
      if (typeof preview.audio_base_64 !== 'string' || preview.audio_base_64.length > 6_700_000
        || !/^[A-Za-z0-9+/]+={0,2}$/.test(preview.audio_base_64)) throw new Error('voice_preview_audio_invalid');
      const bytes = Buffer.from(preview.audio_base_64, 'base64');
      if (!bytes.length || bytes.length > 5_000_000) throw new Error('voice_preview_audio_invalid');
      await writeFile(join(auditionDirectory, `preview-${index + 1}.mp3`), bytes, { flag: 'wx', mode: 0o600 });
    }
    await transcribePreviews(endpoint, key, previews, env.AI_NPC_VOICE_PROVISION_STT_MODEL ?? 'scribe_v2');
    const winner = previews.map((preview, index) => ({ preview, index, score: scorePreview(profile, preview) })).sort((a, b) => b.score - a.score || a.index - b.index)[0];
    const saved = await jsonRequest(endpoint, key, '/v1/text-to-voice/create', { method: 'POST', body: JSON.stringify({ voice_name: `Peak ${profile.voiceProfileId}`, voice_description: `${profile.design.description}${accent}`, generated_voice_id: winner.preview.generated_voice_id }) }) as { voice_id?: string };
    if (!saved.voice_id) throw new Error(`voice_create_invalid:${profile.voiceProfileId}`);
    const record = { provider: 'elevenlabs' as const, voiceId: saved.voice_id, name: `Peak ${profile.voiceProfileId}`, modelIds: ['eleven_flash_v2_5', 'eleven_multilingual_v2'], provisionedAt: new Date().toISOString(), catalogValidatedAt: new Date().toISOString() };
    await writeFile(join(auditionDirectory, 'review.json'), JSON.stringify({ serverId, profileId: profile.voiceProfileId,
      state: 'review_required', fingerprint: voiceFingerprint(record), selectedPreview: winner.index + 1,
      prompt: previewText, scores: previews.map(preview => scorePreview(profile, preview)), record }, null, 2), { flag: 'wx', mode: 0o600 });
    await registry.set(serverId, profile.voiceProfileId, record);
    created += 1;
  }
  return { serverId, configured: profiles.length, unchanged, missing, created, dryRun, reviewRequired: registry.counts(serverId).reviewRequired };
}

function argumentFrom(args: string[], name: string) { const index = args.indexOf(name); return index >= 0 ? args[index + 1] : undefined; }

if (process.argv[1] && import.meta.url === new URL(`file:///${resolve(process.argv[1]).replace(/\\/g, '/')}`).href) {
  loadEnvFile();
  provisionVoices().then(result => console.log(JSON.stringify(result, null, 2))).catch(error => { console.error(JSON.stringify({ error: error instanceof Error ? error.message : 'voice_provision_failed' })); process.exitCode = 1; });
}
