export interface TranscriptionProvider { readonly name: string; transcribe(audioDataUrl: string, language?: string, signal?: AbortSignal): Promise<string>; }

export class NoopTranscriptionProvider implements TranscriptionProvider {
  readonly name = 'none';
  async transcribe(_audioDataUrl: string, _language?: string): Promise<string> { throw new Error('transcription_not_configured'); }
}

export class OpenAICompatibleTranscriptionProvider implements TranscriptionProvider {
  readonly name = 'openai-compatible-stt';
  constructor(private readonly endpoint: string, private readonly key: string, private readonly model: string) {}
  async transcribe(audioDataUrl: string, language?: string, signal?: AbortSignal) {
    if (!validateAudioDataUrl(audioDataUrl)) throw new Error('invalid_audio_data_url');
    const match = audioDataUrl.match(/^data:(audio\/[a-z0-9.+-]+);base64,(.+)$/i);
    if (!match) throw new Error('invalid_audio_data_url');
    const form = new FormData();
    const bytes = Buffer.from(match[2], 'base64');
    if (!bytes.length || bytes.length > 6_000_000) throw new Error('invalid_audio_size');
    if (bytes.length < 16) throw new Error('audio_too_short');
    const extension: Record<string, string> = { 'audio/webm': 'webm', 'audio/ogg': 'ogg', 'audio/mpeg': 'mp3', 'audio/mp4': 'm4a', 'audio/wav': 'wav', 'audio/x-wav': 'wav' };
    form.append('file', new Blob([bytes], { type: match[1] }), `voice-input.${extension[match[1].toLowerCase()] ?? 'wav'}`);
    form.append('model', this.model);
    if (language) form.append('language', language.slice(0, 12));
    const headers: Record<string, string> = {};
    if (this.key) headers.authorization = `Bearer ${this.key}`;
    const timeout = AbortSignal.timeout(Number(process.env.AI_NPC_STT_TIMEOUT_MS ?? 20_000));
    const response = await fetch(`${this.endpoint.replace(/\/$/, '')}/audio/transcriptions`, { method: 'POST', signal: signal ? AbortSignal.any([signal, timeout]) : timeout, headers, body: form });
    if (!response.ok) {
      let errCode = `stt_http_${response.status}`;
      try {
        const errBody = await response.json() as any;
        if (errBody?.error?.message && String(errBody.error.message).includes('too short')) {
          errCode = 'audio_too_short';
        }
      } catch {}
      throw new Error(errCode);
    }
    const body = await response.json() as { text?: string };
    // Common short replies are valid speech, not evidence of hallucination.
    // Silence/noise decisions require capture/provider evidence, not phrase bans.
    const text = typeof body.text === 'string' ? body.text.trim().slice(0, 500) : '';
    if (!text) throw new Error('empty_transcript');
    return text;
  }
}

export function validateAudioDataUrl(value: unknown) {
  if (typeof value !== 'string' || value.length > 8_000_000) return false;
  const match = /^data:audio\/(?:webm|ogg|mpeg|mp4|wav|x-wav);base64,([A-Za-z0-9+/]+={0,2})$/i.exec(value);
  if (!match || match[1].length % 4 !== 0) return false;
  const bytes = Buffer.from(match[1], 'base64');
  return bytes.length > 0 && bytes.toString('base64') === match[1];
}
