CREATE EXTENSION IF NOT EXISTS pgcrypto;

ALTER TABLE ai_npc_memories ADD COLUMN IF NOT EXISTS memory_key text;
ALTER TABLE ai_npc_memories ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'conversation';
ALTER TABLE ai_npc_memories ADD COLUMN IF NOT EXISTS subject text NOT NULL DEFAULT 'player';
ALTER TABLE ai_npc_memories ADD COLUMN IF NOT EXISTS confidence real NOT NULL DEFAULT 1;
ALTER TABLE ai_npc_memories ADD COLUMN IF NOT EXISTS tags jsonb NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE ai_npc_memories ADD COLUMN IF NOT EXISTS unresolved boolean NOT NULL DEFAULT false;
CREATE UNIQUE INDEX IF NOT EXISTS ai_npc_memories_key ON ai_npc_memories(server_id,npc_id,character_id,memory_key) WHERE memory_key IS NOT NULL;

ALTER TABLE ai_npc_relationships ADD COLUMN IF NOT EXISTS familiarity real NOT NULL DEFAULT 0;
ALTER TABLE ai_npc_relationships ADD COLUMN IF NOT EXISTS trust real NOT NULL DEFAULT 0;
ALTER TABLE ai_npc_relationships ADD COLUMN IF NOT EXISTS warmth real NOT NULL DEFAULT 0;
ALTER TABLE ai_npc_relationships ADD COLUMN IF NOT EXISTS respect real NOT NULL DEFAULT 0;
ALTER TABLE ai_npc_relationships ADD COLUMN IF NOT EXISTS fear real NOT NULL DEFAULT 0;
ALTER TABLE ai_npc_relationships ADD COLUMN IF NOT EXISTS irritation real NOT NULL DEFAULT 0;
ALTER TABLE ai_npc_relationships ADD COLUMN IF NOT EXISTS obligation real NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS ai_npc_residents (
  server_id text NOT NULL,resident_id text NOT NULL,name text NOT NULL,model text NOT NULL,gender text NOT NULL,age_band text NOT NULL,occupation text NOT NULL,
  traits jsonb NOT NULL,voice_seed bigint NOT NULL,tone text NOT NULL,appearance jsonb NOT NULL,home jsonb NOT NULL,work jsonb NOT NULL,leisure jsonb NOT NULL,
  location jsonb NOT NULL,bucket integer NOT NULL,activity text NOT NULL,mood text NOT NULL,health text NOT NULL,needs jsonb NOT NULL,possessions jsonb NOT NULL DEFAULT '[]'::jsonb,
  status text NOT NULL,recovering_until timestamptz NULL,pinned boolean NOT NULL DEFAULT false,created_at timestamptz NOT NULL,updated_at timestamptz NOT NULL,last_seen_at timestamptz NOT NULL,
  PRIMARY KEY(server_id,resident_id));
CREATE INDEX IF NOT EXISTS ai_npc_residents_active ON ai_npc_residents(server_id,status,bucket);

CREATE TABLE IF NOT EXISTS ai_npc_character_knowledge (
  server_id text NOT NULL,resident_id text NOT NULL,character_id text NOT NULL,known_name_at timestamptz NULL,player_name_known_at timestamptz NULL,last_met_at timestamptz NULL,meetings integer NOT NULL DEFAULT 0,
  PRIMARY KEY(server_id,resident_id,character_id),FOREIGN KEY(server_id,resident_id) REFERENCES ai_npc_residents(server_id,resident_id) ON DELETE CASCADE);

CREATE TABLE IF NOT EXISTS ai_npc_social_links (
  server_id text NOT NULL,resident_id text NOT NULL,other_resident_id text NOT NULL,kind text NOT NULL,strength real NOT NULL DEFAULT 0,updated_at timestamptz NOT NULL,
  PRIMARY KEY(server_id,resident_id,other_resident_id,kind));

CREATE TABLE IF NOT EXISTS ai_npc_simulation_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),server_id text NOT NULL,resident_id text NOT NULL,kind text NOT NULL,summary text NOT NULL,created_at timestamptz NOT NULL DEFAULT NOW(),expires_at timestamptz NULL);
