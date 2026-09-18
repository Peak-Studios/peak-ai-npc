import type { TurnInput, TurnOutput } from '../contracts.js';
import { boundResponseText, composeSystemPrompt } from '../prompts.js';
import { providerTools, validateToolArguments } from '../tools.js';
import type { TextProvider } from './types.js';

// Gemini function declarations use an OpenAPI-compatible schema subset. It
// does not accept JSON Schema's `additionalProperties`, so remove that
// enforcement-only field at the provider boundary; server validation remains
// authoritative and uses the original shared schema.
function geminiSchema(value: unknown): unknown {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return value;
  const schema = value as Record<string, unknown>;
  const converted: Record<string, unknown> = {};
  for (const [key, item] of Object.entries(schema)) {
    if (key === 'additionalProperties') continue;
    if (key === 'properties' && item && typeof item === 'object' && !Array.isArray(item)) {
      converted.properties = Object.fromEntries(Object.entries(item as Record<string, unknown>).map(([name, property]) => [name, geminiSchema(property)]));
      continue;
    }
    if (key === 'items') { converted.items = geminiSchema(item); continue; }
    converted[key] = item;
  }
  return converted;
}

export class GeminiProvider implements TextProvider {
  readonly name = 'gemini';
  constructor(private readonly endpoint: string, private readonly key: string, private readonly model: string) {}

  async complete(input: TurnInput, signal?: AbortSignal): Promise<TurnOutput> {
    if (!this.key) throw new Error('gemini_key_missing');
    const contents = [...input.history, { role: 'user' as const, content: input.input }].map(message => ({ role: message.role === 'assistant' ? 'model' : 'user', parts: [{ text: message.content }] }));
    const declarations = process.env.AI_NPC_PROVIDER_TOOL_MODE === 'off' ? [] : providerTools(input.allowedTools, input.toolSchemas).map(tool => ({ name: tool.function.name, description: tool.function.description, parameters: geminiSchema(tool.function.parameters) }));
    const base = this.endpoint.replace(/\/$/, '');
    const response = await fetch(`${base}/v1beta/models/${encodeURIComponent(this.model)}:generateContent?key=${encodeURIComponent(this.key)}`, {
      method: 'POST', signal: signal ?? AbortSignal.timeout(Number(process.env.AI_NPC_PROVIDER_TIMEOUT_MS ?? 12_000)), headers: { 'content-type': 'application/json' },
      // Current Gemini production models reject the legacy sampling fields
      // (temperature/top-p/top-k). Keep the bounded output limit only.
      body: JSON.stringify({ systemInstruction: { parts: [{ text: composeSystemPrompt(input) }] }, contents, tools: declarations.length ? [{ functionDeclarations: declarations }] : undefined, generationConfig: { maxOutputTokens: (input.context as Record<string, unknown>).mode === 'memory_extraction' ? 500 : 180 } })
    });
    if (!response.ok) throw new Error(`provider_http_${response.status}`);
    const body = await response.json() as { candidates?: Array<{ content?: { parts?: Array<{ text?: string; functionCall?: { name?: string; args?: unknown } }> } }>; usageMetadata?: { promptTokenCount?: number; candidatesTokenCount?: number } };
    const parts = body.candidates?.[0]?.content?.parts ?? [];
    const text = boundResponseText(parts.map(part => part.text ?? '').join(''));
    const call = parts.find(part => part.functionCall)?.functionCall;
    if (call?.name) {
      if (!input.allowedTools.includes(call.name) || !validateToolArguments(call.name, call.args, input.toolSchemas)) throw new Error('provider_invalid_tool_arguments');
      return { text, toolCall: { name: call.name, arguments: call.args as Record<string, unknown> }, usage: { provider: this.name, inputTokens: body.usageMetadata?.promptTokenCount, outputTokens: body.usageMetadata?.candidatesTokenCount } };
    }
    return { text, usage: { provider: this.name, inputTokens: body.usageMetadata?.promptTokenCount, outputTokens: body.usageMetadata?.candidatesTokenCount } };
  }
}
