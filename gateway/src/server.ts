import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { randomUUID, createHash } from 'node:crypto';
import { validateTurn, type TurnInput, type TurnOutput } from './contracts.js';
import type { TextProvider } from './providers/types.js';
import { createTextProvider } from './providers/factory.js';
import { FileMemoryStore, type MemoryRecord, type MemoryStore, type RelationshipRecord } from './memory/store.js';
import { createSpeechProvider, stripPerformanceMarkup, type SpeechProvider, type SpeechOptions } from './speech.js';
import { extractLicenseKey, extractServerId, managedFeatureAvailable, validateRequestLicense, LicenseRateLimiter, ManagedEntitlementValidator, type LicenseValidationResult, type ManagedPaidFeature } from './license.js';
import { createVisionPipeline, type VisionProvider } from './vision.js';
import { UploadStore, extractMultipartImage } from './uploads.js';
import { PostgresMemoryStore } from './memory/postgres.js';
import { NoopTranscriptionProvider, OpenAICompatibleTranscriptionProvider, validateAudioDataUrl, type TranscriptionProvider } from './transcription.js';
import { NpcCatalog, validNpcDefinition } from './catalog.js';
import { completeWithFallback } from './provider-runtime.js';
import { modernAdminHtml } from './admin.js';
import { FileResidentStore, PostgresResidentStore, type ResidentStore, type Vec4 } from './residents.js';
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { MemoryExtractionQueue, captureDeterministicMemory } from './memory/extractor.js';
import { AudioDelivery } from './audio-delivery.js';
import { VoiceRegistry, approvedVoice, type DeliveryPreset, type QualityMode, type ProviderVoiceRecord } from './voice-registry.js';
import { resolveVoice } from './voice-policy.js';
import { billingEventId, estimatedTextTokens, settlementAmounts, UsageSettlementClient, type UsageSettlement, type UsageReservation } from './usage-settlement.js';
import { audioDataUrlBytes, measuredAudioSeconds } from './audio-duration.js';
import { composeSystemPrompt, maxResponseCharacters } from './prompts.js';
import { providerTools } from './tools.js';
import { OperationLedger, turnOperationKey } from './operation-ledger.js';
import { PortalHeartbeatClient } from './heartbeat.js';
import { operatorAuthorized } from './operator-auth.js';
import { residentVoiceAssignment } from './resident-voice.js';
import { PortalDataDeletionClient } from './data-deletion.js';

function loadEnvFile() {
  const envPath = resolve(process.cwd(), '.env');
  if (existsSync(envPath)) {
    const content = readFileSync(envPath, 'utf8');
    for (const line of content.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) continue;
      const eqIndex = trimmed.indexOf('=');
      if (eqIndex > 0) {
        const key = trimmed.slice(0, eqIndex).trim();
        const value = trimmed.slice(eqIndex + 1).trim();
        if (!process.env[key]) {
          process.env[key] = value;
        }
      }
    }
  }
}
loadEnvFile();
type BillingHold = Omit<UsageReservation, 'protocolVersion' | 'action'>;
type TurnResult = { result: TurnOutput; ttsCharacters: number; synthesizedQualityMode?: QualityMode; audioSeconds?: number; billing?: BillingHold };
const turnOperations = new OperationLedger<TurnResult>(86400000, 10000, process.env.AI_NPC_OPERATIONS_FILE ?? './data/operations.json');
type PaidResult = { output: Record<string, unknown>; amounts: ReturnType<typeof settlementAmounts>; billing?: BillingHold };
const directOperations = new OperationLedger<PaidResult>(86400000, 10000, process.env.AI_NPC_DIRECT_OPERATIONS_FILE ?? './data/direct-operations.json');
let operationStatus = 'initializing';
void Promise.all([turnOperations.stats(), directOperations.stats()])
  .then(() => { operationStatus = 'ready'; })
  .catch(() => { operationStatus = 'error'; structuredLog('error', 'operation_storage_unavailable', {}); });

const port = Number(process.env.PORT ?? 8787);
export function validatedPublicBaseUrl(value: string, env: Record<string, string | undefined> = process.env) {
  let parsed: URL;
  try { parsed = new URL(value); } catch { throw new Error('public_base_url_invalid'); }
  const loopback = ['127.0.0.1', 'localhost', '::1'].includes(parsed.hostname);
  // The explicit flag, not NODE_ENV, defines an operator-authorized local
  // deployment. Container images commonly run with NODE_ENV=production even
  // when bound to loopback for a same-machine FiveM development server.
  const localDevelopment = env.AI_NPC_LOCAL_DEVELOPMENT === 'true';
  if (parsed.protocol !== 'https:' && !localDevelopment) throw new Error('public_base_url_https_required');
  if (loopback && !localDevelopment) throw new Error('public_base_url_client_unreachable');
  return parsed.toString().replace(/\/$/, '');
}
const publicBaseUrl = validatedPublicBaseUrl(process.env.AI_NPC_PUBLIC_BASE_URL ?? `http://127.0.0.1:${port}`, process.env);
const secret = process.env.AI_NPC_GATEWAY_SECRET ?? process.env.PEAK_AI_NPC_LICENSE_KEY ?? '';
const provider: TextProvider = createTextProvider();
const fallbackProvider = process.env.AI_NPC_FALLBACK_PROVIDER ? createTextProvider(process.env, 'AI_NPC_FALLBACK_PROVIDER') : provider;
type Usage = { window: number; count: number; totalRequests: number; totalInputTokens: number; totalOutputTokens: number; failures: number; totalLatencyMs: number };
type RegisteredServer = { serverId: string; name?: string; version?: string; registeredAt: string; lastSeenAt: string };
type RecentConversation = { serverId: string; npcId: string; sessionId: string; requestId: string; provider: string; latencyMs: number; result: string; createdAt: string; input?: string; output?: string };
const usage = new Map<string, Usage>();
const licenseLimiter = new LicenseRateLimiter();
const servers = new Map<string, RegisteredServer>();
const recentConversations: RecentConversation[] = [];
const managedPaidActive = new Map<string, number>();
const captureAdminTranscripts = process.env.AI_NPC_ADMIN_STORE_TRANSCRIPTS === 'true';
const npcCatalog = new NpcCatalog();
let catalogStatus = 'initializing';
const catalogReady = npcCatalog.initialize().then(() => { catalogStatus = 'ready'; })
  .catch(() => { catalogStatus = 'error'; structuredLog('error', 'catalog_initialization_failed', {}); });
const memoryStore: MemoryStore = process.env.AI_NPC_DATABASE_URL ? new PostgresMemoryStore(process.env.AI_NPC_DATABASE_URL) : new FileMemoryStore();
let memoryStatus = 'ready';
const memoryReady = memoryStore.initialize
  ? (memoryStatus = 'initializing', memoryStore.initialize().then(() => { memoryStatus = 'ready'; }).catch(() => { memoryStatus = 'error'; structuredLog('error', 'memory_initialization_failed', {}); }))
  : Promise.resolve();
let retentionRunning = false;
const retentionTimer = setInterval(() => {
  if (retentionRunning || memoryStatus !== 'ready') return;
  retentionRunning = true;
  void Promise.all([memoryStore.purgeExpired?.(), turnOperations.cleanup(), directOperations.cleanup()])
    .catch(() => structuredLog('error', 'retention_cleanup_failed', {}))
    .finally(() => { retentionRunning = false; });
}, 60000);
retentionTimer.unref();
const residentStore: ResidentStore = process.env.AI_NPC_DATABASE_URL ? new PostgresResidentStore(process.env.AI_NPC_DATABASE_URL) : new FileResidentStore();
let residentStatus = 'ready';
const residentReady = residentStore.initialize
  ? (residentStatus = 'initializing', residentStore.initialize().then(() => { residentStatus = 'ready'; }).catch(() => { residentStatus = 'error'; structuredLog('error', 'resident_initialization_failed', {}); }))
  : Promise.resolve();
const extractionQueue = new MemoryExtractionQueue(provider, fallbackProvider, memoryStore, residentStore, Number(process.env.AI_NPC_MEMORY_CONCURRENCY ?? 4), Number(process.env.AI_NPC_MEMORY_QUEUE_MAX ?? 500), billMemoryExtraction);
const speech: SpeechProvider = createSpeechProvider();
const voiceRegistry = new VoiceRegistry();
let voiceRegistryStatus = 'initializing';
const voiceRegistryReady = voiceRegistry.initialize().then(() => { voiceRegistryStatus = 'ready'; }).catch(() => { voiceRegistryStatus = 'error'; structuredLog('error', 'voice_registry_initialization_failed', {}); });
let speechReadiness = { status: speech.name === 'none' ? 'degraded' : 'configured', provider: speech.name } as Awaited<ReturnType<NonNullable<SpeechProvider['readiness']>>>;
const speechReadinessReady = voiceRegistryReady.then(async () => {
  const profiles = voiceRegistry.profiles('*');
  const defaultProfileId = process.env.AI_NPC_TTS_DEFAULT_PROFILE ?? 'martin-hale';
  if (speech.name === 'elevenlabs-tts' && (!approvedVoice(profiles[defaultProfileId]) || profiles[defaultProfileId].provider !== 'elevenlabs')) {
    speechReadiness = { status: 'degraded', provider: speech.name, error: 'voice_review_required' };
    return;
  }
  if (speech.readiness) speechReadiness = await speech.readiness(Object.fromEntries(Object.entries(profiles).filter(([, record]) => approvedVoice(record) && record.provider === speech.name.replace(/-tts$/, '')).map(([profileId, record]) => [profileId, record.voiceId])), profiles[defaultProfileId]?.voiceId);
});
const audioDelivery = new AudioDelivery(speech, publicBaseUrl, metrics => structuredLog(metrics.errorCode ? 'error' : 'info', 'tts_metrics', { provider: speech.name, ...metrics }));
const usageSettlement = new UsageSettlementClient();
const portalHeartbeat = new PortalHeartbeatClient();
const portalDataDeletion = new PortalDataDeletionClient();
const dataDeletionsInFlight = new Set<string>();
const vision: VisionProvider = createVisionPipeline();
const transcription: TranscriptionProvider = ['openai-compatible', 'openai', 'custom'].includes((process.env.AI_NPC_STT_PROVIDER ?? '').toLowerCase())
  ? new OpenAICompatibleTranscriptionProvider(process.env.AI_NPC_STT_ENDPOINT ?? process.env.AI_NPC_PROVIDER_ENDPOINT ?? 'https://api.openai.com/v1', process.env.AI_NPC_STT_KEY ?? '', process.env.AI_NPC_STT_MODEL ?? 'whisper-1')
  : new NoopTranscriptionProvider();

function structuredLog(level: 'info' | 'error', event: string, fields: Record<string, unknown>) {
  const line = JSON.stringify({ service: 'advanced-ai-npc', level, event, at: new Date().toISOString(), ...fields });
  if (level === 'error') console.error(line); else console.log(line);
}

