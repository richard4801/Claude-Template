// Object storage: Cloudflare R2 (or MinIO) through the S3 API, or the local disk for dev. Both hand out presigned
// URLs, so clients and GPU workers move bytes directly without the API in the middle.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { AbortMultipartUploadCommand, CompleteMultipartUploadCommand, CreateMultipartUploadCommand, DeleteObjectCommand, GetObjectCommand, HeadObjectCommand, ListPartsCommand,
  PutObjectCommand, S3Client, UploadPartCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import type { Config } from '../config.js';

export type DownloadAs = { filename: string; contentType?: string };
export type StoredObject = { body: Readable; contentType: string; size?: number };

export interface Storage {
  readonly kind: 'local' | 's3';
  put(key: string, body: Buffer, contentType: string): Promise<void>;
  /** Streams a large object (app builds) without holding it in memory. [bytes] is the exact length. */
  putStream(key: string, body: Readable, contentType: string, bytes: number): Promise<void>;
  get(key: string): Promise<StoredObject | null>;
  head(key: string): Promise<{ size: number; contentType?: string } | null>;
  delete(key: string): Promise<void>;
  /** A URL the holder can PUT the object to, until it expires. */
  presignPut(key: string, contentType: string, ttlSec: number): Promise<{ url: string; headers: Record<string, string> }>;
  /** A URL the holder can GET the object from, until it expires. With [download], the response saves as that file name. */
  presignGet(key: string, ttlSec: number, download?: DownloadAs): Promise<string>;
  /**
   * Multipart upload for large files (long imports, up to 2 GB): the client PUTs parts to presigned URLs (resumable:
   * the parts already stored are listed), then the server completes. `id` is the store's own upload id.
   */
  multipart: {
    create(key: string, contentType: string): Promise<string>;
    partUrl(key: string, id: string, n: number, ttlSec: number): Promise<string>;
    listParts(key: string, id: string): Promise<{ n: number; etag: string; size: number }[]>;
    complete(key: string, id: string, parts: { n: number; etag: string }[]): Promise<void>;
    abort(key: string, id: string): Promise<void>;
  };
}

