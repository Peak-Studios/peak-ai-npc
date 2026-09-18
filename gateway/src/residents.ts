import { readFile } from 'node:fs/promises';
import { writeJsonAtomically } from './atomic-json.js';
import { randomUUID } from 'node:crypto';
import { Pool } from 'pg';
import { initializePostgresSchema } from './postgres-schema.js';
import { residentVoiceAssignment, validateResidentVoice, type ResidentVoiceAssignment } from './resident-voice.js';

export type Vec4 = { x: number; y: number; z: number; w: number };
export type Appearance = {
  components: Array<{ id: number; drawable: number; texture: number; palette: number }>;
  props: Array<{ id: number; drawable: number; texture: number }>;
};
export type ResidentNeeds = { hunger: number; fatigue: number; stress: number; social: number; safety: number };
export type ResidentProfile = {
  voiceAssignment?: ResidentVoiceAssignment;
  residentId: string; serverId: string; name: string; model: string; gender: string; ageBand: string;
  occupation: string; traits: string[]; voiceSeed: number; tone: string; appearance: Appearance;
  home: Vec4; work: Vec4; leisure: Vec4; location: Vec4; bucket: number;
  activity: string; mood: string; health: string; needs: ResidentNeeds; possessions: string[];
  status: 'active'|'recovering'|'archived'; recoveringUntil?: string; pinned: boolean;
  createdAt: string; updatedAt: string; lastSeenAt: string;
};
export type ResidentKnowledge = { serverId: string; residentId: string; characterId: string; knownNameAt?: string; playerNameKnownAt?: string; lastMetAt?: string; meetings: number };
export type ResidentStats = { total: number; active: number; recovering: number; archived: number; knownNames: number; extractionQueue?: { depth: number; running: number; dropped: number; failed: number } };
export type ResidentWorld = { hour?: number; minute?: number; weather?: string };

export type ResolveResidentInput = {
  voice?: unknown;
  serverId: string; residentId?: string; characterId: string; model: string; gender?: string; ageBand?: string;
  location: Vec4; bucket: number; appearance?: Appearance;
};

export interface ResidentStore {
  initialize?(): Promise<void>;
  resolve(input: ResolveResidentInput): Promise<{ resident: ResidentProfile; knowledge: ResidentKnowledge }>;
  list(serverId: string, includeArchived?: boolean): Promise<ResidentProfile[]>;
  knowledge(serverId: string, residentId: string, characterId: string): Promise<ResidentKnowledge>;
  revealName(serverId: string, residentId: string, characterId: string): Promise<ResidentKnowledge>;
  noteMeeting(serverId: string, residentId: string, characterId: string, playerNameKnown?: boolean): Promise<ResidentKnowledge>;
  observe(serverId: string, residentId: string, location: Vec4, activity?: string, mood?: string): Promise<ResidentProfile | undefined>;
  lifecycle(serverId: string, residentId: string, event: 'death'|'recover'|'archive'|'activate'|'respawn'|'pin'|'unpin', recoverySeconds?: number): Promise<ResidentProfile | undefined>;
  simulate(serverId: string, at?: Date, world?: ResidentWorld): Promise<ResidentProfile[]>;
  retire(serverId: string, residentId: string): Promise<number>;
  forgetCharacter(serverId: string, residentId: string, characterId: string): Promise<number>;
  forgetServerKnowledge(serverId: string): Promise<number>;
  stats(serverId: string): Promise<ResidentStats>;
}

const names = ['Alex Parker','Jordan Hayes','Casey Morgan','Taylor Brooks','Jamie Rivera','Morgan Reed','Riley Bennett','Avery Collins','Cameron Price','Quinn Foster','Drew Sullivan','Robin Bailey','Sam Torres','Jesse Ward','Dakota Ellis','Skyler Monroe','Reese Coleman','Charlie Nguyen','Emerson Clarke','Rowan Patel','Hayden Murphy','Peyton Ross','Kendall James','Frankie Woods'];
const occupations = ['retail worker','mechanic','office assistant','delivery driver','hospitality worker','construction worker','student','freelancer','security guard','caregiver','city employee','between jobs'];
const traits = ['patient','observant','wry','warm','reserved','curious','practical','confident','cautious','sociable','stubborn','optimistic'];
const tones = ['calm','friendly','confident','warm','reserved','upbeat'];

