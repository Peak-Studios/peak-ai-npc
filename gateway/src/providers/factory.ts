import { AnthropicProvider } from './anthropic.js';
import { GeminiProvider } from './gemini.js';
import { MockProvider } from './mock.js';
import { OpenAICompatibleProvider } from './openai-compatible.js';
import type { TextProvider } from './types.js';

export type ProviderEnvironment = Record<string, string | undefined>;

/** Creates a text provider without coupling the FiveM resource to any vendor. */
export function createTextProvider(env: ProviderEnvironment = process.env, providerSetting = 'AI_NPC_PROVIDER'): TextProvider {
  // The primary provider uses AI_NPC_PROVIDER_* while named secondary slots
  // use prefixes such as AI_NPC_FALLBACK_*. Preserve the primary prefix so a
  // configured endpoint/key/model never silently falls back to OpenAI defaults.
  const base = providerSetting === 'AI_NPC_PROVIDER' ? providerSetting : providerSetting.replace(/_PROVIDER$/, '');
  const setting = (name: string) => {
    if (name === 'PROVIDER') return env[providerSetting];
    return env[`${base}_${name}`] ?? (base !== 'AI_NPC_PROVIDER' ? env[`AI_NPC_PROVIDER_${name}`] : undefined);
  };
  const kind = (setting('PROVIDER') ?? 'mock').trim().toLowerCase();
  const key = setting('KEY') ?? '';
  const openAIOptions = {
    reasoningEffort: setting('REASONING_EFFORT')?.trim(),
    reasoningFormat: setting('REASONING_FORMAT')?.trim(),
    maxOutputTokens: setting('MAX_OUTPUT_TOKENS') ? Number(setting('MAX_OUTPUT_TOKENS')) : undefined
  };
  if (kind === 'mock') return new MockProvider();
  if (kind === 'openai-compatible' || kind === 'openai' || kind === 'custom') return new OpenAICompatibleProvider(setting('ENDPOINT') ?? 'https://api.openai.com/v1', key, setting('MODEL') ?? 'gpt-4o-mini', kind, openAIOptions);
  if (kind === 'ollama') return new OpenAICompatibleProvider(setting('ENDPOINT') ?? 'http://127.0.0.1:11434/v1', key, setting('MODEL') ?? 'llama3.2', 'ollama', openAIOptions);
  if (kind === 'anthropic' || kind === 'claude') return new AnthropicProvider(setting('ENDPOINT') ?? 'https://api.anthropic.com/v1', key, setting('MODEL') ?? 'claude-sonnet-5');
  if (kind === 'gemini' || kind === 'google') return new GeminiProvider(setting('ENDPOINT') ?? 'https://generativelanguage.googleapis.com', key, setting('MODEL') ?? 'gemini-3.6-flash');
  throw new Error(`unsupported_text_provider:${kind}`);
}
