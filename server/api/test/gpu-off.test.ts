// MUSE's own GPU switched off (GPU_MODE=off, or GPU_MODE=runpod without a RunPod key; plans/gpu-off.md): no pod and no
// RunPod call ever; every GPU feature is refused up front with one plain message; GPU models leave the pickers and Auto;
// hosted models keep working; GPU jobs left from before are failed and refunded at boot.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq, sql } from 'drizzle-orm';
import { clips, jobs, ledger, pods } from '../src/db/schema.js';
import { openDb } from '../src/db/client.js';
import { RunpodApi } from '../src/gpu/runpodApi.js';
import { GPU_OFF_MESSAGE } from '../src/gpu/controller.js';
import { registryByName } from '../src/claude/registry.js';
import { client, demoModel, makeApp, people, type Client } from './helpers.js';
import { fakeReplicate, TOKEN } from './fakeReplicate.js';

const UPSCALE = JSON.stringify({ '1080p': { usdPerSec: 0.02, gpuSecPerSec: 8 } });

/** A RunPod client whose every call fails the test: off mode must never reach RunPod. */
function throwingRunpod(key: string | undefined) {
  const calls: string[] = [];
  const f = (async (_url: string, init: any) => {
    calls.push(String(init?.body ?? ''));
    throw new Error('RunPod must not be called while the GPU is off');
  }) as typeof fetch;
  return { api: new RunpodApi(key, 'http://runpod.fake/graphql', f), calls };
}

async function studioOf(a: Awaited<ReturnType<typeof makeApp>>, userId: string) {
  const [o] = await a.ctx.db.execute(sql`select studio_id from users where id = ${userId}`).then((r: any) => r.rows ?? r);
  return o.studio_id as string;
}