function gatewayHealth() {
  // Self-hosted mode: no managed entitlement portal required.
  const managedReady = true;
  // Speech review/provider failures retain text service and its normal authority gates.
  const healthy = operationStatus === 'ready' && catalogStatus === 'ready' && memoryStatus === 'ready' && residentStatus === 'ready';
  const reason = operationStatus !== 'ready' ? 'operations_unavailable'
    : catalogStatus !== 'ready' ? 'catalog_unavailable'
    : memoryStatus === 'error' ? 'memory_unavailable'
    : residentStatus === 'error' ? 'residents_unavailable'
    : !managedReady ? 'managed_saas_not_ready'
    : voiceRegistryStatus === 'error' ? 'voice_registry_unavailable'
    : speech.name === 'elevenlabs-tts' && speechReadiness.status !== 'ready' ? 'speech_not_ready'
    : undefined;
  return { healthy, reason };
}

function rankMemories(memories: MemoryRecord[], input: string, relationship: RelationshipRecord) {
  const words = new Set(input.toLowerCase().match(/[a-z0-9]{3,}/g) ?? []);
  const relationshipTags = new Set(relationship.tags);
  const now = Date.now();
  return memories.map(memory => {
    const tags = memory.tags ?? [];
    const relevance = tags.reduce((sum, tag) => sum + (words.has(tag.toLowerCase()) ? 1 : 0), 0)
      + (memory.text.toLowerCase().match(/[a-z0-9]{3,}/g) ?? []).reduce((sum, word) => sum + (words.has(word) ? .15 : 0), 0);
    const context = tags.reduce((sum, tag) => sum + (relationshipTags.has(tag) ? .35 : 0), 0);
    const ageDays = Math.max(0, (now - Date.parse(memory.createdAt)) / 86_400_000);
    const recency = Math.max(0, 1 - ageDays / 365);
    return { memory, score: memory.importance * 4 + Math.min(3, relevance) + context + recency + (memory.unresolved ? 2 : 0) };
  }).sort((a, b) => b.score - a.score).slice(0, 16).map(value => value.memory);
}
const uploads = new UploadStore();
const uploadCleanupTimer = setInterval(() => uploads.purgeExpired(), 10_000);
uploadCleanupTimer.unref();
const entitlementValidator = new ManagedEntitlementValidator();
const entitlementCleanupTimer = setInterval(() => {
  entitlementValidator.purgeExpired();
  licenseLimiter.purgeExpired();
}, 60_000);
entitlementCleanupTimer.unref();
const requestLicenses = new WeakMap<IncomingMessage, LicenseValidationResult>();
async function authorized(req: IncomingMessage): Promise<boolean> {
  const extracted = extractLicenseKey(req);
  if (!extracted) {
    if (!secret && !process.env.AI_NPC_ENTITLEMENT_URL) return process.env.NODE_ENV !== 'production';
    return false;
  }
  const validation = await validateRequestLicense(extracted, extractServerId(req), entitlementValidator);
  requestLicenses.set(req, validation);
  return validation.valid;
}

function requestScopeMatches(req: IncomingMessage, claimedServerId: unknown): boolean {
  const bound = requestLicenses.get(req)?.serverId;
  return !bound || (typeof claimedServerId === 'string' && claimedServerId === bound);
}

async function acquireManagedPaidSlot(req: IncomingMessage, serverId: string, feature: ManagedPaidFeature): Promise<() => void> {
  requestSignal(req).throwIfAborted();
  if (requestLicenses.get(req)?.source !== 'managed') return () => {};
  const refreshed = await validateRequestLicense(extractLicenseKey(req), serverId, entitlementValidator);
  requestSignal(req).throwIfAborted();
  requestLicenses.set(req, refreshed);
  if (!refreshed.valid) throw new Error(refreshed.reason ?? 'entitlement_invalid');
  if (!managedFeatureAvailable(refreshed, feature)) throw new Error(`${feature}_feature_unavailable`);
  const rate = licenseLimiter.check(`${refreshed.info?.key ?? 'managed'}:${serverId}`, refreshed.info?.rateLimit ?? 120);
  if (!rate.allowed) throw new Error(`managed_rate_limit:${rate.resetMs}`);
  const concurrencyLimit = refreshed.info?.concurrencyLimit ?? 1;
  const active = managedPaidActive.get(serverId) ?? 0;
  if (active >= concurrencyLimit) throw new Error('managed_concurrency_limit');
  managedPaidActive.set(serverId, active + 1);
  let released = false;
  return () => {
    if (released) return;
    released = true;
    const remaining = (managedPaidActive.get(serverId) ?? 1) - 1;
    if (remaining > 0) managedPaidActive.set(serverId, remaining); else managedPaidActive.delete(serverId);
  };
}

async function settleManaged(req: IncomingMessage, value: Omit<UsageSettlement, 'eventId'>, billing?: BillingHold) {
  if (requestLicenses.get(req)?.source !== 'managed') return;
  if (!billing || billing.serverId !== value.serverId || billing.endpoint !== value.endpoint) throw new Error('usage_reservation_missing');
  await usageSettlement.settleReserved({ ...billing, ...value }, requestSignal(req));
}

function reservationContext(req: IncomingMessage, serverId: string, endpoint: UsageSettlement['endpoint'], operationId: string,
  fingerprint: string, bounds: ReturnType<typeof settlementAmounts>): BillingHold | undefined {
  return requestLicenses.get(req)?.source === 'managed' ? { eventId: billingEventId(serverId, endpoint, operationId), serverId, endpoint,
    ownerId: randomUUID(), fingerprint, ...bounds } : undefined;
}

async function withReservation<T extends object>(req: IncomingMessage, context: unknown, produce: () => Promise<T>): Promise<T & { billing?: BillingHold }> {
  if (requestLicenses.get(req)?.source !== 'managed') return produce();
  const billing = context as BillingHold | undefined;
  if (!billing?.eventId || !billing.ownerId || !billing.fingerprint) throw new Error('usage_reservation_missing');
  try {
    await usageSettlement.reserve(billing, requestSignal(req));
    requestSignal(req).throwIfAborted();
    const result = await produce();
    requestSignal(req).throwIfAborted();
    return { ...result, billing };
  } catch (error) {
    // No usable result was committed. Peak absorbs any provider fee. A release
    // also fences a reserve whose successful reply was lost in transport.
    try { await usageSettlement.release(billing); }
    catch { structuredLog('error', 'usage_reservation_release_unavailable', { serverId: billing.serverId, eventId: billing.eventId }); }
    throw error;
  }
}

function turnTokenReservation(turn: TurnInput) {
  // UTF-8 byte bound includes system instructions, every possible history
  // message and tool schema. Output is separately capped by all adapters.
  return Buffer.byteLength(JSON.stringify([composeSystemPrompt(turn), turn.history, turn.input,
    providerTools(turn.allowedTools, turn.toolSchemas)]), 'utf8') + 1024;
}

function billedTokens(req: IncomingMessage, result: TurnOutput, fallback: number) {
  const input = result.usage?.inputTokens, output = result.usage?.outputTokens;
  if (Number.isSafeInteger(input) && input! >= 0 && Number.isSafeInteger(output) && output! >= 0 && input! + output! > 0) return input! + output!;
  if (requestLicenses.get(req)?.source === 'managed') throw new Error('provider_usage_missing');
  return fallback;
}

async function billMemoryExtraction(turn: TurnInput, work: () => Promise<TurnOutput>) {
  if (!process.env.AI_NPC_ENTITLEMENT_URL?.trim()) return work();
  const operationId = `memory:${turnOperationKey(turn)}`;
  const fingerprint = createHash('sha256').update(JSON.stringify(turn)).digest('hex');
  const bounds = settlementAmounts(0, turnTokenReservation(turn));
  const candidate: BillingHold = { ...bounds, serverId: turn.serverId, endpoint: 'turn',
    eventId: billingEventId(turn.serverId, 'turn', operationId), ownerId: randomUUID(), fingerprint };
  await directOperations.run(operationId, async context => {
    const billing = context as BillingHold;
    try {
      await usageSettlement.reserve(billing);
      const result = await work();
      const input = result.usage?.inputTokens, output = result.usage?.outputTokens;
      if (!Number.isSafeInteger(input) || input! < 0 || !Number.isSafeInteger(output) || output! < 0
        || input! + output! <= 0 || input! + output! > billing.llmTokens) throw new Error('provider_usage_invalid');
      return { output: { memoryCompleted: true }, amounts: settlementAmounts(0, input! + output!), billing };
    } catch (error) {
      try { await usageSettlement.release(billing); }
      catch { structuredLog('error', 'usage_reservation_release_unavailable', { serverId: billing.serverId, eventId: billing.eventId }); }
      throw error;
    }
  }, async value => {
    if (!value.billing) throw new Error('usage_reservation_missing');
    await usageSettlement.settleReserved({ ...value.billing, ...value.amounts });
  }, fingerprint, candidate);
}

const requestSignals = new WeakMap<IncomingMessage, AbortSignal>();
function requestDeadlineMs(req: IncomingMessage) {
  const configured = Number(process.env.AI_NPC_REQUEST_TIMEOUT_MS ?? 30000);
  const bounded = Number.isFinite(configured) ? Math.max(15000, Math.min(120000, Math.trunc(configured))) : 30000;
  // Dialogue includes provider inference and optional speech synthesis. Small
  // control/readiness requests keep a shorter independent transport ceiling.
  return req.url?.split('?')[0] === '/v1/turn' ? bounded : Math.min(bounded, 20000);
}
function requestSignal(req: IncomingMessage) { return requestSignals.get(req) ?? AbortSignal.timeout(requestDeadlineMs(req)); }
async function paidOperation(req: IncomingMessage, serverId: string, endpoint: UsageSettlement['endpoint'], payload: Record<string, unknown>, bounds: ReturnType<typeof settlementAmounts>, produce: () => Promise<PaidResult>) {
  // Hash raw payload before enrichment; it is stable across transport retries and
  // never persists microphone/screenshot bytes or install credentials.
  const operationId = createHash('sha256').update(JSON.stringify([serverId, endpoint, payload])).digest('hex');
  const operation = await directOperations.run(operationId, async context => {
    requestSignal(req).throwIfAborted();
    const release = await acquireManagedPaidSlot(req, serverId, endpoint === 'speech' ? 'tts' : endpoint === 'transcribe' ? 'stt' : 'vision');
    try { return await withReservation(req, context, produce); }
    finally { release(); }
  }, value => settleManaged(req, { serverId, endpoint, ...value.amounts }, value.billing), operationId,
  reservationContext(req, serverId, endpoint, operationId, operationId, bounds));
  return operation.value.output;
}

async function body(req: IncomingMessage): Promise<unknown> {
  return JSON.parse((await rawBody(req, 200_000)).toString('utf8') || '{}');
}

async function rawBody(req: IncomingMessage, maxBytes: number) {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    size += buffer.length;
    if (size > maxBytes) throw new Error('body_too_large');
    chunks.push(buffer);
  }
  return Buffer.concat(chunks);
}