function finite(value: unknown, fallback = 0) { return typeof value === 'number' && Number.isFinite(value) ? value : fallback; }
function bounded(value: unknown, min: number, max: number, fallback = min) { return Math.max(min, Math.min(max, finite(value, fallback))); }
function vec(value: Vec4): Vec4 { return { x: bounded(value.x, -100000, 100000), y: bounded(value.y, -100000, 100000), z: bounded(value.z, -1000, 10000), w: bounded(value.w, -360, 360) }; }
function hash(value: string) { let result = 2166136261; for (const character of value) result = Math.imul(result ^ character.charCodeAt(0), 16777619); return result >>> 0; }
function shifted(origin: Vec4, seed: number, distance: number): Vec4 {
  const angle = ((seed % 360) * Math.PI) / 180;
  return { x: origin.x + Math.cos(angle) * distance, y: origin.y + Math.sin(angle) * distance, z: origin.z, w: (seed * 17) % 360 };
}
function cleanAppearance(value?: Appearance): Appearance {
  const components = Array.isArray(value?.components) ? value!.components.filter(x => Number.isInteger(x.id) && x.id >= 0 && x.id <= 11).slice(0, 12).map(x => ({ id: x.id, drawable: Math.trunc(bounded(x.drawable, 0, 255)), texture: Math.trunc(bounded(x.texture, 0, 255)), palette: Math.trunc(bounded(x.palette, 0, 3)) })) : [];
  const props = Array.isArray(value?.props) ? value!.props.filter(x => Number.isInteger(x.id) && x.id >= 0 && x.id <= 7).slice(0, 8).map(x => ({ id: x.id, drawable: Math.trunc(bounded(x.drawable, -1, 255, -1)), texture: Math.trunc(bounded(x.texture, 0, 255)) })) : [];
  return { components, props };
}
function generated(input: ResolveResidentInput): ResidentProfile {
  const residentId = `resident:${randomUUID()}`;
  const seed = hash(`${input.serverId}:${residentId}:${input.model}`);
  const now = new Date().toISOString();
  const origin = vec(input.location);
  const voiceAssignment = residentVoiceAssignment(input.voice);
  return {
    ...(voiceAssignment ? { voiceAssignment } : {}),
    residentId, serverId: input.serverId, name: names[seed % names.length], model: input.model,
    gender: ['male','female'].includes(input.gender ?? '') ? input.gender! : 'unspecified',
    ageBand: ['young adult','adult','middle-aged','older adult'].includes(input.ageBand ?? '') ? input.ageBand! : ['young adult','adult','middle-aged','older adult'][seed % 4],
    occupation: occupations[(seed >>> 3) % occupations.length],
    traits: [traits[(seed >>> 5) % traits.length], traits[(seed >>> 9) % traits.length]].filter((v, i, a) => a.indexOf(v) === i),
    voiceSeed: seed, tone: tones[(seed >>> 4) % tones.length], appearance: cleanAppearance(input.appearance),
    home: shifted(origin, seed, 35 + (seed % 30)), work: shifted(origin, seed >>> 3, 90 + (seed % 180)), leisure: shifted(origin, seed >>> 7, 45 + (seed % 90)),
    location: origin, bucket: Math.trunc(bounded(input.bucket, 0, 999999)), activity: 'leisure', mood: 'neutral', health: 'healthy',
    needs: { hunger: 20 + seed % 30, fatigue: 15 + (seed >>> 3) % 35, stress: 10 + (seed >>> 6) % 30, social: 20 + (seed >>> 8) % 40, safety: 90 },
    possessions: ['phone', (seed % 2 ? 'wallet' : 'keys')], status: 'active', pinned: false, createdAt: now, updatedAt: now, lastSeenAt: now
  };
}
function defaultKnowledge(serverId: string, residentId: string, characterId: string): ResidentKnowledge { return { serverId, residentId, characterId, meetings: 0 }; }
function correctedLegacyVoice(resident: ResidentProfile, input: ResolveResidentInput, voice?: ResidentVoiceAssignment) {
  const incomingGender = input.gender === 'male' || input.gender === 'female' ? input.gender : undefined;
  if (!incomingGender || resident.gender !== 'unspecified' || !voice
      || resident.voiceAssignment?.profile.genderPresentation !== 'androgynous'
      || voice.profile.genderPresentation !== (incomingGender === 'male' ? 'masculine' : 'feminine')) return false;
  resident.gender = incomingGender;
  resident.voiceAssignment = voice;
  resident.updatedAt = new Date().toISOString();
  return true;
}
function schedule(profile: ResidentProfile, at: Date, world?: ResidentWorld) {
  const suppliedHour = Number(world?.hour);
  const hour = Number.isInteger(suppliedHour) && suppliedHour >= 0 && suppliedHour <= 23 ? suppliedHour : at.getUTCHours();
  const weather = String(world?.weather ?? 'UNKNOWN').toUpperCase();
  if (profile.status === 'recovering' && profile.recoveringUntil && Date.parse(profile.recoveringUntil) <= at.getTime()) {
    profile.status = 'active'; profile.health = 'recovering'; profile.recoveringUntil = undefined; profile.location = profile.home;
  }
  if (profile.status !== 'active') return;
  if (hour < 6 || hour >= 23) { profile.activity = 'sleeping'; profile.location = profile.home; }
  else if (hour < 8) { profile.activity = 'breakfast'; profile.location = profile.home; }
  else if (hour < 17) { profile.activity = 'working'; profile.location = profile.work; }
  else if (hour < 21) { profile.activity = profile.needs.social > 65 ? 'socializing' : 'leisure'; profile.location = profile.leisure; }
  else { profile.activity = 'winding down'; profile.location = profile.home; }
  if (['RAIN','THUNDER','SNOW','BLIZZARD','SNOWLIGHT','XMAS'].includes(weather)
      && (profile.activity === 'leisure' || profile.activity === 'socializing')) {
    profile.activity = 'sheltering';
    profile.location = profile.home;
  }
  profile.needs.hunger = bounded(profile.needs.hunger + (profile.activity === 'breakfast' ? -35 : 4), 0, 100);
  profile.needs.fatigue = bounded(profile.needs.fatigue + (profile.activity === 'sleeping' ? -40 : 3), 0, 100);
  profile.needs.stress = bounded(profile.needs.stress + (profile.activity === 'working' ? 2 : -2), 0, 100);
  profile.needs.social = bounded(profile.needs.social + (profile.activity === 'socializing' ? -25 : 2), 0, 100);
  profile.mood = profile.needs.safety < 35 ? 'afraid' : profile.needs.stress > 75 ? 'stressed' : profile.needs.fatigue > 80 ? 'tired' : profile.needs.social > 75 ? 'lonely' : profile.needs.hunger > 80 ? 'hungry' : 'neutral';
  profile.updatedAt = at.toISOString();
}

