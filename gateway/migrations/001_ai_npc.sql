CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS ai_npc_memories (
  id uuid PRIMARY KEY,
  server_id text NOT NULL,
  npc_id text NOT NULL,
  character_id text NOT NULL,
  text text NOT NULL,
  importance real NOT NULL,
  created_at timestamptz NOT NULL,
  expires_at timestamptz NULL
);

CREATE INDEX IF NOT EXISTS ai_npc_memories_lookup
  ON ai_npc_memories(server_id, npc_id, character_id, importance DESC);

CREATE TABLE IF NOT EXISTS ai_npc_relationships (
  server_id text NOT NULL,
  npc_id text NOT NULL,
  character_id text NOT NULL,
  score real NOT NULL DEFAULT 0,
  tags jsonb NOT NULL DEFAULT '[]'::jsonb,
  updated_at timestamptz NOT NULL,
  PRIMARY KEY(server_id, npc_id, character_id)
);
