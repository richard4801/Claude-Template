// App downloads: the /get page, /download/* (local file or a presigned R2 redirect, 404 page when missing), the
// owner-only PUT /v1/releases/*, and the invite's shareText.
import http from 'node:http';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { makeApp, people } from './helpers.js';

const APK = Buffer.from('PK\u0003\u0004 fake apk bytes');

const put = (a: Awaited<ReturnType<typeof makeApp>>, url: string, token: string | undefined, body: Buffer) =>
  a.app.inject({ method: 'PUT', url, payload: body, headers: { 'content-type': 'application/octet-stream', ...(token ? { authorization: `Bearer ${token}` } : {}) } });

describe('app downloads (local storage)', () => {
  it('/get renders the themed page without a login, with both buttons and the invite line', async () => {
    const a = await makeApp();
    const r = await a.app.inject({ method: 'GET', url: '/get' });
    expect(r.statusCode).toBe(200);
    expect(r.headers['content-type']).toContain('text/html');
    expect(r.body).toContain('Get MUSE');
    expect(r.body).toContain('Download for Android');
    expect(r.body).toContain('Download for Mac');
    expect(r.body).toContain('Then sign up with the invite code you were sent');
    expect(r.body).toContain('name="viewport"');
    expect(r.body).toContain('coming soon'); // nothing uploaded yet
    await a.close();
  });

  it('downloads 404 with a friendly page until a build is uploaded; only the owner can upload', async () => {
    const a = await makeApp();
    const { owner, members } = await people(a, 1);
    for (const p of ['android', 'mac', 'windows']) {
      const r = await a.app.inject({ method: 'GET', url: `/download/${p}` });
      expect(r.statusCode).toBe(404);
      expect(r.headers['content-type']).toContain('text/html');
      expect(r.body).toContain('Not here yet');
    }
    expect((await put(a, '/v1/releases/android', undefined, APK)).statusCode).toBe(401);
    const m = await put(a, '/v1/releases/android', members[0]!.token, APK);
    expect(m.statusCode).toBe(403);
    expect(m.json().code).toBe('owner_only');
    expect((await put(a, '/v1/releases/windows', owner.token, APK)).statusCode).toBe(404);

    const up = await put(a, '/v1/releases/android', owner.token, APK);
    expect(up.statusCode).toBe(200);
    expect(up.json()).toMatchObject({ platform: 'android', key: 'releases/android/latest.apk', bytes: APK.length, filename: 'MUSE.apk' });
    expect(up.json().downloadUrl).toMatch(/\/download\/android$/);

    const d = await a.app.inject({ method: 'GET', url: '/download/android' });
    expect(d.statusCode).toBe(200);
    expect(d.headers['content-disposition']).toBe('attachment; filename="MUSE.apk"');
    expect(d.headers['content-type']).toBe('application/vnd.android.package-archive');
    expect(d.rawPayload.equals(APK)).toBe(true);

    // A new build replaces the old one; JSON bodies work too (any content type is the raw file).
    const zip = Buffer.from('PK mac zip');
    expect((await a.app.inject({ method: 'PUT', url: '/v1/releases/mac', payload: zip, headers: { 'content-type': 'application/zip', authorization: `Bearer ${owner.token}` } })).statusCode).toBe(200);
    const dm = await a.app.inject({ method: 'GET', url: '/download/mac' });
    expect(dm.headers['content-disposition']).toBe('attachment; filename="MUSE-mac.zip"');
    expect(dm.body).toBe('PK mac zip');

    const page = await a.app.inject({ method: 'GET', url: '/get' });
    expect(page.body).toContain('href="/download/android"');
    expect(page.body).toContain('href="/download/mac"');
    expect(page.body).not.toContain('coming soon');
    await a.close();
  });

  it('POST /v1/invites returns shareText with the download page, the code and the email', async () => {
    const a = await makeApp({ PUBLIC_URL: 'https://muse.example' });
    const { owner } = await people(a, 0);
    const inv = (await owner.req('POST', '/v1/invites', { email: 'tess@studio.dev' })).body;
    expect(inv.shareText).toBe(`You're invited to MUSE, the AI model studio. 1) Download: https://muse.example/get 2) Sign up with this invite code: ${inv.code} (email: tess@studio.dev). The code works once and expires in 14 days.`);
    const open = (await owner.req('POST', '/v1/invites', {})).body;
    expect(open.shareText).toContain(open.code);
    expect(open.shareText).not.toContain('email:');
    await a.close();
  });
});

describe('app downloads (R2)', () => {
  // A minimal S3 stand-in: PUT/HEAD/GET by path, and it echoes the presigned response-content-disposition on GET.
  const objects = new Map<string, Buffer>();
  const srv = http.createServer((req, res) => {
    const u = new URL(req.url!, 'http://x');
    const key = decodeURIComponent(u.pathname);
    const chunks: Buffer[] = [];
    req.on('data', c => chunks.push(c));
    req.on('end', () => {
      if (req.method === 'PUT') { objects.set(key, Buffer.concat(chunks)); res.setHeader('etag', '"x"'); return res.end(); }
      const o = objects.get(key);
      if (!o) { res.statusCode = 404; return res.end(req.method === 'HEAD' ? undefined : '<Error><Code>NoSuchKey</Code></Error>'); }
      res.setHeader('content-length', o.length);
      const cd = u.searchParams.get('response-content-disposition');
      if (cd) res.setHeader('content-disposition', cd);
      res.end(req.method === 'HEAD' ? undefined : o);
    });
  });
  let endpoint = '';
  beforeAll(async () => { await new Promise<void>(r => srv.listen(0, '127.0.0.1', r)); endpoint = `http://127.0.0.1:${(srv.address() as any).port}`; });
  afterAll(() => { srv.close(); });

  it('upload streams to R2; /download redirects to a short-lived presigned link that saves as MUSE.apk', async () => {
    const a = await makeApp({ STORAGE: 's3', R2_BUCKET: 'muse-media', R2_ACCESS_KEY_ID: 'AKTEST', R2_SECRET_ACCESS_KEY: 'secret', S3_ENDPOINT: endpoint, S3_FORCE_PATH_STYLE: 'true' });
    const { owner } = await people(a, 0);
    expect((await a.app.inject({ method: 'GET', url: '/download/android' })).statusCode).toBe(404);
    const up = await put(a, '/v1/releases/android', owner.token, APK);
    expect(up.statusCode, up.body).toBe(200);
    expect(objects.get('/muse-media/releases/android/latest.apk')!.equals(APK)).toBe(true);
    const r = await a.app.inject({ method: 'GET', url: '/download/android' });
    expect(r.statusCode).toBe(302);
    const loc = String(r.headers.location);
    expect(loc).toContain('/muse-media/releases/android/latest.apk?');
    expect(loc).toContain('X-Amz-Expires=600');
    expect(loc).not.toContain('secret');
    const got = await fetch(loc);
    expect(got.headers.get('content-disposition')).toBe('attachment; filename="MUSE.apk"');
    expect(Buffer.from(await got.arrayBuffer()).equals(APK)).toBe(true);
    expect((await a.app.inject({ method: 'GET', url: '/download/mac' })).statusCode).toBe(404);
    await a.close();
  });
});
