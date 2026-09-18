import { boundResponseText } from './prompts.js';
import { setTimeout as delay } from 'node:timers/promises';
import type { DeliveryPreset, QualityMode } from './voice-registry.js';

type SpeechEnvironment = Record<string, string | undefined>;

export interface ElevenLabsVoiceSettings {
  stability?: number;
  similarity_boost?: number;
  style?: number;
  use_speaker_boost?: boolean;
  speed?: number;
}

export interface SpeechOptions {
  signal?: AbortSignal;
  model?: string;
  format?: string;
  voiceSettings?: ElevenLabsVoiceSettings;
  qualityMode?: QualityMode;
  deliveryPreset?: DeliveryPreset;
}

export interface SpeechStream {
  contentType: string;
  requestId?: string;
  body: ReadableStream<Uint8Array>;
}

export interface SpeechReadiness {
  status: 'configured' | 'ready' | 'degraded';
  provider: string;
  model?: string;
  format?: string;
  catalogVoices?: number;
  accessibleProfiles?: number;
  missingProfileIds?: string[];
  error?: string;
}

export interface SpeechProvider {
  readonly name: string;
  synthesize(text: string, voice?: string, language?: string, style?: string, options?: SpeechOptions): Promise<string | undefined>;
  openStream?(text: string, voice?: string, language?: string, style?: string, options?: SpeechOptions): Promise<SpeechStream | undefined>;
  readiness?(profileVoices?: Record<string, string>, defaultVoiceOverride?: string): Promise<SpeechReadiness>;
}

export const DELIVERY_SETTINGS: Readonly<Record<DeliveryPreset, Required<ElevenLabsVoiceSettings>>> = Object.freeze({
  neutral: { stability: .55, similarity_boost: .75, style: 0, use_speaker_boost: true, speed: 1 },
  warm: { stability: .45, similarity_boost: .8, style: .1, use_speaker_boost: true, speed: .97 },
  stern: { stability: .62, similarity_boost: .8, style: .08, use_speaker_boost: true, speed: .95 },
  nervous: { stability: .32, similarity_boost: .72, style: .15, use_speaker_boost: false, speed: 1.08 },
  urgent: { stability: .38, similarity_boost: .78, style: .12, use_speaker_boost: false, speed: 1.1 },
  quiet: { stability: .6, similarity_boost: .78, style: .05, use_speaker_boost: true, speed: .9 },
  menacing: { stability: .5, similarity_boost: .82, style: .15, use_speaker_boost: true, speed: .88 }
});

export function deliverySettings(preset: DeliveryPreset = 'neutral', overrides?: ElevenLabsVoiceSettings): Required<ElevenLabsVoiceSettings> {
  const baseline = DELIVERY_SETTINGS[preset];
  return {
    stability: clamp(overrides?.stability, 0, 1, baseline.stability),
    similarity_boost: clamp(overrides?.similarity_boost, 0, 1, baseline.similarity_boost),
    style: clamp(overrides?.style, 0, 1, baseline.style),
    use_speaker_boost: typeof overrides?.use_speaker_boost === 'boolean' ? overrides.use_speaker_boost : baseline.use_speaker_boost,
    speed: clamp(overrides?.speed, .7, 1.2, baseline.speed)
  };
}

function clamp(value: unknown, minimum: number, maximum: number, fallback: number) {
  return typeof value === 'number' && Number.isFinite(value) ? Math.max(minimum, Math.min(maximum, value)) : fallback;
}

export function stripPerformanceMarkup(value: string): string {
  const stripped = value
    .replace(/\*[^*]+\*/g, '')
    .replace(/\[(?:whispers|whispering|chuckles|chuckling|sighs|sighing|laughs|laughing|pauses|pausing|clears throat|smiling|frowning|angry|excited|crying|coughing|gasps|shouts|yells)\]/gi, '')
    .replace(/\((?:whispering|chuckling|sighing|laughing|pausing|smiling|nervously|hesitantly|angrily|sadly|excitedly)\)/gi, '')
    .replace(/\s{2,}/g, ' ')
    .trim();
  return stripped || value;
}

