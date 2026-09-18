import { createHash, randomUUID } from 'node:crypto';
import type { IncomingMessage, ServerResponse } from 'node:http';
import type { SpeechOptions, SpeechProvider } from './speech.js';
import { measuredAudioSeconds } from './audio-duration.js';

type CachedAudio = { bytes: Buffer; contentType: string; lastAccessedAt: number; createdAt: number; providerRequestId?: string; durationSeconds?: number };
type LiveAudio = { chunks: Buffer[]; size: number; contentType: string; subscribers: Set<ServerResponse>; done: Promise<void>; complete: boolean; failed?: string; providerRequestId?: string };
type Token = { cacheKey: string; expiresAt: number };
export type AudioMetrics = { cacheHit: boolean; bytes: number; ttfbMs: number; totalMs?: number; providerRequestId?: string; errorCode?: string };

export class AudioDelivery {
  private cache = new Map<string, CachedAudio>();
  private cacheBytes = 0;
  private live = new Map<string, LiveAudio>();
  private pending = new Map<string, Promise<LiveAudio | undefined>>();
  private tokens = new Map<string, Token>();

  has(url: string) {
    const token = this.tokens.get(url.split('/').pop() ?? '');
    return !!token && token.expiresAt > Date.now() && (this.cache.has(token.cacheKey) || this.live.has(token.cacheKey));
  }

  constructor(
    private readonly provider: SpeechProvider,
    private readonly publicBaseUrl: string,
    private readonly onMetrics: (metrics: AudioMetrics) => void = () => {},
    private readonly maxEntryBytes = 5_000_000,
    private readonly maxCacheBytes = 64 * 1024 * 1024,
    private readonly tokenTtlMs = 60_000
  ) {}

  private key(text: string, voice?: string, language?: string, style?: string, options?: SpeechOptions) {
    return createHash('sha256').update(`${this.provider.name}\0${voice ?? ''}\0${language ?? ''}\0${style ?? ''}\0${JSON.stringify(options ?? {})}\0${text}`).digest('hex');
  }

  async issue(text: string, voice?: string, language?: string, style?: string, options?: SpeechOptions) {
    const cacheKey = this.key(text, voice, language, style, options);
    const start = Date.now();
    const cached = this.cache.get(cacheKey);
    if (cached) {
      cached.lastAccessedAt = Date.now();
      this.onMetrics({ cacheHit: true, bytes: cached.bytes.length, ttfbMs: 0, providerRequestId: cached.providerRequestId });
      return this.token(cacheKey);
    }
    let active = this.live.get(cacheKey);
    if (!active && !this.cache.has(cacheKey)) {
      let pending = this.pending.get(cacheKey);
      if (!pending) {
        pending = this.start(cacheKey, text, voice, language, style, options, start).finally(() => this.pending.delete(cacheKey));
        this.pending.set(cacheKey, pending);
      }
      active = await pending;
    }
    if (active?.failed) throw new Error(active.failed);
    if (!active && !this.cache.has(cacheKey)) throw new Error('speech_unavailable');
    return this.token(cacheKey);
  }

  async measuredSeconds(audioUrl: string, signal?: AbortSignal, maximumSeconds = 120) {
    const token = this.tokens.get(audioUrl.split('/').pop() ?? '');
    if (!token || token.expiresAt <= Date.now()) throw new Error('speech_audio_expired');
    const active = this.live.get(token.cacheKey);
    if (active) {
      signal?.throwIfAborted();
      await new Promise<void>((resolve, reject) => {
        const abort = () => reject(signal?.reason ?? new Error('speech_aborted'));
        signal?.addEventListener('abort', abort, { once: true });
        void active.done.then(() => { signal?.removeEventListener('abort', abort); resolve(); });
      });
      if (active.failed) throw new Error(active.failed);
    }
    signal?.throwIfAborted();
    const cached = this.cache.get(token.cacheKey);
    if (!cached) throw new Error('tts_invalid_audio');
    if (cached.durationSeconds === undefined) cached.durationSeconds = await measuredAudioSeconds(cached.bytes, cached.contentType, { signal, maximumSeconds, rejectSilence: true });
    if (cached.durationSeconds > maximumSeconds) throw new Error('audio_duration_exceeded');
    return cached.durationSeconds;
  }

