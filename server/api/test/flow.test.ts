// The whole app flow on the simulated GPU and image engine, over real HTTP + SSE, with the dev seed (mock data).
import { afterAll, beforeAll, describe, expect, it, onTestFinished, vi } from 'vitest';
import { client, makeApp, sse, until } from './helpers.js';

describe('simulated studio flow (dev seed, like server/mock)', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, base: string, token: string;
  let api: ReturnType<typeof client>;
  beforeAll(async () => {
    a = await makeApp({ DEV_MODE: 'true', DEV_SEED: 'true', BALANCE_MODE: 'simulated', RUNPOD_MIN_BALANCE_USD: '0', CAP_PER_USER_DAY_USD: '50', CAP_PER_DAY_USD: '100' });
    await a.app.listen({ port: 0, host: '127.0.0.1' });
    base = `http://127.0.0.1:${(a.app.server.address() as any).port}`;
    token = (await client(a)('POST', '/v1/auth/signin', { email: 'jen@studio.com', password: 'x' })).body.token;
    api = client(a, token);
  });
  afterAll(async () => { await a.close(); });

  it('seed data matches the mock', async () => {
    const b = (await api('GET', '/v1/balance')).body;
    expect(b).toMatchObject({ balance: 6.07, today: 0.13, perJobLimit: 5, videos: 9, balanceSource: 'studio', studioBalance: 6.07, needsFirstTopUp: false });
    expect((await api('GET', '/v1/models')).body.map((m: any) => m.name)).toEqual(['Demo model', 'Noor Ellis']);
    expect((await api('GET', '/v1/takes')).body.length).toBe(6);
  });

  it('a video job streams step progress over SSE, holds the price, and finishes with takes', async () => {
    // The simulated GPU samples a job's progress every 250 ms of wall-clock time. At the suite's SPEED (2400×) this
    // 2-take job lasts about 0.5 s, so it gets two samples, and a few ms of scheduling delay can put both outside the
    // Rendering phase (one in take 2's start-up, one after the end): no Rendering event is ever sent. At 480× each
    // take renders for about 1.2 s, several samples, so the job always streams Rendering progress. The GPU reads SPEED
    // when it starts a job.
    const speed = a.ctx.config.SPEED;
    a.ctx.config.SPEED = 480;
    onTestFinished(() => { a.ctx.config.SPEED = speed; });
    const es = await sse(base, token);
    const before = (await api('GET', '/v1/balance')).body.balance;
    const job = (await api('POST', '/v1/jobs', { title: 'Dance', modelId: 'm_demo', outfitId: 'o_green', clipId: 'clip_sample', steps: 10, takes: 2 })).body;
    expect(job.state).toBe('running');
    expect(job.cost).toBeCloseTo(2 * 0.6738666666666667, 9);
    expect((await api('GET', '/v1/balance')).body.balance).toBeCloseTo(before - 1.35, 6);
    await vi.waitFor(() => expect(es.events.some(e => e.job?.id === job.id && /^take \d\/2 · Rendering · ~/.test(e.job.phase))).toBe(true),
      { timeout: 10_000, interval: 25 });
    await until(() => es.events.some(e => e.job?.id === job.id && e.job.state === 'done'));
    await es.stop();
    // Member-facing phases never mention steps, GPUs or start-up.
    expect(es.events.filter(e => e.job?.id === job.id).every(e => !/step|gpu|warm|start-up/i.test(e.job.phase))).toBe(true);
    const done = es.events.find(e => e.job?.id === job.id && e.job.state === 'done');
    expect(done.takes.length).toBe(2);
    expect(done.takes[0]).toMatchObject({ kind: 'take', jobId: job.id, label: 'Edit', engineLabel: 'Edit', status: 'test' });
    // Sent by the hold (during POST /v1/jobs) and again by the settle, which the server finishes before it sends `done`.
    expect(es.events.some(e => e.type === 'balance')).toBe(true);
    expect(es.events.some(e => e.type === 'wallet')).toBe(true);
    expect(job.prompt).toContain('<Image 1> (face, front)');
    expect(job.prompt).toContain('outfit, back');
  });

  it('a failing clip only warns; bad steps and the per-job limit are refused', async () => {
    const fd = new FormData();
    fd.append('meta', new Blob([JSON.stringify({ name: 'bad', durationSec: 22, width: 1080, height: 1920, fps: 30, people: 2, watermark: 'TikTok logo' })], { type: 'application/json' }));
    const clip = await (await fetch(`${base}/v1/uploads/clips`, { method: 'POST', body: fd, headers: { authorization: `Bearer ${token}` } })).json();
    expect(clip.checks.filter((c: any) => c.status === 'bad').length).toBe(3);
    expect((await api('POST', '/v1/jobs', { title: 'x', modelId: 'm_demo', steps: 31 })).body.code).toBe('bad_request');
    expect((await api('POST', '/v1/jobs', { title: 'x', modelId: 'm_demo', steps: 30, takes: 3 })).body.code).toBe('over_job_limit');
  });

  it('queue: parked jobs are not charged until Run queue', async () => {
    const before = (await api('GET', '/v1/balance')).body.balance;
    const j = (await api('POST', '/v1/jobs', { title: 'Q', modelId: 'm_demo', outfitId: 'o_green', steps: 10, queue: true })).body;
    expect(j.state).toBe('queued');
    expect((await api('GET', '/v1/balance')).body.balance).toBe(before);
    const started = (await api('POST', '/v1/queue/run')).body;
    expect(started.map((x: any) => x.id)).toEqual([j.id]);
    expect((await api('POST', '/v1/queue/run')).body).toEqual([]);
    await until(async () => (await api('GET', '/v1/jobs')).body.find((x: any) => x.id === j.id).state === 'done');
  });

  it('sheet fill, outfit set and photoshoot use the image engine and record each image', async () => {
    const m = (await api('POST', '/v1/models', { name: 'Mac', age: 30, niche: 'Tech' })).body;
    expect(m.slots.length).toBe(7);
    const fill = (await api('POST', `/v1/models/${m.id}/fill-angles`)).body;
    expect(fill.cost).toBeCloseTo(7 * (0.015 + 0.015), 9); // 7 angles, no references yet: the estimate held
    expect(fill.model.slots.every((s: any) => s.busy)).toBe(true);
    await until(async () => (await api('GET', '/v1/models')).body.find((x: any) => x.id === m.id).slots.every((s: any) => s.image && s.source === 'generated'));
    const o = (await api('POST', '/v1/outfits', { modelId: 'm_demo', name: 'Cream knit', mode: 'describe', description: 'Cream cable-knit sweater' })).body;
    expect(o.state).toBe('generating');
    const ready = await until(async () => (await api('GET', '/v1/outfits')).body.find((x: any) => x.id === o.id && x.state === 'preview'));
    expect(ready.angles.filter(Boolean).length).toBe(4);
    expect((await api('POST', `/v1/outfits/${o.id}/save`)).body.state).toBe('ready');
    const shots = (await api('POST', '/v1/shoots', { modelId: 'm_demo', outfitId: 'o_green', scene: 'Café window', prompt: '', count: 4 })).body;
    expect(shots.length).toBe(4);
    expect(shots[0]).toMatchObject({ kind: 'shot', label: 'Café window · 1' });
    expect(shots[0].prompt).toContain('Scene: café window.');
    const imgs = await a.ctx.db.query.generatedImages.findMany();
    expect(new Set(imgs.map(i => i.purpose))).toEqual(new Set(['sheet', 'outfit', 'shoot']));
    expect(imgs.every(i => i.provider === 'simulated' && i.model === 'bundled-stills' && i.prompt.length > 20)).toBe(true);
  });

  it('identity LoRA: build, review, train on the GPU controller (lora-train), use, retrain', async () => {
    await api('POST', '/v1/balance/topup', { amount: 25 });
    const es = await sse(base, token);
    expect((await api('POST', '/v1/models/m_demo/lora/candidates')).body.state).toBe('building');
    const review = await until(() => es.events.find(e => e.lora?.state === 'review'));
    expect(review.lora.candidates.length).toBe(30);
    expect(review.lora.candidates.filter((c: any) => !c.keep).length).toBe(3);
    const l = (await api('POST', '/v1/models/m_demo/lora/train')).body;
    expect(l.state).toBe('training');
    await until(() => es.events.find(e => e.lora?.state === 'ready'), 20_000);
    await es.stop();
    expect(es.events.some(e => e.lora?.state === 'training' && e.lora.photo.progress > 0)).toBe(true);
    expect((await api('GET', '/v1/models/m_demo/lora')).body).toMatchObject({ version: 1, trainedOn: 27 });
    expect((await api('GET', '/v1/jobs')).body.some((j: any) => j.title.startsWith('LoRA'))).toBe(false);
    const job = (await api('POST', '/v1/jobs', { title: 'L', modelId: 'm_demo', outfitId: 'o_green', steps: 10 })).body;
    expect(job.prompt).toMatch(/LoRA demo_v1 video/);
    expect((await api('PATCH', '/v1/models/m_demo/lora', { use: false })).body.use).toBe(false);
    expect((await api('PATCH', '/v1/models/m_demo/lora', { state: 'review', use: true })).body.state).toBe('review');
  });

  it('accounts and posts: labels only on an explicit true; now hands off; scheduled waits in the DB', async () => {
    expect((await api('POST', '/v1/posts', { modelId: 'm_demo', takeId: 't_j1', platforms: ['tiktok'], when: 'now' })).status).toBe(400);
    expect((await api('POST', '/v1/models/m_demo/accounts/tiktok/connect')).body.account.handle).toBe('@demo.model');
    expect((await api('POST', '/v1/models/m_demo/accounts/myspace/connect')).status).toBe(400);
    const now = (await api('POST', '/v1/posts', { modelId: 'm_demo', takeId: 't_j1', platforms: ['tiktok'], caption: 'Kick', aiLabel: 'yes', when: 'now' })).body;
    expect(now).toMatchObject({ state: 'handoff', aiLabel: false, paidPartnership: false });
    const at = new Date(Date.now() + 3_600_000).toISOString();
    const later = (await api('POST', '/v1/posts', { modelId: 'm_demo', takeId: 't_j1', platforms: ['tiktok'], aiLabel: true, when: at })).body;
    expect(later).toMatchObject({ state: 'scheduled', when: at, aiLabel: true });
    expect((await api('GET', '/v1/posts?state=scheduled')).body.map((p: any) => p.id)).toEqual([later.id]);
    await until(async () => (await api('GET', '/v1/posts?state=posted')).body.find((p: any) => p.id === now.id));
    const soon = (await api('POST', '/v1/posts', { modelId: 'm_demo', takeId: 't_j1', platforms: ['tiktok'], when: new Date(Date.now() + 150).toISOString() })).body;
    await until(async () => (await api('GET', '/v1/posts')).body.find((p: any) => p.id === soon.id && p.state !== 'scheduled'));
    expect((await api('DELETE', `/v1/posts/${later.id}`)).status).toBe(204);
  });

  it('edit and delete a model (with her LoRA and accounts)', async () => {
    const m = (await api('PATCH', '/v1/models/m_demo', { personality: 'Warm', neverAdd: ['tattoos', 'rings', 'chokers'] })).body;
    expect(m.personality).toBe('Warm');
    expect((await api('PATCH', '/v1/models/m_demo', { name: ' ' })).status).toBe(400);
    await api('POST', '/v1/models/m_noor/accounts/x/connect');
    expect((await api('DELETE', '/v1/models/m_noor')).status).toBe(204);
    expect((await api('GET', '/v1/models/m_noor/lora')).status).toBe(404);
    expect((await api('GET', '/v1/models/m_noor/accounts')).status).toBe(404);
  });

  it('Upscale is in the contract but coming soon; Edit takes keep their labels', async () => {
    const r = await api('POST', '/v1/takes/t_j1/upscale', { size: '2k' });
    expect(r.status).toBe(409);
    expect(r.body).toEqual({ code: 'upscale_unavailable', error: 'Upscale is coming soon' });
    expect((await api('POST', '/v1/takes/t_j1/upscale', { size: '8k' })).status).toBe(400);
    expect((await api('POST', '/v1/takes/t_g4/upscale', { size: '4k' })).status).toBe(400); // a photo, not a render
    expect((await api('POST', '/v1/takes/nope/upscale', { size: '4k' })).status).toBe(404);
    const up = (await api('GET', '/v1/settings/studio')).body.features.video.addons.find((x: any) => x.id === 'upscale');
    expect(up).toMatchObject({ label: 'Upscale', available: false, comingSoon: true });
  });

  it('dev reset restores the seed; uploads round-trip', async () => {
    expect((await client(a)('POST', '/v1/dev/reset')).body.ok).toBe(true);
    expect((await api('GET', '/v1/balance')).body.balance).toBe(6.07);
    const fd = new FormData();
    fd.append('file', new Blob([new Uint8Array([0x89, 0x50, 0x4e, 0x47])], { type: 'image/png' }), 'a.png');
    const img = await (await fetch(`${base}/v1/uploads/images`, { method: 'POST', body: fd, headers: { authorization: `Bearer ${token}` } })).json();
    expect(img.url).toMatch(/^\/uploads\/u\/img_[0-9a-f]+\.png$/);
    const got = await fetch(base + img.url);
    expect(got.status).toBe(200);
    expect(new Uint8Array(await got.arrayBuffer())).toEqual(new Uint8Array([0x89, 0x50, 0x4e, 0x47]));
  });

  it("a member's photo loses its GPS EXIF and comes back upright (owner, 2026-11-11)", async () => {
    const sharp = (await import('sharp')).default;
    // 600 × 400 stored sideways (orientation 6: shown 400 × 600), with a GPS position.
    const raw = await sharp({ create: { width: 600, height: 400, channels: 3, background: { r: 200, g: 40, b: 40 } } }).jpeg()
      .withMetadata({ orientation: 6, exif: { IFD3: { GPSLatitudeRef: 'N', GPSLatitude: '48/1 51/1 24/1', GPSLongitudeRef: 'E', GPSLongitude: '2/1 21/1 3/1' } } }).toBuffer();
    expect(await sharp(raw).metadata()).toMatchObject({ orientation: 6, exif: expect.any(Buffer) });
    const fd = new FormData();
    fd.append('file', new Blob([new Uint8Array(raw)], { type: 'image/jpeg' }), 'IMG_0001.jpg');
    const img = await (await fetch(`${base}/v1/uploads/images`, { method: 'POST', body: fd, headers: { authorization: `Bearer ${token}` } })).json();
    const m = await sharp(Buffer.from(await (await fetch(base + img.url)).arrayBuffer())).metadata();
    expect(m).toMatchObject({ format: 'jpeg', width: 400, height: 600 });
    expect(m.exif).toBeUndefined();
    expect(m.orientation).toBeUndefined();
  });
});
