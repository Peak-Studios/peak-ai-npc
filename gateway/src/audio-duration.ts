import { spawn } from 'node:child_process';

const formats: Record<string, string> = {
  'audio/wav': 'wav', 'audio/x-wav': 'wav', 'audio/mpeg': 'mp3', 'audio/mp3': 'mp3',
  'audio/webm': 'matroska,webm', 'audio/ogg': 'ogg', 'audio/mp4': 'mov',
};
const sampleRate = 16_000;
let activeDecoders = 0;

/** Count decoded audio samples, never caller duration, container timestamps or bitrate estimates.
 * Only stdin/stdout pipes are allowed: embedded file/network references cannot be opened.
 * Audio stays in memory, and decoder diagnostics never reach logs or the caller.
 */
export async function measuredAudioSeconds(bytes: Buffer, contentType: string, options: {
  signal?: AbortSignal; maximumSeconds?: number; executable?: string; rejectSilence?: boolean;
} = {}): Promise<number> {
  const format = formats[contentType.toLowerCase().split(';')[0].trim()];
  const maximumSeconds = options.maximumSeconds ?? 120;
  if (!format || !bytes.length || bytes.length > 6_000_000) throw new Error('audio_measurement_invalid');
  if (!Number.isFinite(maximumSeconds) || maximumSeconds <= 0 || maximumSeconds > 3_600) throw new Error('audio_measurement_limit_invalid');
  options.signal?.throwIfAborted();
  if (activeDecoders >= 4) throw new Error('audio_measurement_busy');
  activeDecoders++;
  try {
    return await new Promise<number>((resolve, reject) => {
      // Do not pass provider credentials, FFREPORT, or user FFmpeg overrides to the decoder.
      const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => /^(PATH|SystemRoot|WINDIR)$/i.test(key)));
      const child = spawn(options.executable ?? process.env.AI_NPC_FFMPEG_PATH ?? 'ffmpeg', [
        '-hide_banner', '-loglevel', 'error', '-nostdin', '-xerror', '-max_alloc', '33554432',
        '-protocol_whitelist', 'pipe', '-format_whitelist', 'wav,mp3,ogg,matroska,webm,mov',
        '-threads', '1', '-f', format, '-i', 'pipe:0', '-map', '0:a:0', '-vn', '-sn', '-dn',
        '-threads', '1', '-ac', '1', '-ar', String(sampleRate), '-af', 'asetpts=N/SR/TB',
        '-c:a', 'pcm_s16le', '-f', 's16le', 'pipe:1',
      ], { env, windowsHide: true, shell: false, stdio: ['pipe', 'pipe', 'ignore'] });
      let outputBytes = 0;
      let hasSignal = false;
      let failure: Error | undefined;
      const stop = (code: string) => { failure ??= new Error(code); child.kill('SIGKILL'); };
      const abort = () => stop('audio_measurement_aborted');
      const timer = setTimeout(() => stop('audio_measurement_timeout'), 5_000);
      options.signal?.addEventListener('abort', abort, { once: true });
      if (options.signal?.aborted) abort();
      child.stdout.on('data', (chunk: Buffer) => {
        outputBytes += chunk.length;
        if (!hasSignal && chunk.some(value => value !== 0)) hasSignal = true;
        if (outputBytes > maximumSeconds * sampleRate * 2) stop('audio_duration_exceeded');
      });
      // EPIPE is normal after a bounded rejection; close/error decides the result.
      child.stdin.on('error', () => {});
      child.once('error', () => { failure ??= new Error('audio_measurement_unavailable'); });
      child.once('close', code => {
        clearTimeout(timer);
        options.signal?.removeEventListener('abort', abort);
        if (failure) return reject(failure);
        if (code !== 0 || !outputBytes || outputBytes % 2) return reject(new Error('audio_measurement_invalid'));
        if (options.rejectSilence && !hasSignal) return reject(new Error('audio_measurement_silent'));
        resolve(outputBytes / (sampleRate * 2));
      });
      child.stdin.end(bytes);
    });
  } finally { activeDecoders--; }
}

export function audioDataUrlBytes(value: string) {
  const match = /^data:(audio\/[a-z0-9.+-]+);base64,([A-Za-z0-9+/]+={0,2})$/i.exec(value);
  if (!match || match[2].length > 8_000_000) throw new Error('audio_measurement_invalid');
  const bytes = Buffer.from(match[2], 'base64');
  if (bytes.toString('base64') !== match[2]) throw new Error('audio_measurement_invalid');
  return { bytes, contentType: match[1] };
}