/** Upload parts: 64 MiB (≥ S3's 5 MiB minimum; 2 GB = 32 parts), at most 10 000. */
export const PART_BYTES = 64 * 1024 * 1024;
const unquote = (e: string | undefined) => (e ?? '').replace(/^"|"$/g, '');

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
      // Only add checksums where S3 requires them: otherwise a streamed PUT (app builds) goes out aws-chunked with a
      // trailing CRC, which R2 and MinIO handle inconsistently.
      requestChecksumCalculation: 'WHEN_REQUIRED', responseChecksumValidation: 'WHEN_REQUIRED',
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
  async putStream(key: string, body: Readable, contentType: string, bytes: number) {
    await this.client.send(new PutObjectCommand({ Bucket: this.bucket, Key: safeKey(key), Body: body, ContentType: contentType, ContentLength: bytes }));
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
  readonly multipart: Storage['multipart'] = {
    create: async (key, contentType) => {
      const r = await this.client.send(new CreateMultipartUploadCommand({ Bucket: this.bucket, Key: safeKey(key), ContentType: contentType }));
      if (!r.UploadId) throw new Error('multipart upload not created');
      return r.UploadId;
    },
    partUrl: (key, id, n, ttlSec) => getSignedUrl(this.client, new UploadPartCommand({ Bucket: this.bucket, Key: safeKey(key), UploadId: id, PartNumber: n }), { expiresIn: ttlSec }),
    listParts: async (key, id) => {
      const out: { n: number; etag: string; size: number }[] = [];
      let marker: string | undefined;
      for (;;) {
        const r = await this.client.send(new ListPartsCommand({ Bucket: this.bucket, Key: safeKey(key), UploadId: id, PartNumberMarker: marker }));
        for (const p of r.Parts ?? []) if (p.PartNumber) out.push({ n: p.PartNumber, etag: unquote(p.ETag), size: p.Size ?? 0 });
        if (!r.IsTruncated) return out;
        marker = r.NextPartNumberMarker;
      }
    },
    complete: async (key, id, parts) => {
      await this.client.send(new CompleteMultipartUploadCommand({ Bucket: this.bucket, Key: safeKey(key), UploadId: id,
        MultipartUpload: { Parts: parts.map(p => ({ PartNumber: p.n, ETag: `"${unquote(p.etag)}"` })) } }));
    },
    abort: async (key, id) => { await this.client.send(new AbortMultipartUploadCommand({ Bucket: this.bucket, Key: safeKey(key), UploadId: id })); },
  };
  presignGet(key: string, ttlSec: number, download?: DownloadAs) {
    return getSignedUrl(this.client, new GetObjectCommand({
      Bucket: this.bucket, Key: safeKey(key),
      ...(download ? { ResponseContentDisposition: `attachment; filename="${download.filename}"`, ResponseContentType: download.contentType } : {}),
    }), { expiresIn: ttlSec });
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
  async putStream(key: string, body: Readable, _contentType: string, bytes: number) {
    const f = this.file(key), tmp = `${f}.${crypto.randomBytes(6).toString('hex')}.part`;
    fs.mkdirSync(path.dirname(f), { recursive: true });
    try {
      await pipeline(body, fs.createWriteStream(tmp));
      if (fs.statSync(tmp).size !== bytes) throw new Error('upload size mismatch');
      await fs.promises.rename(tmp, f);
    } finally { await fs.promises.rm(tmp, { force: true }); }
  }
  async head(key: string) { const f = this.file(key); return fs.existsSync(f) ? { size: fs.statSync(f).size } : null; }
  /**
   * A presigned PUT's body, streamed to disk (never buffered: a 2 GB import used to be held in memory here). Refused
   * past `maxBytes`. With `part`, it is one part of a multipart upload. Returns the md5 (the ETag).
   */
  async putFrom(key: string, body: Readable, maxBytes: number, part?: { id: string; n: number }): Promise<{ etag: string; size: number }> {
    const f = part ? this.partFile(key, part.id, part.n) : this.file(key), tmp = `${f}.${crypto.randomBytes(6).toString('hex')}.part`;
    fs.mkdirSync(path.dirname(f), { recursive: true });
    const md5 = crypto.createHash('md5');
    let size = 0;
    try {
      await pipeline(body, async function* (src: AsyncIterable<Buffer>) {
        for await (const c of src) { size += c.length; if (size > maxBytes) throw Object.assign(new Error('too large'), { tooLarge: true }); md5.update(c); yield c; }
      }, fs.createWriteStream(tmp));
      await fs.promises.rename(tmp, f);
      return { etag: md5.digest('hex'), size };
    } finally { await fs.promises.rm(tmp, { force: true }); }
  }
  private partDir(key: string, id: string) {
    if (!/^[A-Za-z0-9]{8,64}$/.test(id)) throw new Error('bad multipart id');
    return `${this.file(key)}.mp-${id}`;
  }
  private partFile(key: string, id: string, n: number) {
    if (!(Number.isInteger(n) && n >= 1 && n <= 10000)) throw new Error('bad part number');
    if (!fs.existsSync(this.partDir(key, id))) throw new Error('no such multipart upload');
    return path.join(this.partDir(key, id), String(n).padStart(5, '0'));
  }
  readonly multipart: Storage['multipart'] = {
    create: async key => {
      const id = crypto.randomBytes(12).toString('hex');
      fs.mkdirSync(this.partDir(key, id), { recursive: true });
      return id;
    },
    partUrl: async (key, id, n, ttlSec) => {
      this.partFile(key, id, n);
      const exp = Date.now() + ttlSec * 1000, scope = `${key}#${id}#${n}`;
      return `${this.publicBase()}/storage/local/${safeKey(key)}?mp=${id}&part=${n}&exp=${exp}&sig=${this.sign('PUT', scope, exp)}`;
    },
    listParts: async (key, id) => {
      const dir = this.partDir(key, id);
      if (!fs.existsSync(dir)) throw new Error('no such multipart upload');
      const out: { n: number; etag: string; size: number }[] = [];
      for (const name of fs.readdirSync(dir).filter(x => /^\d{5}$/.test(x)).sort()) {
        const file = path.join(dir, name), md5 = crypto.createHash('md5');
        await pipeline(fs.createReadStream(file), md5);
        out.push({ n: Number(name), etag: md5.digest('hex'), size: fs.statSync(file).size });
      }
      return out;
    },
    complete: async (key, id, parts) => {
      const have = new Map((await this.multipart.listParts(key, id)).map(p => [p.n, p.etag]));
      for (const p of parts) if (have.get(p.n) !== unquote(p.etag)) throw Object.assign(new Error(`part ${p.n} is missing or different`), { badPart: p.n });
      const f = this.file(key), tmp = `${f}.${crypto.randomBytes(6).toString('hex')}.part`;
      try {
        const out = fs.createWriteStream(tmp);
        for (const p of [...parts].sort((a, b) => a.n - b.n)) await pipeline(fs.createReadStream(this.partFile(key, id, p.n)), out, { end: false });
        await new Promise<void>((res, rej) => out.end((e?: Error | null) => (e ? rej(e) : res())));
        await fs.promises.rename(tmp, f);
      } finally { await fs.promises.rm(tmp, { force: true }); }
      await fs.promises.rm(this.partDir(key, id), { recursive: true, force: true });
    },
    abort: async (key, id) => { await fs.promises.rm(this.partDir(key, id), { recursive: true, force: true }); },
  };
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
  async presignGet(key: string, ttlSec: number, _download?: DownloadAs) { return this.url('GET', key, ttlSec); }
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
