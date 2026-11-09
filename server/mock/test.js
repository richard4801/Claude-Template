// Run: node --test test.js  (starts the server on a random port at 2400x speed)
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
process.env.SPEED = '2400'; process.env.GEN_MS = '50';
process.env.UPLOAD_DIR = (await import('node:os')).tmpdir() + '/muse-mock-test';
const { createServer } = await import('./server.js');
const sim = await import('./sim.js');
let srv, base;
before(async () => { srv = createServer(); await new Promise(r => srv.listen(0, r)); base = `http://127.0.0.1:${srv.address().port}`; });
after(() => { srv.closeAllConnections(); srv.close(); });
const api = async (method, p, body) => {
  const r = await fetch(base + p, { method, headers: { 'content-type': 'application/json' }, body: body && JSON.stringify(body) });
  return { status: r.status, body: r.status === 204 ? null : await r.json() };
};

test('pricing matches the prototype', () => {
  const r = { engine: 'h3', steps: 10, use: 'first' };
  assert.equal(sim.money(sim.estCost(r)), '$0.67');
  assert.equal(Math.round(sim.estMin(r)), 10);
  assert.equal(sim.money(sim.estCost({ engine: 'viggle', use: 'first' })), '$0.13');
});

test('signup needs both attestations', async () => {
  assert.equal((await api('POST', '/v1/auth/signup', { email: 'a@b.c', attestAdultRightsOriginal: true, attestLabelAi: false })).status, 400);
  assert.equal((await api('POST', '/v1/auth/signup', { email: 'a@b.c', attestAdultRightsOriginal: true, attestLabelAi: true })).status, 200);
});

test('seed data', async () => {
  assert.equal((await api('GET', '/v1/balance')).body.balance, 6.07);
  assert.deepEqual((await api('GET', '/v1/models')).body.map(m => m.name), ['Demo model', 'Noor Ellis']);
});

test('clip checks flag a failing clip but only warn (no block)', async () => {
  const fd = new FormData();
  fd.append('meta', new Blob([JSON.stringify({ name: 'bad', durationSec: 22, width: 1080, height: 1920, fps: 30, people: 2, watermark: 'TikTok logo' })], { type: 'application/json' }));
  const clip = await (await fetch(base + '/v1/uploads/clips', { method: 'POST', body: fd })).json();
  assert.equal(clip.checks.filter(c => c.status === 'bad').length, 3);
  // Advice only: the server no longer refuses a job for a failing clip (checked in server/api's flow test).
});

test('job streams progress over SSE, charges, and finishes with takes', async () => {
  const ctrl = new AbortController();
  const events = [];
  const es = fetch(base + '/v1/events', { signal: ctrl.signal }).then(async res => {
    const dec = new TextDecoder();
    for await (const chunk of res.body) for (const line of dec.decode(chunk).split('\n')) if (line.startsWith('data: ')) events.push(JSON.parse(line.slice(6)));
  }).catch(() => {});
  await new Promise(r => setTimeout(r, 50));
  const before = (await api('GET', '/v1/balance')).body.balance;
  const job = (await api('POST', '/v1/jobs', { title: 'Dance', modelId: 'm_demo', outfitId: 'o_green', clipId: 'clip_sample', steps: 10, takes: 2 })).body;
  assert.equal(job.state, 'running');
  assert.ok(Math.abs((await api('GET', '/v1/balance')).body.balance - (before - job.cost)) < 1e-9);
  for (let i = 0; i < 100 && !events.some(e => e.job?.id === job.id && e.job.state === 'done'); i++) await new Promise(r => setTimeout(r, 50));
  ctrl.abort(); await es;
  assert.ok(events.some(e => e.job?.phase?.match(/step \d+\/10/)), 'saw step progress');
  const done = events.find(e => e.job?.id === job.id && e.job.state === 'done');
  assert.ok(done, 'job finished');
  assert.equal(done.takes.length, 2);
});

test('failed job is refunded', async () => {
  await api('POST', '/v1/dev/fail-next', { failNext: true });
  const before = (await api('GET', '/v1/balance')).body.balance;
  const job = (await api('POST', '/v1/jobs', { title: 'Fail', modelId: 'm_demo', outfitId: 'o_green', clipId: 'clip_sample', steps: 10 })).body;
  let j;
  for (let i = 0; i < 100; i++) { j = (await api('GET', '/v1/jobs')).body.find(x => x.id === job.id); if (j.state !== 'running') break; await new Promise(r => setTimeout(r, 50)); }
  assert.equal(j.state, 'failed');
  assert.equal(j.refunded, j.cost);
  assert.ok(Math.abs((await api('GET', '/v1/balance')).body.balance - before) < 1e-9);
});

