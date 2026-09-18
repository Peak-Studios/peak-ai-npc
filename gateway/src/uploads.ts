import { randomBytes } from 'node:crypto';

export type PendingUpload = { token: string; expiresAt: number; serverId: string; sessionId: string; bytes?: Buffer; mimeType?: string };

export class UploadStore {
  private readonly uploads = new Map<string, PendingUpload>();

  create(serverId: string, sessionId: string, ttlMs = 30_000) {
    this.cleanup();
    const upload: PendingUpload = { token: randomBytes(32).toString('base64url'), expiresAt: Date.now() + ttlMs, serverId, sessionId };
    this.uploads.set(upload.token, upload);
    return upload;
  }

  put(token: string, bytes: Buffer, mimeType: string) {
    const upload = this.uploads.get(token);
    if (!upload || upload.expiresAt <= Date.now()) { this.uploads.delete(token); return false; }
    if (upload.bytes) return false;
    if (!/^image\/(png|jpeg|webp)$/.test(mimeType) || bytes.length < 64 || bytes.length > 1_500_000) return false;
    upload.bytes = bytes;
    upload.mimeType = mimeType;
    return true;
  }

  consume(token: string, serverId: string, sessionId: string) {
    const upload = this.uploads.get(token);
    if (!upload) return undefined;
    if (upload.expiresAt <= Date.now()) { this.uploads.delete(token); return undefined; }
    if (upload.serverId !== serverId || upload.sessionId !== sessionId) return undefined;
    this.uploads.delete(token);
    if (!upload.bytes || !upload.mimeType) return undefined;
    return { serverId: upload.serverId, dataUrl: `data:${upload.mimeType};base64,${upload.bytes.toString('base64')}` };
  }

  purgeExpired() { this.cleanup(); }

  private cleanup() { for (const [token, upload] of this.uploads) if (upload.expiresAt <= Date.now()) this.uploads.delete(token); }
}

export function extractMultipartImage(body: Buffer, contentType: string) {
  const match = contentType.match(/boundary=(?:"([^"]+)"|([^;]+))/i);
  if (!match) return undefined;
  const boundary = Buffer.from(`--${match[1] ?? match[2]}`);
  const headerEnd = body.indexOf(Buffer.from('\r\n\r\n'));
  if (headerEnd < 0) return undefined;
  const payloadStart = headerEnd + 4;
  const payloadEnd = body.indexOf(Buffer.concat([Buffer.from('\r\n'), boundary]), payloadStart);
  if (payloadEnd < 0) return undefined;
  const headers = body.subarray(0, headerEnd).toString('utf8');
  const mime = headers.match(/\r\nContent-Type:\s*([^\r\n]+)/i)?.[1]?.trim();
  if (!mime) return undefined;
  return { bytes: body.subarray(payloadStart, payloadEnd), mime };
}
