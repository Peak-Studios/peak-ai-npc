-- Additive and repeatable. Existing people keep their identity and relationships.
-- Legacy voice assignments are filled once at the next resident resolution;
-- this migration deliberately does not infer or replace their casting.
ALTER TABLE ai_npc_residents
  ADD COLUMN IF NOT EXISTS voice_assignment jsonb NULL;
