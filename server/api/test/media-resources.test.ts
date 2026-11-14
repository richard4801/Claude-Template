// The media profile (lib/resources.ts) and the media lane's size (lib/mediaLane.ts), 2026-11-14 Trial → Hobby.
import { afterEach, describe, expect, it } from 'vitest';
import { cgroupCpus, cgroupMemMB, decThreads, detectResources, encThreads, profileFor, setMediaResources, x264Lean } from '../src/lib/resources.js';
import { laneConcurrency, leanDecode, oneAtATime, resetLane } from '../src/lib/mediaLane.js';

const files = (m: Record<string, string>) => (f: string) => { if (f in m) return m[f]!; throw new Error('ENOENT'); };

describe('resources', () => {
  it('reads cgroup v2 limits, falls back to the host, and env wins', () => {
    const r = files({ '/sys/fs/cgroup/cpu.max': '200000 100000\n', '/sys/fs/cgroup/memory.max': String(8 * 1024 ** 3) });
    expect(cgroupCpus(r)).toBe(2);
    expect(cgroupMemMB(r)).toBe(8192);
    expect(cgroupCpus(files({ '/sys/fs/cgroup/cpu.max': 'max 100000' }))).toBeNull();
    expect(cgroupMemMB(files({ '/sys/fs/cgroup/memory.max': 'max' }))).toBeNull();
    expect(cgroupMemMB(files({}))).toBeNull();
    const d = detectResources({}, r);
    expect(d.cpus).toBeLessThanOrEqual(2);
    expect(d.memMB).toBeLessThanOrEqual(8192);
    expect(detectResources({ MEDIA_CPUS: '8', MEDIA_MEM_MB: '512' }, r)).toEqual({ cpus: 8, memMB: 512 });
    expect(detectResources({ MEDIA_CPUS: 'x' }, files({})).cpus).toBeGreaterThan(0);
  });

  it('small keeps the Trial behaviour exactly', () => {
    const p = profileFor({ cpus: 2, memMB: 1024 });
    expect(p).toMatchObject({ name: 'small', x264Sliced: true, laneConcurrency: 1, renderConcurrency: 1 });
    setMediaResources({ cpus: 8, memMB: 1024 });
    expect([encThreads(2), encThreads(1), decThreads(1), decThreads(2)]).toEqual(['2', '1', '1', '2']);
    expect(x264Lean()).toEqual(['-x264-params', 'sliced-threads=1:rc-lookahead=5:sync-lookahead=0']);
    expect(leanDecode()).toEqual(['-threads', '1', '-filter_threads', '1']);
  });

  it('large scales threads, x264 frame threads and concurrency with memory', () => {
    expect(profileFor({ cpus: 8, memMB: 2048 })).toMatchObject({ name: 'large', encodeThreads: 6, decodeThreads: 4, x264Sliced: true, laneConcurrency: 1, renderConcurrency: 1 });
    expect(profileFor({ cpus: 8, memMB: 3072 })).toMatchObject({ x264Sliced: false, laneConcurrency: 2, renderConcurrency: 1 });
    expect(profileFor({ cpus: 8, memMB: 4096 })).toMatchObject({ laneConcurrency: 2, renderConcurrency: 2 });
    expect(profileFor({ cpus: 8, memMB: 8192 })).toMatchObject({ laneConcurrency: 3, renderConcurrency: 2 });
    expect(profileFor({ cpus: 2, memMB: 8192 })).toMatchObject({ encodeThreads: 2, decodeThreads: 2 });
    setMediaResources({ cpus: 8, memMB: 8192 });
    expect([encThreads(2), decThreads(1)]).toEqual(['6', '4']);
    expect(x264Lean()).toEqual([]);
  });
  afterEach(() => { setMediaResources(null); resetLane(); });
});

describe('media lane', () => {
  afterEach(() => { setMediaResources(null); resetLane(); });
  const work = (log: number[], ms = 30) => async () => { log.push(1); await new Promise(r => setTimeout(r, ms)); return 1; };

  it('runs at most N at once (the profile\'s size)', async () => {
    for (const [mem, n] of [[1024, 1], [3072, 2], [8192, 3]] as const) {
      setMediaResources({ cpus: 8, memMB: mem }); resetLane();
      const log: number[] = [];
      await Promise.all(Array.from({ length: 6 }, () => oneAtATime(work(log))));
      expect(log.length).toBe(6);
      expect(laneConcurrency()).toBe(n);
    }
  });

  it('stays re-entrant at any size: nested calls never wait for their own place', async () => {
    for (const n of [1, 2]) {
      resetLane(n);
      // Fill every place with work that asks for the lane again (twice, in parallel).
      const nested = () => oneAtATime(async () => (await Promise.all([oneAtATime(async () => 1), oneAtATime(() => oneAtATime(async () => 2))])).reduce((a, b) => a + b));
      const all = Promise.all(Array.from({ length: n + 2 }, nested));
      const v = await Promise.race([all, new Promise(res => setTimeout(() => res('deadlock'), 2000))]);
      expect(v).toEqual(Array(n + 2).fill(3));
    }
  });

  it('a failure frees its place', async () => {
    resetLane(1);
    await expect(oneAtATime(async () => { throw new Error('boom'); })).rejects.toThrow('boom');
    await expect(oneAtATime(async () => 5)).resolves.toBe(5);
  });
});

describe('edit renders have their own budget', () => {
  afterEach(() => { setMediaResources(null); resetLane(); });
  it('a render never waits behind a busy media lane, and its state carries renderMs and the profile', async () => {
    const { EditRenders } = await import('../src/editor/renders.js');
    const stored = new Map<string, Buffer>();
    const ctx = {
      config: { FFMPEG_PATH: 'ffmpeg', FFPROBE_PATH: 'ffprobe' },
      storage: { kind: 'local', put: async (k: string, b: Buffer) => { stored.set(k, b); }, putStream: async (k: string) => { stored.set(k, Buffer.alloc(0)); }, get: async () => null, delete: async () => undefined },
      log: { info: () => {}, warn: () => {} },
    } as never;
    const r = new EditRenders(ctx);
    resetLane(1);
    let free!: () => void;
    const held = oneAtATime(() => new Promise<void>(res => { free = res; })); // a long Claude watch holds the only place
    const project = { version: 2, sourceTakeId: 't', canvas: { width: 180, height: 320, fps: 30, background: '#000000' }, assets: [],
      tracks: [{ id: 'main', kind: 'main', items: [] }, { id: 'text', kind: 'text', items: [{ id: 'x', startSec: 0, durationSec: 0.5, text: 'HI', style: { font: 'sans', weight: 700, sizePct: 0.1, color: '#FFFFFF', align: 'center' }, transform: { x: 0.5, y: 0.5 } }] }] } as never;
    const st = r.start('st', 'renders/k.mp4', 1, project, { maxSide: 320 });
    const done = await Promise.race([r.idle().then(() => 'done'), new Promise(res => setTimeout(() => res('waited behind the lane'), 20_000))]);
    expect(done).toBe('done');
    expect(st.state).not.toBe('rendering');
    expect(st.renderMs).toBeGreaterThanOrEqual(0);
    expect(st.profile).toBe('small');
    free(); await held;
  }, 30_000);
});
