export type VisionResult = {
  text: string;
  llmTokens: number;
  provider: string;
  fallbackFrom?: string;
};

export interface VisionProvider {
  readonly name: string;
  describe(imageDataUrl: string, prompt: string, signal?: AbortSignal): Promise<string>;
  describeMetered?(imageDataUrl: string, prompt: string, signal?: AbortSignal): Promise<VisionResult>;
}

export type VisionEnvironment = Record<string, string | undefined>;

type VisionOptions = {
  timeoutMs?: number;
  maxOutputTokens?: number;
  reasoningEffort?: string;
  reasoningFormat?: string;
  keepAlive?: string;
};

function boundedInteger(value: unknown, fallback: number, minimum: number, maximum: number) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? Math.max(minimum, Math.min(maximum, Math.trunc(parsed))) : fallback;
}

function safeTokens(...values: unknown[]) {
  const tokens = values.map(Number);
  return tokens.every(value => Number.isSafeInteger(value) && value >= 0) ? tokens.reduce((sum, value) => sum + value, 0) : Number.NaN;
}

function dataUrlImage(imageDataUrl: string) {
  const match = imageDataUrl.match(/^data:(image\/(?:png|jpeg|webp));base64,([A-Za-z0-9+/=]+)$/);
  if (!match) throw new Error('vision_image_invalid');
  return { mimeType: match[1], data: match[2] };
}

function requestSignal(signal: AbortSignal | undefined, timeoutMs: number) {
  const deadline = AbortSignal.timeout(timeoutMs);
  return { deadline, combined: signal ? AbortSignal.any([signal, deadline]) : deadline };
}

function providerFailure(error: unknown, callerSignal: AbortSignal | undefined, deadline: AbortSignal): never {
  if (callerSignal?.aborted) throw callerSignal.reason ?? error;
  if (deadline.aborted) throw new Error('vision_timeout');
  if (error instanceof TypeError || /(?:fetch failed|ECONNRESET|ECONNREFUSED|ENOTFOUND|EAI_AGAIN)/i.test(String(error))) throw new Error('vision_transport_error');
  throw error;
}

function responseText(value: unknown) {
  const text = String(value ?? '').trim().slice(0, 2000);
  if (!text) throw new Error('provider_empty_output');
  return text;
}

function transientVisionFailure(error: unknown) {
  const message = error instanceof Error ? error.message : String(error);
  return message === 'vision_timeout' || message === 'vision_transport_error'
    || /^vision_http_(?:408|425|429|5\d\d)$/.test(message);
}

export class NoopVisionProvider implements VisionProvider {
  readonly name = 'none';
  async describe(_imageDataUrl: string, _prompt: string): Promise<string> { throw new Error('vision_not_configured'); }
}

export class OpenAICompatibleVisionProvider implements VisionProvider {
  readonly name: string;
  private readonly timeoutMs: number;
  private readonly maxOutputTokens: number;
  private readonly options: VisionOptions;

  constructor(
    private readonly endpoint: string,
    private readonly key: string,
    private readonly model: string,
    options: VisionOptions = {},
    name = 'openai-compatible-vision'
  ) {
    this.name = name;
    this.timeoutMs = boundedInteger(options.timeoutMs, 20_000, 250, 60_000);
    this.maxOutputTokens = boundedInteger(options.maxOutputTokens, 120, 32, 1_000);
    this.options = options;
  }

  async describe(imageDataUrl: string, prompt: string, signal?: AbortSignal) {
    return (await this.describeMetered(imageDataUrl, prompt, signal)).text;
  }

  async describeMetered(imageDataUrl: string, prompt: string, signal?: AbortSignal): Promise<VisionResult> {
    dataUrlImage(imageDataUrl);
    const headers: Record<string, string> = { 'content-type': 'application/json' };
    if (this.key) headers.authorization = `Bearer ${this.key}`;
    const { deadline, combined } = requestSignal(signal, this.timeoutMs);
    let response: Response;
    try {
      response = await fetch(`${this.endpoint.replace(/\/$/, '')}/chat/completions`, {
        method: 'POST',
        signal: combined,
        headers,
        body: JSON.stringify({
          model: this.model,
          messages: [{ role: 'user', content: [{ type: 'text', text: prompt }, { type: 'image_url', image_url: { url: imageDataUrl } }] }],
          temperature: 0.2,
          max_tokens: this.maxOutputTokens,
          ...(this.options.reasoningEffort ? { reasoning_effort: this.options.reasoningEffort } : {}),
          ...(this.options.reasoningFormat ? { reasoning_format: this.options.reasoningFormat } : {})
        })
      });
    } catch (error) { providerFailure(error, signal, deadline); }
    if (!response.ok) throw new Error(`vision_http_${response.status}`);
    const body = await response.json() as { choices?: Array<{ message?: { content?: unknown } }>; usage?: { prompt_tokens?: number; completion_tokens?: number; total_tokens?: number } };
    const text = responseText(body.choices?.[0]?.message?.content);
    const summed = safeTokens(body.usage?.prompt_tokens, body.usage?.completion_tokens);
    const total = Number(body.usage?.total_tokens);
    const llmTokens = Number.isSafeInteger(total) && total > 0 ? total : summed;
    return { text, llmTokens, provider: this.name };
  }
}

