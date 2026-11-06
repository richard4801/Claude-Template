// /uploads/<key> serves every storage prefix the server writes and links to: suite takes (s/), camera-session stills (cam/),
// Claude chat frames (claude/) as well as the older u/ c/ g/ r/ l/ t/. A suite take used to 404 here (owner report, 2026-11-06).
import { afterAll, describe, expect, it } from 'vitest';
import { makeApp } from './helpers.js';

describe('/uploads route', async () => {
  const a = await makeApp();
  afterAll(async () => { await a.app.close(); });

  it('serves suite takes, camera stills and Claude frames', async () => {
    for (const key of ['s/jl_test/take_1.mp4', 's/jl_test/take_1.jpg', 'cam/cs_test/as_1.jpg', 'claude/th_test/img_1.png', 'r/jb_test/take_1.mp4']) {
      await a.ctx.storage.put(key, Buffer.from('x'), key.endsWith('.mp4') ? 'video/mp4' : 'image/jpeg');
      const r = await a.app.inject({ method: 'GET', url: `/uploads/${key}` });
      expect([200, 302], key).toContain(r.statusCode);
    }
  });

  it('still refuses unknown prefixes and path tricks', async () => {
    for (const url of ['/uploads/zz/x.jpg', '/uploads/s/../u/x.jpg', '/uploads/secret.txt']) {
      expect((await a.app.inject({ method: 'GET', url })).statusCode, url).toBe(404);
    }
  });
});