test('balance too low blocks generate', async () => {
  await api('POST', '/v1/dev/reset');
  for (let i = 0; i < 9; i++) await api('POST', '/v1/jobs', { title: 'x', modelId: 'm_demo', outfitId: 'o_green', clipId: 'clip_sample', steps: 10 });
  const r = await api('POST', '/v1/jobs', { title: 'x', modelId: 'm_demo', outfitId: 'o_green', clipId: 'clip_sample', steps: 10 });
  assert.equal(r.status, 402);
  assert.equal(r.body.code, 'insufficient_balance');
  await api('POST', '/v1/dev/reset');
});

const until = async (fn, ms = 5000) => { const t0 = Date.now(); for (;;) { const v = await fn(); if (v) return v; if (Date.now() - t0 > ms) throw new Error('timed out'); await new Promise(r => setTimeout(r, 30)); } };

test('balance carries today', async () => {
  await api('POST', '/v1/dev/reset');
  const b = (await api('GET', '/v1/balance')).body;
  assert.equal(b.today, 0.13);
  await api('POST', '/v1/jobs', { title: 'x', modelId: 'm_demo', outfitId: 'o_green', clipId: 'clip_sample', steps: 10 });
  assert.ok((await api('GET', '/v1/balance')).body.today > 0.13);
  await api('POST', '/v1/dev/reset');
});

test('identity LoRA: build set, review, blocked on low balance, train, use, retrain', async () => {
  await api('POST', '/v1/dev/reset');
  assert.equal(sim.money(sim.loraTrainCost()), '$6.65');
  let l = (await api('GET', '/v1/models/m_demo/lora')).body;
  assert.equal(l.state, 'none'); assert.equal(l.version, 0); assert.equal(l.use, true);
  l = (await api('POST', '/v1/models/m_demo/lora/candidates')).body;
  assert.equal(l.state, 'building');
  assert.ok(Math.abs((await api('GET', '/v1/balance')).body.balance - (6.07 - 0.60)) < 1e-9);
  l = await until(async () => { const x = (await api('GET', '/v1/models/m_demo/lora')).body; return x.state === 'review' && x; });
  assert.equal(l.candidates.length, 30);
  const flagged = l.candidates.filter(c => c.flag);
  assert.equal(flagged.length, 3);
  assert.ok(flagged.every(c => !c.keep), 'flagged shots are dropped by default');
  assert.ok(l.candidates.every(c => c.image.asset && !c.image.asset.startsWith('vid_')));
  // $5.47 left < $6.65: blocked
  let r = await api('POST', '/v1/models/m_demo/lora/train');
  assert.equal(r.status, 402); assert.equal(r.body.code, 'insufficient_balance');
  await api('POST', '/v1/balance/topup', { amount: 25, method: 'card' });
  // drop down to 19 kept: blocked
  for (const c of l.candidates.filter(c => c.keep).slice(0, 8)) await api('PATCH', `/v1/models/m_demo/lora/candidates/${c.id}`, { keep: false });
  r = await api('POST', '/v1/models/m_demo/lora/train');
  assert.equal(r.status, 400);
  r = await api('PATCH', `/v1/models/m_demo/lora/candidates/${flagged[0].id}`, { keep: true }); // restore a flagged one
  assert.equal(r.body.candidates.filter(c => c.keep).length, 20);
  const before = (await api('GET', '/v1/balance')).body.balance;
  l = (await api('POST', '/v1/models/m_demo/lora/train')).body;
  assert.equal(l.state, 'training');
  assert.ok(Math.abs((await api('GET', '/v1/balance')).body.balance - (before - 6.65)) < 1e-9);
  l = await until(async () => { const x = (await api('GET', '/v1/models/m_demo/lora')).body; return x.state === 'ready' && x; });
  assert.equal(l.version, 1); assert.equal(l.trainedOn, 20); assert.equal(l.photo.progress, 100); assert.equal(l.video.progress, 100);
  // The H3 prompt names the video LoRA while it's on, and drops it when off.
  const job = (await api('POST', '/v1/jobs', { title: 'L', modelId: 'm_demo', outfitId: 'o_green', clipId: 'clip_sample', steps: 10 })).body;
  assert.match(job.prompt, /LoRA demo_v1 video/);
  assert.equal((await api('PATCH', '/v1/models/m_demo/lora', { use: false })).body.use, false);
  const job2 = (await api('POST', '/v1/jobs', { title: 'L', modelId: 'm_demo', outfitId: 'o_green', clipId: 'clip_sample', steps: 4, engine: 'viggle' })).body;
  assert.doesNotMatch(job2.prompt, /LoRA/);
  // Retrain makes v2
  assert.equal((await api('PATCH', '/v1/models/m_demo/lora', { state: 'review', use: true })).body.state, 'review');
  await api('POST', '/v1/models/m_demo/lora/train');
  l = await until(async () => { const x = (await api('GET', '/v1/models/m_demo/lora')).body; return x.state === 'ready' && x; });
  assert.equal(l.version, 2);
  await api('POST', '/v1/dev/reset');
});

