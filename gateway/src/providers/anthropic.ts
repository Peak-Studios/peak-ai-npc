import type { TurnInput, TurnOutput } from '../contracts.js';
import { boundResponseText, composeSystemPrompt } from '../prompts.js';
import { providerTools, validateToolArguments } from '../tools.js';
import type { TextProvider } from './types.js';

export class AnthropicProvider implements TextProvider {
  readonly name = 'anthropic';
  constructor(private readonly endpoint: string, private readonly key: string, private readonly model: string) {}

  async complete(input: TurnInput, signal?: AbortSignal): Promise<TurnOutput> {
    if (!this.key) throw new Error('anthropic_key_missing');
    const messages = [...input.history, { role: 'user' as const, content: input.input }];
    const tools = process.env.AI_NPC_PROVIDER_TOOL_MODE === 'off' ? [] : providerTools(input.allowedTools, input.toolSchemas).map(tool => ({ name: tool.function.name, description: tool.function.description, input_schema: tool.function.parameters }));
    const response = await fetch(`${this.endpoint.replace(/\/$/, '')}/messages`, {
      method: 'POST', signal: signal ?? AbortSignal.timeout(Number(process.env.AI_NPC_PROVIDER_TIMEOUT_MS ?? 12_000)),
      headers: { 'content-type': 'application/json', 'x-api-key': this.key, 'anthropic-version': '2023-06-01' },
      // Current Claude models choose their own sampling/thinking behavior and
      // reject non-default sampling fields. Omitting temperature also remains
      // compatible with earlier Messages API models.
      body: JSON.stringify({ model: this.model, max_tokens: (input.context as Record<string, unknown>).mode === 'memory_extraction' ? 500 : 180, system: composeSystemPrompt(input), messages, ...(tools.length ? { tools } : {}) })
    });
    if (!response.ok) throw new Error(`provider_http_${response.status}`);
    const body = await response.json() as { content?: Array<{ type?: string; text?: string; name?: string; input?: unknown }>; usage?: { input_tokens?: number; output_tokens?: number } };
    const text = boundResponseText(body.content?.filter(part => part.type === 'text').map(part => part.text ?? '').join('') ?? '');
    const call = body.content?.find(part => part.type === 'tool_use');
    if (call?.name) {
      if (!input.allowedTools.includes(call.name) || !validateToolArguments(call.name, call.input, input.toolSchemas)) throw new Error('provider_invalid_tool_arguments');
      return { text, toolCall: { name: call.name, arguments: call.input as Record<string, unknown> }, usage: { provider: this.name, inputTokens: body.usage?.input_tokens, outputTokens: body.usage?.output_tokens } };
    }
    return { text, usage: { provider: this.name, inputTokens: body.usage?.input_tokens, outputTokens: body.usage?.output_tokens } };
  }
}