function send(res: ServerResponse, status: number, data: unknown) { if (res.writableEnded || res.destroyed) return; res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' }); res.end(JSON.stringify(data)); }
function sendRequestError(res: ServerResponse, error: unknown, fallback: string) {
  if (error instanceof SyntaxError) return send(res, 400, { error: 'invalid_json' });
  const message = error instanceof Error ? error.message : fallback;
  if (message === 'upload_expired' || message === 'speech_audio_expired') return send(res, 410, { error: message });
  if (message === 'body_too_large') return send(res, 413, { error: message });
  if (message.endsWith('_feature_unavailable')) return send(res, 403, { error: message });
  if (message === 'managed_concurrency_limit') return send(res, 429, { error: message, retryAfterMs: 250 });
  if (message.startsWith('managed_rate_limit:')) return send(res, 429, { error: 'managed_rate_limit', retryAfterMs: Number(message.split(':')[1]) || 1000 });
  if (message === 'usage_quota_exceeded') return send(res, 402, { error: message });
  if (message === 'operation_payload_conflict' || message === 'usage_settlement_event_conflict') return send(res, 409, { error: message });
  if (message === 'usage_settlement_concurrency_limit' || message === 'usage_settlement_rate_limit') return send(res, 429, { error: message });
  if (message.startsWith('voice_profile_') || message === 'legacy_voice_requires_profile') return send(res, 409, { error: message });
  if (message.startsWith('usage_settlement_') || message.startsWith('entitlement_')) return send(res, 503, { error: message });
  return send(res, 502, { error: message });
}
function sendUpload(res: ServerResponse, status: number, data: unknown) {
  // screenshot-basic uploads from a FiveM NUI origin, so the one-time upload
  // response must be readable cross-origin. The token is unguessable, expires
  // quickly, and can only be consumed once by the authenticated server flow.
  res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store', 'access-control-allow-origin': '*' });
  res.end(JSON.stringify(data));
}
function sendHtml(res: ServerResponse, html: string) { res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' }); res.end(html); }
function validScope(value: unknown, maximum = 200) { return typeof value === 'string' && value.length >= 1 && value.length <= maximum && /^[A-Za-z0-9_.:@-]+$/.test(value); }
function validLocation(value: unknown): value is Vec4 {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const v = value as Record<string, unknown>;
  return ['x','y','z','w'].every(key => typeof v[key] === 'number' && Number.isFinite(v[key])) && Math.abs(v.x as number) <= 100000 && Math.abs(v.y as number) <= 100000 && (v.z as number) >= -1000 && (v.z as number) <= 10000 && Math.abs(v.w as number) <= 360;
}
async function synthesizeIssued(text: string, voice?: string, language?: string, style?: string, options?: SpeechOptions, maximumSeconds = 120) {
  const issued = await audioDelivery.issue(text, voice, language, style, options);
  try {
    const audioSeconds = await audioDelivery.measuredSeconds(issued.audioUrl, options?.signal, maximumSeconds);
    return { ...issued, audioSeconds };
  } catch (error) { audioDelivery.revoke(issued.audioUrl); throw error; }
}

async function describeBilled(req: IncomingMessage, image: string, prompt: string) {
  if (!vision.describeMetered) throw new Error('provider_usage_unavailable');
  const startedAt = Date.now();
  const result = await vision.describeMetered(image, prompt, requestSignal(req));
  if (!Number.isSafeInteger(result.llmTokens) || result.llmTokens <= 0) {
    if (requestLicenses.get(req)?.source === 'managed') throw new Error('provider_usage_missing');
    result.llmTokens = estimatedTextTokens(prompt, result.text);
  }
  if (result.llmTokens > 16384) throw new Error('provider_usage_exceeded');
  structuredLog('info', 'vision_complete', { provider: result.provider, fallbackFrom: result.fallbackFrom, latencyMs: Date.now() - startedAt, promptCharacters: prompt.length, imageBytes: Math.floor(image.length * 0.75) });
  return result;
}

function mergedRelationshipContext(persistent: RelationshipRecord, supplied: unknown) {
  const current = supplied && typeof supplied === 'object' && !Array.isArray(supplied) ? supplied as Record<string, unknown> : {};
  const finiteDimension = (value: unknown) => {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? Math.max(-100, Math.min(100, parsed)) : 0;
  };
  const suppliedSessionScore = current.sessionScore ?? current.score;
  const sessionScore = Number(suppliedSessionScore);
  const recentTreatment = typeof current.recentTreatment === 'string' && /^[a-z][a-z_-]{0,31}$/i.test(current.recentTreatment)
    ? current.recentTreatment.toLowerCase()
    : undefined;
  return {
    score: finiteDimension(persistent.score),
    familiarity: finiteDimension(persistent.familiarity),
    trust: finiteDimension(persistent.trust),
    warmth: finiteDimension(persistent.warmth),
    respect: finiteDimension(persistent.respect),
    fear: finiteDimension(persistent.fear),
    irritation: finiteDimension(persistent.irritation),
    obligation: finiteDimension(persistent.obligation),
    tags: persistent.tags.filter(tag => /^[a-z0-9:_-]{1,64}$/i.test(tag)).slice(-12),
    updatedAt: String(persistent.updatedAt).slice(0, 40),
    ...(Number.isFinite(sessionScore) ? { sessionScore: Math.max(-100, Math.min(100, sessionScore)) } : {}),
    ...(recentTreatment ? { recentTreatment } : {})
  };
}

function contextualDeliveryPreset(turn: TurnInput, fallback: DeliveryPreset = 'neutral'): DeliveryPreset {
  const context = turn.context as Record<string, any>;
  const relationship = context.relationship as Record<string, unknown> | undefined;
  const world = context.environment?.world as Record<string, unknown> | undefined;
  const behavior = context.behavior as Record<string, unknown> | undefined;
  const occupation = String((turn.npc.identity as Record<string, unknown> | undefined)?.occupation ?? '').toLowerCase();
  const archetype = String(turn.npc.archetype ?? context.npc?.archetype ?? '').toLowerCase();
  const treatment = String(relationship?.recentTreatment ?? '').toLowerCase();
  const dimension = (key: string) => {
    const value = Number(relationship?.[key]);
    return Number.isFinite(value) ? value : 0;
  };
  if (behavior?.threatValidated === true || treatment === 'threatening') {
    return archetype === 'gang' || occupation.includes('crew') || occupation.includes('gang') ? 'menacing' : 'nervous';
  }
  if (dimension('fear') >= 4) return 'nervous';
  if (treatment === 'insulting' || dimension('irritation') >= 4 || dimension('respect') <= -4) return 'stern';
  if (treatment === 'respectful' || dimension('warmth') >= 4 || dimension('trust') >= 4) return 'warm';
  const weather = world?.authoritative === true ? String(world?.weather ?? '').toUpperCase() : '';
  if (weather === 'THUNDER' || weather === 'RAIN') return 'urgent';
  const hour = world?.authoritative === true ? Number(world?.hour) : Number.NaN;
  if (Number.isInteger(hour) && (hour >= 23 || hour < 5)) return 'quiet';
  return fallback;
}

function providerStyle(preset: DeliveryPreset) {
  const styles: Record<DeliveryPreset, string> = { neutral: 'naturally', warm: 'warmly', stern: 'sternly', nervous: 'nervously', urgent: 'urgently', quiet: 'quietly', menacing: 'menacing whisper' };
  return speech.name === 'elevenlabs-tts' ? undefined : styles[preset];
}

function resolveTurnVoice(serverId: string, npc: Record<string, unknown>, preset: DeliveryPreset) {
  return resolveVoice(voiceRegistry, speech.name, serverId, npc, preset);
}

const audioCleanupTimer = setInterval(() => audioDelivery.purgeExpired(), 10_000);
audioCleanupTimer.unref();

const adminHtml = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>AI NPC Gateway</title><style>body{font:15px system-ui;max-width:1100px;margin:32px auto;padding:0 18px;background:#0f172a;color:#e2e8f0}input,textarea,button{font:inherit;padding:9px;margin:4px 0;border-radius:7px;border:1px solid #475569;background:#111827;color:#e2e8f0}input,textarea{width:100%;box-sizing:border-box}textarea{min-height:180px;font-family:ui-monospace,monospace}.grid{display:grid;grid-template-columns:1fr 1fr;gap:16px}.card{background:#111827;border:1px solid #334155;border-radius:10px;padding:16px;margin:16px 0}pre{white-space:pre-wrap;overflow:auto;background:#020617;padding:12px;border-radius:7px;min-height:36px}.danger{background:#7f1d1d}.primary{background:#0369a1}@media(max-width:760px){.grid{grid-template-columns:1fr}}</style><h1>Advanced AI NPC Gateway</h1><p>Authenticated operational and NPC catalog dashboard.</p><div class="card"><label>Gateway secret<br><input id="secret" type="password" autocomplete="off"></label><div><button class="primary" onclick="loadAll()">Refresh</button><span id="status"></span></div></div><div class="grid"><section class="card"><h2>Health</h2><pre id="health">loading...</pre></section><section class="card"><h2>Usage</h2><pre id="usage">locked</pre></section></div><section class="card"><h2>Registered servers</h2><pre id="servers">locked</pre></section><section class="card"><h2>NPC catalog</h2><label>Server ID<br><input id="serverId" value="local"></label><label>NPC ID<br><input id="npcId" value="shopkeeper"></label><button onclick="loadNpcs()">Load NPCs</button><button class="primary" onclick="saveNpc()">Save JSON</button><button class="danger" onclick="deleteNpc()">Delete selected NPC</button><textarea id="npcJson" spellcheck="false">{"model":"mp_m_shopkeep_01","coords":{"x":24.4,"y":-1345.2,"z":29.5,"w":266},"identity":{"name":"Martin Hale","occupation":"shopkeeper"},"personality":"Patient and concise.","knowledge":"Use only configured context and tool results.","allowedTools":["get_shop_stock"]}</textarea><pre id="npcs">No NPCs loaded.</pre></section><script>const byId=id=>document.getElementById(id);const headers=()=>({'X-AI-NPC-Secret':byId('secret').value});async function get(path){const r=await fetch(path,{headers:headers()});return {status:r.status,data:await r.json()}}async function loadAll(){byId('health').textContent=JSON.stringify(await fetch('/health').then(r=>r.json()),null,2);const s=await get('/v1/servers');byId('servers').textContent=JSON.stringify(s.data,null,2);const u=await get('/v1/usage');byId('usage').textContent=JSON.stringify(u.data,null,2);await loadNpcs()}async function loadNpcs(){const result=await get('/v1/npcs?serverId='+encodeURIComponent(byId('serverId').value));byId('npcs').textContent=JSON.stringify(result.data,null,2);if(result.data.npcs&&result.data.npcs[0]){byId('npcId').value=result.data.npcs[0].id;byId('npcJson').value=JSON.stringify(result.data.npcs[0].definition,null,2)}}async function saveNpc(){try{const r=await fetch('/v1/npcs/'+encodeURIComponent(byId('serverId').value)+'/'+encodeURIComponent(byId('npcId').value),{method:'PUT',headers:Object.assign({'content-type':'application/json'},headers()),body:byId('npcJson').value});byId('status').textContent=' Save: '+r.status;await loadNpcs()}catch(e){byId('status').textContent=' Invalid JSON'}}async function deleteNpc(){const r=await fetch('/v1/npcs/'+encodeURIComponent(byId('serverId').value)+'/'+encodeURIComponent(byId('npcId').value),{method:'DELETE',headers:headers()});byId('status').textContent=' Delete: '+r.status;await loadNpcs()}loadAll()</script>`;

async function handle(req: IncomingMessage, res: ServerResponse) {
  if (req.url?.split('?')[0] === '/v1/operator/voices') {
    res.setHeader('cache-control', 'no-store');
    if (!operatorAuthorized(req.headers['x-ai-npc-operator-secret'])) return send(res, 401, { error: 'unauthorized' });
    if (voiceRegistryStatus !== 'ready') return send(res, 503, { error: 'voice_registry_unavailable' });
    if (req.method === 'GET') {
      const serverId = new URL(req.url, 'http://localhost').searchParams.get('serverId');
      if (!serverId || serverId.length > 100) return send(res, 400, { error: 'voice_registry_scope_invalid' });
      return send(res, 200, { serverId, profiles: voiceRegistry.reviewStatus(serverId) });
    }
    if (req.method !== 'POST') return send(res, 405, { error: 'method_not_allowed' });
    let value: Record<string, unknown>;
    try { value = (await body(req)) as Record<string, unknown>; } catch { return send(res, 400, { error: 'invalid_json' }); }
    if (!value || typeof value !== 'object' || Array.isArray(value) || typeof value.serverId !== 'string'
      || !value.serverId || value.serverId.length > 100 || typeof value.profileId !== 'string'
      || (value.action !== 'register' && (typeof value.expectedFingerprint !== 'string' || !/^[a-f0-9]{64}$/.test(value.expectedFingerprint)))) return send(res, 400, { error: 'invalid_voice_review_request' });
    try {
      const { serverId, profileId } = value;
      const expectedFingerprint = value.expectedFingerprint as string;
      const review = { reviewedBy: value.reviewedBy as string, evidence: value.evidence as string };
      if (value.action === 'register') {
        if (voiceRegistry.resolve(serverId, profileId)) return send(res, 409, { error: 'voice_profile_already_registered' });
        await voiceRegistry.set(serverId, profileId, value.candidate as ProviderVoiceRecord);
      }
      else if (value.action === 'stage') await voiceRegistry.stage(serverId, profileId, expectedFingerprint, value.candidate as ProviderVoiceRecord);
      else if (value.action === 'approve') await voiceRegistry.approve(serverId, profileId, expectedFingerprint, review);
      else if (value.action === 'reject') await voiceRegistry.reject(serverId, profileId, expectedFingerprint, review);
      else if (value.action === 'rollback' && Number.isSafeInteger(value.targetRevision)) await voiceRegistry.rollback(serverId, profileId, expectedFingerprint, value.targetRevision as number, review);
      else return send(res, 400, { error: 'invalid_voice_review_action' });
      return send(res, 200, { ok: true, profiles: voiceRegistry.reviewStatus(serverId) });
    } catch (error) {
      const code = error instanceof Error ? error.message : '';
      const permitted = new Set(['voice_registry_record_invalid', 'voice_registry_scope_invalid', 'voice_review_scope_not_found', 'voice_review_conflict', 'voice_review_evidence_required', 'voice_candidate_already_pending', 'voice_revision_history_full', 'voice_rollback_revision_not_approved', 'voice_recast_requires_review']);
      return send(res, permitted.has(code) ? 409 : 500, { error: permitted.has(code) ? code : 'voice_review_failed' });
    }
  }
  if (req.method === 'GET' && req.url === '/v1/operator/operations') {
    res.setHeader('cache-control', 'no-store');
    if (!operatorAuthorized(req.headers['x-ai-npc-operator-secret'])) return send(res, 401, { error: 'unauthorized' });
    const [turns, direct] = await Promise.all([turnOperations.stats(), directOperations.stats()]);
    return send(res, 200, { turns, direct });
  }
  if (req.method === 'GET' && req.url === '/v1/operator/unresolved') {
    res.setHeader('cache-control', 'no-store');
    if (!operatorAuthorized(req.headers['x-ai-npc-operator-secret'])) return send(res, 401, { error: 'unauthorized' });
    const [turns, direct] = await Promise.all([turnOperations.listUnresolved(), directOperations.listUnresolved()]);
    return send(res, 200, { turns, direct });
  }
  if (req.method === 'POST' && req.url === '/v1/operator/reconcile') {
    res.setHeader('cache-control', 'no-store');
    if (!operatorAuthorized(req.headers['x-ai-npc-operator-secret'])) return send(res, 401, { error: 'unauthorized' });
    let value: Record<string, unknown>;
    try { value = (await body(req)) as Record<string, unknown>; } catch { return send(res, 400, { error: 'invalid_json' }); }
    if (!value || typeof value !== 'object' || Array.isArray(value)) return send(res, 400, { error: 'invalid_reconcile_request' });
    const { ledger, key, action } = value;
    if (typeof key !== 'string' || !/^[a-zA-Z0-9:_-]{1,128}$/.test(key)) return send(res, 400, { error: 'invalid_operation_key' });
    if (action !== 'settle' && action !== 'discard') return send(res, 400, { error: 'invalid_reconcile_action' });
    const targetLedger = ledger === 'turns' ? turnOperations : ledger === 'direct' ? directOperations : undefined;
    if (!targetLedger) return send(res, 400, { error: 'invalid_target_ledger' });
    try {
      const result = await targetLedger.reconcile(key, action, undefined, async (paid, context) => {
        const billing = ((paid as PaidResult | TurnResult | undefined)?.billing ?? context) as BillingHold | undefined;
        if (!billing) {
          if (process.env.AI_NPC_ENTITLEMENT_URL?.trim()) throw new Error('usage_reservation_missing');
          return;
        }
        if (action === 'discard') { await usageSettlement.release(billing); return; }
        if (!paid) throw new Error('operation_result_missing');
        const amounts = 'amounts' in paid ? paid.amounts : settlementAmounts(paid.ttsCharacters,
          billedTokens(req, paid.result, 0), paid.synthesizedQualityMode, paid.audioSeconds);
        await usageSettlement.settleReserved({ ...billing, ...amounts });
      });
      return send(res, 200, { ok: true, result });
    } catch (error: any) {
      if (error?.message === 'operation_not_found') return send(res, 404, { error: 'operation_not_found' });
      if (error?.message === 'operation_in_flight') return send(res, 409, { error: 'operation_in_flight' });
      if (error?.message === 'operation_result_missing') return send(res, 409, { error: 'operation_result_missing' });
      return send(res, 500, { error: 'reconciliation_failed' });
    }
  }
  if (req.url === '/v1/operator/data-deletions') {
    res.setHeader('cache-control', 'no-store');
    if (!operatorAuthorized(req.headers['x-ai-npc-operator-secret'])) return send(res, 401, { error: 'unauthorized' });
    if (req.method === 'GET') {
      try { return send(res, 200, { requests: await portalDataDeletion.list() }); }
      catch { return send(res, 503, { error: 'data_requests_unavailable' }); }
    }
    if (req.method !== 'POST') return send(res, 405, { error: 'method_not_allowed' });
    let value: Record<string, unknown>;
    try { value = await body(req) as Record<string, unknown>; } catch { return send(res, 400, { error: 'invalid_json' }); }
    const requestId = typeof value.requestId === 'string' ? value.requestId : '';
    const expectedServerId = typeof value.serverId === 'string' ? value.serverId : '';
    if (!/^[0-9a-f-]{36}$/i.test(requestId) || !validScope(expectedServerId, 100)) return send(res, 400, { error: 'invalid_data_deletion_request' });
    if (memoryStatus !== 'ready' || residentStatus !== 'ready') return send(res, 503, { error: 'hosted_data_unavailable' });
    if (dataDeletionsInFlight.has(requestId)) return send(res, 409, { error: 'data_deletion_in_flight' });
    dataDeletionsInFlight.add(requestId);
    try {
      const pending = await portalDataDeletion.list();
      const request = pending.find(entry => entry.id === requestId && entry.serverId === expectedServerId);
      if (!request) return send(res, 404, { error: 'pending_data_request_not_found' });
      await extractionQueue.blockServer(request.serverId);
      try {
        await Promise.all([memoryReady, residentReady]);
        const [deletedMemoryRecords, deletedResidentKnowledgeRecords] = await Promise.all([
          memoryStore.forgetServer(request.serverId), residentStore.forgetServerKnowledge(request.serverId),
        ]);
        let clearedTransientConversations = 0;
        for (let index = recentConversations.length - 1; index >= 0; index--) {
          if (recentConversations[index].serverId === request.serverId) {
            recentConversations.splice(index, 1); clearedTransientConversations++;
          }
        }
        const completion = await portalDataDeletion.complete(request, {
          deletedMemoryRecords, deletedResidentKnowledgeRecords, clearedTransientConversations,
        });
        structuredLog('info', 'hosted_memory_deletion_completed', { requestId, serverId: request.serverId,
          deletedMemoryRecords, deletedResidentKnowledgeRecords, clearedTransientConversations });
        return send(res, 200, { ok: true, requestId, serverId: request.serverId,
          deletedMemoryRecords, deletedResidentKnowledgeRecords, clearedTransientConversations,
          portalAlreadyCompleted: completion.idempotent });
      } finally { extractionQueue.unblockServer(request.serverId); }
    } catch (error) {
      const message = error instanceof Error ? error.message : '';
      const known = new Set(['data_requests_unavailable', 'data_requests_invalid_response', 'data_request_not_found',
        'data_request_not_pending', 'data_request_completion_failed', 'portal_secret_invalid']);
      structuredLog('error', 'hosted_memory_deletion_failed', { requestId, code: known.has(message) ? message : 'deletion_failed' });
      return send(res, 503, { error: known.has(message) ? message : 'data_deletion_failed' });
    } finally { dataDeletionsInFlight.delete(requestId); }
  }
  if (req.method === 'GET' && req.url === '/health') {
    const { healthy } = gatewayHealth();
    const managedMode = Boolean(process.env.AI_NPC_ENTITLEMENT_URL?.trim());
    return send(res, healthy ? 200 : 503, { ok: healthy, provider: provider.name, speech: speech.name, speechReadiness, voiceRegistry: { status: voiceRegistryStatus, ...voiceRegistry.counts('*') }, audio: audioDelivery.stats(), vision: vision.name, transcription: transcription.name, memory: memoryStatus, residents: residentStatus, extraction: extractionQueue.stats(), managedSaas: { enabled: managedMode, entitlement: entitlementValidator.readiness(), usage: usageSettlement.readiness(), heartbeat: portalHeartbeat.readiness(), dataDeletion: portalDataDeletion.readiness(), ready: !managedMode || (entitlementValidator.readiness().ready && usageSettlement.readiness().ready && portalHeartbeat.readiness().ready && portalDataDeletion.readiness().ready), quotaBalanceCache: 'disabled' }, version: '0.4.0' });
  }
  if (req.method === 'GET' && req.url === '/admin') return sendHtml(res, modernAdminHtml);
  const audioMatch = req.method === 'GET' ? req.url?.match(/^\/v1\/audio\/([A-Za-z0-9]{32})$/) : undefined;
  if (audioMatch) {
    if (!await audioDelivery.serve(req, res, audioMatch[1])) return send(res, 404, { error: 'audio_not_found' });
    return;
  }
  if (req.method === 'GET' && req.url === '/v1/usage') {
    if (!await authorized(req)) return send(res, 401, { error: 'unauthorized' });
    const boundServerId = requestLicenses.get(req)?.serverId;
    return send(res, 200, { servers: [...usage.entries()].filter(([serverId]) => !boundServerId || serverId === boundServerId).map(([serverId, value]) => ({ serverId, windowStartedAt: new Date(value.window).toISOString(), requestsInWindow: value.count, totalRequests: value.totalRequests, totalInputTokens: value.totalInputTokens, totalOutputTokens: value.totalOutputTokens, failures: value.failures, averageLatencyMs: value.totalRequests ? Math.round(value.totalLatencyMs / value.totalRequests) : 0 })) });
  }
  if (req.method === 'GET' && req.url === '/v1/servers') {
    if (!await authorized(req)) return send(res, 401, { error: 'unauthorized' });
    const boundServerId = requestLicenses.get(req)?.serverId;
    return send(res, 200, { servers: [...servers.values()].filter(server => !boundServerId || server.serverId === boundServerId) });
  }
  if (req.method === 'GET' && req.url?.startsWith('/v1/conversations?')) {
    if (!await authorized(req)) return send(res, 401, { error: 'unauthorized' });
    const serverId = new URL(req.url, 'http://localhost').searchParams.get('serverId') ?? '';
    if (!serverId || serverId.length > 100) return send(res, 400, { error: 'invalid_server_id' });
    if (!requestScopeMatches(req, serverId)) return send(res, 403, { error: 'server_scope_mismatch' });
    return send(res, 200, { conversations: recentConversations.filter(turn => turn.serverId === serverId).slice(-100).reverse(), transcriptCapture: captureAdminTranscripts });
  }
  if (req.method === 'GET' && req.url === '/v1/settings') {
    if (!await authorized(req)) return send(res, 401, { error: 'unauthorized' });
    return send(res, 200, {
      transcriptCapture: captureAdminTranscripts,
      memoryRetention: 'per-turn server policy',
      audioTokenTtlSeconds: 60,
      screenshotTtlSeconds: 30,
      maxResponseCharacters: Number(process.env.AI_NPC_MAX_RESPONSE_CHARACTERS ?? 1200),
      maxTtsCharacters: Number(process.env.AI_NPC_TTS_MAX_CHARACTERS ?? 1200),
      configurationSource: 'deployment environment'
    });
  }
  if (req.method === 'GET' && req.url?.startsWith('/v1/residents?')) {
    if (!await authorized(req)) return send(res, 401, { error: 'unauthorized' });
    const query = new URL(req.url, 'http://localhost').searchParams;
    const serverId = query.get('serverId') ?? '';
    if (!validScope(serverId, 100)) return send(res, 400, { error: 'invalid_server_id' });
    if (!requestScopeMatches(req, serverId)) return send(res, 403, { error: 'server_scope_mismatch' });
    await residentReady;
    const residents = await residentStore.list(serverId, query.get('archived') === 'true');
    return send(res, 200, { residents, stats: { ...(await residentStore.stats(serverId)), extractionQueue: extractionQueue.stats() } });
  }
  if (req.method === 'POST' && req.url === '/v1/residents/resolve') {
    if (!await authorized(req)) return send(res, 401, { error: 'unauthorized' });
    try {
      await residentReady;
      const value = await body(req) as Record<string, unknown>;
      if (!requestScopeMatches(req, value.serverId)) return send(res, 403, { error: 'server_scope_mismatch' });
      const ageBand=typeof value.ageBand==='string'?value.ageBand:undefined;
      if (!validScope(value.serverId,100) || !validScope(value.characterId) || typeof value.model !== 'string' || value.model.length > 80 || !validLocation(value.location) || !Number.isInteger(value.bucket) || (value.residentId !== undefined && !validScope(value.residentId)) || (ageBand!==undefined&&!['young adult','adult','middle-aged','older adult'].includes(ageBand))) return send(res,400,{error:'invalid_resident'});
      let voice;
      try { voice = residentVoiceAssignment(value.voice)?.profile; } catch { return send(res, 400, { error: 'invalid_resident_voice' }); }
      const resolved = await residentStore.resolve({ serverId:value.serverId as string,characterId:value.characterId as string,residentId:value.residentId as string|undefined,model:value.model,gender:typeof value.gender==='string'?value.gender:undefined,ageBand,location:value.location,bucket:value.bucket as number,appearance:value.appearance as any,voice });
      resolved.knowledge = await residentStore.noteMeeting(value.serverId as string,resolved.resident.residentId,value.characterId as string,false);
      return send(res,200,resolved);
    } catch(error){return sendRequestError(res,error,'resident_resolve_failed');}
  }
  if (req.method === 'POST' && req.url === '/v1/residents/knowledge') {
    if (!await authorized(req)) return send(res,401,{error:'unauthorized'});
    const value=await body(req) as Record<string,unknown>;
    if(!requestScopeMatches(req,value.serverId))return send(res,403,{error:'server_scope_mismatch'});
    if(!validScope(value.serverId,100)||!validScope(value.residentId)||!validScope(value.characterId))return send(res,400,{error:'invalid_resident_scope'});
    await residentReady;
    const knowledge=value.revealName===true?await residentStore.revealName(value.serverId as string,value.residentId as string,value.characterId as string):await residentStore.noteMeeting(value.serverId as string,value.residentId as string,value.characterId as string,value.playerNameKnown===true);
    return send(res,200,{knowledge});
  }
  if (req.method === 'POST' && req.url === '/v1/residents/observe') {
    if(!await authorized(req))return send(res,401,{error:'unauthorized'});const value=await body(req) as Record<string,unknown>;
    if(!requestScopeMatches(req,value.serverId))return send(res,403,{error:'server_scope_mismatch'});
    if(!validScope(value.serverId,100)||!validScope(value.residentId)||!validLocation(value.location))return send(res,400,{error:'invalid_resident_observation'});
    await residentReady;return send(res,200,{resident:await residentStore.observe(value.serverId as string,value.residentId as string,value.location,typeof value.activity==='string'?value.activity:undefined,typeof value.mood==='string'?value.mood:undefined)});
  }
  if (req.method === 'POST' && req.url === '/v1/residents/simulate') {
    if(!await authorized(req))return send(res,401,{error:'unauthorized'});const value=await body(req) as Record<string,unknown>;
    if(!requestScopeMatches(req,value.serverId))return send(res,403,{error:'server_scope_mismatch'});
    if(!validScope(value.serverId,100))return send(res,400,{error:'invalid_server_id'});
    const suppliedWorld=value.world;
    let world: {hour?:number;minute?:number;weather?:string}|undefined;
    if(suppliedWorld!==undefined){
      if(!suppliedWorld||typeof suppliedWorld!=='object'||Array.isArray(suppliedWorld))return send(res,400,{error:'invalid_resident_world'});
      const candidate=suppliedWorld as Record<string,unknown>;
      if(!Number.isInteger(candidate.hour)||Number(candidate.hour)<0||Number(candidate.hour)>23
        ||!Number.isInteger(candidate.minute)||Number(candidate.minute)<0||Number(candidate.minute)>59
        ||typeof candidate.weather!=='string'||!/^[A-Z_]{3,20}$/.test(candidate.weather))return send(res,400,{error:'invalid_resident_world'});
      world={hour:Number(candidate.hour),minute:Number(candidate.minute),weather:candidate.weather};
    }
    await residentReady;const residents=await residentStore.simulate(value.serverId as string,new Date(),world);return send(res,200,{residents,stats:{...(await residentStore.stats(value.serverId as string)),extractionQueue:extractionQueue.stats()}});
  }
  if (req.method === 'POST' && req.url === '/v1/residents/lifecycle') {
    if(!await authorized(req))return send(res,401,{error:'unauthorized'});const value=await body(req) as Record<string,unknown>;const event=String(value.event??'');
    if(!requestScopeMatches(req,value.serverId))return send(res,403,{error:'server_scope_mismatch'});
    if(!validScope(value.serverId,100)||!validScope(value.residentId)||!['death','recover','archive','activate','respawn','pin','unpin'].includes(event))return send(res,400,{error:'invalid_resident_lifecycle'});const recoverySeconds=typeof value.recoverySeconds==='number'&&Number.isFinite(value.recoverySeconds)?Math.max(60,Math.min(86400,Math.trunc(value.recoverySeconds))):1800;await residentReady;return send(res,200,{resident:await residentStore.lifecycle(value.serverId as string,value.residentId as string,event as any,recoverySeconds)});
  }
  if (req.method === 'POST' && req.url === '/v1/residents/forget') {
    if(!await authorized(req))return send(res,401,{error:'unauthorized'});const value=await body(req) as Record<string,unknown>;
    if(!requestScopeMatches(req,value.serverId))return send(res,403,{error:'server_scope_mismatch'});
    if(!validScope(value.serverId,100)||!validScope(value.residentId)||!validScope(value.characterId))return send(res,400,{error:'invalid_resident_scope'});await residentReady;const identity=await residentStore.forgetCharacter(value.serverId as string,value.residentId as string,value.characterId as string);const memory=await memoryStore.forget(value.serverId as string,value.residentId as string,value.characterId as string);return send(res,200,{deleted:identity+memory});
  }
  if (req.method === 'DELETE' && req.url?.startsWith('/v1/residents/')) {
    if(!await authorized(req))return send(res,401,{error:'unauthorized'});const parts=req.url.split('/').filter(Boolean);const serverId=decodeURIComponent(parts[2]??''),residentId=decodeURIComponent(parts.slice(3).join('/'));
    if(!requestScopeMatches(req,serverId))return send(res,403,{error:'server_scope_mismatch'});
    if(!validScope(serverId,100)||!validScope(residentId))return send(res,400,{error:'invalid_resident_scope'});await residentReady;return send(res,200,{deleted:await residentStore.retire(serverId,residentId)});
  }
  if (req.method === 'GET' && req.url?.startsWith('/v1/npcs?')) {
    if (!await authorized(req)) return send(res, 401, { error: 'unauthorized' });
    const serverId = new URL(req.url, 'http://localhost').searchParams.get('serverId') ?? '';
    if (!serverId || serverId.length > 100) return send(res, 400, { error: 'invalid_server_id' });
    if (!requestScopeMatches(req, serverId)) return send(res, 403, { error: 'server_scope_mismatch' });
    await catalogReady;
    return send(res, 200, { npcs: await npcCatalog.list(serverId) });
  }
  const npcMatch = req.url?.match(/^\/v1\/npcs\/([^/]+)\/([a-zA-Z0-9_-]{1,64})$/);
  if (npcMatch && req.method === 'PUT') {
    if (!await authorized(req)) return send(res, 401, { error: 'unauthorized' });
    try {
      const serverId = decodeURIComponent(npcMatch[1]);
      if (!requestScopeMatches(req, serverId)) return send(res, 403, { error: 'server_scope_mismatch' });
      const value = await body(req);
      if (!validNpcDefinition(npcMatch[2], value)) return send(res, 400, { error: 'invalid_npc_definition' });
      await catalogReady;
      return send(res, 200, { npc: await npcCatalog.save(serverId, npcMatch[2], value as Record<string, unknown>) });
    } catch { return send(res, 400, { error: 'invalid_npc_definition' }); }
  }
  if (npcMatch && req.method === 'DELETE') {
    if (!await authorized(req)) return send(res, 401, { error: 'unauthorized' });
    if (!requestScopeMatches(req, decodeURIComponent(npcMatch[1]))) return send(res, 403, { error: 'server_scope_mismatch' });
    await catalogReady;
    return send(res, 200, { deleted: await npcCatalog.remove(decodeURIComponent(npcMatch[1]), npcMatch[2]) });
  }
  if (req.method === 'POST' && req.url === '/v1/register') {
    if (!await authorized(req)) return send(res, 401, { error: 'unauthorized' });
    try {
      const value = await body(req) as Record<string, unknown>;
      const serverId = String(value.serverId ?? '');
      if (!requestScopeMatches(req, serverId)) return send(res, 403, { error: 'server_scope_mismatch' });
      if (!serverId || serverId.length > 100) return send(res, 400, { error: 'invalid_server_id' });
      const now = new Date().toISOString();
      const existing = servers.get(serverId);
      servers.set(serverId, { serverId, name: typeof value.name === 'string' ? value.name.slice(0, 120) : existing?.name, version: typeof value.version === 'string' ? value.version.slice(0, 32) : existing?.version, registeredAt: existing?.registeredAt ?? now, lastSeenAt: now });
      if (requestLicenses.get(req)?.source === 'managed') {
        const health = gatewayHealth();
        const resourceVersion = servers.get(serverId)?.version;
        void portalHeartbeat.send({ serverId, status: health.healthy && !health.reason ? 'ready' : 'degraded', ...(health.reason ? { reason: health.reason } : {}), ...(resourceVersion ? { resourceVersion } : {}) })
          .catch(error => structuredLog('error', 'portal_heartbeat_failed', { serverId, error: error instanceof Error ? error.message : 'heartbeat_error' }));
      }
      return send(res, 200, { ok: true, server: servers.get(serverId) });
    } catch { return send(res, 400, { error: 'invalid_registration' }); }
  }
  if (req.method === 'POST' && req.url === '/v1/memory/delete') {
    if (!await authorized(req)) return send(res, 401, { error: 'unauthorized' });
    try {
      await memoryReady;
      const value = await body(req) as Record<string, unknown>;
      const serverId = String(value.serverId ?? '');
      if (!requestScopeMatches(req, serverId)) return send(res, 403, { error: 'server_scope_mismatch' });
      const npcId = String(value.npcId ?? '');
      const characterId = String(value.characterId ?? '');
      if (!serverId || !npcId || !characterId || serverId.length > 100 || npcId.length > 100 || characterId.length > 200) return send(res, 400, { error: 'invalid_memory_scope' });
      return send(res, 200, { deleted: await memoryStore.forget(serverId, npcId, characterId) });
    } catch { return send(res, 503, { error: 'memory_unavailable' }); }
  }
  if (req.method === 'POST' && req.url === '/v1/speech') {
    if (!await authorized(req)) return send(res, 401, { error: 'unauthorized' });
    let releasePaidSlot: (() => void) | undefined;
    let issuedAudioUrl: string | undefined;
    try {
      const value = await body(req) as Record<string, unknown>;
      const serverId = String(value.serverId ?? '');
      if (!requestScopeMatches(req, serverId)) return send(res, 403, { error: 'server_scope_mismatch' });
      const sessionId = String(value.sessionId ?? '');
      const text = String(value.text ?? '').trim();
      const voiceProfileId = typeof value.voiceProfileId === 'string' && value.voiceProfileId.length <= 64 ? value.voiceProfileId : undefined;
      const legacyVoice = typeof value.voice === 'string' && value.voice.length <= 160 ? value.voice : undefined;
      const legacyProvider = typeof value.provider === 'string' ? value.provider : undefined;
      const legacyPreset = typeof value.style === 'string' ? ({ warmly: 'warm', warm: 'warm', sternly: 'stern', nervous: 'nervous', nervously: 'nervous', urgently: 'urgent', quietly: 'quiet', 'menacing whisper': 'menacing' } as Record<string, DeliveryPreset>)[value.style.toLowerCase()] : undefined;
      const requestedPreset = typeof value.deliveryPreset === 'string' && ['neutral','warm','stern','nervous','urgent','quiet','menacing'].includes(value.deliveryPreset) ? value.deliveryPreset as DeliveryPreset : legacyPreset ?? 'neutral';
      const language = typeof value.language === 'string' && /^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,2}$/.test(value.language) ? value.language : undefined;
      const model = typeof value.model === 'string' && value.model.length <= 80 ? value.model : undefined;
      const format = typeof value.output_format === 'string' ? value.output_format : typeof value.format === 'string' ? value.format : undefined;
      const vsRaw = value.voice_settings ?? value.voiceSettings;
      const voiceSettings = vsRaw && typeof vsRaw === 'object' ? vsRaw as any : undefined;
      const resolvedVoice = resolveTurnVoice(serverId, { voice: { voiceProfileId, voice: legacyVoice, provider: legacyProvider, language, qualityMode: value.qualityMode } }, requestedPreset);
      const options: SpeechOptions = { ...(model ? { model } : {}), ...(format ? { format } : {}), ...(voiceSettings ? { voiceSettings } : {}), qualityMode: resolvedVoice.qualityMode, deliveryPreset: requestedPreset, signal: requestSignal(req) };
      const maximum = Number(process.env.AI_NPC_TTS_MAX_CHARACTERS ?? process.env.AI_NPC_MAX_RESPONSE_CHARACTERS ?? 1200);
      if (!serverId || serverId.length > 100 || sessionId.length < 16 || sessionId.length > 160 || !text || text.length > maximum) return send(res, 400, { error: 'invalid_speech_request' });
      if (speech.name === 'none') return send(res, 503, { error: 'speech_not_configured' });
      const speechBounds = settlementAmounts(text.length, 0, resolvedVoice.qualityMode, 120);
      if (requestLicenses.get(req)?.source === 'managed') speechBounds.voiceSeconds = Math.min(speechBounds.voiceSeconds, requestLicenses.get(req)?.info?.remainingVoiceSeconds ?? 0);
      const output = await paidOperation(req, serverId, 'speech', value, speechBounds, async () => {
        const issued = await synthesizeIssued(text, resolvedVoice.voice, resolvedVoice.language, providerStyle(requestedPreset), options, speechBounds.voiceSeconds / (resolvedVoice.qualityMode === 'quality' ? 2 : 1));
        issuedAudioUrl = issued.audioUrl;
        const utteranceId = randomUUID();
        return { output: { utteranceId, audioUrl: issued.audioUrl, audio: { utteranceId, url: issued.audioUrl, expiresAt: issued.expiresAt, contentType: issued.contentType }, provider: speech.name, voiceProfileId: resolvedVoice.profileId, deliveryPreset: requestedPreset }, amounts: settlementAmounts(text.length, 0, resolvedVoice.qualityMode, issued.audioSeconds) };
      });
      if (typeof output.audioUrl === 'string' && !audioDelivery.has(output.audioUrl)) throw new Error('speech_audio_expired');
      return send(res, 200, output);
    } catch (error) {
      // Keep the opaque audio alive for a settlement retry; its normal TTL applies.
      if (issuedAudioUrl && !(error instanceof Error && error.message.startsWith('usage_'))) audioDelivery.revoke(issuedAudioUrl);
      return sendRequestError(res, error, 'speech_error');
    } finally { releasePaidSlot?.(); }
  }
  if (req.method === 'POST' && (req.url === '/v1/transcribe' || req.url === '/v1/transcript')) {
    if (!await authorized(req)) return send(res, 401, { error: 'unauthorized' });
    try {
      const value = JSON.parse((await rawBody(req, req.url === '/v1/transcribe' ? 8_100_000 : 200_000)).toString('utf8') || '{}') as Record<string, unknown>;
      if (!requestScopeMatches(req, value.serverId)) return send(res, 403, { error: 'server_scope_mismatch' });
      if (req.url === '/v1/transcript') {
        const text = String(value.text ?? '').trim();
        if (typeof value.serverId !== 'string' || typeof value.sessionId !== 'string' || !text || text.length > 500) return send(res, 400, { error: 'invalid_transcript' });
        return send(res, 200, { text, serverId: value.serverId, sessionId: value.sessionId, source: 'external-transcript' });
      }
      const audioDataUrl = value.audioDataUrl;
      if (typeof value.serverId !== 'string' || value.serverId.length < 1 || value.serverId.length > 100 || typeof value.sessionId !== 'string' || value.sessionId.length < 16 || value.sessionId.length > 160) return send(res, 400, { error: 'invalid_transcription_scope' });
      if (!validateAudioDataUrl(audioDataUrl)) return send(res, 400, { error: 'invalid_audio' });
      if (transcription.name === 'none') return send(res, 503, { error: 'transcription_not_configured' });
      const decoded = audioDataUrlBytes(audioDataUrl as string);
      let voiceSeconds: number;
      try { voiceSeconds = Math.ceil(await measuredAudioSeconds(decoded.bytes, decoded.contentType, { signal: requestSignal(req), maximumSeconds: 120, rejectSilence: true })); }
      catch (error) {
        if (error instanceof Error && ['audio_measurement_invalid', 'audio_measurement_silent', 'audio_duration_exceeded'].includes(error.message)) return send(res, 400, { error: 'invalid_audio' });
        throw error;
      }
      {
        const output = await paidOperation(req, value.serverId, 'transcribe', value, { ttsCharacters: 0, llmTokens: 0, voiceSeconds }, async () => {
          const text = await transcription.transcribe(audioDataUrl as string, typeof value.language === 'string' ? value.language : undefined, requestSignal(req));
          if (!text.trim()) throw new Error('provider_empty_output');
          return { output: { text, provider: transcription.name }, amounts: { ttsCharacters: 0, llmTokens: 0, voiceSeconds } };
        });
        return send(res, 200, output);
      }
    } catch (error) { return sendRequestError(res, error, 'transcription_error'); }
  }
  if (req.method === 'POST' && req.url === '/v1/vision') {
    if (!await authorized(req)) return send(res, 401, { error: 'unauthorized' });
    try {
      const value = JSON.parse((await rawBody(req, 2_100_000)).toString('utf8') || '{}') as Record<string, unknown>;
      if (value.serverId !== undefined && !requestScopeMatches(req, value.serverId)) return send(res, 403, { error: 'server_scope_mismatch' });
      const imageDataUrl = String(value.imageDataUrl ?? '');
      const prompt = String(value.prompt ?? 'Describe only relevant visible gameplay facts.');
      if (!/^data:image\/(png|jpeg|webp);base64,/.test(imageDataUrl) || imageDataUrl.length > 2_000_000) return send(res, 400, { error: 'invalid_image' });
      if (prompt.length < 1 || prompt.length > 500) return send(res, 400, { error: 'invalid_prompt' });
      if (vision.name === 'none') return send(res, 503, { error: 'vision_not_configured' });
      const serverId = String(value.serverId ?? '');
      if (!serverId) return send(res, 400, { error: 'invalid_server_id' });
      {
        const output = await paidOperation(req, serverId, 'vision', value, settlementAmounts(0, 16384), async () => {
          const { text, llmTokens, provider: usedProvider, fallbackFrom } = await describeBilled(req, imageDataUrl, prompt);
          return { output: { text, provider: usedProvider, ...(fallbackFrom ? { fallbackFrom } : {}) }, amounts: settlementAmounts(0, llmTokens) };
        });
        return send(res, 200, output);
      }
    } catch (error) { return sendRequestError(res, error, 'vision_error'); }
  }
  if (req.method === 'POST' && req.url === '/v1/vision/upload-url') {
    if (!await authorized(req)) return send(res, 401, { error: 'unauthorized' });
    try {
      const value = await body(req) as Record<string, unknown>;
      if (!requestScopeMatches(req, value.serverId)) return send(res, 403, { error: 'server_scope_mismatch' });
      if (typeof value.serverId !== 'string' || value.serverId.length < 1 || value.serverId.length > 100 || typeof value.sessionId !== 'string' || value.sessionId.length < 16 || value.sessionId.length > 160) return send(res, 400, { error: 'invalid_upload_scope' });
      const upload = uploads.create(value.serverId, value.sessionId);
      return send(res, 200, { token: upload.token, uploadUrl: `${publicBaseUrl}/v1/vision/upload/${upload.token}`, expiresAt: new Date(upload.expiresAt).toISOString(), maxBytes: 1_500_000 });
    } catch { return send(res, 400, { error: 'invalid_request' }); }
  }
  const uploadMatch = req.method === 'POST' ? req.url?.match(/^\/v1\/vision\/upload\/([A-Za-z0-9_-]+)$/) : undefined;
  if (uploadMatch) {
    try {
      const raw = await rawBody(req, 1_600_000);
      const part = extractMultipartImage(raw, String(req.headers['content-type'] ?? ''));
      if (!part || !uploads.put(uploadMatch[1], part.bytes, part.mime)) return sendUpload(res, 400, { error: 'invalid_or_expired_upload' });
      return sendUpload(res, 200, { ok: true });
    } catch { return sendUpload(res, 413, { error: 'upload_too_large' }); }
  }
  if (req.method === 'POST' && req.url === '/v1/vision/from-upload') {
    if (!await authorized(req)) return send(res, 401, { error: 'unauthorized' });
    try {
      const value = await body(req) as Record<string, unknown>;
      const token = String(value.token ?? '');
      const serverId = String(value.serverId ?? '');
      if (!requestScopeMatches(req, serverId)) return send(res, 403, { error: 'server_scope_mismatch' });
      const sessionId = String(value.sessionId ?? '');
      const prompt = String(value.prompt ?? 'Describe only relevant visible gameplay facts.');
      if (!/^[A-Za-z0-9_-]{40,64}$/.test(token) || serverId.length < 1 || serverId.length > 100 || sessionId.length < 16 || sessionId.length > 160 || prompt.length < 1 || prompt.length > 500) return send(res, 400, { error: 'invalid_request' });
      if (vision.name === 'none') return send(res, 503, { error: 'vision_not_configured' });
      {
        const output = await paidOperation(req, serverId, 'vision', value, settlementAmounts(0, 16384), async () => {
          const upload = uploads.consume(token, serverId, sessionId);
          if (!upload) throw new Error('upload_expired');
          const { text, llmTokens, provider: usedProvider, fallbackFrom } = await describeBilled(req, upload.dataUrl, prompt);
          return { output: { text, provider: usedProvider, ...(fallbackFrom ? { fallbackFrom } : {}) }, amounts: settlementAmounts(0, llmTokens) };
        });
        return send(res, 200, output);
      }
    } catch (error) { return sendRequestError(res, error, 'vision_error'); }
  }
  if (req.method !== 'POST' || req.url !== '/v1/turn') return send(res, 404, { error: 'not_found' });
  if (!await authorized(req)) return send(res, 401, { error: 'unauthorized' });
  let meteredServerId: string | undefined;
  let meteredRequestId: string | undefined;
  let releasePaidSlot: (() => void) | undefined;
  let issuedTurnAudioUrl: string | undefined;
  try {
    await memoryReady;
    if (memoryStatus === 'error') return send(res, 503, { error: 'memory_unavailable' });
    const turn = validateTurn(await body(req));
    if (!requestScopeMatches(req, turn.serverId)) return send(res, 403, { error: 'server_scope_mismatch' });
    meteredServerId = turn.serverId;
    const requestIdHeader = req.headers['x-ai-npc-request-id'];
    const requestId = turn.requestId ?? (Array.isArray(requestIdHeader) ? requestIdHeader[0] : requestIdHeader) ?? `${turn.sessionId}.${Date.now()}`;
    meteredRequestId = requestId;
    const startedAt = Date.now();
    const current = usage.get(turn.serverId) ?? { window: Date.now(), count: 0, totalRequests: 0, totalInputTokens: 0, totalOutputTokens: 0, failures: 0, totalLatencyMs: 0 };
    if (Date.now() - current.window > 60_000) { current.window = Date.now(); current.count = 0; }
    current.count += 1;
    const validation = requestLicenses.get(req);
    if (validation?.source !== 'managed') {
      const entitlement = validation?.info;
      const rate = licenseLimiter.check(`${entitlement?.key ?? 'development'}:${turn.serverId}`, entitlement?.rateLimit ?? 120);
      if (!rate.allowed) return send(res, 429, { error: 'server_rate_limit', retryAfterMs: rate.resetMs });
    }
    current.totalRequests += 1;
    usage.set(turn.serverId, current);
    const characterId = String((turn.context.player as Record<string, unknown> | undefined)?.characterId ?? 'unknown-character');
    const npcId = String(turn.npc.id ?? 'unknown-npc');
    const memorySettings = turn.context.memory as { enabled?: boolean; retentionDays?: number; minimumImportance?: number } | undefined;
    const memoryEnabled = memorySettings?.enabled !== false
      && managedFeatureAvailable(requestLicenses.get(req), 'memory');
    const minimumImportance = typeof memorySettings?.minimumImportance === 'number' ? Math.max(0, Math.min(1, memorySettings.minimumImportance)) : 0;
    const [recalled, relationship] = memoryEnabled
      ? await Promise.all([memoryStore.recall(turn.serverId, npcId, characterId), memoryStore.relationship(turn.serverId, npcId, characterId)])
      : [[], { serverId: turn.serverId, npcId, characterId, score: 0, tags: [], updatedAt: new Date().toISOString(), familiarity: 0, trust: 0, warmth: 0, respect: 0, fear: 0, irritation: 0, obligation: 0 }];
    const memories = rankMemories(recalled.filter(memory => memory.importance >= minimumImportance), turn.input, relationship);
    let relationshipContext = mergedRelationshipContext(relationship, turn.context.relationship);
    const enrichedTurn = { ...turn, context: { ...turn.context, memories: memories.map(memory => ({ text: memory.text, importance: memory.importance })), relationship: relationshipContext } };
    // A tool result is already authoritative. Do not offer tools again while the
    // provider turns that result into player-facing dialogue: this makes a turn
    // finite even if a provider repeatedly asks for the same function.
    const executionTurn = turn.toolResult ? { ...enrichedTurn, allowedTools: [], toolSchemas: undefined } : enrichedTurn;
    const operationId = turnOperationKey({ ...turn, requestId });
    const fingerprint = createHash('sha256').update(JSON.stringify(turn)).digest('hex');
    const tokenBound = turnTokenReservation(executionTurn);
    if (tokenBound > 2_000_000) throw new Error('provider_input_exceeded');
    const canSpeak = speech.name !== 'none' && managedFeatureAvailable(requestLicenses.get(req), 'tts');
    const managedInfo = requestLicenses.get(req)?.source === 'managed' ? requestLicenses.get(req)?.info : undefined;
    const bounds = { ttsCharacters: canSpeak ? Math.min(maxResponseCharacters(), managedInfo?.remainingTtsQuota ?? 100000) : 0,
      llmTokens: tokenBound, voiceSeconds: canSpeak ? Math.min(240, managedInfo?.remainingVoiceSeconds ?? 240) : 0 };
    const operation = await turnOperations.run(operationId, async context => {
      releasePaidSlot = await acquireManagedPaidSlot(req, turn.serverId, 'llm');
      return withReservation(req, context, async () => {
      const signal = requestSignal(req);
      let result = await completeWithFallback(provider, fallbackProvider, executionTurn, { signal, onAttempt: metrics => structuredLog(metrics.outcome === 'error' ? 'error' : 'info', 'provider_attempt', {
        requestId,
        serverId: turn.serverId,
        npcId,
        ...metrics,
        historyMessages: executionTurn.history.length,
        historyCharacters: executionTurn.history.reduce((sum, message) => sum + message.content.length, 0),
        contextCharacters: JSON.stringify(executionTurn.context).length
      }) });
      if (result.text) {
        result.text = stripPerformanceMarkup(result.text);
      }
      if (!result.text?.trim() && !result.toolCall) throw new Error('provider_empty_output');
      const tokens = billedTokens(req, result, estimatedTextTokens(turn.input, result.text));
      if (tokens > tokenBound) throw new Error('provider_usage_exceeded');
      let synthesizedQualityMode: QualityMode | undefined;
      let ttsCharacters = 0;
      let audioSeconds = 0;
      if (result.text && result.text.length <= bounds.ttsCharacters && bounds.voiceSeconds > 0 && !result.toolCall && speech.name !== 'none' && managedFeatureAvailable(requestLicenses.get(req), 'tts')) {
        const authoredVoice = turn.npc.voice as Record<string, unknown> | undefined;
        const legacyBaseline = typeof authoredVoice?.style === 'string' ? ({ warm: 'warm', warmly: 'warm', sternly: 'stern', urgently: 'urgent', quietly: 'quiet', nervously: 'nervous', 'menacing whisper': 'menacing' } as Record<string, DeliveryPreset>)[authoredVoice.style.toLowerCase()] : undefined;
        const baseline = typeof authoredVoice?.deliveryPreset === 'string' && ['neutral','warm','stern','nervous','urgent','quiet','menacing'].includes(authoredVoice.deliveryPreset) ? authoredVoice.deliveryPreset as DeliveryPreset : legacyBaseline ?? 'neutral';
        const preset = contextualDeliveryPreset(enrichedTurn, baseline);
        try {
          const resolvedVoice = resolveTurnVoice(turn.serverId, turn.npc, preset);
          const issued = await synthesizeIssued(result.text, resolvedVoice.voice, resolvedVoice.language, providerStyle(preset), { qualityMode: resolvedVoice.qualityMode, deliveryPreset: preset, signal }, Math.min(120, bounds.voiceSeconds / (resolvedVoice.qualityMode === 'quality' ? 2 : 1)));
          synthesizedQualityMode = resolvedVoice.qualityMode;
          ttsCharacters = result.text.length;
          audioSeconds = issued.audioSeconds;
          const utteranceId = randomUUID();
          result.audioUrl = issued.audioUrl;
          issuedTurnAudioUrl = issued.audioUrl;
          const networkId = Number((turn.context.npc as Record<string, unknown> | undefined)?.networkId);
          const configuredDistance = Number((turn.npc as Record<string, unknown>).speechDistance ?? 18);
          result.audio = { utteranceId, url: issued.audioUrl, expiresAt: issued.expiresAt, contentType: 'audio/mpeg', ...(Number.isInteger(networkId) && networkId > 0 ? { sourceNetworkId: networkId } : {}), maximumDistance: Number.isFinite(configuredDistance) ? Math.max(3, Math.min(40, configuredDistance)) : 18 };
          const cadence = preset === 'quiet' || preset === 'menacing' ? 'slow' : preset === 'stern' ? 'measured' : preset === 'urgent' || preset === 'nervous' ? 'brisk' : 'natural';
          const gesture = preset === 'warm' ? 'greet' : preset === 'stern' || preset === 'menacing' || preset === 'urgent' ? 'warn' : preset === 'neutral' ? 'explain' : 'none';
          result.performance = { emotion: preset, intensity: preset === 'urgent' || preset === 'menacing' ? .85 : preset === 'neutral' ? .35 : .6, cadence, deliveryPreset: preset, gesture, gaze: preset === 'nervous' ? 'scan' : 'player' };
        } catch (error) {
          // A canceled/deadline-bound request must not degrade into a successful
          // subtitle-only turn. Re-throw the shared lifecycle signal so the
          // operation ledger cannot commit memory or usage after the client has
          // abandoned this conversation turn. Genuine speech-provider failures
          // still degrade to text below.
          if (signal.aborted) throw signal.reason ?? error;
          const rawCode = error instanceof Error ? error.message : 'speech_error';
          const errorCode = /^[a-z0-9_:-]{1,80}$/i.test(rawCode) ? rawCode : 'speech_error';
          structuredLog('error', 'turn_speech_failed', { requestId, serverId: turn.serverId, npcId, provider: speech.name, error: errorCode });
        }
      }
      return { result, ttsCharacters, synthesizedQualityMode, audioSeconds };
    }); }, async ({ result, ttsCharacters, synthesizedQualityMode, audioSeconds, billing }) => {
      const llmTokens = billedTokens(req, result, estimatedTextTokens(turn.input, result.text));
      await settleManaged(req, { serverId: turn.serverId, endpoint: 'turn', ...settlementAmounts(ttsCharacters, llmTokens, synthesizedQualityMode, audioSeconds) }, billing);
    }, fingerprint, reservationContext(req, turn.serverId, 'turn', operationId, fingerprint, bounds));
    const result = { ...operation.value.result };
    // Audio tokens are intentionally ephemeral. A durable text replay after a
    // process restart must use subtitles instead of returning a dead audio URL.
    if (result.audioUrl && !audioDelivery.has(result.audioUrl)) { delete result.audioUrl; delete result.audio; }
    const proactiveTurn = (turn.context.proactive as { playerHasNotSpoken?: boolean } | undefined)?.playerHasNotSpoken === true;
    if (!operation.replayed && memoryEnabled && !proactiveTurn && !result.toolCall) {
      try {
        await extractionQueue.runMemoryWrite(turn.serverId,
          () => captureDeterministicMemory(memoryStore, enrichedTurn, result.text));
        relationshipContext = mergedRelationshipContext(await memoryStore.relationship(turn.serverId, npcId, characterId), turn.context.relationship);
      } catch (error) {
        structuredLog('error', 'deterministic_memory_failed', { requestId, serverId: turn.serverId, npcId, error: error instanceof Error ? error.message : 'memory_error' });
      }
      extractionQueue.enqueue({ ...enrichedTurn, requestId }, result.text);
    }
    current.totalInputTokens += result.usage?.inputTokens ?? 0;
    current.totalOutputTokens += result.usage?.outputTokens ?? 0;
    current.totalLatencyMs += Date.now() - startedAt;
    recentConversations.push({
      serverId: turn.serverId,
      npcId,
      sessionId: turn.sessionId,
      requestId,
      provider: result.usage?.provider ?? provider.name,
      latencyMs: Date.now() - startedAt,
      result: result.toolCall ? `tool:${result.toolCall.name}` : result.audioUrl ? 'speech+subtitle' : 'subtitle',
      createdAt: new Date().toISOString(),
      ...(captureAdminTranscripts ? { input: turn.input.slice(0, 500), output: result.text.slice(0, 1200) } : {})
    });
    if (recentConversations.length > 500) recentConversations.splice(0, recentConversations.length - 500);
    structuredLog('info', 'turn_complete', { requestId, serverId: turn.serverId, npcId, provider: result.usage?.provider ?? provider.name, fallbackFrom: result.usage?.fallbackFrom, latencyMs: Date.now() - startedAt, providerQueueMs: result.usage?.queueMs, providerPromptMs: result.usage?.promptMs, providerCompletionMs: result.usage?.completionMs, historyMessages: executionTurn.history.length, result: result.toolCall ? 'tool' : 'dialogue', audio: Boolean(result.audioUrl) });
    return send(res, 200, { ...result, requestId, relationship: relationshipContext });
  } catch (error) {
    if (meteredServerId) {
      const record = usage.get(meteredServerId);
      if (record) record.failures += 1;
    }
    const message = error instanceof Error ? error.message : 'gateway_error';
    if (issuedTurnAudioUrl && !message.startsWith('usage_settlement_')) audioDelivery.revoke(issuedTurnAudioUrl);
    structuredLog('error', 'turn_failed', { requestId: meteredRequestId, serverId: meteredServerId, error: message });
    const status = message === 'body_too_large' ? 413
      : message.startsWith('invalid') || error instanceof SyntaxError ? 400
      : message.endsWith('_feature_unavailable') ? 403
      : message === 'operation_payload_conflict' || message === 'usage_settlement_event_conflict' ? 409
      : message === 'usage_settlement_concurrency_limit' || message === 'usage_settlement_rate_limit' ? 429
      : message === 'managed_concurrency_limit' || message === 'provider_concurrency_limit' || message.startsWith('managed_rate_limit:') ? 429
      : message === 'usage_quota_exceeded' ? 402
      : message.startsWith('usage_settlement_') || message.startsWith('entitlement_') ? 503
      : 502;
    const responseError = message.startsWith('managed_rate_limit:') ? 'managed_rate_limit' : error instanceof SyntaxError ? 'invalid_json' : message;
    const retryAfterMs = message === 'managed_concurrency_limit' || message === 'provider_concurrency_limit' ? 250 : message.startsWith('managed_rate_limit:') ? Number(message.split(':')[1]) || 1000 : undefined;
    return send(res, status, { error: responseError, ...(retryAfterMs ? { retryAfterMs } : {}) });
  } finally { releasePaidSlot?.(); }
}

async function captureMemory(store: MemoryStore, turn: TurnInput, response: string) {
  const characterId = String((turn.context.player as Record<string, unknown> | undefined)?.characterId ?? 'unknown-character');
  const npcId = String(turn.npc.id ?? 'unknown-npc');
  const nameMatch = turn.input.match(/\bmy name is ([a-z][a-z '-]{1,40})\b/i);
  const settings = turn.context.memory as { retentionDays?: number; minimumImportance?: number } | undefined;
  const days = typeof settings?.retentionDays === 'number' && settings.retentionDays > 0 ? Math.min(settings.retentionDays, 3650) : undefined;
  const expiresAt = days ? new Date(Date.now() + days * 86_400_000).toISOString() : undefined;
  if (nameMatch) await store.remember({ serverId: turn.serverId, npcId, characterId, text: `The player's name is ${nameMatch[1].trim()}.`, importance: 0.9, expiresAt });
  const factMatch = turn.input.match(/\bremember that (.{3,180})/i);
  if (factMatch) await store.remember({ serverId: turn.serverId, npcId, characterId, text: factMatch[1].trim(), importance: 0.75, expiresAt });
  if (/\b(thank you|thanks|you helped|i helped)\b/i.test(turn.input)) await store.adjustRelationship(turn.serverId, npcId, characterId, 2, 'helpful');
  if (/\b(threaten|kill you|you owe me|shut up)\b/i.test(turn.input)) await store.adjustRelationship(turn.serverId, npcId, characterId, -3, 'hostile');
  if (response && turn.history.length >= 4 && (turn.history.length + 2) % 6 === 0) {
    const recent = [...turn.history.slice(-4), { role: 'user', content: turn.input }, { role: 'assistant', content: response }]
      .map(message => `${message.role}: ${message.content.replace(/\s+/g, ' ').slice(0, 240)}`)
      .join(' | ')
      .slice(0, 1200);
    const importance = typeof settings?.minimumImportance === 'number' ? Math.max(0.65, Math.min(1, settings.minimumImportance)) : 0.65;
    await store.remember({ serverId: turn.serverId, npcId, characterId, text: `Conversation summary: ${recent}`, importance, expiresAt });
  }
}

createServer((req, res) => {
  const controller = new AbortController();
  const deadlineMs = requestDeadlineMs(req);
  const timer = setTimeout(() => {
    controller.abort(new Error('request_deadline'));
    send(res, 504, { error: 'request_deadline' });
  }, deadlineMs);
  timer.unref();
  requestSignals.set(req, AbortSignal.any([controller.signal, AbortSignal.timeout(deadlineMs)]));
  res.once('close', () => { clearTimeout(timer); if (!res.writableEnded) controller.abort(new Error('request_cancelled')); });
  res.once('finish', () => clearTimeout(timer));
  void handle(req, res).catch(error => {
    console.error('[advanced-ai-npc] unhandled request error', error instanceof Error ? error.message : 'unknown_error');
    if (!res.headersSent) send(res, 500, { error: 'internal_error' });
    else res.destroy();
  });
}).listen(port, '0.0.0.0', () => console.log(`[advanced-ai-npc] gateway listening on ${port} using ${provider.name}`));
