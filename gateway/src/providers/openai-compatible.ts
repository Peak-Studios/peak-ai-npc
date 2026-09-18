import type { TurnInput, TurnOutput } from '../contracts.js';
import type { TextProvider } from './types.js';
import { providerTools, validateToolArguments } from '../tools.js';
import { boundResponseText, composeSystemPrompt } from '../prompts.js';

export type OpenAICompatibleOptions = {
  reasoningEffort?: string;
  reasoningFormat?: string;
  maxOutputTokens?: number;
};

function boundedOutputTokens(value: unknown) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? Math.max(32, Math.min(1000, Math.trunc(parsed))) : 180;
}

function secondsToMs(value: unknown) {
  const seconds = Number(value);
  return Number.isFinite(seconds) && seconds >= 0 ? Math.round(seconds * 1000) : undefined;
}

export class OpenAICompatibleProvider implements TextProvider {
  readonly name: string;
  constructor(private readonly endpoint: string, private readonly key: string, private readonly model: string, name = 'openai-compatible', private readonly options: OpenAICompatibleOptions = {}) { this.name = name; }
  async complete(input: TurnInput, signal?: AbortSignal): Promise<TurnOutput> {
    const system = composeSystemPrompt(input);
    // Keep recent history bounded to 8 messages (4 turns) to keep prompt tokens compact and prevent TPM rate limits in long conversations
    const history = (input.history || []).slice(-8);
    const messages: Array<Record<string, unknown>> = [{ role: 'system', content: system }, ...history, { role: 'user', content: input.input }];
    // A key is intentionally optional.  Local runtimes such as Ollama, vLLM,
    // llama.cpp and LiteLLM deployments commonly expose this protocol without
    // bearer authentication.
    const headers: Record<string, string> = { 'content-type': 'application/json' };
    if (this.key) headers.authorization = `Bearer ${this.key}`;
    const tools = process.env.AI_NPC_PROVIDER_TOOL_MODE === 'off' ? [] : providerTools(input.allowedTools, input.toolSchemas);
    const extraction = (input.context as Record<string, unknown>).mode === 'memory_extraction';
    const request = {
      model: this.model,
      messages,
      ...(tools.length ? { tools, tool_choice: 'auto' } : {}),
      temperature: extraction ? 0.1 : 0.7,
      max_tokens: extraction ? 500 : boundedOutputTokens(this.options.maxOutputTokens),
      ...(this.options.reasoningEffort ? { reasoning_effort: this.options.reasoningEffort } : {}),
      ...(this.options.reasoningFormat ? { reasoning_format: this.options.reasoningFormat } : {})
    };
    const response = await fetch(`${this.endpoint.replace(/\/$/, '')}/chat/completions`, { method: 'POST', signal: signal ?? AbortSignal.timeout(Number(process.env.AI_NPC_PROVIDER_TIMEOUT_MS ?? 12_000)), headers, body: JSON.stringify(request) });
    if (!response.ok) {
      const err = new Error(`provider_http_${response.status}`);
      let waitMs = 0;
      const retryAfter = response.headers.get('retry-after');
      const resetTokens = response.headers.get('x-ratelimit-reset-tokens');
      if (retryAfter) {
        const sec = parseFloat(retryAfter);
        if (!isNaN(sec) && sec > 0) waitMs = Math.ceil(sec * 1000);
      } else if (resetTokens) {
        if (resetTokens.endsWith('ms')) waitMs = parseFloat(resetTokens);
        else if (resetTokens.endsWith('s')) waitMs = parseFloat(resetTokens) * 1000;
      }
      if (response.status === 429 && waitMs === 0) waitMs = 2000;
      (err as any).retryAfterMs = waitMs;
      throw err;
    }
    const body = await response.json() as any;
    const message = body.choices?.[0]?.message ?? {};
    const requestedTool = message.tool_calls?.[0];
    let toolCall;
    if (requestedTool?.function?.name) {
      if (!input.allowedTools.includes(requestedTool.function.name)) throw new Error('provider_tool_not_allowed');
      let args: Record<string, unknown> = {};
      try { args = JSON.parse(requestedTool.function.arguments || '{}'); } catch { throw new Error('provider_invalid_tool_arguments'); }
      if (!validateToolArguments(requestedTool.function.name, args, input.toolSchemas)) throw new Error('provider_invalid_tool_arguments');
      toolCall = { name: requestedTool.function.name, arguments: args };
    }
    let text = boundResponseText(message.content);
    if (!text && !toolCall && !extraction) throw new Error('provider_empty_output');
    return { text: text || '', toolCall, usage: {
      provider: this.name,
      inputTokens: body.usage?.prompt_tokens,
      outputTokens: body.usage?.completion_tokens,
      queueMs: secondsToMs(body.usage?.queue_time),
      promptMs: secondsToMs(body.usage?.prompt_time),
      completionMs: secondsToMs(body.usage?.completion_time)
    } };
  }
}