export class GeminiVisionProvider implements VisionProvider {
  readonly name = 'gemini-vision';
  private readonly timeoutMs: number;
  private readonly maxOutputTokens: number;

  constructor(private readonly endpoint: string, private readonly key: string, private readonly model: string, options: VisionOptions = {}) {
    this.timeoutMs = boundedInteger(options.timeoutMs, 20_000, 250, 60_000);
    this.maxOutputTokens = boundedInteger(options.maxOutputTokens, 120, 32, 1_000);
  }

  async describe(imageDataUrl: string, prompt: string, signal?: AbortSignal) {
    return (await this.describeMetered(imageDataUrl, prompt, signal)).text;
  }

  async describeMetered(imageDataUrl: string, prompt: string, signal?: AbortSignal): Promise<VisionResult> {
    if (!this.key) throw new Error('gemini_key_missing');
    const image = dataUrlImage(imageDataUrl);
    const { deadline, combined } = requestSignal(signal, this.timeoutMs);
    let response: Response;
    try {
      response = await fetch(`${this.endpoint.replace(/\/$/, '')}/v1beta/models/${encodeURIComponent(this.model)}:generateContent`, {
        method: 'POST',
        signal: combined,
        headers: { 'content-type': 'application/json', 'x-goog-api-key': this.key },
        body: JSON.stringify({
          contents: [{ role: 'user', parts: [{ text: prompt }, { inlineData: { mimeType: image.mimeType, data: image.data } }] }],
          generationConfig: { maxOutputTokens: this.maxOutputTokens, thinkingConfig: { thinkingLevel: 'MINIMAL' } }
        })
      });
    } catch (error) { providerFailure(error, signal, deadline); }
    if (!response.ok) throw new Error(`vision_http_${response.status}`);
    const body = await response.json() as {
      candidates?: Array<{ content?: { parts?: Array<{ text?: string; thought?: boolean }> } }>;
      usageMetadata?: { promptTokenCount?: number; candidatesTokenCount?: number; thoughtsTokenCount?: number; totalTokenCount?: number };
    };
    const parts = body.candidates?.[0]?.content?.parts ?? [];
    const text = responseText(parts.filter(part => part.thought !== true).map(part => part.text ?? '').join(''));
    const reportedTotal = Number(body.usageMetadata?.totalTokenCount);
    const summed = safeTokens(body.usageMetadata?.promptTokenCount, body.usageMetadata?.candidatesTokenCount, body.usageMetadata?.thoughtsTokenCount ?? 0);
    const llmTokens = Number.isSafeInteger(reportedTotal) && reportedTotal > 0 ? reportedTotal : summed;
    return { text, llmTokens, provider: this.name };
  }
}

export class OllamaVisionProvider implements VisionProvider {
  readonly name = 'ollama-vision';
  private readonly timeoutMs: number;
  private readonly maxOutputTokens: number;
  private readonly keepAlive: string;

  constructor(private readonly endpoint: string, private readonly model: string, options: VisionOptions = {}) {
    this.timeoutMs = boundedInteger(options.timeoutMs, 20_000, 250, 120_000);
    this.maxOutputTokens = boundedInteger(options.maxOutputTokens, 120, 32, 1_000);
    this.keepAlive = options.keepAlive?.trim() || '30m';
  }

  async describe(imageDataUrl: string, prompt: string, signal?: AbortSignal) {
    return (await this.describeMetered(imageDataUrl, prompt, signal)).text;
  }

