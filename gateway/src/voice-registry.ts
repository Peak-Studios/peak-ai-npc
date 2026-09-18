import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
import { writeJsonAtomically } from './atomic-json.js';

export type GenderPresentation = 'masculine' | 'feminine' | 'androgynous';
export type AgeBand = 'young-adult' | 'adult' | 'older-adult';
export type QualityMode = 'realtime' | 'quality';
export type DeliveryPreset = 'neutral' | 'warm' | 'stern' | 'nervous' | 'urgent' | 'quiet' | 'menacing';

export interface VoiceProfileSpec {
  voiceProfileId: string;
  voiceSeed?: number;
  genderPresentation: GenderPresentation;
  ageBand: AgeBand;
  accent?: string;
  language: string;
  qualityMode: QualityMode;
  deliveryPreset: DeliveryPreset;
  exclusive?: boolean;
  archetypes?: string[];
  design?: { description: string; previewText: string };
}

export interface VoiceApproval {
  fingerprint: string;
  reviewedBy: string;
  reviewedAt: string;
  evidence: string;
  action: 'approve' | 'rollback';
}

export interface VoiceRevision {
  provider: 'elevenlabs' | 'cartesia' | 'openai-compatible';
  voiceId: string;
  name: string;
  modelIds: string[];
  provisionedAt?: string;
  catalogValidatedAt?: string;
  revision?: number;
  approval?: VoiceApproval;
}

export interface ProviderVoiceRecord extends VoiceRevision {
  history?: VoiceRevision[];
  candidate?: VoiceRevision;
  lastRevision?: number;
  rejected?: Array<{ revision: number; fingerprint: string; reviewedBy: string; reviewedAt: string; evidence: string }>;
}

type RegistryDocument = {
  version: 1;
  servers: Record<string, { profiles: Record<string, ProviderVoiceRecord> }>;
};

const EMPTY: RegistryDocument = { version: 1, servers: {} };
const PROFILE_ID = /^[a-z0-9][a-z0-9_.-]{1,63}$/;
const safeKey = (key: string) => !['__proto__', 'prototype', 'constructor'].includes(key);
function own<T>(values: Record<string, T> | undefined, key: string): T | undefined {
  return values && Object.hasOwn(values, key) ? values[key] : undefined;
}
export function voiceFingerprint(record: VoiceRevision) {
  return createHash('sha256').update(JSON.stringify({ provider: record.provider, voiceId: record.voiceId,
    modelIds: [...record.modelIds].sort(), revision: record.revision ?? 1 })).digest('hex');
}

export function approvedVoice(record: VoiceRevision | undefined): record is VoiceRevision & { approval: VoiceApproval } {
  return Boolean(record?.approval && record.approval.fingerprint === voiceFingerprint(record));
}

function validRevision(value: unknown): value is VoiceRevision {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const record = value as ProviderVoiceRecord;
  return ['elevenlabs', 'cartesia', 'openai-compatible'].includes(record.provider) && typeof record.voiceId === 'string' && /^[A-Za-z0-9_-]{1,100}$/.test(record.voiceId)
    && typeof record.name === 'string' && record.name.length <= 200
    && Array.isArray(record.modelIds) && record.modelIds.length > 0 && record.modelIds.length <= 30
    && record.modelIds.every(id => typeof id === 'string' && /^[A-Za-z0-9_./-]{1,100}$/.test(id))
    && new Set(record.modelIds).size === record.modelIds.length
    && (record.revision === undefined || (Number.isSafeInteger(record.revision) && record.revision! > 0))
    && (record.approval === undefined || (typeof record.approval === 'object' && record.approval !== null
      && validReview(record.approval) && ['approve', 'rollback'].includes(record.approval.action)
      && typeof record.approval.reviewedAt === 'string' && Number.isFinite(Date.parse(record.approval.reviewedAt))
      && record.approval.fingerprint === voiceFingerprint(record)));
}

