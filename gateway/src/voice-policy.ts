import { approvedVoice, type DeliveryPreset, type QualityMode, type VoiceRegistry } from './voice-registry.js';

/** Resolve identity before paid dispatch. Never convert one provider's ID into another's. */
export function resolveVoice(registry: VoiceRegistry, providerName: string, serverId: string,
  npc: Record<string, unknown>, preset: DeliveryPreset, env: Record<string, string | undefined> = process.env) {
  const authored = npc.voice && typeof npc.voice === 'object' && !Array.isArray(npc.voice) ? npc.voice as Record<string, unknown> : {};
  const profileId = typeof authored.voiceProfileId === 'string' ? authored.voiceProfileId : typeof npc.voiceProfileId === 'string' ? npc.voiceProfileId : undefined;
  const activeProvider = providerName.replace(/-tts$/, '');
  const profile = profileId ? registry.resolve(serverId, profileId) : undefined;
  if (profileId && !profile) throw new Error('voice_profile_not_provisioned');
  if (profile && profile.provider !== activeProvider) throw new Error('voice_profile_provider_mismatch');
  if (profile && !approvedVoice(profile)) throw new Error('voice_profile_review_required');
  // All provider mappings require review; raw IDs/defaults cannot bypass casting.
  if (!profileId && activeProvider !== 'none') throw new Error('voice_profile_required');
  const legacyProvider = typeof authored.provider === 'string' ? authored.provider.toLowerCase() : undefined;
  const legacyVoice = typeof authored.voice === 'string' ? authored.voice : undefined;
  if (legacyVoice || legacyProvider) throw new Error('legacy_voice_requires_profile');
  const language = typeof authored.language === 'string' ? authored.language : 'en';
  const qualityMode: QualityMode = authored.qualityMode === 'quality' ? 'quality' : 'realtime';
  const model = activeProvider === 'elevenlabs'
    ? qualityMode === 'quality' ? 'eleven_multilingual_v2' : env.AI_NPC_TTS_MODEL ?? 'eleven_flash_v2_5'
    : env.AI_NPC_TTS_MODEL ?? (activeProvider === 'cartesia' ? 'sonic-3.5' : 'gpt-4o-mini-tts');
  if (profile && !profile.modelIds.includes(model)) throw new Error('voice_profile_model_not_approved');
  return { voice: profile?.voiceId ?? legacyVoice, language, profileId, qualityMode, deliveryPreset: preset,
    revision: profile?.revision ?? (profile ? 1 : undefined) };
}
