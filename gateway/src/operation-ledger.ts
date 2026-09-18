import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { writeJsonAtomically } from './atomic-json.js';
import type { TurnInput } from './contracts.js';
export function turnOperationKey(turn: TurnInput) {
  const stage = turn.toolResult ? createHash('sha256').update(JSON.stringify(turn.toolResult)).digest('hex') : 'initial';
  return createHash('sha256').update(JSON.stringify([turn.serverId, turn.sessionId, turn.requestId ?? turn.turnId ?? turn.gatewayNonce, stage])).digest('hex');
}
type Entry<T> = { expires: number; createdAt?: number; value?: T; pending?: Promise<T>; settled: boolean; uncertain?: boolean; fingerprint?: string; context?: unknown };
export class OperationLedger<T> {
  private entries = new Map<string, Entry<T>>();
  private ready?: Promise<void>;
  private writes: Promise<void> = Promise.resolve();
  private reconciling = false;
  constructor(private ttlMs = 86400000, private capacity = 2000, private path?: string) {}
  private async load() {
    if (!this.path) return;
    try {
      const rows = JSON.parse(await readFile(this.path, 'utf8')) as Array<[string, Entry<T>]>;
      if (!Array.isArray(rows)) throw new Error('invalid_operation_ledger');
      const seen = new Set<string>();
      for (const row of rows) {
        if (!Array.isArray(row) || row.length !== 2) throw new Error('invalid_operation_ledger');
        const [key, entry] = row;
        if (typeof key !== 'string' || !key || seen.has(key) || !entry || typeof entry !== 'object'
          || !Number.isFinite(entry.expires) || typeof entry.settled !== 'boolean'
          || (entry.createdAt !== undefined && (!Number.isFinite(entry.createdAt) || entry.createdAt < 0))
          || (entry.settled && entry.value === undefined)) throw new Error('invalid_operation_ledger');
        seen.add(key);
      }
      for (const [key, entry] of rows) {
        // An unpaid result or ambiguous dispatch must survive the replay TTL.
        if (!entry.settled || entry.expires >= Date.now()) this.entries.set(key, { ...entry, pending: undefined, uncertain: entry.value === undefined });
      }
      if (this.entries.size !== rows.length) await this.persist();
    } catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error; }
  }
  private persist(entries = this.entries) {
    if (!this.path) return Promise.resolve();
    const path = this.path;
    const snapshot = JSON.stringify([...entries].map(([key, { pending, ...entry }]) => [key, entry]));
    const write = this.writes.then(() => writeJsonAtomically(path, snapshot));
    this.writes = write.catch(() => {});
    return write;
  }
  async cleanup(): Promise<void> {
    await (this.ready ??= this.load());
    if (this.reconciling) return;
    let changed = false;
    for (const [id, entry] of this.entries) {
      if (entry.settled && !entry.pending && entry.expires < Date.now()) { this.entries.delete(id); changed = true; }
    }
    if (changed) await this.persist();
  }
  /** Aggregate only: never expose operation keys, paid results, or customer dialogue. */
  async stats() {
    await (this.ready ??= this.load());
    const now = Date.now();
    const unresolved = [...this.entries.values()].filter(entry => !entry.settled);
    const ages = unresolved.map(entry => Math.max(0, now - (entry.createdAt ?? entry.expires - this.ttlMs)));
    return {
      entries: this.entries.size, capacity: this.capacity,
      available: Math.max(0, this.capacity - this.entries.size),
      unresolved: unresolved.length,
      uncertain: unresolved.filter(entry => entry.uncertain && !entry.pending).length,
      inFlight: [...this.entries.values()].filter(entry => entry.pending).length + (this.reconciling ? 1 : 0),
      oldestUnresolvedAgeMs: ages.length ? Math.max(...ages) : 0
    };
  }
  /** Operator reconciliation: inspect unresolved operation hashes and status without exposing customer dialogue. */
  async listUnresolved(): Promise<Array<{ key: string; createdAt?: number; expires: number; settled: boolean; uncertain: boolean; inFlight: boolean }>> {
    await (this.ready ??= this.load());
    const result: Array<{ key: string; createdAt?: number; expires: number; settled: boolean; uncertain: boolean; inFlight: boolean }> = [];
    for (const [key, entry] of this.entries) {
      if (!entry.settled || entry.uncertain || entry.pending) {
        result.push({
          key,
          createdAt: entry.createdAt,
          expires: entry.expires,
          settled: entry.settled,
          uncertain: !!entry.uncertain && !entry.pending,
          inFlight: !!entry.pending
        });
      }
    }
    return result;
  }
  /** Operator reconciliation: explicitly settle or discard an uncertain/unsettled operation. */
  async reconcile(key: string, action: 'settle' | 'discard', value?: T, beforeCommit?: (value: T | undefined, context: unknown) => Promise<void>): Promise<{ success: boolean; key: string; action: string }> {
    await (this.ready ??= this.load());
    if (this.reconciling || [...this.entries.values()].some(entry => entry.pending)) throw new Error('operation_in_flight');
    const entry = this.entries.get(key);
    if (!entry) throw new Error('operation_not_found');
    if (action !== 'settle' && action !== 'discard') throw new Error('invalid_reconcile_action');
    if (action === 'settle' && value === undefined && entry.value === undefined) throw new Error('operation_result_missing');
    this.reconciling = true;
    try {
      // Block new work and drain previous cleanup writes before snapshotting.
      // Readers keep the old committed state if storage fails.
      await this.writes;
      // Remote billing must complete before recording local reconciliation.
      // Both remote operations are idempotent if the subsequent disk write fails.
      await beforeCommit?.(entry.value, entry.context);
      const next = new Map(this.entries);
      if (action === 'discard') next.delete(key);
      else next.set(key, { ...entry, settled: true, uncertain: false, value: value === undefined ? entry.value : structuredClone(value) });
      await this.persist(next);
      this.entries = next;
      return { success: true, key, action };
    } finally { this.reconciling = false; }
  }
  async run(key: string, produce: (context?: unknown) => Promise<T>, settle: (value: T) => Promise<unknown>, fingerprint?: string, context?: unknown): Promise<{ value: T; replayed: boolean }> {
    await (this.ready ??= this.load());
    if (this.reconciling) throw new Error('operation_in_flight');
    await this.cleanup();
    if (this.reconciling) throw new Error('operation_in_flight');
    let entry = this.entries.get(key);
    if (entry && fingerprint !== undefined && entry.fingerprint !== fingerprint) throw new Error('operation_payload_conflict');
    // Exactly one caller may own post-settlement side effects, including joiners.
    const replayed = !!entry?.settled || !!entry?.pending;
    if (!entry) {
      if (this.entries.size >= this.capacity) throw new Error('operation_capacity');
      entry = { createdAt: Date.now(), expires: Date.now() + this.ttlMs, settled: false, fingerprint, context };
      this.entries.set(key, entry);
    }
    const current = entry;
    if (current.uncertain && !current.pending) throw new Error('operation_outcome_unknown');
    if (!current.pending) current.pending = (async () => {
      if (current.value === undefined) {
        await this.persist(); // A restart after dispatch fails closed until reconciled.
        current.uncertain = true;
        current.value = await produce(current.context);
        current.uncertain = false;
      }
      // Retry this write even if an earlier write failed after produce completed.
      await this.persist(); // Persist the paid result before attempting settlement.
      if (!current.settled) {
        await settle(current.value);
        current.settled = true;
        try { await this.persist(); } catch (error) { current.settled = false; throw error; }
      }
      return current.value;
    })();
    const pending = current.pending;
    try { return { value: await pending, replayed }; }
    catch (error) {
      // Provider errors may represent a paid request whose response was lost.
      // Keep the durable dispatch marker and require operator reconciliation.
      throw error;
    }
    finally { if (current.pending === pending) current.pending = undefined; }
  }
}