for (const variant of [
  { name: 'GPU_MODE=off (key still set)', env: { GPU_MODE: 'off' } as Record<string, string>, key: 'rp_test_key' as string | undefined },
  { name: 'GPU_MODE=runpod with no RUNPOD_API_KEY', env: { GPU_MODE: 'runpod', BALANCE_MODE: 'runpod' }, key: undefined },
]) {
  describe(`GPU off · ${variant.name}`, () => {
    let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, member: Client, fake: Awaited<ReturnType<typeof fakeReplicate>>;
    let model: string, rp: ReturnType<typeof throwingRunpod>;
    const ownerUser = async () => ({ id: owner.id, studioId: await studioOf(a, owner.id), email: 'owner@test.dev', role: 'owner' as const, studioName: 'Test Studio', sessionId: null });

    beforeAll(async () => {
      fake = await fakeReplicate();
      rp = throwingRunpod(variant.key);
      a = await makeApp({ ...variant.env, SUITE_MODE: 'mock', SUITE_POLL_MS: '10', REPLICATE_API_TOKEN: TOKEN, REPLICATE_API_URL: fake.base,
        REPLICATE_WEB_URL: fake.web, UPSCALE_PRICES: UPSCALE, RUNPOD_NETWORK_VOLUME_ID: 'vol_123', RUNPOD_WORKER_CAPABILITIES: 'h3,viggle,latentsync,lora-train,upscale' },
      { runpod: rp.api, startLoops: false });
      ({ owner, members: [member] } = await people(a, 1) as any);
      await owner.req('POST', '/v1/wallets/transfer', { toUserId: member.id, tokens: 500 });
      model = (await demoModel(owner)).id;
      await a.ctx.db.insert(clips).values({ id: 'c_off', studioId: await studioOf(a, owner.id), name: 'dance', durationSec: 6, width: 720, height: 1280, fps: 30,
        meta: {}, checks: [], storageKey: 'clips/dance.mp4', createdAt: Date.now() });
    });
    afterAll(async () => { await a?.close(); await fake?.close(); });

    it('the controller is off and makes no RunPod call, even on dispatcher passes', async () => {
      expect(a.ctx.gpu.mode).toBe('off');
      await a.ctx.jobs.tick(); await a.ctx.jobs.tick(Date.now() + 3_600_000);
      expect(await a.ctx.db.select().from(pods)).toEqual([]);
      expect(rp.calls).toEqual([]);
    });

    it('Edit / Fast / lip sync jobs are refused with the plain message before any hold', async () => {
      const before = (await member.req('GET', '/v1/wallet')).body;
      for (const body of [
        { title: 'e', modelId: model, clipId: 'c_off', engine: 'h3', steps: 10 },
        { title: 'f', modelId: model, clipId: 'c_off', engine: 'viggle', steps: 4 },
        { title: 'l', modelId: model, clipId: 'c_off', engine: 'h3', steps: 10, lipSync: true },
      ]) {
        const r = await member.req('POST', '/v1/jobs', body);
        expect(r.status, JSON.stringify(r.body)).toBe(400);
        expect(r.body).toMatchObject({ code: 'engine_unavailable', error: GPU_OFF_MESSAGE });
      }
      // The swap engines on our GPU, picked by name (owner): the same message, not "can't be used".
      for (const engineModel of ['h3-open', 'viggle']) {
        const r = await owner.req('POST', '/v1/jobs', { title: 'p', modelId: model, clipId: 'c_off', engineModel });
        expect(r.body).toMatchObject({ code: 'engine_unavailable', error: GPU_OFF_MESSAGE });
      }
      expect((await member.req('GET', '/v1/wallet')).body).toEqual(before);
      expect(await a.ctx.db.select().from(jobs)).toEqual([]);
      expect(rp.calls).toEqual([]);
    });

    it('LoRA training, Upscale and the warm GPU are refused; the Claude tool refuses before an Approve card', async () => {
      for (const url of [`/v1/models/${model}/lora/train`, `/v1/models/${model}/lora/candidates`]) {
        const r = await owner.req('POST', url, {});
        expect(r.body).toMatchObject({ code: 'engine_unavailable', error: GPU_OFF_MESSAGE });
      }
      expect((await owner.req('POST', '/v1/takes/t_none/upscale', { size: '1080p' })).body.error).toBe(GPU_OFF_MESSAGE);
      expect((await owner.req('POST', '/v1/gpu/warm', { on: true })).body.error).toBe(GPU_OFF_MESSAGE);
      expect((await owner.req('POST', '/v1/gpu/warm', { extend: true })).body.error).toBe(GPU_OFF_MESSAGE);
      const w = (await owner.req('GET', '/v1/gpu/warm')).body;
      expect(w).toMatchObject({ state: 'off', unavailable: 'RunPod is switched off' });
      const u = await ownerUser();
      await expect(registryByName.get('warm_gpu_on')!.run({ ctx: a.ctx, user: u, source: 'chat' } as any, {})).rejects.toMatchObject({ message: GPU_OFF_MESSAGE });
      expect((await registryByName.get('warm_gpu')!.run({ ctx: a.ctx, user: u, source: 'chat' } as any, { action: 'status' }) as any).state).toBe('off');
      expect(await a.ctx.db.select().from(pods)).toEqual([]);
      expect(rp.calls).toEqual([]);
    });

    it('pickers and Auto: no GPU model anywhere; features say Edit, Fast, lip sync, LoRA and Upscale are off', async () => {
      const all = (await owner.req('GET', '/v1/engines')).body;
      const ids = all.engines.map((e: any) => e.model);
      for (const gpu of ['h3-open', 'viggle', 'seedvr2']) expect(ids).not.toContain(gpu);
      expect(all.engines.some((e: any) => e.provider === 'runpod')).toBe(false);
      const swap = (await owner.req('GET', '/v1/engines?purpose=swap')).body;
      expect(swap.models.map((e: any) => e.model)).not.toContain('h3-open');
      expect(swap.default).toBe('h3'); // Auto: the hosted H3
      expect((await owner.req('GET', '/v1/engines?purpose=upscale')).body.models).toEqual([]);
      const f = (await member.req('GET', '/v1/settings/studio')).body.features;
      expect(f).toMatchObject({ standard: false, fastBeta: false, lipSync: false, loraTraining: false, replicate: true });
      const addons = Object.fromEntries(f.video.addons.map((x: any) => [x.id, x.available]));
      expect(addons).toEqual({ edit: false, fast: false, upscale: false });
      expect(f.video.options.every((o: any) => o.available)).toBe(true); // Draft / Standard / HD (hosted) unchanged
      expect(rp.calls).toEqual([]);
    });

    it('Settings → Engines shows RunPod as off with no call made', async () => {
      const s = (await owner.req('GET', '/v1/settings/studio')).body;
      const runpod = s.engines.list.find((e: any) => e.id === 'runpod');
      expect(runpod).toMatchObject({ status: 'off', message: 'RunPod is switched off', balance: { source: 'unavailable', balance: null, reason: 'RunPod is switched off' } });
      expect(runpod.balanceUsd).toBeUndefined();
      expect(s.engines.list.find((e: any) => e.id === 'replicate').status).toBe('ready');
      expect(await a.ctx.money.runpodBalance(await studioOf(a, owner.id))).toEqual({ source: 'unavailable', balance: null, reason: 'RunPod is switched off' });
      expect(s.gpu).toMatchObject({ mode: 'off', pods: [] });
      expect((await a.app.inject({ method: 'GET', url: '/health' })).statusCode).toBeLessThan(500);
      expect(rp.calls).toEqual([]);
    });

    it('hosted swaps still run (Replicate)', async () => {
      const r = await member.req('POST', '/v1/jobs', { title: 'hosted', modelId: model, clipId: 'c_off', engine: 'replicate', quality: 'draft' });
      expect(r.status, JSON.stringify(r.body)).toBe(200);
      expect(r.body.state).toBe('running');
      expect(rp.calls).toEqual([]);
    });
  });
}

