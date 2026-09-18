import { createHash, randomUUID } from 'node:crypto';

export type UsageSettlement = {
  eventId: string;
  serverId: string;
  endpoint: 'turn' | 'speech' | 'transcribe' | 'vision';
  ttsCharacters: number;
  llmTokens: number;
  voiceSeconds: number;
};
export type UsageReservation = UsageSettlement & {
  protocolVersion: 2;
  action: 'reserve' | 'settle' | 'release';
  ownerId: string;
  fingerprint: string;
};

export function billingEventId(serverId: string, endpoint: UsageSettlement['endpoint'], operationId?: string) {
  const scope = createHash('sha256').update(serverId).digest('hex').slice(0, 12);
  return `bill_${scope}_${endpoint}_${operationId ? createHash('sha256').update(operationId).digest('hex').slice(0, 32) : randomUUID().replace(/-/g, '')}`;
}

export function estimatedTextTokens(...values: string[]) {
  const characters = values.reduce((total, value) => total + value.length, 0);
  return Math.max(1, Math.ceil(characters / 4));
}

export function settlementAmounts(ttsCharacters: number, llmTokens: number, qualityMode?: 'realtime' | 'quality', audioSeconds = 0) {
  const safeCharacters = Math.max(0, Math.trunc(ttsCharacters));
  const safeTokens = Math.max(0, Math.trunc(llmTokens));
  if (safeCharacters > 0 && (!Number.isFinite(audioSeconds) || audioSeconds <= 0)) throw new Error('audio_measurement_missing');
  const voiceSeconds = safeCharacters > 0 ? Math.ceil(audioSeconds * (qualityMode === 'quality' ? 2 : 1)) : 0;
  return { ttsCharacters: safeCharacters, llmTokens: safeTokens, voiceSeconds };
}

type FetchLike = typeof fetch;

export function usageUrl(env: Record<string, string | undefined> = process.env): string | undefined {
  const explicit = env.AI_NPC_USAGE_URL?.trim();
  if (explicit) return validatedUrl(explicit, env);
  const base = env.AI_NPC_PORTAL_BASE_URL?.trim();
  if (base) return validatedUrl(new URL('/api/gateway/usage', ensureAbsolute(base)).toString(), env);
  const entitlement = env.AI_NPC_ENTITLEMENT_URL?.trim();
  if (entitlement) return validatedUrl(new URL('/api/gateway/usage', ensureAbsolute(entitlement)).toString(), env);
  return undefined;
}

function ensureAbsolute(value: string) {
  const parsed = new URL(value);
  return parsed.toString();
}

function validatedUrl(value: string, env: Record<string, string | undefined>) {
  const parsed = new URL(value);
  if (parsed.protocol !== 'https:' && env.AI_NPC_LOCAL_DEVELOPMENT !== 'true') throw new Error('usage_url_invalid');
  return parsed.toString();
}

function boundedTimeout(value: unknown) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? Math.max(300, Math.min(5_000, Math.trunc(parsed))) : 1_500;
}

export class UsageSettlementClient {
  private readonly endpoint: string | undefined;
  private readonly secret: string;

  private readonly configurationError?: string;

  constructor(
    private readonly env: Record<string, string | undefined> = process.env,
    private readonly fetcher: FetchLike = fetch,
  ) {
    try { this.endpoint = usageUrl(env); }
    catch (error) { this.endpoint = undefined; this.configurationError = error instanceof Error ? error.message : 'usage_url_invalid'; }
    this.secret = env.AI_NPC_GATEWAY_PORTAL_SECRET?.trim() ?? '';
  }

  get configured() { return Boolean(this.endpoint && this.secret); }

  readiness() {
    if (this.configurationError) return { configured: true, ready: false, reason: this.configurationError };
    if (!this.endpoint) return { configured: false, ready: false, reason: 'usage_url_missing' };
    if (!this.secret) return { configured: false, ready: false, reason: 'portal_secret_missing' };
    if (this.secret.length < 32) return { configured: true, ready: false, reason: 'portal_secret_invalid' };
    return { configured: true, ready: true };
  }