function validRecord(value: unknown): value is ProviderVoiceRecord {
  if (!validRevision(value)) return false;
  const record = value as ProviderVoiceRecord;
  if (record.lastRevision !== undefined && (!Number.isSafeInteger(record.lastRevision) || record.lastRevision < (record.revision ?? 1))) return false;
  if (record.rejected !== undefined && (!Array.isArray(record.rejected) || record.rejected.length > 100
    || record.rejected.some(item => !item || !Number.isSafeInteger(item.revision) || item.revision < 1
      || item.revision > (record.lastRevision ?? record.revision ?? 1) || typeof item.fingerprint !== 'string' || !/^[a-f0-9]{64}$/.test(item.fingerprint)
      || !validReview(item) || typeof item.reviewedAt !== 'string' || !Number.isFinite(Date.parse(item.reviewedAt))))) return false;
  if (record.candidate !== undefined && (!validRevision(record.candidate) || record.candidate.approval
    || record.candidate.revision !== (record.lastRevision ?? (record.revision ?? 1) + 1) || record.candidate.revision! <= (record.revision ?? 1) || 'history' in record.candidate || 'candidate' in record.candidate)) return false;
  return record.history === undefined || (Array.isArray(record.history) && record.history.length <= 100
    && record.history.every(item => validRevision(item) && (item.revision ?? 1) < (record.revision ?? 1) && !('history' in item) && !('candidate' in item))
    && new Set(record.history.map(item => item.revision ?? 1)).size === record.history.length);
}

function validReview(value: { reviewedBy?: unknown; evidence?: unknown }) {
  return typeof value.reviewedBy === 'string' && /^[A-Za-z0-9][A-Za-z0-9 _.@-]{1,79}$/.test(value.reviewedBy)
    && typeof value.evidence === 'string' && value.evidence.trim().length >= 3 && value.evidence.length <= 300
    && !/[\x00-\x1f\x7f]/.test(value.evidence);
}

function revisionOnly(record: VoiceRevision): VoiceRevision {
  const { provider, voiceId, name, modelIds, provisionedAt, catalogValidatedAt, revision = 1, approval } = record;
  return structuredClone({ provider, voiceId, name, modelIds, ...(provisionedAt ? { provisionedAt } : {}),
    ...(catalogValidatedAt ? { catalogValidatedAt } : {}), revision, ...(approval ? { approval } : {}) });
}

export function validVoiceProfileSpec(value: unknown): value is VoiceProfileSpec {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const p = value as Record<string, unknown>;
  return typeof p.voiceProfileId === 'string' && PROFILE_ID.test(p.voiceProfileId)
    && ['masculine', 'feminine', 'androgynous'].includes(String(p.genderPresentation))
    && ['young-adult', 'adult', 'older-adult'].includes(String(p.ageBand))
    && typeof p.language === 'string' && /^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,2}$/.test(p.language)
    && ['realtime', 'quality'].includes(String(p.qualityMode))
    && ['neutral', 'warm', 'stern', 'nervous', 'urgent', 'quiet', 'menacing'].includes(String(p.deliveryPreset))
    && (p.accent === undefined || (typeof p.accent === 'string' && p.accent.length >= 2 && p.accent.length <= 80));
}

export class VoiceRegistry {
  private document: RegistryDocument = structuredClone(EMPTY);
  private writeChain = Promise.resolve();

  constructor(readonly file = process.env.AI_NPC_VOICE_REGISTRY_PATH ?? './data/voice-registry.json') {}

  async initialize() {
    try {
      const parsed = JSON.parse(await readFile(resolve(this.file), 'utf8')) as RegistryDocument;
      if (!parsed || parsed.version !== 1 || !parsed.servers || typeof parsed.servers !== 'object' || Array.isArray(parsed.servers)) throw new Error('voice_registry_invalid');
      for (const [serverId, server] of Object.entries(parsed.servers)) {
        if (!safeKey(serverId) || !serverId || serverId.length > 100 || !server || !server.profiles
          || typeof server.profiles !== 'object' || Array.isArray(server.profiles)) throw new Error('voice_registry_invalid');
        for (const [id, record] of Object.entries(server.profiles)) {
          if (!safeKey(id) || !PROFILE_ID.test(id) || !validRecord(record)) throw new Error('voice_registry_invalid');
        }
      }
      this.document = parsed;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
      this.document = structuredClone(EMPTY);
    }
  }

  resolve(serverId: string, profileId: string) {
    if (!safeKey(serverId) || !safeKey(profileId)) return undefined;
    return structuredClone(own(own(this.document.servers, serverId)?.profiles, profileId)
      ?? own(own(this.document.servers, '*')?.profiles, profileId));
  }

  profiles(serverId: string) {
    return structuredClone({ ...(own(this.document.servers, '*')?.profiles ?? {}), ...(safeKey(serverId) ? own(this.document.servers, serverId)?.profiles ?? {} : {}) });
  }

