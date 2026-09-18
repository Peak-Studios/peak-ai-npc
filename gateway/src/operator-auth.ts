import { timingSafeEqual } from 'node:crypto';

/** Separate from customer activation and portal credentials; disabled unless configured. */
export function operatorAuthorized(value: string | string[] | undefined, env: NodeJS.ProcessEnv = process.env): boolean {
  const secret = env.AI_NPC_OPERATOR_SECRET;
  if (!secret || secret.length < 32 || secret === env.AI_NPC_GATEWAY_SECRET
    || secret === env.AI_NPC_GATEWAY_PORTAL_SECRET || typeof value !== 'string') return false;
  const expected = Buffer.from(secret), supplied = Buffer.from(value);
  return supplied.length === expected.length && timingSafeEqual(expected, supplied);
}
