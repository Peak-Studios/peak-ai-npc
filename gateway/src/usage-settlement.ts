import { createHash, randomUUID } from 'node:crypto';

/**
 * Usage settlement — no-op in self-hosted mode.
 *
 * In self-hosted deployments there is no external portal to report usage to.
 * All methods succeed silently. The type definitions are preserved so that
 * the gateway's internal accounting and operation ledger still work correctly.
 */

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

/** No-op usage client for self-hosted deployments. */
export class UsageSettlementClient {
  get configured() { return false; }
  readiness() { return { configured: false, ready: false, reason: 'self_hosted' }; }
  async settle(_value: UsageSettlement, _signal?: AbortSignal): Promise<boolean> { return true; }
  async reserve(_value: Omit<UsageReservation, 'protocolVersion' | 'action'>, _signal?: AbortSignal) { /* no-op */ }
  async settleReserved(_value: Omit<UsageReservation, 'protocolVersion' | 'action'>, _signal?: AbortSignal) { /* no-op */ }
  async release(_value: Omit<UsageReservation, 'protocolVersion' | 'action'>) { /* no-op */ }
}
