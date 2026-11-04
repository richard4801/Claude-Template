// The RunPod controller against a fake RunPod GraphQL API (no pods are started, no money spent), and the worker
// protocol end to end: claim → progress → done / failed / heartbeat timeout.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { and, eq } from 'drizzle-orm';
import { jobs, ledger, pods, studioSettings, takes } from '../src/db/schema.js';
import { RunpodApi } from '../src/gpu/runpodApi.js';
import { makeApp, people, sienna, type Client } from './helpers.js';

type Fake = { balance: number; deployed: { id: string; gpuTypeId: string; token: string; podId: string }[]; terminated: string[]; unavailable: Set<string> };
function fakeRunpod(state: Fake) {
  let n = 0;
  const f = (async (_url: string, init: any) => {
    const { query, variables } = JSON.parse(init.body);
    if (init.headers.authorization !== 'Bearer rp_test_key') return new Response('{}', { status: 401 });
    if (query.includes('myself')) return Response.json({ data: { myself: { clientBalance: state.balance, currentSpendPerHr: 0 } } });
    if (query.includes('podFindAndDeployOnDemand')) {
      const input = variables.input;
      if (state.unavailable.has(input.gpuTypeId)) return Response.json({ errors: [{ message: 'There are no longer any instances available with the requested specifications.' }] });
      const env = Object.fromEntries(input.env.map((e: any) => [e.key, e.value]));
      const id = `rp${++n}`;
      state.deployed.push({ id, gpuTypeId: input.gpuTypeId, token: env.WORKER_TOKEN, podId: env.MUSE_POD_ID });
      expect(input.networkVolumeId).toBe('vol_123');
      return Response.json({ data: { podFindAndDeployOnDemand: { id, desiredStatus: 'RUNNING', costPerHr: 3.6 } } });
    }
    if (query.includes('podTerminate')) { state.terminated.push(variables.input.podId); return Response.json({ data: { podTerminate: null } }); }
    return Response.json({ errors: [{ message: 'not faked' }] });
  }) as typeof fetch;
  return new RunpodApi('rp_test_key', 'http://runpod.fake/graphql', f);
}

async function uploadClip(a: Awaited<ReturnType<typeof makeApp>>, c: Client) {
  const b = '----musetest';
  const meta = JSON.stringify({ name: 'dance', durationSec: 5.2, width: 1080, height: 1920, fps: 30 });
  const body = Buffer.concat([
    Buffer.from(`--${b}\r\nContent-Disposition: form-data; name="meta"\r\n\r\n${meta}\r\n`),
    Buffer.from(`--${b}\r\nContent-Disposition: form-data; name="file"; filename="dance.mp4"\r\nContent-Type: video/mp4\r\n\r\n`),
    Buffer.from('fake mp4 bytes'), Buffer.from(`\r\n--${b}--\r\n`),
  ]);
  const r = await a.app.inject({ method: 'POST', url: '/v1/uploads/clips', headers: { authorization: `Bearer ${c.token}`, 'content-type': `multipart/form-data; boundary=${b}` }, payload: body });
  expect(r.statusCode).toBe(200);
  return JSON.parse(r.body).id as string;
}

