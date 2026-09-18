import { readFile } from 'node:fs/promises';
import { writeJsonAtomically } from '../atomic-json.js';
import { randomUUID } from 'node:crypto';

export type MemoryRecord = {
  id: string; serverId: string; npcId: string; characterId: string; text: string; importance: number; createdAt: string; expiresAt?: string;
  memoryKey?: string; kind?: string; subject?: string; confidence?: number; tags?: string[]; unresolved?: boolean;
};
export type RelationshipDimensions = { familiarity: number; trust: number; warmth: number; respect: number; fear: number; irritation: number; obligation: number };
export type RelationshipRecord = { serverId: string; npcId: string; characterId: string; score: number; tags: string[]; updatedAt: string } & RelationshipDimensions;
const neutral: RelationshipDimensions = { familiarity: 0, trust: 0, warmth: 0, respect: 0, fear: 0, irritation: 0, obligation: 0 };

export interface MemoryStore {
  initialize?(): Promise<void>;
  purgeExpired?(): Promise<number>;
  recall(serverId: string, npcId: string, characterId: string): Promise<MemoryRecord[]>;
  remember(record: Omit<MemoryRecord, 'id'|'createdAt'>): Promise<MemoryRecord>;
  forget(serverId: string, npcId: string, characterId: string): Promise<number>;
  forgetServer(serverId: string): Promise<number>;
  relationship(serverId: string, npcId: string, characterId: string): Promise<RelationshipRecord>;
  adjustRelationship(serverId: string, npcId: string, characterId: string, delta: number, tag?: string): Promise<RelationshipRecord>;
  adjustRelationshipDimensions(serverId: string, npcId: string, characterId: string, deltas: Partial<RelationshipDimensions>, tag?: string): Promise<RelationshipRecord>;
}

function relationshipNext(current: RelationshipRecord, deltas: Partial<RelationshipDimensions>, tag?: string): RelationshipRecord {
  const dimension = (key: keyof RelationshipDimensions) => Math.max(-100, Math.min(100, current[key] + Math.max(-10, Math.min(10, (Number.isFinite(deltas[key]) ? Number(deltas[key]) : 0)))));
  const next = { ...current, familiarity: dimension('familiarity'), trust: dimension('trust'), warmth: dimension('warmth'), respect: dimension('respect'), fear: dimension('fear'), irritation: dimension('irritation'), obligation: dimension('obligation'), tags: tag && !current.tags.includes(tag) ? [...current.tags, tag].slice(-12) : current.tags, updatedAt: new Date().toISOString() };
  next.score = Math.max(-100, Math.min(100, Math.round((next.trust + next.warmth + next.respect - next.fear - next.irritation + next.obligation * .5) / 4)));
  return next;
}

export class FileMemoryStore implements MemoryStore {
  private committedRecords: MemoryRecord[] = []; private committedRelationships: RelationshipRecord[] = [];
  private records: MemoryRecord[] = []; private relationships: RelationshipRecord[] = []; private loadPromise?: Promise<void>; private persistChain=Promise.resolve(); private mutationChain=Promise.resolve();
  constructor(private readonly file=process.env.AI_NPC_MEMORY_FILE??'./data/memories.json'){}
  async initialize(){await this.ensureLoaded();}
  private async ensureLoaded(){if(!this.loadPromise)this.loadPromise=(async()=>{try{const parsed=JSON.parse(await readFile(this.file,'utf8'));if(Array.isArray(parsed))this.records=parsed;else{if(!parsed||(!Array.isArray(parsed.memories)&&!Array.isArray(parsed.relationships))||(parsed.memories!==undefined&&!Array.isArray(parsed.memories))||(parsed.relationships!==undefined&&!Array.isArray(parsed.relationships)))throw new Error('invalid_memory_store');this.records=parsed.memories??[];this.relationships=(parsed.relationships??[]).map((x:RelationshipRecord)=>({...neutral,...x}));}this.committedRecords=structuredClone(this.records);this.committedRelationships=structuredClone(this.relationships);}catch(error){if((error as NodeJS.ErrnoException).code!=='ENOENT')throw error;}})();return this.loadPromise;}
  private async persist(){const snapshot=JSON.stringify({memories:this.records,relationships:this.relationships},null,2);const op=this.persistChain.then(()=>writeJsonAtomically(this.file,snapshot));this.persistChain=op.catch(()=>undefined);await op;}
  private async mutate<T>(operation:()=>Promise<T>){const current=this.mutationChain.then(async()=>{await this.ensureLoaded();const records=structuredClone(this.records),relationships=structuredClone(this.relationships);try{const result=await operation();this.committedRecords=structuredClone(this.records);this.committedRelationships=structuredClone(this.relationships);return structuredClone(result);}catch(error){this.records=records;this.relationships=relationships;throw error;}});this.mutationChain=current.then(()=>undefined,()=>undefined);return current;}
  async purgeExpired(){return this.mutate(async()=>{await this.ensureLoaded();const before=this.records.length;const now=Date.now();this.records=this.records.filter(x=>!x.expiresAt||Date.parse(x.expiresAt)>now);const removed=before-this.records.length;if(removed)await this.persist();return removed;});}
  async recall(serverId:string,npcId:string,characterId:string){await this.purgeExpired();return structuredClone(this.committedRecords.filter(x=>x.serverId===serverId&&x.npcId===npcId&&x.characterId===characterId).sort((a,b)=>(Number(b.unresolved??false)-Number(a.unresolved??false))||(b.importance-a.importance)||(Date.parse(b.createdAt)-Date.parse(a.createdAt))).slice(0,64));}
  async remember(record:Omit<MemoryRecord,'id'|'createdAt'>){return this.mutate(async()=>{await this.ensureLoaded();const next={...record,id:randomUUID(),createdAt:new Date().toISOString()};this.records=this.records.filter(x=>!(x.serverId===next.serverId&&x.npcId===next.npcId&&x.characterId===next.characterId&&(next.memoryKey?x.memoryKey===next.memoryKey:x.text===next.text)));this.records.push(next);this.records=this.records.slice(-10000);await this.persist();return next;});}
  async forget(serverId:string,npcId:string,characterId:string){return this.mutate(async()=>{await this.ensureLoaded();const match=(x:{serverId:string;npcId:string;characterId:string})=>x.serverId===serverId&&x.npcId===npcId&&x.characterId===characterId;const before=this.records.filter(match).length+this.relationships.filter(match).length;this.records=this.records.filter(x=>!match(x));this.relationships=this.relationships.filter(x=>!match(x));if(before)await this.persist();return before;});}
  async forgetServer(serverId:string){return this.mutate(async()=>{await this.ensureLoaded();const before=this.records.filter(x=>x.serverId===serverId).length+this.relationships.filter(x=>x.serverId===serverId).length;this.records=this.records.filter(x=>x.serverId!==serverId);this.relationships=this.relationships.filter(x=>x.serverId!==serverId);if(before)await this.persist();return before;});}
  async relationship(serverId:string,npcId:string,characterId:string){await this.ensureLoaded();return structuredClone(this.committedRelationships.find(x=>x.serverId===serverId&&x.npcId===npcId&&x.characterId===characterId)??{serverId,npcId,characterId,score:0,tags:[],updatedAt:new Date().toISOString(),...neutral});}
  async adjustRelationship(serverId:string,npcId:string,characterId:string,delta:number,tag?:string){return this.adjustRelationshipDimensions(serverId,npcId,characterId,delta>=0?{warmth:delta,trust:delta,respect:delta,obligation:delta*2}:{warmth:delta,trust:delta,respect:delta,irritation:-delta},tag);}
  async adjustRelationshipDimensions(serverId:string,npcId:string,characterId:string,deltas:Partial<RelationshipDimensions>,tag?:string){return this.mutate(async()=>{await this.ensureLoaded();const next=relationshipNext(await this.relationship(serverId,npcId,characterId),deltas,tag);this.relationships=this.relationships.filter(x=>!(x.serverId===serverId&&x.npcId===npcId&&x.characterId===characterId));this.relationships.push(next);await this.persist();return next;});}
}

