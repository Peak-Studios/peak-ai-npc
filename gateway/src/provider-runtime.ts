import type { TurnInput, TurnOutput } from './contracts.js';
import type { TextProvider } from './providers/types.js';
import { setTimeout as delay } from 'node:timers/promises';

export type ProviderAttempt = { provider: string; role: 'primary' | 'fallback'; attempt: number; latencyMs: number; outcome: 'success' | 'error'; error?: string };
type RetryOptions = { retries?: number; delayMs?: number; timeoutMs?: number; signal?: AbortSignal; onAttempt?: (metrics: ProviderAttempt) => void };
function retryable(error: unknown) {
  const message = error instanceof Error ? `${error.name}:${error.message}` : String(error);
  // Lost responses may follow paid work; do not redispatch ambiguous outcomes.
  return /(?:provider_down|provider_http_(?:425|429))$/i.test(message);
}
function bounded(value: number, fallback: number, maximum: number) { return Number.isFinite(value) ? Math.max(0, Math.min(maximum, Math.trunc(value))) : fallback; }
const activeCalls = new WeakMap<TextProvider, number>();
async function attempt(provider: TextProvider, input: TurnInput, signal: AbortSignal): Promise<TurnOutput> {
  signal.throwIfAborted();
  const maximum = Math.max(1, bounded(Number(process.env.AI_NPC_PROVIDER_CONCURRENCY ?? 8), 8, 128));
  const active = activeCalls.get(provider) ?? 0;
  if (active >= maximum) throw new Error('provider_concurrency_limit');
  activeCalls.set(provider, active + 1);
  // Race also bounds custom adapters that have not yet implemented cancellation.
  let abort: () => void = () => {};
  const cancelled = new Promise<never>((_, reject) => { abort = () => reject(signal.reason); signal.addEventListener('abort', abort, { once: true }); });
  // Hold capacity until the actual adapter settles, even if it ignores abort.
  // A timeout must never turn four stuck calls into an unbounded upstream queue.
  const work = Promise.resolve().then(() => { signal.throwIfAborted(); return provider.complete(input, signal); })
    .finally(() => activeCalls.set(provider, Math.max(0, (activeCalls.get(provider) ?? 1) - 1)));
  try { return await Promise.race([work, cancelled]); }
  finally { signal.removeEventListener('abort', abort); }
}
function errorCode(error: unknown) {
  const message = error instanceof Error ? error.message : String(error);
  return /^[a-z0-9_:-]{1,80}$/i.test(message) ? message : 'provider_error';
}
function reportAttempt(options: RetryOptions, metrics: ProviderAttempt) {
  try { options.onAttempt?.(metrics); } catch { /* Metrics must never change provider behavior. */ }
}
async function completeWithRetry(provider: TextProvider, input: TurnInput, options: RetryOptions, signal: AbortSignal, role: ProviderAttempt['role']) {
  const retries = bounded(options.retries ?? Number(process.env.AI_NPC_PROVIDER_RETRIES ?? 0), 0, 5);
  const delayMs = bounded(options.delayMs ?? Number(process.env.AI_NPC_PROVIDER_RETRY_DELAY_MS ?? 500), 0, 5000);
  for (let index = 0; ; index++) {
    signal.throwIfAborted();
    const startedAt = Date.now();
    try {
      const result = await attempt(provider, input, signal);
      reportAttempt(options, { provider: provider.name, role, attempt: index + 1, latencyMs: Date.now() - startedAt, outcome: 'success' });
      return result;
    }
    catch (error) {
      reportAttempt(options, { provider: provider.name, role, attempt: index + 1, latencyMs: Date.now() - startedAt, outcome: 'error', error: errorCode(error) });
      signal.throwIfAborted();
      if (index >= retries || !retryable(error)) throw error;
      const specificDelay = options.delayMs === 0 ? 0 : Number((error as any)?.retryAfterMs);
      const waitTime = specificDelay ? Math.min(specificDelay + 250, 4000) : (delayMs ? delayMs * (index + 1) : 0);
      if (waitTime > 0) await delay(waitTime, undefined, { signal });
    }
  }
}
export async function completeWithFallback(primary: TextProvider, fallback: TextProvider, input: TurnInput, options: RetryOptions = {}): Promise<TurnOutput> {
  const timeoutMs = Math.max(1, bounded(options.timeoutMs ?? Number(process.env.AI_NPC_PROVIDER_TIMEOUT_MS ?? 20000), 20000, 120000));
  const timer = AbortSignal.timeout(timeoutMs);
  const signal = options.signal ? AbortSignal.any([options.signal, timer]) : timer;
  try { return await completeWithRetry(primary, input, options, signal, 'primary'); }
  catch (error) {
    signal.throwIfAborted();
    if (primary === fallback || !retryable(error)) throw error;
    const result = await completeWithRetry(fallback, input, options, signal, 'fallback');
    result.usage = { ...(result.usage ?? { provider: fallback.name }), provider: fallback.name, fallbackFrom: primary.name };
    return result;
  }
}
