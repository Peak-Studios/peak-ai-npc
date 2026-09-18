/**
 * Data deletion client — no-op in self-hosted mode.
 *
 * In self-hosted deployments there is no external portal to receive deletion
 * requests from. Operators manage their own data retention directly via the
 * gateway's local memory store and PostgreSQL database.
 */

export type HostedDataRequest = {
  id: string;
  serverId: string;
  requestType: 'delete_hosted_memory';
  requestedAt: string;
};

export class PortalDataDeletionClient {
  readiness() { return { ready: false, reason: 'self_hosted' }; }
  async list(_signal?: AbortSignal): Promise<HostedDataRequest[]> { return []; }
  async complete(
    _request: HostedDataRequest,
    _counts: { deletedMemoryRecords: number; deletedResidentKnowledgeRecords: number; clearedTransientConversations: number },
    _signal?: AbortSignal
  ) { return { idempotent: false }; }
}