test('lora events stream training progress', async () => {
  await api('POST', '/v1/dev/reset');
  await api('POST', '/v1/balance/topup', { amount: 25 });
  const ctrl = new AbortController(), events = [];
  const es = fetch(base + '/v1/events', { signal: ctrl.signal }).then(async res => {
    const dec = new TextDecoder();
    for await (const chunk of res.body) for (const line of dec.decode(chunk).split('\n')) if (line.startsWith('data: ')) events.push(JSON.parse(line.slice(6)));
  }).catch(() => {});
  await new Promise(r => setTimeout(r, 50));
  await api('POST', '/v1/models/m_demo/lora/candidates');
  await until(() => events.some(e => e.type === 'lora' && e.lora.state === 'review'));
  await api('POST', '/v1/models/m_demo/lora/train');
  await until(() => events.some(e => e.type === 'lora' && e.lora.state === 'ready'));
  ctrl.abort(); await es;
  assert.ok(events.some(e => e.type === 'lora' && e.lora.state === 'training' && e.lora.photo.progress > 0));
  await api('POST', '/v1/dev/reset');
});

test('accounts connect and disconnect per model', async () => {
  await api('POST', '/v1/dev/reset');
  assert.deepEqual((await api('GET', '/v1/models/m_demo/accounts')).body, []);
  const r = await api('POST', '/v1/models/m_demo/accounts/tiktok/connect');
  assert.equal(r.body.account.handle, '@demo.model');
  assert.equal(r.body.account.canPostDirect, false);
  assert.equal((await api('POST', '/v1/models/m_demo/accounts/youtube/connect')).body.account.handle, 'Demo model');
  assert.equal((await api('POST', '/v1/models/m_demo/accounts/myspace/connect')).status, 400);
  assert.deepEqual((await api('GET', '/v1/models/m_demo/accounts')).body.map(a => a.platform), ['tiktok', 'youtube']);
  assert.deepEqual((await api('GET', '/v1/models/m_noor/accounts')).body, []);
  assert.equal((await api('DELETE', '/v1/models/m_demo/accounts/youtube')).status, 204);
  assert.deepEqual((await api('GET', '/v1/models/m_demo/accounts')).body.map(a => a.platform), ['tiktok']);
  await api('POST', '/v1/dev/reset');
});

test('posts: labels stay off unless the user turns them on; now hands off, schedule waits', async () => {
  await api('POST', '/v1/dev/reset');
  let r = await api('POST', '/v1/posts', { modelId: 'm_demo', takeId: 't_j1', platforms: ['tiktok'], caption: 'hi', when: 'now' });
  assert.equal(r.status, 400, 'needs a connected account');
  await api('POST', '/v1/models/m_demo/accounts/tiktok/connect');
  await api('POST', '/v1/models/m_demo/accounts/instagram/connect');
  r = await api('POST', '/v1/posts', { modelId: 'm_demo', takeId: 't_j1', platforms: [], caption: 'x' });
  assert.equal(r.status, 400);
  const now = (await api('POST', '/v1/posts', { modelId: 'm_demo', takeId: 't_j1', platforms: ['tiktok', 'instagram'], caption: 'Kick #dance', when: 'now' })).body;
  assert.equal(now.state, 'handoff');
  assert.equal(now.aiLabel, false); assert.equal(now.paidPartnership, false);
  const labelled = (await api('POST', '/v1/posts', { modelId: 'm_demo', takeId: 't_j2', platforms: ['tiktok'], caption: '', aiLabel: true, paidPartnership: true, when: 'now' })).body;
  assert.equal(labelled.aiLabel, true); assert.equal(labelled.paidPartnership, true);
  const truthy = (await api('POST', '/v1/posts', { modelId: 'm_demo', takeId: 't_j2', platforms: ['tiktok'], aiLabel: 'yes', when: 'now' })).body;
  assert.equal(truthy.aiLabel, false, 'only an explicit true turns a label on');
  const at = new Date(Date.now() + 3_600_000).toISOString();
  const sched = (await api('POST', '/v1/posts', { modelId: 'm_demo', takeId: 't_j1', platforms: ['instagram'], caption: 'later', when: at })).body;
  assert.equal(sched.state, 'scheduled'); assert.equal(sched.when, at);
  assert.deepEqual((await api('GET', '/v1/posts?state=scheduled')).body.map(p => p.id), [sched.id]);
  const posted = await until(async () => (await api('GET', '/v1/posts?state=posted')).body.find(p => p.id === now.id));
  assert.ok(posted.stats.views > 0 && posted.stats.likes > 0);
  assert.equal((await api('DELETE', `/v1/posts/${sched.id}`)).status, 204);
  assert.equal((await api('GET', '/v1/posts?state=scheduled')).body.length, 0);
  await api('POST', '/v1/dev/reset');
});