export class InMemoryStore implements MemoryStore {
  private records:MemoryRecord[]=[];private relationships:RelationshipRecord[]=[];
  async purgeExpired(){const before=this.records.length;const now=Date.now();this.records=this.records.filter(x=>!x.expiresAt||Date.parse(x.expiresAt)>now);return before-this.records.length;}
  async recall(serverId:string,npcId:string,characterId:string){const now=Date.now();return this.records.filter(x=>x.serverId===serverId&&x.npcId===npcId&&x.characterId===characterId&&(!x.expiresAt||Date.parse(x.expiresAt)>now)).sort((a,b)=>(Number(b.unresolved??false)-Number(a.unresolved??false))||(b.importance-a.importance)||(Date.parse(b.createdAt)-Date.parse(a.createdAt))).slice(0,64);}
  async remember(record:Omit<MemoryRecord,'id'|'createdAt'>){const next={...record,id:randomUUID(),createdAt:new Date().toISOString()};this.records=this.records.filter(x=>!(x.serverId===next.serverId&&x.npcId===next.npcId&&x.characterId===next.characterId&&(next.memoryKey?x.memoryKey===next.memoryKey:x.text===next.text)));this.records.push(next);return next;}
  async forget(serverId:string,npcId:string,characterId:string){const match=(x:{serverId:string;npcId:string;characterId:string})=>x.serverId===serverId&&x.npcId===npcId&&x.characterId===characterId;const before=this.records.filter(match).length+this.relationships.filter(match).length;this.records=this.records.filter(x=>!match(x));this.relationships=this.relationships.filter(x=>!match(x));return before;}
  async forgetServer(serverId:string){const before=this.records.filter(x=>x.serverId===serverId).length+this.relationships.filter(x=>x.serverId===serverId).length;this.records=this.records.filter(x=>x.serverId!==serverId);this.relationships=this.relationships.filter(x=>x.serverId!==serverId);return before;}
  async relationship(serverId:string,npcId:string,characterId:string){return this.relationships.find(x=>x.serverId===serverId&&x.npcId===npcId&&x.characterId===characterId)??{serverId,npcId,characterId,score:0,tags:[],updatedAt:new Date().toISOString(),...neutral};}
  async adjustRelationship(serverId:string,npcId:string,characterId:string,delta:number,tag?:string){return this.adjustRelationshipDimensions(serverId,npcId,characterId,delta>=0?{warmth:delta,trust:delta,respect:delta,obligation:delta*2}:{warmth:delta,trust:delta,respect:delta,irritation:-delta},tag);}
  async adjustRelationshipDimensions(serverId:string,npcId:string,characterId:string,deltas:Partial<RelationshipDimensions>,tag?:string){const next=relationshipNext(await this.relationship(serverId,npcId,characterId),deltas,tag);this.relationships=this.relationships.filter(x=>!(x.serverId===serverId&&x.npcId===npcId&&x.characterId===characterId));this.relationships.push(next);return next;}
}