  private async start(cacheKey: string, text: string, voice: string | undefined, language: string | undefined, style: string | undefined, options: SpeechOptions | undefined, start: number) {
    if (!this.provider.openStream) {
      const dataUrl = await this.provider.synthesize(text, voice, language, style, options);
      if (!dataUrl) throw new Error('speech_unavailable');
      const match = dataUrl.match(/^data:([^;,]+);base64,([A-Za-z0-9+/=]+)$/);
      if (!match) throw new Error('tts_invalid_audio');
      const bytes = Buffer.from(match[2], 'base64');
      if (!bytes.length || bytes.length > this.maxEntryBytes) throw new Error('tts_audio_too_large');
      this.store(cacheKey, bytes, match[1]);
      this.onMetrics({ cacheHit: false, bytes: bytes.length, ttfbMs: Date.now() - start, totalMs: Date.now() - start });
      return undefined;
    }
    const opened = await this.provider.openStream(text, voice, language, style, options);
    if (!opened) throw new Error('speech_unavailable');
    const reader = opened.body.getReader();
    const first = await reader.read();
    if (first.done || !first.value?.byteLength) throw new Error('tts_invalid_audio');
    const initial = Buffer.from(first.value);
    if (initial.length > this.maxEntryBytes) throw new Error('tts_audio_too_large');
    let settle!: () => void;
    const active: LiveAudio = { chunks: [initial], size: initial.length, contentType: opened.contentType, subscribers: new Set(), complete: false, providerRequestId: opened.requestId, done: new Promise(resolve => { settle = resolve; }) };
    this.live.set(cacheKey, active);
    this.onMetrics({ cacheHit: false, bytes: initial.length, ttfbMs: Date.now() - start, providerRequestId: opened.requestId });
    void (async () => {
      try {
        while (true) {
          const next = await reader.read();
          if (next.done) break;
          const chunk = Buffer.from(next.value);
          active.size += chunk.length;
          if (active.size > this.maxEntryBytes) throw new Error('tts_audio_too_large');
          active.chunks.push(chunk);
          for (const subscriber of active.subscribers) subscriber.write(chunk);
        }
        active.complete = true;
        const bytes = Buffer.concat(active.chunks, active.size);
        this.store(cacheKey, bytes, active.contentType, active.providerRequestId);
        for (const subscriber of active.subscribers) subscriber.end();
        this.onMetrics({ cacheHit: false, bytes: active.size, ttfbMs: Date.now() - start, totalMs: Date.now() - start, providerRequestId: active.providerRequestId });
      } catch (error) {
        active.failed = safeError(error);
        void reader.cancel().catch(() => {});
        for (const subscriber of active.subscribers) subscriber.destroy();
        this.onMetrics({ cacheHit: false, bytes: active.size, ttfbMs: Date.now() - start, totalMs: Date.now() - start, providerRequestId: active.providerRequestId, errorCode: active.failed });
      } finally {
        settle();
        this.live.delete(cacheKey);
      }
    })();
    return active;
  }

  private token(cacheKey: string) {
    const token = randomUUID().replace(/-/g, '');
    const expiresAt = Date.now() + this.tokenTtlMs;
    this.tokens.set(token, { cacheKey, expiresAt });
    const contentType = this.cache.get(cacheKey)?.contentType ?? this.live.get(cacheKey)?.contentType ?? 'audio/mpeg';
    return { audioUrl: `${this.publicBaseUrl}/v1/audio/${token}`, expiresAt: new Date(expiresAt).toISOString(), contentType: contentType === 'audio/mp3' ? 'audio/mpeg' : contentType };
  }

