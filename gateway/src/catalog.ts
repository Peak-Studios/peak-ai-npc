import { readFile } from 'node:fs/promises';
import { writeJsonAtomically } from './atomic-json.js';

export type NpcTemplate = { id: string; serverId: string; definition: Record<string, unknown>; createdAt: string; updatedAt: string };

export class NpcCatalog {
  private entries: NpcTemplate[] = [];
  private loadPromise: Promise<void> | undefined;
  private persistChain: Promise<void> = Promise.resolve();
  constructor(private readonly file = process.env.AI_NPC_CATALOG_FILE ?? './data/npcs.json') {}

  async initialize() {
    if (this.loadPromise) return this.loadPromise;
    this.loadPromise = (async () => {
      try {
        const parsed = JSON.parse(await readFile(this.file, 'utf8')) as NpcTemplate[];
        const scopes = new Set<string>();
        if (!Array.isArray(parsed)) throw new Error('invalid_npc_catalog');
        for (const entry of parsed) {
          if (!entry || typeof entry.serverId !== 'string' || !entry.serverId || typeof entry.id !== 'string' || !entry.id
            || !entry.definition || typeof entry.definition !== 'object' || Array.isArray(entry.definition)
            || typeof entry.createdAt !== 'string' || typeof entry.updatedAt !== 'string') throw new Error('invalid_npc_catalog');
          const scope = JSON.stringify([entry.serverId, entry.id]);
          if (scopes.has(scope)) throw new Error('invalid_npc_catalog');
          scopes.add(scope);
        }
        this.entries = parsed;
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
      }
    })();
    return this.loadPromise;
  }

  async list(serverId: string) { await this.initialize(); return structuredClone(this.entries.filter(entry => entry.serverId === serverId)); }

  async save(serverId: string, id: string, definition: Record<string, unknown>) {
    const detached = structuredClone(definition);
    return this.mutate(next => {
      const now = new Date().toISOString();
      const existing = next.find(entry => entry.serverId === serverId && entry.id === id);
      const entry = existing ? Object.assign(existing, { definition: detached, updatedAt: now })
        : { id, serverId, definition: detached, createdAt: now, updatedAt: now };
      if (!existing) next.push(entry);
      return entry;
    });
  }

  async remove(serverId: string, id: string) {
    return this.mutate(next => {
      const index = next.findIndex(entry => entry.serverId === serverId && entry.id === id);
      if (index < 0) return false;
      next.splice(index, 1);
      return true;
    });
  }

  private mutate<T>(change: (next: NpcTemplate[]) => T): Promise<T> {
    const operation = this.persistChain.then(async () => {
      await this.initialize();
      const next = structuredClone(this.entries);
      const result = change(next);
      await writeJsonAtomically(this.file, JSON.stringify(next, null, 2));
      this.entries = next;
      return structuredClone(result);
    });
    this.persistChain = operation.then(() => undefined, () => undefined);
    return operation;
  }
}

export function validNpcDefinition(id: string, value: unknown) {
  if (!/^[a-z0-9_-]{1,64}$/i.test(id) || !value || typeof value !== 'object' || Array.isArray(value)) return false;
  const definition = value as Record<string, unknown>;
  const identity = definition.identity as Record<string, unknown> | undefined;
  const coords = definition.coords as Record<string, unknown> | undefined;
  const tools = definition.allowedTools;
  const validCoords = !!coords
    && typeof coords.x === 'number' && Number.isFinite(coords.x) && coords.x >= -100000 && coords.x <= 100000
    && typeof coords.y === 'number' && Number.isFinite(coords.y) && coords.y >= -100000 && coords.y <= 100000
    && typeof coords.z === 'number' && Number.isFinite(coords.z) && coords.z >= -1000 && coords.z <= 10000
    && typeof coords.w === 'number' && Number.isFinite(coords.w) && coords.w >= -360 && coords.w <= 360;
  return typeof definition.model === 'string' && definition.model.length > 0 && definition.model.length <= 80
    && !!identity && typeof identity.name === 'string' && identity.name.length > 0 && identity.name.length <= 80
    && typeof identity.occupation === 'string' && identity.occupation.length > 0 && identity.occupation.length <= 80
    && (definition.enabled === undefined || typeof definition.enabled === 'boolean')
    && validCoords && Array.isArray(tools) && tools.length <= 32 && tools.every(tool => typeof tool === 'string' && /^[a-z0-9_-]{1,64}$/i.test(tool))
    && JSON.stringify(definition).length <= 50_000;
}
