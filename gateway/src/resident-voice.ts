import { validVoiceProfileSpec, type VoiceProfileSpec } from './voice-registry.js';

export type ResidentVoiceAssignment = { version: 1; profile: VoiceProfileSpec };

/** Freeze only provider-neutral fields; provider credentials/IDs never cross into Lua. */
export function residentVoiceAssignment(value: unknown): ResidentVoiceAssignment | undefined {
  if (value === undefined) return undefined;
  if (!validVoiceProfileSpec(value)) throw new Error('invalid_resident_voice');
  const { voiceProfileId, genderPresentation, ageBand, accent, language, qualityMode, deliveryPreset } = value;
  return { version: 1, profile: { voiceProfileId, genderPresentation, ageBand,
    ...(accent ? { accent } : {}), language, qualityMode, deliveryPreset } };
}

export function validateResidentVoice(value: unknown): asserts value is ResidentVoiceAssignment | undefined {
  if (value === undefined) return;
  const stored = value as ResidentVoiceAssignment;
  if (!stored || stored.version !== 1 || !validVoiceProfileSpec(stored.profile)) throw new Error('invalid_resident_voice_assignment');
}