  async describeMetered(imageDataUrl: string, prompt: string, signal?: AbortSignal): Promise<VisionResult> {
    const image = dataUrlImage(imageDataUrl);
    const { deadline, combined } = requestSignal(signal, this.timeoutMs);
    const base = this.endpoint.replace(/\/v1\/?$/, '').replace(/\/$/, '');
    let response: Response;
    try {
      response = await fetch(`${base}/api/chat`, {
        method: 'POST',
        signal: combined,
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          model: this.model,
          messages: [{ role: 'user', content: prompt, images: [image.data] }],
          stream: false,
          think: false,
          keep_alive: this.keepAlive,
          options: { temperature: 0.2, num_predict: this.maxOutputTokens }
        })
      });
    } catch (error) { providerFailure(error, signal, deadline); }
    if (!response.ok) throw new Error(`vision_http_${response.status}`);
    const body = await response.json() as { message?: { content?: string }; prompt_eval_count?: number; eval_count?: number };
    return { text: responseText(body.message?.content), llmTokens: safeTokens(body.prompt_eval_count, body.eval_count), provider: this.name };
  }
}

export class FallbackVisionProvider implements VisionProvider {
  readonly name: string;
  constructor(private readonly primary: VisionProvider, private readonly fallback: VisionProvider) {
    this.name = `${primary.name}+${fallback.name}`;
  }

  async describe(imageDataUrl: string, prompt: string, signal?: AbortSignal) {
    return (await this.describeMetered(imageDataUrl, prompt, signal)).text;
  }

  async describeMetered(imageDataUrl: string, prompt: string, signal?: AbortSignal): Promise<VisionResult> {
    if (!this.primary.describeMetered || !this.fallback.describeMetered) throw new Error('provider_usage_unavailable');
    try { return await this.primary.describeMetered(imageDataUrl, prompt, signal); }
    catch (error) {
      if (signal?.aborted) throw signal.reason ?? error;
      if (!transientVisionFailure(error)) throw error;
      const result = await this.fallback.describeMetered(imageDataUrl, prompt, signal);
      return { ...result, fallbackFrom: this.primary.name };
    }
  }
}

function providerOptions(env: VisionEnvironment, prefix: string): VisionOptions {
  return {
    timeoutMs: Number(env[`${prefix}_TIMEOUT_MS`]),
    maxOutputTokens: Number(env[`${prefix}_MAX_OUTPUT_TOKENS`]),
    reasoningEffort: env[`${prefix}_REASONING_EFFORT`]?.trim(),
    reasoningFormat: env[`${prefix}_REASONING_FORMAT`]?.trim(),
    keepAlive: env[`${prefix}_KEEP_ALIVE`]?.trim()
  };
}

export function createVisionProvider(env: VisionEnvironment = process.env, prefix = 'AI_NPC_VISION'): VisionProvider {
  const kind = (env[`${prefix}_PROVIDER`] ?? '').trim().toLowerCase();
  if (!kind || kind === 'none') return new NoopVisionProvider();
  const options = providerOptions(env, prefix);
  if (['openai-compatible', 'openai', 'custom'].includes(kind)) {
    const endpoint = env[`${prefix}_ENDPOINT`]?.trim() || (prefix === 'AI_NPC_VISION' ? env.AI_NPC_PROVIDER_ENDPOINT?.trim() : '') || 'https://api.openai.com/v1';
    const key = env[`${prefix}_KEY`] ?? (prefix === 'AI_NPC_VISION' ? env.AI_NPC_PROVIDER_KEY ?? '' : '');
    const model = env[`${prefix}_MODEL`]?.trim() || 'gpt-4o-mini';
    return new OpenAICompatibleVisionProvider(endpoint, key, model, options);
  }
  if (kind === 'gemini' || kind === 'google') {
    const key = env[`${prefix}_KEY`]?.trim() || '';
    if (!key) throw new Error(`vision_key_missing:${prefix}`);
    return new GeminiVisionProvider(env[`${prefix}_ENDPOINT`]?.trim() || 'https://generativelanguage.googleapis.com', key, env[`${prefix}_MODEL`]?.trim() || 'gemini-3.5-flash-lite', options);
  }
  if (kind === 'ollama') return new OllamaVisionProvider(env[`${prefix}_ENDPOINT`]?.trim() || 'http://127.0.0.1:11434', env[`${prefix}_MODEL`]?.trim() || 'gemma3:4b', options);
  throw new Error(`unsupported_vision_provider:${kind}`);
}

export function createVisionPipeline(env: VisionEnvironment = process.env): VisionProvider {
  const primary = createVisionProvider(env);
  if (primary.name === 'none' || !env.AI_NPC_VISION_FALLBACK_PROVIDER?.trim()) return primary;
  return new FallbackVisionProvider(primary, createVisionProvider(env, 'AI_NPC_VISION_FALLBACK'));
}