// Compact quantities are useful in subtitles and receipts ("5x sandwiches"),
// but the literal x sounds unnatural when sent to text-to-speech.
export function spokenText(value: string) {
  const cleaned = stripPerformanceMarkup(value)
    .replace(/\bDr\.\s+/g, 'Doctor ')
    .replace(/\bMr\.\s+/g, 'Mister ')
    .replace(/\bMrs\.\s+/g, 'Missus ')
    .replace(/\bMs\.\s+/g, 'Miss ')
    .replace(/\bProf\.\s+/g, 'Professor ')
    .replace(/\bOfc\.\s+/g, 'Officer ')
    .replace(/\bSgt\.\s+/g, 'Sergeant ')
    .replace(/\bLt\.\s+/g, 'Lieutenant ')
    .replace(/\bCpt\.\s+/g, 'Captain ')
    .replace(/\bAve\.(?=\s|[,\.!?]|$)/g, 'Avenue')
    .replace(/\bBlvd\.(?=\s|[,\.!?]|$)/g, 'Boulevard')
    .replace(/\bRd\.(?=\s|[,\.!?]|$)/g, 'Road')
    .replace(/\bApt\.(?=\s|[,\.!?]|$)/g, 'Apartment')
    .replace(/\betc\.(?=\s|[,\.!?]|$)/g, 'et cetera')
    .replace(/\be\.g\.(?=\s|[,\.!?]|$)/g, 'for example')
    .replace(/\bi\.e\.(?=\s|[,\.!?]|$)/g, 'that is')
    .replace(/\bvs\.(?=\s|[,\.!?]|$)/g, 'versus')
    .replace(/\bapprox\.(?=\s|[,\.!?]|$)/g, 'approximately');

  return cleaned
    .replace(/\b(\d{4})-(\d{2})-(\d{2})\b/g, (_match, year, month, day) => {
      const date = new Date(Date.UTC(Number(year), Number(month) - 1, Number(day)));
      return Number.isNaN(date.valueOf()) ? _match : new Intl.DateTimeFormat('en-US', { timeZone: 'UTC', year: 'numeric', month: 'long', day: 'numeric' }).format(date);
    })
    .replace(/\b(\d{3})[-. ](\d{3})[-. ](\d{4})\b/g, (_match, a, b, c) => [...a, ...b, ...c].join(' '))
    .replace(/\$(\d+)(?:\.(\d{1,2}))?/g, (_match, dollars: string, cents?: string) => `${numberWords(Number(dollars))} dollars${cents && Number(cents) ? ` and ${numberWords(Number(cents.padEnd(2, '0')))} cents` : ''}`)
    .replace(/\b(\d+)\s*[x×]\s+(?=[A-Za-z])/g, (_match, count: string) => `${numberWords(Number(count))} `)
    .replace(/\b\d{1,6}\b/g, digits => numberWords(Number(digits)));
}

function numberWords(value: number): string {
  if (!Number.isInteger(value) || value < 0 || value > 999_999) return String(value);
  if (value === 0) return 'zero';
  const underTwenty = ['', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen', 'sixteen', 'seventeen', 'eighteen', 'nineteen'];
  const tens = ['', '', 'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty', 'ninety'];
  const underThousand = (number: number): string => {
    const parts: string[] = [];
    if (number >= 100) { parts.push(underTwenty[Math.floor(number / 100)], 'hundred'); number %= 100; }
    if (number >= 20) { parts.push(tens[Math.floor(number / 10)]); number %= 10; }
    if (number > 0) parts.push(underTwenty[number]);
    return parts.join(' ');
  };
  if (value < 1000) return underThousand(value);
  return `${underThousand(Math.floor(value / 1000))} thousand${value % 1000 ? ` ${underThousand(value % 1000)}` : ''}`;
}

function configuredMaximum(env: SpeechEnvironment) {
  const parsed = Number(env.AI_NPC_TTS_MAX_CHARACTERS);
  if (Number.isInteger(parsed) && parsed >= 20 && parsed <= 5000) return parsed;
  const responseMaximum = Number(env.AI_NPC_MAX_RESPONSE_CHARACTERS);
  return Number.isInteger(responseMaximum) && responseMaximum >= 80 && responseMaximum <= 1200 ? responseMaximum : 1200;
}

function cleanStyle(style?: string) {
  const value = style?.trim().toLowerCase();
  return value && /^[a-z]+(?: [a-z]+)?$/.test(value) && value.length <= 32 ? value : undefined;
}

function inputText(text: string, env: SpeechEnvironment, style?: string) {
  const direction = cleanStyle(style);
  const spoken = `${direction ? `[${direction}] ` : ''}${spokenText(text)}`;
  const bounded = boundResponseText(spoken, configuredMaximum(env));
  if (!bounded) throw new Error('tts_empty_text');
  return bounded;
}

function timeout(env: SpeechEnvironment) {
  const parsed = Number(env.AI_NPC_TTS_TIMEOUT_MS);
  return Number.isInteger(parsed) && parsed >= 1000 && parsed <= 60_000 ? parsed : 15_000;
}

function speechSignal(env: SpeechEnvironment, caller?: AbortSignal) {
  const deadline = AbortSignal.timeout(timeout(env));
  return caller ? AbortSignal.any([caller, deadline]) : deadline;
}

async function audioDataUrl(response: Response, fallbackMime: string) {
  if (!response.ok) throw new Error(`tts_http_${response.status}`);
  const bytes = Buffer.from(await response.arrayBuffer());
  if (!bytes.length || bytes.length > 5_000_000) throw new Error('tts_invalid_audio');
  const responseMime = response.headers.get('content-type')?.split(';')[0].trim().toLowerCase();
  const mime = !responseMime || responseMime === 'application/octet-stream' ? fallbackMime : responseMime;
  if (!/^(audio\/|application\/octet-stream$)/.test(mime)) throw new Error('tts_invalid_content_type');
  return `data:${mime};base64,${bytes.toString('base64')}`;
}

function cleanLanguage(language?: string) {
  return language && /^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,2}$/.test(language) ? language : undefined;
}

