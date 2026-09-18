export type HostedDataRequest = {
  id: string;
  serverId: string;
  requestType: 'delete_hosted_memory';
  requestedAt: string;
};

type FetchLike = typeof fetch;

function endpoint(env: Record<string, string | undefined>) {
  const explicit = env.AI_NPC_DATA_REQUESTS_URL?.trim();
  const entitlement = env.AI_NPC_ENTITLEMENT_URL?.trim();
  const value = explicit || (entitlement ? new URL('/api/gateway/data-requests', entitlement).toString() : '');
  if (!value) throw new Error('data_requests_url_missing');
  const parsed = new URL(value);
  if (parsed.protocol !== 'https:' && env.AI_NPC_LOCAL_DEVELOPMENT !== 'true') throw new Error('data_requests_url_invalid');
  return parsed.toString();
}

function validRequest(value: unknown): value is HostedDataRequest {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const row = value as Record<string, unknown>;
  return typeof row.id === 'string' && /^[0-9a-f-]{36}$/i.test(row.id)
    && typeof row.serverId === 'string' && /^srv_[A-Za-z0-9_-]{12,40}$/.test(row.serverId)
    && row.requestType === 'delete_hosted_memory'
    && typeof row.requestedAt === 'string' && Number.isFinite(Date.parse(row.requestedAt));
}

export class PortalDataDeletionClient {
  constructor(private readonly env: Record<string, string | undefined> = process.env, private readonly fetcher: FetchLike = fetch) {}

  readiness() {
    const secret = this.env.AI_NPC_GATEWAY_PORTAL_SECRET?.trim() ?? '';
    if (secret.length < 32) return { ready: false, reason: 'portal_secret_invalid' };
    try { return { ready: true, endpoint: new URL(endpoint(this.env)).origin }; }
    catch (error) { return { ready: false, reason: error instanceof Error ? error.message : 'data_requests_url_invalid' }; }
  }

  async list(signal?: AbortSignal): Promise<HostedDataRequest[]> {
    const response = await this.call({ method: 'GET', signal });
    const payload = await response.json().catch(() => null) as Record<string, unknown> | null;
    if (!response.ok) throw new Error(response.status === 401 ? 'data_requests_unauthorized' : 'data_requests_unavailable');
    if (!payload || !Array.isArray(payload.requests) || !payload.requests.every(validRequest)) throw new Error('data_requests_invalid_response');
    return payload.requests;
  }

  async complete(request: HostedDataRequest, counts: {
    deletedMemoryRecords: number;
    deletedResidentKnowledgeRecords: number;
    clearedTransientConversations: number;
  }, signal?: AbortSignal) {
    const response = await this.call({ method: 'POST', signal, headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ requestId: request.id, serverId: request.serverId, ...counts }) });
    const payload = await response.json().catch(() => null) as Record<string, unknown> | null;
    if (!response.ok || payload?.success !== true || payload.status !== 'completed') {
      throw new Error(response.status === 404 ? 'data_request_not_found' : response.status === 409 ? 'data_request_not_pending' : 'data_request_completion_failed');
    }
    return { idempotent: payload.idempotent === true };
  }

  private call(init: RequestInit) {
    const secret = this.env.AI_NPC_GATEWAY_PORTAL_SECRET?.trim() ?? '';
    if (secret.length < 32) throw new Error('portal_secret_invalid');
    return this.fetcher(endpoint(this.env), { ...init, signal: init.signal ?? AbortSignal.timeout(5_000),
      headers: { authorization: `Bearer ${secret}`, ...init.headers } });
  }
}