  counts(serverId = '*') {
    const records = Object.values(this.profiles(serverId));
    return { profiles: records.length, elevenlabs: records.filter(record => record.provider === 'elevenlabs').length,
      approved: records.filter(approvedVoice).length, reviewRequired: records.filter(record => !approvedVoice(record)).length,
      candidates: records.filter(record => record.candidate).length };
  }

  reviewStatus(serverId: string) {
    return Object.entries(this.profiles(serverId)).map(([profileId, record]) => ({ profileId,
      revision: record.revision ?? 1, fingerprint: voiceFingerprint(record), approved: approvedVoice(record),
      provider: record.provider, modelIds: [...record.modelIds], approval: structuredClone(record.approval),
      candidate: record.candidate ? { revision: record.candidate.revision, fingerprint: voiceFingerprint(record.candidate), provider: record.candidate.provider } : undefined,
      rejected: structuredClone(record.rejected ?? []),
      history: (record.history ?? []).map(item => ({ revision: item.revision ?? 1, fingerprint: voiceFingerprint(item), approved: approvedVoice(item) })) }));
  }

  async set(serverId: string, profileId: string, record: ProviderVoiceRecord) {
    if (!PROFILE_ID.test(profileId) || !safeKey(profileId) || !safeKey(serverId) || !serverId || serverId.length > 100) throw new Error('voice_registry_scope_invalid');
    if (!validRecord(record)) throw new Error('voice_registry_record_invalid');
    const detached = revisionOnly(record);
    // Registering a mapping is not evidence of a human listening review.
    delete detached.approval;
    detached.revision = 1;
    const write = this.writeChain.then(async () => {
      const next = structuredClone(this.document);
      if (!Object.hasOwn(next.servers, serverId)) next.servers[serverId] = { profiles: {} };
      const existing = own(next.servers[serverId].profiles, profileId);
      const inherited = serverId !== '*' ? own(own(next.servers, '*')?.profiles, profileId) : undefined;
      if (!existing && inherited && voiceFingerprint({ ...inherited, revision: 1 }) !== voiceFingerprint(detached)) throw new Error('voice_recast_requires_review');
      if (existing) {
        detached.revision = existing.revision ?? 1;
        if (voiceFingerprint(existing) !== voiceFingerprint(detached)) throw new Error('voice_recast_requires_review');
      }
      next.servers[serverId].profiles[profileId] = { ...detached,
        ...(existing?.approval ? { approval: existing.approval } : {}),
        ...(existing?.history ? { history: existing.history } : {}),
        ...(existing?.lastRevision ? { lastRevision: existing.lastRevision } : {}),
        ...(existing?.rejected ? { rejected: existing.rejected } : {}),
        ...(existing?.candidate ? { candidate: existing.candidate } : {}) };
      const target = resolve(this.file);
      await writeJsonAtomically(target, `${JSON.stringify(next, null, 2)}\n`);
      this.document = next;
    });
    this.writeChain = write.catch(() => {});
    await write;
  }

  private async change(serverId: string, profileId: string, mutate: (record: ProviderVoiceRecord) => ProviderVoiceRecord) {
    if (!safeKey(serverId) || !safeKey(profileId) || !PROFILE_ID.test(profileId)) throw new Error('voice_registry_scope_invalid');
    const write = this.writeChain.then(async () => {
      const next = structuredClone(this.document);
      // Explicit scope only: reviewing a tenant must never mutate the global fallback.
      const current = own(own(next.servers, serverId)?.profiles, profileId);
      if (!current) throw new Error('voice_review_scope_not_found');
      const changed = mutate(current);
      if (!validRecord(changed)) throw new Error('voice_registry_record_invalid');
      next.servers[serverId].profiles[profileId] = changed;
      await writeJsonAtomically(resolve(this.file), `${JSON.stringify(next, null, 2)}\n`);
      this.document = next;
    });
    this.writeChain = write.catch(() => {});
    await write;
  }

  async stage(serverId: string, profileId: string, expectedFingerprint: string, candidate: ProviderVoiceRecord) {
    if (!validRecord(candidate)) throw new Error('voice_registry_record_invalid');
    const pending = revisionOnly(candidate);
    delete pending.approval;
    await this.change(serverId, profileId, current => {
      if (voiceFingerprint(current) !== expectedFingerprint) throw new Error('voice_review_conflict');
      pending.revision = current.candidate?.revision ?? (current.lastRevision ?? current.revision ?? 1) + 1;
      if (current.candidate && voiceFingerprint(current.candidate) !== voiceFingerprint(pending)) throw new Error('voice_candidate_already_pending');
      return { ...current, candidate: pending, lastRevision: pending.revision };
    });
  }