  async settle(value: UsageSettlement, signal?: AbortSignal): Promise<boolean> {
    return this.send(value, signal);
  }

  async reserve(value: Omit<UsageReservation, 'protocolVersion' | 'action'>, signal?: AbortSignal) {
    await this.send({ ...value, protocolVersion: 2, action: 'reserve' }, signal);
  }

  async settleReserved(value: Omit<UsageReservation, 'protocolVersion' | 'action'>, signal?: AbortSignal) {
    await this.send({ ...value, protocolVersion: 2, action: 'settle' }, signal);
  }

  async release(value: Omit<UsageReservation, 'protocolVersion' | 'action'>) {
    // A canceled client must not cancel cleanup. Tombstones fence late reserve replies.
    await this.send({ ...value, ttsCharacters: 0, llmTokens: 0, voiceSeconds: 0, protocolVersion: 2, action: 'release' });
  }

  private async send(value: UsageSettlement | UsageReservation, signal?: AbortSignal): Promise<boolean> {
    const deadline = AbortSignal.timeout(boundedTimeout(this.env.AI_NPC_USAGE_TIMEOUT_MS));
    const shared = signal ? AbortSignal.any([signal, deadline]) : deadline;
    for (let attempt = 0; ; attempt++) {
      try { shared.throwIfAborted(); return await this.settleOnce(value, shared); }
      catch (error) {
        if (shared.aborted) throw new Error('usage_settlement_unavailable');
        const code = error instanceof Error ? error.message : '';
        if (attempt >= 2 || !/^usage_settlement_(?:unavailable|http_(?:408|425|429|5\d\d))$/.test(code)) throw error;
        await new Promise(resolve => setTimeout(resolve, 100 * (attempt + 1)));
      }
    }
  }
  private async settleOnce(value: UsageSettlement | UsageReservation, signal: AbortSignal): Promise<boolean> {
    if (!this.configured || this.secret.length < 32) throw new Error(this.configurationError ?? (this.secret ? 'usage_settlement_portal_secret_invalid' : 'usage_settlement_not_configured'));
    let response: Response;
    try {
      // Never send a v2 reserve to the v1 endpoint: older portals ignore extra
      // fields and would charge its maximum as completed usage.
      const target = new URL(this.endpoint!);
      if ('protocolVersion' in value) target.pathname = `${target.pathname.replace(/\/$/, '')}/reservations`;
      response = await this.fetcher(target.toString(), {
        method: 'POST',
        signal,
        headers: { authorization: `Bearer ${this.secret}`, 'content-type': 'application/json' },
        body: JSON.stringify(value),
      });
    } catch { throw new Error('usage_settlement_unavailable'); }
    let payload: Record<string, unknown> = {};
    try { payload = await response.json() as Record<string, unknown>; } catch { /* invalid response handled below */ }
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) throw new Error('usage_settlement_invalid_response');
    if (!response.ok) {
      const reason = typeof payload.reason === 'string' && /^[a-z0-9_-]{1,64}$/i.test(payload.reason) ? payload.reason : `http_${response.status}`;
      throw new Error(reason === 'quota_exceeded' ? 'usage_quota_exceeded' : `usage_settlement_${reason}`);
    }
    if (payload.success !== true) throw new Error('usage_settlement_invalid_response');
    if ('protocolVersion' in value) {
      const expected = value.action === 'reserve' ? ['reserved'] : value.action === 'release' ? ['released'] : ['settled', 'duplicate'];
      if (payload.protocolVersion !== 2 || payload.action !== value.action || !expected.includes(String(payload.outcome))) {
        throw new Error('usage_settlement_protocol_mismatch');
      }
    }
    return true;
  }
}
