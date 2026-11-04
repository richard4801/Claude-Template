// Object storage: Cloudflare R2 (or MinIO) through the S3 API, or the local disk for dev. Both hand out presigned
// URLs, so clients and GPU workers move bytes directly without the API in the middle.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { Readable } from 'node:stream';
import { DeleteObjectCommand, GetObjectCommand, HeadObjectCommand, PutObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import type { Config } from '../config.js';

export type StoredObject = { body: Readable; contentType: string; size?: number };

export interface Storage {
  readonly kind: 'local' | 's3';
  put(key: string, body: Buffer, contentType: string): Promise<void>;
  get(key: string): Promise<StoredObject | null>;
  head(key: string): Promise<{ size: number; contentType?: string } | null>;
  delete(key: string): Promise<void>;
  /** A URL the holder can PUT the object to, until it expires. */
  presignPut(key: string, contentType: string, ttlSec: number): Promise<{ url: string; headers: Record<string, string> }>;
  /** A URL the holder can GET the object from, until it expires. */
  presignGet(key: string, ttlSec: number): Promise<string>;
}

export const contentTypeFor = (key: string) =>
  key.endsWith('.png') ? 'image/png' : key.endsWith('.webp') ? 'image/webp' : key.endsWith('.mp4') ? 'video/mp4'
    : key.endsWith('.mov') ? 'video/quicktime' : key.endsWith('.safetensors') ? 'application/octet-stream' : 'image/jpeg';

const safeKey = (key: string) => {
  if (!/^[A-Za-z0-9][A-Za-z0-9._\/-]*$/.test(key) || key.includes('..')) throw new Error('bad storage key');
  return key;
};

export class S3Storage implements Storage {
  readonly kind = 's3' as const;
  readonly client: S3Client;
  constructor(private bucket: string, opts: { endpoint: string; region: string; accessKeyId: string; secretAccessKey: string; forcePathStyle: boolean }) {
    this.client = new S3Client({
      endpoint: opts.endpoint, region: opts.region, forcePathStyle: opts.forcePathStyle,
      credentials: { accessKeyId: opts.accessKeyId, secretAccessKey: opts.secretAccessKey },
    });
  }
  async put(key: string, body: Buffer, contentType: string) {
    await this.client.send(new PutObjectCommand({ Bucket: this.bucket, Key: safeKey(key), Body: body, ContentType: contentType }));
  }
  async get(key: string) {
    try {
      const r = await this.client.send(new GetObjectCommand({ Bucket: this.bucket, Key: safeKey(key) }));
      return { body: r.Body as Readable, contentType: r.ContentType ?? contentTypeFor(key), size: r.ContentLength };
    } catch (e: any) { if (e?.$metadata?.httpStatusCode === 404 || e?.name === 'NoSuchKey') return null; throw e; }
  }
  async head(key: string) {
    try {
      const r = await this.client.send(new HeadObjectCommand({ Bucket: this.bucket, Key: safeKey(key) }));
      return { size: r.ContentLength ?? 0, contentType: r.ContentType };
    } catch (e: any) { if (e?.$metadata?.httpStatusCode === 404 || e?.name === 'NotFound') return null; throw e; }
  }
  async delete(key: string) { await this.client.send(new DeleteObjectCommand({ Bucket: this.bucket, Key: safeKey(key) })); }
  async presignPut(key: string, contentType: string, ttlSec: number) {
    const url = await getSignedUrl(this.client, new PutObjectCommand({ Bucket: this.bucket, Key: safeKey(key), ContentType: contentType }), { expiresIn: ttlSec });
    return { url, headers: { 'content-type': contentType } };
  }
  presignGet(key: string, ttlSec: number) {
    return getSignedUrl(this.client, new GetObjectCommand({ Bucket: this.bucket, Key: safeKey(key) }), { expiresIn: ttlSec });
  }
}

/** Dev storage on disk. Presigned URLs point at this API (/storage/local/...) and carry an HMAC signature. */
export class LocalStorage implements Storage {
  readonly kind = 'local' as const;
  private secret = crypto.randomBytes(32);
  constructor(private dir: string, private publicBase: () => string) { fs.mkdirSync(dir, { recursive: true }); }
  private file(key: string) { return path.join(this.dir, safeKey(key)); }
  async put(key: string, body: Buffer) { const f = this.file(key); fs.mkdirSync(path.dirname(f), { recursive: true }); await fs.promises.writeFile(f, body); }
  async get(key: string) {
    const f = this.file(key);
    if (!fs.existsSync(f)) return null;
    return { body: fs.createReadStream(f), contentType: contentTypeFor(key), size: fs.statSync(f).size };
  }
  async head(key: string) { const f = this.file(key); return fs.existsSync(f) ? { size: fs.statSync(f).size } : null; }
  async delete(key: string) { await fs.promises.rm(this.file(key), { force: true }); }
  sign(method: string, key: string, exp: number) { return crypto.createHmac('sha256', this.secret).update(`${method}\n${key}\n${exp}`).digest('base64url'); }
  verify(method: string, key: string, exp: number, sig: string) {
    if (!(exp > Date.now())) return false;
    const want = Buffer.from(this.sign(method, key, exp)), got = Buffer.from(sig ?? '');
    return want.length === got.length && crypto.timingSafeEqual(want, got);
  }
  private url(method: string, key: string, ttlSec: number) {
    const exp = Date.now() + ttlSec * 1000;
    return `${this.publicBase()}/storage/local/${safeKey(key)}?exp=${exp}&sig=${this.sign(method, key, exp)}`;
  }
  async presignPut(key: string, contentType: string, ttlSec: number) { return { url: this.url('PUT', key, ttlSec), headers: { 'content-type': contentType } }; }
  async presignGet(key: string, ttlSec: number) { return this.url('GET', key, ttlSec); }
}

export function createStorage(c: Config, publicBase: () => string): Storage {
  if (c.storage === 's3') {
    if (!c.R2_BUCKET || !c.R2_ACCESS_KEY_ID || !c.R2_SECRET_ACCESS_KEY) throw new Error('Bad configuration: STORAGE=s3 needs R2_BUCKET, R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY');
    const endpoint = c.S3_ENDPOINT ?? (c.R2_ACCOUNT_ID ? `https://${c.R2_ACCOUNT_ID}.r2.cloudflarestorage.com` : undefined);
    if (!endpoint) throw new Error('Bad configuration: set R2_ACCOUNT_ID (or S3_ENDPOINT)');
    return new S3Storage(c.R2_BUCKET, { endpoint, region: c.S3_REGION, accessKeyId: c.R2_ACCESS_KEY_ID, secretAccessKey: c.R2_SECRET_ACCESS_KEY, forcePathStyle: c.S3_FORCE_PATH_STYLE });
  }
  return new LocalStorage(path.resolve(c.UPLOAD_DIR), publicBase);
}
