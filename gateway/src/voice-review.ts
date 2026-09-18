import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

/** Operator-only loopback client; the gateway performs durable writes in its owning process. */
export async function reviewVoices(env: Record<string, string | undefined>, args: string[], request = fetch) {
  const value = (flag: string) => { const index = args.indexOf(flag); return index >= 0 ? args[index + 1] : undefined; };
  const secret = env.AI_NPC_OPERATOR_SECRET;
  if (!secret || secret.length < 32) throw new Error('operator_secret_missing');
  const origin = new URL(env.AI_NPC_OPERATOR_URL ?? 'http://127.0.0.1:8787');
  if (origin.protocol !== 'http:' || !['127.0.0.1', '[::1]', 'localhost'].includes(origin.hostname)
    || origin.username || origin.password || origin.pathname !== '/' || origin.search || origin.hash) throw new Error('operator_loopback_required');
  const target = new URL('/v1/operator/voices', origin);
  const file = value('--request');
  const serverId = value('--server');
  let payload: unknown;
  if (file) {
    const source = await readFile(resolve(file), 'utf8');
    if (source.length > 20000) throw new Error('voice_review_request_too_large');
    payload = JSON.parse(source);
  } else {
    if (!serverId) throw new Error('voice_review_server_required');
    target.searchParams.set('serverId', serverId);
  }
  const response = await request(target, { method: file ? 'POST' : 'GET', redirect: 'error',
    headers: { 'x-ai-npc-operator-secret': secret, ...(file ? { 'content-type': 'application/json' } : {}) },
    ...(file ? { body: JSON.stringify(payload) } : {}), signal: AbortSignal.timeout(10000) });
  const result = await response.json() as Record<string, unknown>;
  if (!response.ok) throw new Error(typeof result.error === 'string' && /^[a-z_]{1,80}$/.test(result.error) ? result.error : 'voice_review_request_failed');
  return result;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  reviewVoices(process.env, process.argv.slice(2)).then(result => console.log(JSON.stringify(result, null, 2)))
    .catch(error => { const code = error instanceof Error && /^[a-z_]{1,80}$/.test(error.message) ? error.message : 'voice_review_request_failed'; console.error(JSON.stringify({ error: code })); process.exitCode = 1; });
}
