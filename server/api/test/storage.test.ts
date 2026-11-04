// R2 presigning against a stub S3 endpoint (path-style, like MinIO), and the presigned upload + confirm flow.
import http from 'node:http';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { S3Storage } from '../src/storage/index.js';
import { makeApp, people } from './helpers.js';

/** Stores PUTs in memory and serves GET/HEAD; refuses requests without a SigV4 presigned query. */
function stubS3() {
  const objects = new Map<string, { body: Buffer; type: string }>();
  const srv = http.createServer((req, res) => {
    const u = new URL(req.url!, 'http://x');
    const signed = u.searchParams.get('X-Amz-Algorithm') === 'AWS4-HMAC-SHA256' && u.searchParams.get('X-Amz-Signature') && u.searchParams.get('X-Amz-Credential')?.startsWith('AKTEST/');
    const authed = signed || (req.headers.authorization ?? '').startsWith('AWS4-HMAC-SHA256 Credential=AKTEST/');
    if (!authed) { res.statusCode = 403; return res.end('<Error><Code>AccessDenied</Code></Error>'); }
    const chunks: Buffer[] = [];
    req.on('data', c => chunks.push(c));
    req.on('end', () => {
      const key = decodeURIComponent(u.pathname);
      if (req.method === 'PUT') { objects.set(key, { body: Buffer.concat(chunks), type: String(req.headers['content-type'] ?? '') }); res.setHeader('etag', '"x"'); return res.end(); }
      const o = objects.get(key);
      if (!o) { res.statusCode = 404; return res.end(req.method === 'HEAD' ? undefined : '<Error><Code>NoSuchKey</Code></Error>'); }
      res.setHeader('content-type', o.type); res.setHeader('content-length', o.body.length);
      res.end(req.method === 'HEAD' ? undefined : o.body);
    });
  });
  return { srv, objects };
}

describe('S3/R2 storage', () => {
  const { srv, objects } = stubS3();
  let endpoint = '';
  beforeAll(async () => { await new Promise<void>(r => srv.listen(0, '127.0.0.1', r)); endpoint = `http://127.0.0.1:${(srv.address() as any).port}`; });
  afterAll(() => { srv.close(); });

  it('presigned PUT and GET URLs work and expire in the URL', async () => {
    const s = new S3Storage('muse', { endpoint, region: 'auto', accessKeyId: 'AKTEST', secretAccessKey: 'secret', forcePathStyle: true });
    const put = await s.presignPut('u/test.jpg', 'image/jpeg', 600);
    expect(put.url).toContain('/muse/u/test.jpg?');
    expect(put.url).toContain('X-Amz-Expires=600');
    expect(put.url).not.toContain('secret');
    expect((await fetch(put.url, { method: 'PUT', headers: put.headers, body: 'jpeg bytes' })).status).toBe(200);
    expect(objects.get('/muse/u/test.jpg')!.body.toString()).toBe('jpeg bytes');
    expect(await s.head('u/test.jpg')).toMatchObject({ size: 10 });
    const get = await s.presignGet('u/test.jpg', 600);
    expect(await (await fetch(get)).text()).toBe('jpeg bytes');
    expect(await s.head('u/missing.jpg')).toBeNull();
    expect(() => s.presignGet('../etc/passwd', 60)).toThrow();
  });

  it('API: presign → PUT → confirm gives an image ref and a clip with checks; /uploads redirects to R2', async () => {
    const a = await makeApp({ STORAGE: 's3', R2_BUCKET: 'muse', R2_ACCESS_KEY_ID: 'AKTEST', R2_SECRET_ACCESS_KEY: 'secret', S3_ENDPOINT: endpoint, S3_FORCE_PATH_STYLE: 'true' });
    const { owner } = await people(a, 0);
    const p = (await owner.req('POST', '/v1/uploads/presign', { kind: 'clip', contentType: 'video/mp4', bytes: 9 })).body;
    expect(p).toMatchObject({ method: 'PUT', headers: { 'content-type': 'video/mp4' } });
    expect((await owner.req('POST', `/v1/uploads/${p.uploadId}/confirm`, { meta: { name: 'd', durationSec: 5, width: 1080, height: 1920, fps: 30 } })).body.code).toBe('upload_missing');
    expect((await fetch(p.url, { method: 'PUT', headers: p.headers, body: 'mp4 bytes' })).status).toBe(200);
    const clip = (await owner.req('POST', `/v1/uploads/${p.uploadId}/confirm`, { meta: { name: 'd', durationSec: 5, width: 1080, height: 1920, fps: 30 } })).body;
    expect(clip.checks.every((c: any) => c.status !== 'bad')).toBe(true);
    const up = (await a.ctx.db.query.uploads.findMany()).find(u => u.id === p.uploadId)!;
    expect(up).toMatchObject({ state: 'ready', bytes: 9, sha256: expect.stringMatching(/^[0-9a-f]{64}$/) });
    const i = (await owner.req('POST', '/v1/uploads/presign', { kind: 'image', contentType: 'image/png' })).body;
    await fetch(i.url, { method: 'PUT', headers: i.headers, body: 'png' });
    const ref = (await owner.req('POST', `/v1/uploads/${i.uploadId}/confirm`)).body;
    expect(ref.url).toMatch(/^\/uploads\/u\/up_[0-9a-f]+\.png$/);
    const r = await a.app.inject({ method: 'GET', url: ref.url });
    expect(r.statusCode).toBe(302);
    expect(await (await fetch(r.headers.location as string)).text()).toBe('png');
    expect((await owner.req('POST', '/v1/uploads/presign', { kind: 'image', contentType: 'video/mp4' })).status).toBe(400);
    await a.close();
  });

  it('local storage presigned URLs check their signature', async () => {
    const a = await makeApp();
    const url = await a.ctx.storage.presignPut('u/x.jpg', 'image/jpeg', 60);
    const path = url.url.replace(/^https?:\/\/[^/]+/, '');
    expect((await a.app.inject({ method: 'PUT', url: path.replace(/sig=[^&]+/, 'sig=forged'), payload: 'x', headers: { 'content-type': 'image/jpeg' } })).statusCode).toBe(403);
    expect((await a.app.inject({ method: 'PUT', url: path, payload: 'x', headers: { 'content-type': 'image/jpeg' } })).statusCode).toBe(200);
    await a.close();
  });
});