  async approve(serverId: string, profileId: string, expectedFingerprint: string, review: { reviewedBy: string; evidence: string }) {
    if (!validReview(review)) throw new Error('voice_review_evidence_required');
    const evidence = structuredClone(review);
    await this.change(serverId, profileId, current => {
      const selected = current.candidate ?? current;
      if (voiceFingerprint(selected) !== expectedFingerprint) throw new Error('voice_review_conflict');
      if (!current.candidate && approvedVoice(current)) return current;
      const history = current.candidate ? [...(current.history ?? []), revisionOnly(current)] : current.history;
      if (history && history.length > 100) throw new Error('voice_revision_history_full');
      return { ...revisionOnly(selected), approval: { ...evidence, fingerprint: expectedFingerprint,
        reviewedAt: new Date().toISOString(), action: 'approve' }, ...(history ? { history } : {}),
        ...(current.lastRevision ? { lastRevision: current.lastRevision } : {}), ...(current.rejected ? { rejected: current.rejected } : {}) };
    });
  }

  async reject(serverId: string, profileId: string, expectedFingerprint: string, review: { reviewedBy: string; evidence: string }) {
    if (!validReview(review)) throw new Error('voice_review_evidence_required');
    const evidence = structuredClone(review);
    await this.change(serverId, profileId, current => {
      if (!current.candidate || voiceFingerprint(current.candidate) !== expectedFingerprint) throw new Error('voice_review_conflict');
      const rejected = [...(current.rejected ?? []), { ...evidence, revision: current.candidate.revision!, fingerprint: expectedFingerprint, reviewedAt: new Date().toISOString() }];
      if (rejected.length > 100) throw new Error('voice_revision_history_full');
      const { candidate, ...active } = current;
      return { ...active, rejected, lastRevision: candidate.revision };
    });
  }

  async rollback(serverId: string, profileId: string, expectedFingerprint: string, targetRevision: number, review: { reviewedBy: string; evidence: string }) {
    if (!validReview(review)) throw new Error('voice_review_evidence_required');
    const evidence = structuredClone(review);
    await this.change(serverId, profileId, current => {
      if (voiceFingerprint(current) !== expectedFingerprint || current.candidate) throw new Error('voice_review_conflict');
      const target = current.history?.find(item => (item.revision ?? 1) === targetRevision);
      if (!target || !approvedVoice(target)) throw new Error('voice_rollback_revision_not_approved');
      const restored = { ...revisionOnly(target), revision: (current.lastRevision ?? current.revision ?? 1) + 1 };
      const history = [...(current.history ?? []), revisionOnly(current)];
      if (history.length > 100) throw new Error('voice_revision_history_full');
      return { ...restored, history, lastRevision: restored.revision, ...(current.rejected ? { rejected: current.rejected } : {}), approval: { ...evidence, fingerprint: voiceFingerprint(restored),
        reviewedAt: new Date().toISOString(), action: 'rollback' } };
    });
  }
}

export async function loadVoiceProfileManifest(file = process.env.AI_NPC_VOICE_PROFILES_PATH ?? './voice-profiles.json') {
  const parsed = JSON.parse(await readFile(resolve(file), 'utf8')) as unknown;
  if (!Array.isArray(parsed) || parsed.length === 0 || parsed.some(value => !validVoiceProfileSpec(value))) throw new Error('voice_profile_manifest_invalid');
  const ids = new Set<string>();
  for (const profile of parsed) {
    if (ids.has(profile.voiceProfileId)) throw new Error(`voice_profile_duplicate:${profile.voiceProfileId}`);
    ids.add(profile.voiceProfileId);
  }
  return parsed as VoiceProfileSpec[];
}

export function selectAmbientProfile(profiles: VoiceProfileSpec[], identitySeed: number, archetype: string, gender: GenderPresentation, ageBand: AgeBand, audibleProfileIds: ReadonlySet<string>) {
  const exact = profiles.filter(p => !p.exclusive && p.genderPresentation === gender && p.ageBand === ageBand && (!p.archetypes?.length || p.archetypes.includes(archetype)));
  const pool = exact.length ? exact : profiles.filter(p => !p.exclusive && p.genderPresentation === gender);
  if (!pool.length) return undefined;
  const start = Math.abs(Math.trunc(identitySeed)) % pool.length;
  // Concurrency is not a casting input: changing a voice to avoid a collision
  // breaks character continuity. Capacity failures should degrade to text.
  return pool[start];
}