function primaryLanguage(language?: string) { return cleanLanguage(language)?.split('-')[0].toLowerCase(); }
function redactedHttpError(response: Response) {
  const requestId = response.headers.get('request-id') ?? response.headers.get('xi-request-id');
  return new Error(`tts_http_${response.status}${requestId ? ':request_id_present' : ''}`);
}

export class NoopSpeechProvider implements SpeechProvider {
  readonly name = 'none';
  async synthesize() { return undefined; }
  async readiness(): Promise<SpeechReadiness> { return { status: 'degraded', provider: this.name, error: 'speech_not_configured' }; }
}

export class OpenAICompatibleSpeechProvider implements SpeechProvider {
  readonly name = 'openai-compatible-tts';
  constructor(private readonly endpoint: string, private readonly key: string, private readonly model: string, private readonly defaultVoice = process.env.AI_NPC_TTS_VOICE ?? 'alloy', private readonly env: SpeechEnvironment = process.env) {}
  async synthesize(text: string, voice?: string, _language?: string, style?: string, options?: SpeechOptions) {
    const headers: Record<string, string> = { 'content-type': 'application/json' };
    if (this.key) headers.authorization = `Bearer ${this.key}`;
    const format = this.env.AI_NPC_TTS_FORMAT ?? 'mp3';
    const fallbackMime: Record<string, string> = { mp3: 'audio/mpeg', wav: 'audio/wav', opus: 'audio/ogg', aac: 'audio/aac', flac: 'audio/flac' };
    const response = await fetch(`${this.endpoint.replace(/\/$/, '')}/audio/speech`, { method: 'POST', signal: speechSignal(this.env, options?.signal), headers, body: JSON.stringify({ model: this.model, voice: voice || this.defaultVoice, input: inputText(text, this.env, this.model.startsWith('canopylabs/orpheus-') ? style : undefined), response_format: format }) });
    return audioDataUrl(response, fallbackMime[format] || 'application/octet-stream');
  }
}

export class ElevenLabsSpeechProvider implements SpeechProvider {
  readonly name = 'elevenlabs-tts';
  constructor(private readonly endpoint: string, private readonly key: string, private readonly model: string, private readonly defaultVoice: string, private readonly env: SpeechEnvironment = process.env) {}

  private request(text: string, voice?: string, language?: string, options?: SpeechOptions) {
    if (!this.key) throw new Error('elevenlabs_key_missing');
    const selectedVoice = voice || this.defaultVoice;
    if (!selectedVoice) throw new Error('elevenlabs_voice_missing');
    const qualityMode = options?.qualityMode ?? (options?.model === 'eleven_multilingual_v2' ? 'quality' : 'realtime');
    const selectedModel = options?.model ?? (qualityMode === 'quality' ? 'eleven_multilingual_v2' : ((this.env.AI_NPC_TTS_MODEL ?? this.model) || 'eleven_flash_v2_5'));
    if (qualityMode === 'realtime' && selectedModel !== 'eleven_flash_v2_5') throw new Error('elevenlabs_realtime_model_invalid');
    if (qualityMode === 'quality' && selectedModel !== 'eleven_multilingual_v2') throw new Error('elevenlabs_quality_model_invalid');
    const configuredFormat = options?.format ?? this.env.AI_NPC_TTS_FORMAT ?? 'mp3_44100_128';
    const outputFormat = configuredFormat === 'mp3' ? 'mp3_44100_128' : configuredFormat;
    if (outputFormat !== 'mp3_44100_128') throw new Error('elevenlabs_format_invalid');
    const settings = deliverySettings(options?.deliveryPreset, options?.voiceSettings);
    const body = JSON.stringify({ text: inputText(text, this.env), model_id: selectedModel, ...(primaryLanguage(language) ? { language_code: primaryLanguage(language) } : {}), voice_settings: settings });
    return { selectedVoice, selectedModel, outputFormat, body };
  }