type FileData = { residents: ResidentProfile[]; knowledge: ResidentKnowledge[] };
export class FileResidentStore implements ResidentStore {
  private data: FileData = { residents: [], knowledge: [] }; private loaded?: Promise<void>; private chain = Promise.resolve();
  private committed: FileData = { residents: [], knowledge: [] };
  private mutations = Promise.resolve();
  private mutate<T>(operation: () => Promise<T>): Promise<T> {
    const pending = this.mutations.then(async () => {
      await this.load();
      const before = structuredClone(this.data);
      try { const result = await operation(); this.committed = structuredClone(this.data); return structuredClone(result); }
      catch (error) { this.data = before; throw error; }
    });
    this.mutations = pending.then(() => undefined, () => undefined);
    return pending;
  }
  constructor(private readonly file = process.env.AI_NPC_RESIDENT_FILE ?? './data/residents.json') {}
  async initialize() { await this.load(); }
  private async load() {
    if (!this.loaded) this.loaded = readFile(this.file, 'utf8').then(raw => {
      const parsed = JSON.parse(raw);
      if (!parsed || !Array.isArray(parsed.residents) || (parsed.knowledge !== undefined && !Array.isArray(parsed.knowledge))) {
        throw new Error('invalid_resident_store');
      }
      this.data = { residents: parsed.residents, knowledge: parsed.knowledge ?? [] };
      for (const resident of this.data.residents) validateResidentVoice(resident.voiceAssignment);
      this.committed = structuredClone(this.data);
    }).catch((error: NodeJS.ErrnoException) => {
      // Corruption and permissions failures must not silently erase durable identities.
      if (error.code !== 'ENOENT') throw error;
    });
    await this.loaded;
  }
  private async save() { const snapshot = JSON.stringify(this.data, null, 2); const operation = this.chain.then(()=>writeJsonAtomically(this.file, snapshot)); this.chain = operation.catch(()=>undefined); await operation; }
  async resolve(input: ResolveResidentInput) {
    const voice = residentVoiceAssignment(input.voice);
    return this.mutate(async () => {
      let resident = input.residentId ? this.data.residents.find(x => x.serverId === input.serverId && x.residentId === input.residentId && x.status !== 'archived') : undefined;
      if (!resident) {
        if (this.data.residents.filter(x => x.serverId === input.serverId && x.status !== 'archived').length >= 500) throw new Error('resident_capacity_reached');
        resident = generated({ ...input, voice: voice?.profile });
        this.data.residents.push(resident);
        await this.save();
      } else if (!resident.voiceAssignment && voice) {
        // Legacy migration is additive and once-only; never regenerate identity.
        resident.voiceAssignment = voice;
        await this.save();
      } else if (correctedLegacyVoice(resident, input, voice)) {
        // Correct only the known legacy neutral-cast defect. Established gendered
        // residents and all identity/biography/relationship fields remain fixed.
        await this.save();
      }
      return { resident, knowledge: await this.knowledge(input.serverId, resident.residentId, input.characterId) };
    });
  }
  async list(serverId:string, includeArchived=false){await this.load();return structuredClone(this.committed.residents.filter(x=>x.serverId===serverId&&(includeArchived||x.status!=='archived')).slice(0,500));}
  async knowledge(serverId:string,residentId:string,characterId:string){await this.load();return structuredClone(this.committed.knowledge.find(x=>x.serverId===serverId&&x.residentId===residentId&&x.characterId===characterId)??defaultKnowledge(serverId,residentId,characterId));}
  private async updateKnowledge(serverId:string,residentId:string,characterId:string, mutator:(x:ResidentKnowledge)=>void){return this.mutate(async()=>{const current=await this.knowledge(serverId,residentId,characterId);mutator(current);this.data.knowledge=this.data.knowledge.filter(x=>!(x.serverId===serverId&&x.residentId===residentId&&x.characterId===characterId));this.data.knowledge.push(current);await this.save();return current;});}
  revealName(a:string,b:string,c:string){return this.updateKnowledge(a,b,c,x=>{x.knownNameAt=x.knownNameAt??new Date().toISOString();});}
  noteMeeting(a:string,b:string,c:string,known=false){return this.updateKnowledge(a,b,c,x=>{x.meetings+=1;x.lastMetAt=new Date().toISOString();if(known)x.playerNameKnownAt=x.playerNameKnownAt??new Date().toISOString();});}
  async observe(serverId:string,id:string,location:Vec4,activity?:string,mood?:string){return this.mutate(async()=>{const x=this.data.residents.find(r=>r.serverId===serverId&&r.residentId===id);if(!x)return;x.location=vec(location);if(activity)x.activity=activity.slice(0,40);if(mood)x.mood=mood.slice(0,40);x.lastSeenAt=x.updatedAt=new Date().toISOString();await this.save();return x;});}
  async lifecycle(serverId:string,id:string,event:'death'|'recover'|'archive'|'activate'|'respawn'|'pin'|'unpin',recoverySeconds=1800){return this.mutate(async()=>{const x=this.data.residents.find(r=>r.serverId===serverId&&r.residentId===id);if(!x)return;if(event==='pin'||event==='unpin')x.pinned=event==='pin';else if(event==='death'){x.status='recovering';x.health='injured';x.activity='unavailable';x.recoveringUntil=new Date(Date.now()+bounded(recoverySeconds,60,86400,1800)*1000).toISOString();}else if(event==='archive')x.status='archived';else{x.status='active';x.health=event==='recover'?'recovering':'healthy';x.recoveringUntil=undefined;x.location=x.home;}x.updatedAt=new Date().toISOString();await this.save();return x;});}
  async simulate(serverId:string,at=new Date(),world?:ResidentWorld){return this.mutate(async()=>{const list=this.data.residents.filter(x=>x.serverId===serverId);for(const x of list)schedule(x,at,world);await this.save();return list;});}
  async retire(serverId:string,id:string){return this.mutate(async()=>{const before=this.data.residents.length;this.data.residents=this.data.residents.filter(x=>!(x.serverId===serverId&&x.residentId===id));this.data.knowledge=this.data.knowledge.filter(x=>!(x.serverId===serverId&&x.residentId===id));await this.save();return before-this.data.residents.length;});}
  async forgetCharacter(serverId:string,id:string,c:string){return this.mutate(async()=>{const before=this.data.knowledge.length;this.data.knowledge=this.data.knowledge.filter(x=>!(x.serverId===serverId&&x.residentId===id&&x.characterId===c));await this.save();return before-this.data.knowledge.length;});}
  async forgetServerKnowledge(serverId:string){return this.mutate(async()=>{const before=this.data.knowledge.length;this.data.knowledge=this.data.knowledge.filter(x=>x.serverId!==serverId);const deleted=before-this.data.knowledge.length;if(deleted)await this.save();return deleted;});}
  async stats(serverId:string){const all=await this.list(serverId,true);return{total:all.length,active:all.filter(x=>x.status==='active').length,recovering:all.filter(x=>x.status==='recovering').length,archived:all.filter(x=>x.status==='archived').length,knownNames:this.committed.knowledge.filter(x=>x.serverId===serverId&&x.knownNameAt).length};}
}

