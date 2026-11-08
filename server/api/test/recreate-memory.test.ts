// workstream 1 · the 512 MB box (prod's first real Recreate run was killed mid-analysis): the whole analysis of a
// large 1080×1920 30 fps clip stays under a memory budget with one decoder at a time; optional steps are skipped when
// memory is short or after a crash (lite); a reference a crash left "analyzing" resumes lite, then fails with Retry.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { eq } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { recreateReferences, users } from '../src/db/schema.js';
import { analyzeReference } from '../src/recreate/analyze.js';
import { treeRssMb } from '../src/recreate/pose.js';
import { recreateOf } from '../src/recreate/references.js';
import { putObject } from '../src/storage/objects.js';
import { makeApp, people, until, type Client } from './helpers.js';
import { FONT, ff, hasFfmpeg } from './recreate-fixture.js';

const hasProc = fs.existsSync('/proc/self/status');
/** The analysis of a ≤ 60 s reference (Node, ffmpeg, tesseract and the pose child together, measured in this harness's
 * tsx child) stays below this. Before the fix the same clip's text step alone ran ~13 full-size decoders at once (1.6 GB). */
const BUDGET_MB = 400;

let dir: string, clip: string;
beforeAll(() => {
  if (!hasFfmpeg) return;
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-rx-mem-'));
  clip = path.join(dir, 'big.mp4');
  const text = (t: string, y: number, from: number, to: number) => FONT ? `,drawtext=fontfile=${FONT}:text='${t}':fontsize=90:fontcolor=white:borderw=6:x=(w-tw)/2:y=${y}:enable='between(t,${from},${to})'` : '';
  // 1080×1920 at 30 fps, three shots (cuts at 5 s and 10 s), two captions, a beat.
  ff('-f', 'lavfi', '-i', 'testsrc2=s=1080x1920:r=30:d=5', '-f', 'lavfi', '-i', 'smptehdbars=s=1080x1920:r=30:d=5', '-f', 'lavfi', '-i', 'mandelbrot=s=1080x1920:r=30',
    '-f', 'lavfi', '-i', "aevalsrc='0.6*sin(2*PI*80*t)*exp(-20*mod(t,0.5))':s=44100:d=15",
    '-filter_complex', `[0]format=yuv420p[a];[1]format=yuv420p[b];[2]trim=0:5,setpts=PTS-STARTPTS,format=yuv420p[c];[a][b][c]concat=n=3:v=1:a=0${text('POV you finally did it', 300, 1, 6)}${text('part 2', 1500, 8, 13)}[v]`,
    '-map', '[v]', '-map', '3:a', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', clip);
}, 120_000);
afterAll(() => { if (dir) fs.rmSync(dir, { recursive: true, force: true }); });

/** Names of the live processes under `root` (Linux /proc). */
function treeNames(root: number): string[] {
  const kids = new Map<number, number[]>();
  for (const d of fs.readdirSync('/proc')) {
    if (!/^\d+$/.test(d)) continue;
    try { const st = fs.readFileSync(`/proc/${d}/stat`, 'utf8'); const pp = Number(st.slice(st.lastIndexOf(')') + 2).split(' ')[1]); (kids.get(pp) ?? kids.set(pp, []).get(pp)!).push(Number(d)); } catch { /* gone */ }
  }
  const out: string[] = [], stack = [...(kids.get(root) ?? [])];
  while (stack.length) { const p = stack.pop()!; try { out.push(fs.readFileSync(`/proc/${p}/comm`, 'utf8').trim()); } catch { /* gone */ } stack.push(...(kids.get(p) ?? [])); }
  return out;
}

describe.skipIf(!hasFfmpeg || !hasProc)('Recreate analysis memory (the 512 MB box)', () => {
  it(`a 1080×1920 30 fps clip: the whole process tree peaks under ${BUDGET_MB} MB, never more than one ffmpeg at a time`, async () => {
    const child = spawn(process.execPath, ['--import', 'tsx', path.resolve(__dirname, 'recreate-memory-child.ts'), clip], { cwd: path.resolve(__dirname, '..'), stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '', err = '', peak = 0, maxFfmpeg = 0;
    child.stdout.on('data', d => { out += String(d); });
    child.stderr.on('data', d => { err = (err + String(d)).slice(-4000); });
    const timer = setInterval(() => {
      peak = Math.max(peak, treeRssMb(child.pid!));
      maxFfmpeg = Math.max(maxFfmpeg, treeNames(child.pid!).filter(n => n === 'ffmpeg').length);
    }, 20);
    const code = await new Promise<number | null>(res => child.on('close', res));
    clearInterval(timer);
    expect(code, err).toBe(0);
    const r = JSON.parse(out) as { slots: number; text: number; analyzer: Record<string, unknown> };
    expect(r.slots).toBe(3);
    expect(r.analyzer.skipped).toBeUndefined(); // everything ran (no step was dropped to fit)
    console.info(`recreate analysis peak ${peak} MB (budget ${BUDGET_MB}), at most ${maxFfmpeg} ffmpeg at once`, JSON.stringify(r.analyzer));
    expect(peak).toBeGreaterThan(0);
    expect(peak).toBeLessThan(BUDGET_MB);
    expect(maxFfmpeg).toBeLessThanOrEqual(1);
  }, 300_000);

  it('short of memory: the optional steps are skipped and noted, the recipe is still made; lite skips them too', async () => {
    const cfg = { ffmpeg: 'ffmpeg', ffprobe: 'ffprobe', tesseract: 'tesseract', pose: true };
    const prev = process.env.MUSE_MEMORY_LIMIT_MB;
    process.env.MUSE_MEMORY_LIMIT_MB = '1'; // the guard sees no free memory at all
    try {
      const short = await analyzeReference(cfg, clip, { maxSec: 61 });
      expect(short.recipe.slots).toHaveLength(3);
      const steps = (short.recipe.analyzer.skipped ?? []).filter(s => s.why === 'memory').map(s => s.step);
      expect(steps).toEqual(expect.arrayContaining(['textMotion', 'pose']));
      expect(short.recipe.gaps.find(g => g.key === 'pose')?.note).toMatch(/short of memory/);
    } finally { if (prev === undefined) delete process.env.MUSE_MEMORY_LIMIT_MB; else process.env.MUSE_MEMORY_LIMIT_MB = prev; }
    const lite = await analyzeReference(cfg, clip, { maxSec: 61, lite: true });
    expect(lite.recipe.analyzer.lite).toBe(true);
    expect(lite.recipe.analyzer.skipped!.map(s => s.step)).toEqual(expect.arrayContaining(['textMotion', 'pose']));
    expect(lite.recipe.analyzer.skipped!.every(s => s.why === 'lite')).toBe(true);
    expect(lite.recipe.slots).toHaveLength(3);
    expect(lite.recipe.text.length).toBeGreaterThan(0); // the text boxes are a required step
    expect(lite.contactSheetPng).toBeTruthy();
  }, 300_000);
});

describe.skipIf(!hasFfmpeg)('after a crash mid-analysis', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, studioId: string, userId: string;
  beforeAll(async () => {
    a = await makeApp({ RECREATE_POSE: 'false', TESSERACT_PATH: '' });
    ({ owner } = await people(a, 0) as any);
    const [u] = await a.ctx.db.select().from(users).where(eq(users.id, owner.id));
    studioId = u!.studioId; userId = u!.id;
    await putObject(a.ctx, { key: 'u/rxmem/ref.mp4', body: fs.readFileSync(clip), studioId, kind: 'clip', contentType: 'video/mp4' });
  }, 60_000);
  afterAll(async () => { await a?.close(); });
  const row = (id: string, attempts: number) => a.ctx.db.insert(recreateReferences).values({ id, studioId, userId, name: id, storageKey: 'u/rxmem/ref.mp4', state: 'analyzing',
    phase: 'Reading the text', progress: 50, analyzeAttempts: attempts, createdAt: Date.now(), expiresAt: Date.now() + 86_400_000 });
  const get = async (id: string) => (await owner.req('GET', `/v1/recreate/references/${id}`)).body;

  it('startup: one that was running resumes lite; one that stopped the server twice fails with Retry; Retry runs it lite', async () => {
    await row('rx_crashed_once', 1);
    await row('rx_crashed_twice', 2);
    await row('rx_queued', 0);
    await recreateOf(a.ctx).startup();
    expect(await get('rx_crashed_twice')).toMatchObject({ state: 'failed', errorCode: 'analysis_crashed', error: expect.stringMatching(/Retry/) });
    const once = await until(async () => { const r = await get('rx_crashed_once'); return r.state === 'ready' || r.state === 'failed' ? r : null; }, 120_000);
    expect(once.state, once.error).toBe('ready');
    expect(once.recipe.analyzer.lite).toBe(true);
    const queued = await until(async () => { const r = await get('rx_queued'); return r.state === 'ready' || r.state === 'failed' ? r : null; }, 120_000);
    expect(queued.state).toBe('ready');
    expect(queued.recipe.analyzer.lite).toBeUndefined(); // never started before: a full analysis
    // Retry: only a failed one; after a crash it runs lite.
    expect((await owner.req('POST', '/v1/recreate/references/rx_queued/retry')).body.code).toBe('not_failed');
    const re = await owner.req('POST', '/v1/recreate/references/rx_crashed_twice/retry');
    expect(re.status).toBe(200);
    expect(re.body).toMatchObject({ state: 'analyzing' });
    const after = await until(async () => { const r = await get('rx_crashed_twice'); return r.state === 'ready' || r.state === 'failed' ? r : null; }, 120_000);
    expect(after.state, after.error).toBe('ready');
    expect(after.recipe.analyzer.lite).toBe(true);
    const [db] = await a.ctx.db.select().from(recreateReferences).where(eq(recreateReferences.id, 'rx_crashed_twice'));
    expect(db!.analyzeAttempts).toBe(2);
  }, 300_000);
});