  async openStream(text: string, voice?: string, language?: string, _style?: string, options?: SpeechOptions) {
    const localDeadline = AbortSignal.timeout(timeout(this.env));
    const signal = options?.signal ? AbortSignal.any([options.signal, localDeadline]) : localDeadline;
    const request = this.request(text, voice, language, options);
    const target = `${this.endpoint.replace(/\/$/, '')}/v1/text-to-speech/${encodeURIComponent(request.selectedVoice)}/stream?output_format=${encodeURIComponent(request.outputFormat)}`;
    let lastError: Error | undefined;
    for (let attempt = 0; attempt < 3; attempt += 1) {
      try {
        signal.throwIfAborted();
        const response = await fetch(target, { method: 'POST', signal, headers: { 'content-type': 'application/json', accept: 'audio/mpeg', 'xi-api-key': this.key }, body: request.body });
        if (response.ok) {
          const mime = response.headers.get('content-type')?.split(';')[0].trim().toLowerCase();
          if (mime && mime !== 'audio/mpeg' && mime !== 'audio/mp3' && mime !== 'application/octet-stream') throw new Error('tts_invalid_content_type');
          if (!response.body) throw new Error('tts_invalid_audio');
          return { contentType: 'audio/mpeg', requestId: response.headers.get('request-id') ?? response.headers.get('xi-request-id') ?? undefined, body: response.body };
        }
        const retryable = response.status === 429;
        lastError = redactedHttpError(response);
        await response.body?.cancel();
        if (!retryable || attempt === 2) throw lastError;
        const retryAfter = Number(response.headers.get('retry-after'));
        await delay(Number.isFinite(retryAfter) ? Math.max(0, Math.min(5_000, retryAfter * 1000)) : 100 * 2 ** attempt, undefined, { signal });
      } catch (error) {
        signal.throwIfAborted();
        lastError = error instanceof Error ? error : new Error('tts_network_error');
        // Lost responses may represent billed synthesis. Only the explicit
        // rate-limit rejection above is safe for automatic retry.
        throw lastError;
      }
    }
    throw lastError ?? new Error('tts_unavailable');
  }

  async synthesize(text: string, voice?: string, language?: string, style?: string, options?: SpeechOptions) {
    const opened = await this.openStream(text, voice, language, style, options);
    if (!opened) return undefined;
    return audioDataUrl(new Response(opened.body, { headers: { 'content-type': opened.contentType } }), opened.contentType);
  }