describe('runpod controller: one pod per user', () => {
  let a: Awaited<ReturnType<typeof makeApp>>;
  let owner: Client, u1: Client, u2: Client, u3: Client;
  const rp: Fake = { balance: 100, deployed: [], terminated: [], unavailable: new Set() };
  let model1: string, model2: string, model3: string, clip1: string, clip2: string, clip3: string;
  const worker = (token: string) => async (url: string, body: unknown = {}) => {
    const r = await a.app.inject({ method: 'POST', url, headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, payload: JSON.stringify(body) });
    return { status: r.statusCode, body: r.body ? JSON.parse(r.body) : null };
  };
  const tick = (dt = 0) => a.ctx.jobs.tick(Date.now() + dt);
  const podRows = () => a.ctx.db.select().from(pods);

  beforeAll(async () => {
    a = await makeApp({ GPU_MODE: 'runpod', BALANCE_MODE: 'runpod', RUNPOD_NETWORK_VOLUME_ID: 'vol_123', MAX_GPUS: '2', RUNPOD_MIN_BALANCE_USD: '2',
      PUBLIC_URL: 'http://api.test' }, { runpod: fakeRunpod(rp), startLoops: false });
    const p = await people(a, 3);
    owner = p.owner; [u1, u2, u3] = p.members as [Client, Client, Client];
    for (const u of [u1, u2, u3]) await owner.req('POST', '/v1/wallets/transfer', { toUserId: u.id, tokens: 500 });
    model1 = (await sienna(u1)).id; model2 = model1; model3 = model1;
    clip1 = await uploadClip(a, u1); clip2 = await uploadClip(a, u2); clip3 = await uploadClip(a, u3);
  });
  afterAll(async () => { await a.close(); });

  it('engine → GPU type; Fast · beta and LoRA training are refused before any GPU starts (not enabled on the pod image)', async () => {
    const r = await u1.req('POST', '/v1/jobs', { title: 'v', modelId: model1, clipId: clip1, engine: 'viggle', steps: 4 });
    expect(r.status).toBe(400); expect(r.body.code).toBe('engine_unavailable');
    expect((await u1.req('POST', '/v1/jobs', { title: 'n', modelId: model1, steps: 10 })).body.error).toMatch(/clip file/);
    expect(rp.deployed.length).toBe(0);
  });

  it('two users at once get two pods (H100 for Standard)', async () => {
    const j1 = (await u1.req('POST', '/v1/jobs', { title: 'A', modelId: model1, clipId: clip1, steps: 10 })).body;
    const j2 = (await u2.req('POST', '/v1/jobs', { title: 'B', modelId: model2, clipId: clip2, steps: 10 })).body;
    expect([j1.state, j2.state]).toEqual(['running', 'running']);
    await tick();
    expect(rp.deployed.map(d => d.gpuTypeId)).toEqual(['NVIDIA H100 80GB HBM3', 'NVIDIA H100 80GB HBM3']);
    const rows = await podRows();
    expect(new Set(rows.map(p => p.assignedUserId))).toEqual(new Set([u1.id, u2.id]));
    expect(rows.every(p => p.state === 'starting')).toBe(true);
  });

  it('over MAX_GPUS the job waits with its queue position and ETA', async () => {
    const j3 = (await u3.req('POST', '/v1/jobs', { title: 'C', modelId: model3, clipId: clip3, steps: 10 })).body;
    await tick();
    expect(rp.deployed.length).toBe(2);
    const j = (await u3.req('GET', '/v1/jobs')).body.find((x: any) => x.id === j3.id);
    expect(j.queuePosition).toBe(1);
    expect(j.etaSeconds).toBeGreaterThan(j.totalSeconds - 1);
    expect(j.phase).toMatch(/Waiting for a GPU/);
  });

  it('worker protocol: claim gives the pod user\'s job with presigned inputs (bytes + sha256) and outputs', async () => {
    const d1 = rp.deployed[0]!;
    const pod1 = (await podRows()).find(p => p.id === d1.podId)!;
    // Pretend the pod took 2 minutes to boot.
    await a.ctx.db.update(pods).set({ startedAt: Date.now() - 120_000 }).where(eq(pods.id, pod1.id));
    const w = worker(d1.token);
    expect((await worker('wrong')('/worker/v1/claim', {})).status).toBe(401);
    const c = await w('/worker/v1/claim', { podId: d1.id, gpu: 'NVIDIA H100 80GB HBM3', capabilities: ['h3', 'latentsync'] });
    expect(c.status).toBe(200);
    const job = c.body.job;
    expect(job.kind).toBe('h3');
    expect((await a.ctx.db.select().from(jobs).where(eq(jobs.id, job.id)))[0]!.userId).toBe(pod1.assignedUserId);
    expect(job.steps).toBe(10);
    expect(job.prompt).toContain('subject_definitions:');
    expect(job.prompt).toContain('<Image 5> (body, back)');
    expect(job.inputs.map((i: any) => i.name)).toEqual(['source.mp4', 'image_1.jpg', 'image_2.jpg', 'image_3.jpg', 'image_4.jpg', 'image_5.jpg']);
    for (const i of job.inputs) { expect(i.sha256).toMatch(/^[0-9a-f]{64}$/); expect(i.bytes).toBeGreaterThan(0); expect(i.url).toMatch(/^http:\/\/api\.test\/storage\/local\//); }
    expect(job.params).toMatchObject({ takes: 1, use: 'first', keepAudio: true, lipSync: false, audioMode: 'fully_copy', source: 'source.mp4',
      references: ['image_1.jpg', 'image_2.jpg', 'image_3.jpg', 'image_4.jpg', 'image_5.jpg'] });
    expect(job.outputs).toEqual([{ name: 'take_1.mp4', uploadUrl: expect.stringMatching(/\/storage\/local\/r\//), contentType: 'video/mp4' }]);
    // Download an input through its presigned URL and check the hash.
    const src = job.inputs[0];
    const got = await a.app.inject({ method: 'GET', url: src.url.replace('http://api.test', '') });
    expect(got.statusCode).toBe(200);
    expect(require('node:crypto').createHash('sha256').update(got.rawPayload).digest('hex')).toBe(src.sha256);
    // The same worker asking again (restart) gets the same job.
    expect((await w('/worker/v1/claim', { podId: d1.id, capabilities: ['h3'] })).body.job.id).toBe(job.id);

    // progress (with take/takes, no etaSeconds) → app-facing job fields
    expect((await w(`/worker/v1/jobs/${job.id}/progress`, { step: 4, totalSteps: 10, phase: 'denoise', take: 1, takes: 1 })).status).toBe(204);
    const pj = (await u1.req('GET', '/v1/jobs')).body.find((x: any) => x.id === job.id) ?? (await u2.req('GET', '/v1/jobs')).body.find((x: any) => x.id === job.id);
    expect(pj.step).toBe(4); expect(pj.phase).toMatch(/^step 4\/10 · ~\d+ min left$/); expect(pj.progress).toBeCloseTo(40, 5);

    // done before the upload arrived → refused; then upload to the presigned PUT and finish.
    expect((await w(`/worker/v1/jobs/${job.id}/done`, { outputs: [{ name: 'take_1.mp4' }], gpuSeconds: 200 })).body.code).toBe('output_missing');
    const put = await a.app.inject({ method: 'PUT', url: job.outputs[0].uploadUrl.replace('http://api.test', ''), headers: { 'content-type': 'video/mp4' }, payload: Buffer.from('rendered video') });
    expect(put.statusCode).toBe(200);
    const owner1 = pod1.assignedUserId === u1.id ? u1 : u2;
    const before = (await owner1.req('GET', '/v1/wallet')).body;
    const done = await w(`/worker/v1/jobs/${job.id}/done`, { outputs: [{ name: 'take_1.mp4', bytes: 14, width: 768, height: 1344, fps: 24, durationSec: 5.04 }], gpuSeconds: 200,
      stats: { load_s: 30, gen_s: 165, step_times_s: [16.5], peak_vram_gb: 71.2, attention: 'fa3' } });
    expect(done.status).toBe(204);
    const [row] = await a.ctx.db.select().from(jobs).where(eq(jobs.id, job.id));
    expect(row!.state).toBe('done');
    expect(row!.stats).toMatchObject({ load_s: 30, attention: 'fa3' });
    expect(row!.actualCost).toBeCloseTo(170 / 3600 * 3.6, 9); // gpuSeconds − load_s, at the pod's rate
    const [take] = await a.ctx.db.select().from(takes).where(eq(takes.jobId, job.id));
    expect(take!.media).toMatchObject({ width: 768, height: 1344, durationSec: 5.04 });
    const tv = (await owner1.req('GET', '/v1/takes')).body.find((t: any) => t.id === take!.id);
    expect(tv.durationSec).toBe(5.04); expect(tv.videoUrl).toBe(`http://api.test/uploads/r/${job.id}/take_1.mp4`);
    // Warm-up (2 min boot + 30 s model load at $3.60/h) is the user's own line; the render settles to the actual cost.
    const lines = await a.ctx.db.select().from(ledger).where(and(eq(ledger.jobId, job.id), eq(ledger.userId, owner1.id)));
    const warm = lines.filter(l => l.kind === 'warmup');
    expect(warm.length).toBe(2);
    expect(warm.reduce((s, l) => s + l.amountUsd, 0)).toBeCloseTo((120 + 30) / 3600 * 3.6, 2);
    const after = (await owner1.req('GET', '/v1/wallet')).body;
    expect(after.heldTokens).toBe(0);
    // `before` was read after the claim (boot warm-up of 12 tokens already paid): the 68-token hold comes back, 17 actual + 3 load are spent.
    expect(after.tokens - before.tokens).toBe(68 - 17 - 3);
    expect(row!.warmupCost).toBeGreaterThan(0.14);
  });

  it('a warm idle pod is handed to the waiting user instead of starting a cold one', async () => {
    const d1 = rp.deployed[0]!;
    await tick();
    expect(rp.deployed.length).toBe(2); // no third pod
    const pod1 = (await podRows()).find(p => p.id === d1.podId)!;
    expect(pod1.assignedUserId).toBe(u3.id);
    const c = await worker(d1.token)('/worker/v1/claim', { podId: d1.id, capabilities: ['h3', 'latentsync'] });
    expect((await a.ctx.db.select().from(jobs).where(eq(jobs.id, c.body.job.id)))[0]!.userId).toBe(u3.id);
    // failed → refunded in full, pod freed
    const before = (await u3.req('GET', '/v1/wallet')).body;
    expect((await worker(d1.token)(`/worker/v1/jobs/${c.body.job.id}/failed`, { error: 'CUDA out of memory', retryable: true })).status).toBe(204);
    const j = (await u3.req('GET', '/v1/jobs')).body.find((x: any) => x.id === c.body.job.id);
    expect(j.state).toBe('failed'); expect(j.refunded).toBe(j.cost); expect(j.error).toBe('CUDA out of memory');
    const after = (await u3.req('GET', '/v1/wallet')).body;
    expect(after.heldTokens).toBe(0); expect(after.tokens).toBe(before.tokens + before.heldTokens);
  });

  it('heartbeats stop for 60 s → the job fails (retryable), is refunded and the pod is terminated', async () => {
    const d2 = rp.deployed[1]!;
    const w = worker(d2.token);
    expect((await w('/worker/v1/heartbeat', { podId: d2.id, busy: false, state: 'idle' })).status).toBe(204);
    const c = await w('/worker/v1/claim', { podId: d2.id, capabilities: ['h3'] });
    expect(c.status).toBe(200);
    const d1 = rp.deployed[0]!; // pod 1 keeps sending heartbeats
    await a.ctx.db.update(pods).set({ lastHeartbeatAt: Date.now() + 3_600_000 }).where(eq(pods.id, d1.podId));
    await tick(61_000);
    const [row] = await a.ctx.db.select().from(jobs).where(eq(jobs.id, c.body.job.id));
    expect(row!.state).toBe('failed'); expect(row!.retryable).toBe(true); expect(row!.refunded).toBe(row!.cost);
    expect(rp.terminated).toContain(d2.id);
    expect((await w(`/worker/v1/jobs/${c.body.job.id}/progress`, { step: 5, totalSteps: 10 })).status).toBe(401); // its token died with the pod
  });

  it('idle shutdown after IDLE_SHUTDOWN_SECONDS, idle time charged to the pod user', async () => {
    const d1 = rp.deployed[0]!;
    await tick(60_000);
    expect(rp.terminated).not.toContain(d1.id);
    await tick(181_000);
    expect(rp.terminated).toContain(d1.id);
    const idle = await a.ctx.db.select().from(ledger).where(and(eq(ledger.kind, 'warmup'), eq(ledger.userId, u3.id)));
    expect(idle.some(l => /GPU idle/.test(l.note ?? ''))).toBe(true);
  });

  it('cancelled job: progress answers 409 job_cancelled', async () => {
    const j = (await u1.req('POST', '/v1/jobs', { title: 'Cancel me', modelId: model1, clipId: clip1, steps: 10 })).body;
    await tick();
    const d = rp.deployed[rp.deployed.length - 1]!;
    const c = await worker(d.token)('/worker/v1/claim', { podId: d.id, capabilities: ['h3'] });
    expect(c.body.job.id).toBe(j.id);
    expect((await u1.req('DELETE', `/v1/jobs/${j.id}`)).status).toBe(204);
    const r = await worker(d.token)(`/worker/v1/jobs/${j.id}/progress`, { step: 1, totalSteps: 10 });
    expect(r.status).toBe(409); expect(r.body.code).toBe('job_cancelled');
    expect((await u1.req('GET', '/v1/wallet')).body.heldTokens).toBe(0);
  });

  it('lip sync jobs only go to pods that advertise latentsync', async () => {
    const j = (await u1.req('POST', '/v1/jobs', { title: 'Talk', modelId: model1, clipId: clip1, steps: 10, lipSync: true })).body;
    await tick();
    const d = rp.deployed[rp.deployed.length - 1]!;
    await worker(d.token)(`/worker/v1/jobs/x/failed`, {}).catch(() => {});
    expect((await worker(d.token)('/worker/v1/claim', { podId: d.id, capabilities: ['h3'] })).status).toBe(204);
    expect((await worker(d.token)('/worker/v1/claim', { podId: d.id, capabilities: ['h3', 'latentsync'] })).body.job.id).toBe(j.id);
  });

  it('low RunPod balance pauses new jobs for everyone, and they resume when it recovers', async () => {
    rp.balance = 2.5; // < in-flight work + $2 margin
    const j = (await u2.req('POST', '/v1/jobs', { title: 'Paused', modelId: model2, clipId: clip2, steps: 10 })).body;
    await tick();
    let row = (await u2.req('GET', '/v1/jobs')).body.find((x: any) => x.id === j.id);
    expect(row.blocked).toBe('owner_balance_low');
    expect(row.phase).toBe("Paused: the studio's GPU credit is low");
    const [s] = await a.ctx.db.select().from(studioSettings);
    expect(s!.lowBalanceSince).toBeGreaterThan(0);
    expect((await owner.req('GET', '/v1/settings/studio')).body.lowBalance).toBe(true);
    rp.balance = 100;
    await tick();
    row = (await u2.req('GET', '/v1/jobs')).body.find((x: any) => x.id === j.id);
    expect(row.blocked).toBeUndefined();
    expect((await owner.req('GET', '/v1/settings/studio')).body.lowBalance).toBe(false);
  });
});

describe('GPU type fallback and Viggle on H200', () => {
  it('uses the next GPU type in the table when the first is sold out, and H200 for Fast · beta', async () => {
    const rp: Fake = { balance: 100, deployed: [], terminated: [], unavailable: new Set(['NVIDIA H200 NVL']) };
    const a = await makeApp({ GPU_MODE: 'runpod', BALANCE_MODE: 'runpod', RUNPOD_NETWORK_VOLUME_ID: 'vol_123', RUNPOD_WORKER_CAPABILITIES: 'h3,viggle,latentsync' }, { runpod: fakeRunpod(rp), startLoops: false });
    const p = await people(a, 0);
    const m = await sienna(p.owner);
    const clip = await uploadClip(a, p.owner);
    expect((await p.owner.req('POST', '/v1/jobs', { title: 'v', modelId: m.id, clipId: clip, engine: 'viggle', steps: 4 })).status).toBe(200);
    await a.ctx.jobs.tick();
    expect(rp.deployed.map(d => d.gpuTypeId)).toEqual(['NVIDIA H200']);
    // Nothing available at all: the job stays queued, the controller reports it and retries later.
    rp.unavailable.add('NVIDIA H200');
    await p.owner.req('POST', '/v1/settings/studio', {});
    const status = (await p.owner.req('GET', '/v1/settings/studio')).body;
    expect(status.features).toMatchObject({ fastBeta: true, replaceAudio: false, outputSize: { width: 768, height: 1344 } });
    await a.close();
  });
});