  private store(key: string, bytes: Buffer, contentType: string, providerRequestId?: string) {
    const old = this.cache.get(key);
    if (old) this.cacheBytes -= old.bytes.length;
    this.cache.delete(key);
    this.cache.set(key, { bytes, contentType, createdAt: Date.now(), lastAccessedAt: Date.now(), providerRequestId });
    this.cacheBytes += bytes.length;
    while (this.cacheBytes > this.maxCacheBytes && this.cache.size) {
      const oldest = this.cache.keys().next().value as string;
      const evicted = this.cache.get(oldest)!;
      this.cache.delete(oldest);
      this.cacheBytes -= evicted.bytes.length;
    }
  }

  async serve(req: IncomingMessage, res: ServerResponse, token: string) {
    const issued = this.tokens.get(token);
    if (!issued || issued.expiresAt <= Date.now()) {
      this.tokens.delete(token);
      return false;
    }
    const cached = this.cache.get(issued.cacheKey);
    if (cached) {
      cached.lastAccessedAt = Date.now();
      return serveBuffer(req, res, cached.bytes, cached.contentType);
    }
    const active = this.live.get(issued.cacheKey);
    if (!active || active.failed) return false;
    const headers = corsHeaders(active.contentType);
    res.writeHead(200, headers);
    for (const chunk of active.chunks) res.write(chunk);
    if (active.complete) res.end(); else active.subscribers.add(res);
    res.once('close', () => active.subscribers.delete(res));
    return true;
  }

  purgeExpired(now = Date.now()) {
    for (const [token, issued] of this.tokens) if (issued.expiresAt <= now) this.tokens.delete(token);
    const referenced = new Set([...this.tokens.values()].map(token => token.cacheKey));
    for (const [key, entry] of this.cache) {
      if (!referenced.has(key) && now - entry.createdAt >= 300000) {
        this.cache.delete(key); this.cacheBytes -= entry.bytes.length;
      }
    }
  }

  revoke(audioUrl: string) {
    const token = audioUrl.match(/\/v1\/audio\/([A-Za-z0-9]{32})$/)?.[1];
    return token ? this.tokens.delete(token) : false;
  }

  stats() { return { cacheEntries: this.cache.size, cacheBytes: this.cacheBytes, inFlight: this.live.size + this.pending.size, issuedTokens: this.tokens.size }; }
}

function corsHeaders(contentType: string) {
  return { 'content-type': contentType === 'audio/mp3' ? 'audio/mpeg' : contentType, 'cache-control': 'private, no-store', 'x-content-type-options': 'nosniff', 'access-control-allow-origin': '*', 'cross-origin-resource-policy': 'cross-origin', 'accept-ranges': 'bytes' };
}

function serveBuffer(req: IncomingMessage, res: ServerResponse, bytes: Buffer, contentType: string) {
  const common = corsHeaders(contentType);
  const range = typeof req.headers.range === 'string' ? req.headers.range.match(/^bytes=(\d*)-(\d*)$/) : undefined;
  if (!range) { res.writeHead(200, { ...common, 'content-length': bytes.length }); res.end(bytes); return true; }
  const suffix = !range[1] && range[2] ? Number(range[2]) : undefined;
  const start = suffix !== undefined ? Math.max(0, bytes.length - suffix) : range[1] ? Number(range[1]) : 0;
  const end = suffix !== undefined ? bytes.length - 1 : range[2] ? Number(range[2]) : bytes.length - 1;
  if (!Number.isInteger(start) || !Number.isInteger(end) || start > end || start >= bytes.length) { res.writeHead(416, { ...common, 'content-range': `bytes */${bytes.length}` }); res.end(); return true; }
  const slice = bytes.subarray(start, Math.min(end, bytes.length - 1) + 1);
  res.writeHead(206, { ...common, 'content-length': slice.length, 'content-range': `bytes ${start}-${start + slice.length - 1}/${bytes.length}` });
  res.end(slice);
  return true;
}

function safeError(error: unknown) {
  const raw = error instanceof Error ? error.message : 'tts_stream_error';
  return /^[a-z0-9_:-]{1,80}$/i.test(raw) ? raw : 'tts_stream_error';
}