  async readiness(profileVoices: Record<string, string> = {}, defaultVoiceOverride?: string): Promise<SpeechReadiness> {
    const configured: SpeechReadiness = { status: 'configured', provider: this.name, model: this.model || 'eleven_flash_v2_5', format: this.env.AI_NPC_TTS_FORMAT ?? 'mp3_44100_128' };
    const defaultVoice = defaultVoiceOverride || this.defaultVoice;
    if (!this.key || !defaultVoice || configured.format !== 'mp3_44100_128' || configured.model !== 'eleven_flash_v2_5') return { ...configured, status: 'degraded', error: !this.key ? 'credential_missing' : !defaultVoice ? 'default_voice_missing' : 'model_or_format_invalid' };
    try {
      const voiceIds = new Set<string>();
      let pageToken: string | undefined;
      const seenPages = new Set<string>();
      do {
        const url = new URL(`${this.endpoint.replace(/\/$/, '')}/v2/voices`);
        url.searchParams.set('page_size', '100');
        if (pageToken) url.searchParams.set('page_token', pageToken);
        const catalogResponse = await fetch(url, { headers: { 'xi-api-key': this.key }, signal: AbortSignal.timeout(timeout(this.env)) });
        if (!catalogResponse.ok) throw redactedHttpError(catalogResponse);
        const catalog = await catalogResponse.json() as { voices?: Array<{ voice_id?: string }>; has_more?: boolean; next_page_token?: string };
        for (const voice of catalog.voices ?? []) if (voice.voice_id) voiceIds.add(voice.voice_id);
        pageToken = catalog.has_more ? catalog.next_page_token : undefined;
        if (catalog.has_more && !pageToken) throw new Error('voice_catalog_pagination_invalid');
        if (pageToken && (seenPages.has(pageToken) || seenPages.size >= 100)) throw new Error('voice_catalog_pagination_invalid');
        if (pageToken) seenPages.add(pageToken);
      } while (pageToken);
      const required = { ...profileVoices, '$default': defaultVoice };
      const missingProfileIds = Object.entries(required).filter(([, voiceId]) => !voiceIds.has(voiceId)).map(([profileId]) => profileId);
      if (missingProfileIds.length) return { ...configured, status: 'degraded', catalogVoices: voiceIds.size, accessibleProfiles: Object.keys(required).length - missingProfileIds.length, missingProfileIds, error: 'voice_roster_incomplete' };
      await this.synthesize('Ready.', defaultVoice, 'en', undefined, { qualityMode: 'realtime', deliveryPreset: 'neutral' });
      return { ...configured, status: 'ready', catalogVoices: voiceIds.size, accessibleProfiles: Object.keys(required).length, missingProfileIds: [] };
    } catch (error) {
      const code = error instanceof Error && /^[a-z0-9_:]+$/i.test(error.message) ? error.message : 'preflight_failed';
      return { ...configured, status: 'degraded', error: code };
    }
  }
}

export class CartesiaSpeechProvider implements SpeechProvider {
  readonly name = 'cartesia-tts';
  constructor(private readonly endpoint: string, private readonly key: string, private readonly model: string, private readonly defaultVoice: string, private readonly env: SpeechEnvironment = process.env) {}
  async synthesize(text: string, voice?: string, language?: string, _style?: string, options?: SpeechOptions) {
    if (!this.key) throw new Error('cartesia_key_missing');
    const selectedVoice = voice || this.defaultVoice;
    if (!selectedVoice) throw new Error('cartesia_voice_missing');
    const languageCode = primaryLanguage(language);
    const response = await fetch(`${this.endpoint.replace(/\/$/, '')}/tts/bytes`, { method: 'POST', signal: speechSignal(this.env, options?.signal), headers: { 'content-type': 'application/json', authorization: `Bearer ${this.key}`, 'cartesia-version': this.env.AI_NPC_CARTESIA_VERSION ?? '2026-03-01' }, body: JSON.stringify({ model_id: this.model, transcript: inputText(text, this.env), voice: { mode: 'id', id: selectedVoice }, output_format: { container: 'mp3', sample_rate: 44_100, bit_rate: 128_000 }, ...(languageCode ? { language: languageCode } : {}) }) });
    return audioDataUrl(response, 'audio/mpeg');
  }
}

export function createSpeechProvider(env: SpeechEnvironment = process.env): SpeechProvider {
  const kind = (env.AI_NPC_TTS_PROVIDER ?? '').trim().toLowerCase();
  if (!kind || kind === 'none' || kind === 'disabled') return new NoopSpeechProvider();
  if (['openai-compatible', 'openai', 'custom'].includes(kind)) return new OpenAICompatibleSpeechProvider(env.AI_NPC_TTS_ENDPOINT ?? env.AI_NPC_PROVIDER_ENDPOINT ?? 'https://api.openai.com/v1', env.AI_NPC_TTS_KEY ?? '', env.AI_NPC_TTS_MODEL ?? 'gpt-4o-mini-tts', env.AI_NPC_TTS_VOICE ?? 'alloy', env);
  if (kind === 'elevenlabs') return new ElevenLabsSpeechProvider(env.AI_NPC_TTS_ENDPOINT ?? 'https://api.elevenlabs.io', env.AI_NPC_TTS_KEY ?? '', env.AI_NPC_TTS_MODEL ?? 'eleven_flash_v2_5', env.AI_NPC_TTS_VOICE ?? '', env);
  if (kind === 'cartesia') return new CartesiaSpeechProvider(env.AI_NPC_TTS_ENDPOINT ?? 'https://api.cartesia.ai', env.AI_NPC_TTS_KEY ?? '', env.AI_NPC_TTS_MODEL ?? 'sonic-3.5', env.AI_NPC_TTS_VOICE ?? '', env);
  throw new Error(`unsupported_speech_provider:${kind}`);
}
