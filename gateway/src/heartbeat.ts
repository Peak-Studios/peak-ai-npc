export type PortalHeartbeat = {
  serverId: string;
  status: 'ready' | 'degraded';
  reason?: string;
  resourceVersion?: string;
};

type FetchLike = typeof fetch;

export function heartbeatUrl(env: Record<string, string | undefined> = process.env): string | undefined {
  const explicit = env.AI_NPC_HEARTBEAT_URL?.trim();
  const source = explicit || env.AI_NPC_PORTAL_BASE_URL?.trim() || env.AI_NPC_ENTITLEMENT_URL?.trim();
  if (!source) return undefined;
  const parsed = explicit ? new URL(source) : new URL('/api/gateway/installations/heartbeat', new URL(source));
  if (parsed.protocol !== 'https:' && env.AI_NPC_LOCAL_DEVELOPMENT !== 'true') throw new Error('heartbeat_url_invalid');
  return parsed.toString();
}

function timeout(value: unknown) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? Math.max(300, Math.min(5_000, Math.trunc(parsed))) : 1_500;
}

export class PortalHeartbeatClient {
  private readonly endpoint: string | undefined;
  private readonly secret: string;

  private readonly configurationError?: string;

  constructor(
    private readonly env: Record<string, string | undefined> = process.env,
    private readonly fetcher: FetchLike = fetch,
  ) {
    try { this.endpoint = heartbeatUrl(env); }
    catch (error) { this.endpoint = undefined; this.configurationError = error instanceof Error ? error.message : 'heartbeat_url_invalid'; }
    this.secret = env.AI_NPC_GATEWAY_PORTAL_SECRET?.trim() ?? '';
  }

  get configured() { return Boolean(this.endpoint && this.secret); }

  readiness() {
    if (this.configurationError) return { configured: true, ready: false, reason: this.configurationError };
    if (!this.endpoint) return { configured: false, ready: false, reason: 'heartbeat_url_missing' };
    if (!this.secret) return { configured: false, ready: false, reason: 'portal_secret_missing' };
    if (this.secret.length < 32) return { configured: true, ready: false, reason: 'portal_secret_invalid' };
    return { configured: true, ready: true };
  }

  async send(value: PortalHeartbeat): Promise<boolean> {
    if (!this.configured || this.secret.length < 32) return false;
    let response: Response;
    try {
      response = await this.fetcher(this.endpoint!, {
        method: 'POST',
        signal: AbortSignal.timeout(timeout(this.env.AI_NPC_HEARTBEAT_TIMEOUT_MS)),
        headers: { authorization: `Bearer ${this.secret}`, 'content-type': 'application/json' },
        body: JSON.stringify(value),
      });
    } catch { throw new Error('heartbeat_unavailable'); }
    if (!response.ok) throw new Error(`heartbeat_http_${response.status}`);
    if (response.status !== 204) {
      const payload: unknown = await response.json().catch(() => null);
      if (!payload || typeof payload !== 'object' || Array.isArray(payload)
          || (payload as Record<string, unknown>).success !== true) throw new Error('heartbeat_invalid_response');
    }
    return true;
  }
}