test('queue: queued jobs are not charged until Run queue', async () => {
  await api('POST', '/v1/dev/reset');
  const before = (await api('GET', '/v1/balance')).body.balance;
  const j = (await api('POST', '/v1/jobs', { title: 'Q', modelId: 'm_demo', outfitId: 'o_green', clipId: 'clip_sample', steps: 10, queue: true })).body;
  assert.equal(j.state, 'queued');
  assert.equal((await api('GET', '/v1/balance')).body.balance, before);
  const started = (await api('POST', '/v1/queue/run')).body;
  assert.deepEqual(started.map(x => x.id), [j.id]);
  assert.equal(started[0].state, 'running');
  assert.ok((await api('GET', '/v1/balance')).body.balance < before);
  assert.deepEqual((await api('POST', '/v1/queue/run')).body, []);
  await api('POST', '/v1/dev/reset');
});

test('edit and delete a model (with her LoRA and accounts)', async () => {
  await api('POST', '/v1/dev/reset');
  const m = (await api('PATCH', '/v1/models/m_demo', { name: 'Demo M.', personality: 'Warm, dry humour', notes: 'No gym content', neverAdd: ['tattoos', 'rings', 'chokers'] })).body;
  assert.equal(m.name, 'Demo M.'); assert.equal(m.personality, 'Warm, dry humour'); assert.equal(m.notes, 'No gym content');
  assert.deepEqual(m.neverAdd, ['tattoos', 'rings', 'chokers']);
  assert.equal((await api('PATCH', '/v1/models/m_demo', { name: ' ' })).status, 400);
  await api('POST', '/v1/models/m_noor/accounts/x/connect');
  await api('POST', '/v1/models/m_noor/lora/candidates');
  assert.equal((await api('DELETE', '/v1/models/m_noor')).status, 204);
  assert.deepEqual((await api('GET', '/v1/models')).body.map(x => x.id), ['m_demo']);
  assert.equal((await api('GET', '/v1/models/m_noor/lora')).status, 404);
  assert.equal((await api('GET', '/v1/models/m_noor/accounts')).status, 404);
  assert.equal((await api('DELETE', '/v1/models/m_noor')).status, 404);
  await api('POST', '/v1/dev/reset');
});

test('editor uploads: a font is presigned, PUT, checked and named; other files are refused', async () => {
  const fs = await import('node:fs');
  const figtree = fs.readFileSync(new URL('../api/assets/fonts/figtree_700.ttf', import.meta.url));
  const p = (await api('POST', '/v1/editor/uploads/presign', { purpose: 'font', contentType: 'font/ttf', bytes: figtree.length })).body;
  assert.equal((await fetch(p.url, { method: 'PUT', headers: p.headers, body: figtree })).status, 204);
  assert.deepEqual((await api('POST', '/v1/editor/uploads/font-check', { uploadId: p.uploadId })).body, { uploadId: p.uploadId, name: 'Figtree Bold' });
  assert.ok((await api('GET', `/v1/editor/uploads/${p.uploadId}`)).body.url.startsWith('/uploads/'));
  const junk = (await api('POST', '/v1/editor/uploads/presign', { purpose: 'font', contentType: 'application/octet-stream' })).body;
  await fetch(junk.url, { method: 'PUT', body: 'not a font at all' });
  const r = await api('POST', '/v1/editor/uploads/font-check', { uploadId: junk.uploadId });
  assert.equal(r.status, 400); assert.match(r.body.error, /not a TrueType or OpenType font/);
  assert.equal((await api('POST', '/v1/editor/uploads/presign', { purpose: 'font', contentType: 'font/woff2' })).status, 400);
  assert.equal((await api('POST', '/v1/editor/uploads/presign', { purpose: 'font', contentType: 'font/ttf', bytes: 11 * 1024 * 1024 })).status, 400);
});
