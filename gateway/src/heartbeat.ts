/**
 * Heartbeat client — no-op in self-hosted mode.
 * In self-hosted deployments the gateway does not report status to an external portal.
 */

export type PortalHeartbeat = {
  serverId: string;
  status: 'ready' | 'degraded';
  reason?: string;
  resourceVersion?: string;
};

export class PortalHeartbeatClient {
  get configured() { return false; }
  readiness() { return { configured: false, ready: false, reason: 'self_hosted' }; }
  async send(_value: PortalHeartbeat): Promise<boolean> { return false; }
}
