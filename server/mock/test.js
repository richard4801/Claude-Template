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
  assert.deepEqual((await api('GET', '/v1/models')).body.map(m => m.name), ['Sienna Vale', 'Noor Ellis']);
});

test('clip checks flag a failing clip and block the job', async () => {
  const fd = new FormData();
  fd.append('meta', new Blob([JSON.stringify({ name: 'bad', durationSec: 22, width: 1080, height: 1920, fps: 30, people: 2, watermark: 'TikTok logo' })], { type: 'application/json' }));
  const clip = await (await fetch(base + '/v1/uploads/clips', { method: 'POST', body: fd })).json();
  assert.equal(clip.checks.filter(c => c.status === 'bad').length, 3);
  const r = await api('POST', '/v1/jobs', { title: 'x', modelId: 'm_sienna', outfitId: 'o_green', clipId: clip.id, steps: 10 });
  assert.equal(r.body.code, 'clip_failed_checks');
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
  const job = (await api('POST', '/v1/jobs', { title: 'Dance', modelId: 'm_sienna', outfitId: 'o_green', clipId: 'clip_sample', steps: 10, takes: 2 })).body;
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
  const job = (await api('POST', '/v1/jobs', { title: 'Fail', modelId: 'm_sienna', outfitId: 'o_green', clipId: 'clip_sample', steps: 10 })).body;
  let j;
  for (let i = 0; i < 100; i++) { j = (await api('GET', '/v1/jobs')).body.find(x => x.id === job.id); if (j.state !== 'running') break; await new Promise(r => setTimeout(r, 50)); }
  assert.equal(j.state, 'failed');
  assert.equal(j.refunded, j.cost);
  assert.ok(Math.abs((await api('GET', '/v1/balance')).body.balance - before) < 1e-9);
});

test('balance too low blocks generate', async () => {
  await api('POST', '/v1/dev/reset');
  for (let i = 0; i < 9; i++) await api('POST', '/v1/jobs', { title: 'x', modelId: 'm_sienna', outfitId: 'o_green', clipId: 'clip_sample', steps: 10 });
  const r = await api('POST', '/v1/jobs', { title: 'x', modelId: 'm_sienna', outfitId: 'o_green', clipId: 'clip_sample', steps: 10 });
  assert.equal(r.status, 402);
  assert.equal(r.body.code, 'insufficient_balance');
  await api('POST', '/v1/dev/reset');
});