export class PostgresResidentStore implements ResidentStore {
  private readonly pool: Pool; constructor(url:string){this.pool=new Pool({connectionString:url,max:5});}
  async initialize(){await initializePostgresSchema(this.pool, `
    CREATE EXTENSION IF NOT EXISTS pgcrypto;
    CREATE TABLE IF NOT EXISTS ai_npc_residents (
      server_id text NOT NULL,resident_id text NOT NULL,name text NOT NULL,model text NOT NULL,gender text NOT NULL,age_band text NOT NULL,occupation text NOT NULL,
      traits jsonb NOT NULL,voice_seed bigint NOT NULL,tone text NOT NULL,appearance jsonb NOT NULL,home jsonb NOT NULL,work jsonb NOT NULL,leisure jsonb NOT NULL,
      location jsonb NOT NULL,bucket integer NOT NULL,activity text NOT NULL,mood text NOT NULL,health text NOT NULL,needs jsonb NOT NULL,possessions jsonb NOT NULL DEFAULT '[]'::jsonb,
      status text NOT NULL,recovering_until timestamptz NULL,pinned boolean NOT NULL DEFAULT false,created_at timestamptz NOT NULL,updated_at timestamptz NOT NULL,last_seen_at timestamptz NOT NULL,
      PRIMARY KEY(server_id,resident_id));
    ALTER TABLE ai_npc_residents ADD COLUMN IF NOT EXISTS voice_assignment jsonb NULL;
    CREATE INDEX IF NOT EXISTS ai_npc_residents_active ON ai_npc_residents(server_id,status,bucket);
    CREATE TABLE IF NOT EXISTS ai_npc_character_knowledge (
      server_id text NOT NULL,resident_id text NOT NULL,character_id text NOT NULL,known_name_at timestamptz NULL,player_name_known_at timestamptz NULL,last_met_at timestamptz NULL,meetings integer NOT NULL DEFAULT 0,
      PRIMARY KEY(server_id,resident_id,character_id),FOREIGN KEY(server_id,resident_id) REFERENCES ai_npc_residents(server_id,resident_id) ON DELETE CASCADE);
    CREATE TABLE IF NOT EXISTS ai_npc_social_links (
      server_id text NOT NULL,resident_id text NOT NULL,other_resident_id text NOT NULL,kind text NOT NULL,strength real NOT NULL DEFAULT 0,updated_at timestamptz NOT NULL,
      PRIMARY KEY(server_id,resident_id,other_resident_id,kind));
    CREATE TABLE IF NOT EXISTS ai_npc_simulation_events (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),server_id text NOT NULL,resident_id text NOT NULL,kind text NOT NULL,summary text NOT NULL,created_at timestamptz NOT NULL DEFAULT NOW(),expires_at timestamptz NULL);
  `);}
  private row(r:any):ResidentProfile{validateResidentVoice(r.voiceAssignment??undefined);return{voiceAssignment:r.voiceAssignment??undefined,residentId:r.residentId,serverId:r.serverId,name:r.name,model:r.model,gender:r.gender,ageBand:r.ageBand,occupation:r.occupation,traits:r.traits,voiceSeed:Number(r.voiceSeed),tone:r.tone,appearance:r.appearance,home:r.home,work:r.work,leisure:r.leisure,location:r.location,bucket:r.bucket,activity:r.activity,mood:r.mood,health:r.health,needs:r.needs,possessions:r.possessions??[],status:r.status,recoveringUntil:r.recoveringUntil?.toISOString?.()??r.recoveringUntil,pinned:r.pinned,createdAt:r.createdAt?.toISOString?.()??r.createdAt,updatedAt:r.updatedAt?.toISOString?.()??r.updatedAt,lastSeenAt:r.lastSeenAt?.toISOString?.()??r.lastSeenAt};}
  private select=`SELECT voice_assignment AS "voiceAssignment",server_id AS "serverId",resident_id AS "residentId",name,model,gender,age_band AS "ageBand",occupation,traits,voice_seed AS "voiceSeed",tone,appearance,home,work,leisure,location,bucket,activity,mood,health,needs,possessions,status,recovering_until AS "recoveringUntil",pinned,created_at AS "createdAt",updated_at AS "updatedAt",last_seen_at AS "lastSeenAt" FROM ai_npc_residents`;
  async resolve(input: ResolveResidentInput) {
    const voice = residentVoiceAssignment(input.voice);
    const client = await this.pool.connect();
    let resident: ResidentProfile;
    try {
      await client.query('BEGIN');
      await client.query("SET LOCAL statement_timeout = '5s'");
      // Serialize this tenant's first-assignment/capacity decision, not other tenants.
      await client.query('SELECT pg_advisory_xact_lock(81279, hashtext($1))', [input.serverId]);
      const found = input.residentId ? await client.query(`${this.select} WHERE server_id=$1 AND resident_id=$2 AND status<>'archived' FOR UPDATE`, [input.serverId, input.residentId]) : undefined;
      if (found?.rows[0]) {
        resident = this.row(found.rows[0]);
        if (!resident.voiceAssignment && voice) {
          await client.query('UPDATE ai_npc_residents SET voice_assignment=$3 WHERE server_id=$1 AND resident_id=$2', [input.serverId, resident.residentId, JSON.stringify(voice)]);
          resident.voiceAssignment = voice;
        } else if (correctedLegacyVoice(resident, input, voice)) {
          await client.query('UPDATE ai_npc_residents SET gender=$3,voice_assignment=$4,updated_at=$5 WHERE server_id=$1 AND resident_id=$2', [input.serverId, resident.residentId, resident.gender, JSON.stringify(resident.voiceAssignment), resident.updatedAt]);
        }
      } else {
        const count = await client.query("SELECT COUNT(*)::int count FROM ai_npc_residents WHERE server_id=$1 AND status<>'archived'", [input.serverId]);
        if (count.rows[0].count >= 500) throw new Error('resident_capacity_reached');
        resident = generated({ ...input, voice: voice?.profile });
        const x = resident;
        await client.query(`INSERT INTO ai_npc_residents(server_id,resident_id,name,model,gender,age_band,occupation,traits,voice_seed,tone,appearance,home,work,leisure,location,bucket,activity,mood,health,needs,possessions,status,pinned,created_at,updated_at,last_seen_at,voice_assignment) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,$25,$26,$27)`, [x.serverId,x.residentId,x.name,x.model,x.gender,x.ageBand,x.occupation,JSON.stringify(x.traits),x.voiceSeed,x.tone,JSON.stringify(x.appearance),JSON.stringify(x.home),JSON.stringify(x.work),JSON.stringify(x.leisure),JSON.stringify(x.location),x.bucket,x.activity,x.mood,x.health,JSON.stringify(x.needs),JSON.stringify(x.possessions),x.status,x.pinned,x.createdAt,x.updatedAt,x.lastSeenAt,x.voiceAssignment ? JSON.stringify(x.voiceAssignment) : null]);
      }
      await client.query('COMMIT');
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally { client.release(); }
    return { resident, knowledge: await this.knowledge(input.serverId, resident.residentId, input.characterId) };
  }
  async close() { await this.pool.end(); }
  async list(serverId:string,includeArchived=false){const result=await this.pool.query(`${this.select} WHERE server_id=$1 ${includeArchived?'':`AND status<>'archived'`} ORDER BY pinned DESC,last_seen_at DESC LIMIT 500`,[serverId]);return result.rows.map(r=>this.row(r));}
  async knowledge(serverId:string,id:string,c:string){const r=await this.pool.query(`SELECT server_id AS "serverId",resident_id AS "residentId",character_id AS "characterId",known_name_at AS "knownNameAt",player_name_known_at AS "playerNameKnownAt",last_met_at AS "lastMetAt",meetings FROM ai_npc_character_knowledge WHERE server_id=$1 AND resident_id=$2 AND character_id=$3`,[serverId,id,c]);const x=r.rows[0];return x?{...x,knownNameAt:x.knownNameAt?.toISOString?.()??x.knownNameAt,playerNameKnownAt:x.playerNameKnownAt?.toISOString?.()??x.playerNameKnownAt,lastMetAt:x.lastMetAt?.toISOString?.()??x.lastMetAt}:defaultKnowledge(serverId,id,c);}
  async upsertKnowledge(serverId:string,id:string,c:string,kind:'reveal'|'meeting',playerKnown=false){await this.pool.query(`INSERT INTO ai_npc_character_knowledge(server_id,resident_id,character_id,known_name_at,player_name_known_at,last_met_at,meetings) VALUES($1,$2,$3,CASE WHEN $4='reveal' THEN NOW() ELSE NULL END,CASE WHEN $5 THEN NOW() ELSE NULL END,CASE WHEN $4='meeting' THEN NOW() ELSE NULL END,CASE WHEN $4='meeting' THEN 1 ELSE 0 END) ON CONFLICT(server_id,resident_id,character_id) DO UPDATE SET known_name_at=CASE WHEN $4='reveal' THEN COALESCE(ai_npc_character_knowledge.known_name_at,NOW()) ELSE ai_npc_character_knowledge.known_name_at END,player_name_known_at=CASE WHEN $5 THEN COALESCE(ai_npc_character_knowledge.player_name_known_at,NOW()) ELSE ai_npc_character_knowledge.player_name_known_at END,last_met_at=CASE WHEN $4='meeting' THEN NOW() ELSE ai_npc_character_knowledge.last_met_at END,meetings=ai_npc_character_knowledge.meetings+CASE WHEN $4='meeting' THEN 1 ELSE 0 END`,[serverId,id,c,kind,playerKnown]);return this.knowledge(serverId,id,c);}
  revealName(a:string,b:string,c:string){return this.upsertKnowledge(a,b,c,'reveal');}
  noteMeeting(a:string,b:string,c:string,k=false){return this.upsertKnowledge(a,b,c,'meeting',k);}
  async observe(serverId:string,id:string,location:Vec4,activity?:string,mood?:string){await this.pool.query(`UPDATE ai_npc_residents SET location=$3,activity=COALESCE($4,activity),mood=COALESCE($5,mood),updated_at=NOW(),last_seen_at=NOW() WHERE server_id=$1 AND resident_id=$2`,[serverId,id,JSON.stringify(vec(location)),activity?.slice(0,40),mood?.slice(0,40)]);return (await this.list(serverId,true)).find(x=>x.residentId===id);}
  async lifecycle(serverId:string,id:string,event:'death'|'recover'|'archive'|'activate'|'respawn'|'pin'|'unpin',recoverySeconds=1800){if(event==='pin'||event==='unpin')await this.pool.query(`UPDATE ai_npc_residents SET pinned=$3,updated_at=NOW() WHERE server_id=$1 AND resident_id=$2`,[serverId,id,event==='pin']);else if(event==='death')await this.pool.query(`UPDATE ai_npc_residents SET status='recovering',health='injured',activity='unavailable',recovering_until=NOW()+($3 * INTERVAL '1 second'),updated_at=NOW() WHERE server_id=$1 AND resident_id=$2`,[serverId,id,bounded(recoverySeconds,60,86400,1800)]);else if(event==='archive')await this.pool.query(`UPDATE ai_npc_residents SET status='archived',updated_at=NOW() WHERE server_id=$1 AND resident_id=$2`,[serverId,id]);else await this.pool.query(`UPDATE ai_npc_residents SET status='active',health=$3,recovering_until=NULL,location=home,updated_at=NOW() WHERE server_id=$1 AND resident_id=$2`,[serverId,id,event==='recover'?'recovering':'healthy']);return(await this.list(serverId,true)).find(x=>x.residentId===id);}
  async simulate(serverId:string,at=new Date(),world?:ResidentWorld){const all=await this.list(serverId,true);for(const x of all)schedule(x,at,world);const client=await this.pool.connect();try{await client.query('BEGIN');for(const x of all)await client.query(`UPDATE ai_npc_residents SET status=$3,recovering_until=$4,health=$5,activity=$6,location=$7,needs=$8,mood=$9,updated_at=$10 WHERE server_id=$1 AND resident_id=$2`,[serverId,x.residentId,x.status,x.recoveringUntil??null,x.health,x.activity,JSON.stringify(x.location),JSON.stringify(x.needs),x.mood,x.updatedAt]);await client.query('COMMIT');}catch(e){await client.query('ROLLBACK');throw e;}finally{client.release();}return all;}
  async retire(serverId:string,id:string){const r=await this.pool.query(`DELETE FROM ai_npc_residents WHERE server_id=$1 AND resident_id=$2`,[serverId,id]);return r.rowCount??0;}
  async forgetCharacter(serverId:string,id:string,c:string){const r=await this.pool.query(`DELETE FROM ai_npc_character_knowledge WHERE server_id=$1 AND resident_id=$2 AND character_id=$3`,[serverId,id,c]);return r.rowCount??0;}
  async forgetServerKnowledge(serverId:string){const r=await this.pool.query(`DELETE FROM ai_npc_character_knowledge WHERE server_id=$1`,[serverId]);return r.rowCount??0;}
  async stats(serverId:string){const r=await this.pool.query(`SELECT COUNT(*)::int total,COUNT(*) FILTER(WHERE status='active')::int active,COUNT(*) FILTER(WHERE status='recovering')::int recovering,COUNT(*) FILTER(WHERE status='archived')::int archived FROM ai_npc_residents WHERE server_id=$1`,[serverId]);const k=await this.pool.query(`SELECT COUNT(*)::int count FROM ai_npc_character_knowledge WHERE server_id=$1 AND known_name_at IS NOT NULL`,[serverId]);return{...r.rows[0],knownNames:k.rows[0].count};}
}
