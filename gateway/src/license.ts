import type { IncomingMessage } from 'node:http';
import { timingSafeEqual } from 'node:crypto';

export type LicenseTier = 'standard' | 'pro' | 'enterprise';
export type LicenseStatus = 'active' | 'suspended' | 'expired';

export interface LicenseInfo {
  key: string;
  tier: LicenseTier;
  status: LicenseStatus;
  rateLimit: number; // requests per minute
  allowedFeatures: string[];
}

export interface LicenseValidationResult {
  valid: boolean;
  info?: LicenseInfo;
  reason?: string;
  source?: 'local';
  serverId?: string;
}

const DEFAULT_FEATURES = ['tts', 'stt', 'vision', 'memory', 'residents'];

export function extractServerId(req: IncomingMessage): string {
  const header = req.headers['x-peak-server-id'];
  const raw = Array.isArray(header) ? (header[0] ?? '') : (header ?? '');
  return raw.trim();
}

/**
 * Extracts the gateway shared secret from HTTP request headers.
 * Accepts X-Peak-License-Key (preferred) or legacy X-AI-NPC-Secret.
 */
export function extractLicenseKey(req: IncomingMessage): string {
  const peakHeader = req.headers['x-peak-license-key'];
  if (peakHeader) {
    const raw = Array.isArray(peakHeader) ? (peakHeader[0] ?? '') : peakHeader;
    if (raw.trim()) return raw.trim();
  }

  const legacyHeader = req.headers['x-ai-npc-secret'];
  if (legacyHeader) {
    const raw = Array.isArray(legacyHeader) ? (legacyHeader[0] ?? '') : legacyHeader;
    if (raw.trim()) return raw.trim();
  }

  return '';
}

function safeCompare(a: string, b: string): boolean {
  const bufA = Buffer.from(a);
  const bufB = Buffer.from(b);
  return bufA.length === bufB.length && timingSafeEqual(bufA, bufB);
}

/**
 * Validates the gateway shared secret from the environment.
 *
 * Set AI_NPC_GATEWAY_SECRET to a long random string in your gateway .env.
 * The FiveM resource sends this value in the peak_ai_npc_gateway_url convar.
 * Never put this secret in Lua files, NUI, logs, or client-side code.
 */
export function validateLicenseKey(
  key: string,
  env: Record<string, string | undefined> = process.env
): LicenseValidationResult {
  if (!key || typeof key !== 'string') {
    return { valid: false, reason: 'license_key_missing' };
  }

  const trimmedKey = key.trim();
  if (trimmedKey.length < 4 || trimmedKey.length > 256) {
    return { valid: false, reason: 'invalid_license_key' };
  }

  const envSecret = (env.AI_NPC_GATEWAY_SECRET ?? '').trim();

  if (envSecret !== '') {
    if (safeCompare(trimmedKey, envSecret)) {
      return {
        valid: true,
        info: {
          key: trimmedKey,
          tier: 'pro',
          status: 'active',
          rateLimit: 120,
          allowedFeatures: DEFAULT_FEATURES,
        },
      };
    }
    return { valid: false, reason: 'invalid_license_key' };
  }

  // Development fallback: accept any non-empty key when no secret is configured
  const isDev = env.NODE_ENV !== 'production';
  if (isDev) {
    return {
      valid: true,
      info: {
        key: trimmedKey,
        tier: 'pro',
        status: 'active',
        rateLimit: 120,
        allowedFeatures: DEFAULT_FEATURES,
      },
    };
  }

  return { valid: false, reason: 'invalid_license_key' };
}

/** Validates the request secret against the configured gateway secret. */
export async function validateRequestLicense(
  key: string,
  serverId: string,
  _validator: unknown,
  env: Record<string, string | undefined> = process.env,
): Promise<LicenseValidationResult> {
  const result = validateLicenseKey(key, env);
  return {
    ...result,
    source: result.valid ? 'local' : undefined,
    ...(result.valid && serverId ? { serverId } : {}),
  };
}

// Stub for managed feature availability — always returns true in self-hosted mode
export type ManagedPaidFeature = 'llm' | 'tts' | 'stt' | 'vision';
export type ManagedFeature = ManagedPaidFeature | 'memory';

export function managedFeatureAvailable(_validation: LicenseValidationResult | undefined, _feature: ManagedFeature): boolean {
  return true;
}

export interface RateLimitStatus {
  allowed: boolean;
  limit: number;
  current: number;
  resetMs: number;
}

export class LicenseRateLimiter {
  private windows = new Map<
    string,
    { windowStart: number; count: number }
  >();

  check(key: string, limit: number): RateLimitStatus {
    const now = Date.now();
    const windowMs = 60_000;
    const record = this.windows.get(key);

    if (!record || now - record.windowStart >= windowMs) {
      this.windows.set(key, { windowStart: now, count: 1 });
      return {
        allowed: true,
        limit,
        current: 1,
        resetMs: windowMs,
      };
    }

    record.count += 1;
    const allowed = record.count <= limit;
    const resetMs = Math.max(0, windowMs - (now - record.windowStart));

    return {
      allowed,
      limit,
      current: record.count,
      resetMs,
    };
  }

  purgeExpired(): void {
    const now = Date.now();
    for (const [k, v] of this.windows.entries()) {
      if (now - v.windowStart >= 60_000) {
        this.windows.delete(k);
      }
    }
  }
}

/** Stub — no managed entitlement validation in self-hosted mode */
export class ManagedEntitlementValidator {
  async validate(_key: string, _serverId: string): Promise<LicenseValidationResult> {
    return { valid: false, reason: 'entitlement_not_configured' };
  }
  readiness() { return { configured: false, ready: false, reason: 'self_hosted' }; }
  purgeExpired() { /* no-op */ }
}