describe('GPU off · boot', () => {
  it('GPU jobs queued or running from before are failed with a refund and the plain message; old pods are marked stopped; no RunPod call', async () => {
    const dbh = await openDb('pglite://memory');
    try {
      // Before: the simulated GPU (standing in for RunPod), renders paused (SPEED 0) so the jobs stay in the line.
      const a = await makeApp({ GPU_MODE: 'simulated', BALANCE_MODE: 'simulated', SPEED: '0' }, { db: dbh, startLoops: false });
      const { owner, members: [member] } = await people(a, 1) as { owner: Client; members: Client[] };
      await owner.req('POST', '/v1/wallets/transfer', { toUserId: member!.id, tokens: 500 });
      const model = (await demoModel(owner)).id;
      await a.ctx.db.insert(clips).values({ id: 'c_boot', studioId: await studioOf(a, owner.id), name: 'dance', durationSec: 6, width: 720, height: 1280, fps: 30,
        meta: {}, checks: [], storageKey: 'clips/dance.mp4', createdAt: Date.now() });
      const start = (await member!.req('GET', '/v1/wallet')).body;
      const j1 = (await member!.req('POST', '/v1/jobs', { title: 'Edit 1', modelId: model, clipId: 'c_boot', engine: 'h3', steps: 10 })).body;
      const j2 = (await member!.req('POST', '/v1/jobs', { title: 'Edit 2', modelId: model, clipId: 'c_boot', engine: 'h3', steps: 10 })).body;
      expect([j1.state, j2.state]).toEqual(['running', 'running']);
      await a.ctx.jobs.tick(); // a pod starts for the member (simulated)
      expect((await a.ctx.db.select().from(pods)).some(p => p.state === 'running')).toBe(true);
      const held = (await member!.req('GET', '/v1/wallet')).body;
      expect(held).not.toEqual(start);
      await a.close(); // the db stays open (it was passed in)

      // After: GPU_MODE=runpod, the key removed. A RunPod client that throws if touched.
      const rp = throwingRunpod(undefined);
      const b = await makeApp({ GPU_MODE: 'runpod', BALANCE_MODE: 'simulated' }, { db: dbh, runpod: rp.api, startLoops: false });
      try {
        expect(b.ctx.gpu.mode).toBe('off');
        expect(b.ctx.boot.gpuOff).toEqual({ pods: 1, jobs: 2 });
        for (const id of [j1.id, j2.id]) {
          const j = (await b.ctx.db.select().from(jobs).where(eq(jobs.id, id)))[0]!;
          expect(j).toMatchObject({ state: 'failed', error: GPU_OFF_MESSAGE, refunded: j.cost, retryable: false });
          expect((j.stats as any).errorCode).toBe('gpu_off');
          expect((await b.ctx.db.select().from(ledger).where(eq(ledger.jobId, id))).some(l => l.kind === 'release')).toBe(true);
        }
        expect((await b.ctx.db.select().from(pods)).every(p => p.state === 'stopped')).toBe(true);
        expect((await client(b, member!.token)('GET', '/v1/wallet')).body).toEqual(start);
        expect(rp.calls).toEqual([]);
      } finally { await b.close(); }
    } finally { await dbh.close(); }
  });
});
