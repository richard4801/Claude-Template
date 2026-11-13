// Editing to notes (song_notes, find_impacts, sync_hits): synthetic fixtures made with ffmpeg, no network, nothing paid.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { eq, sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import type { AuthUser } from '../src/ctx.js';
import { users } from '../src/db/schema.js';
import { BEAT_SR, decodeMono } from '../src/editor/audio.js';
import * as M from '../src/editor/model.js';
import { findImpacts, measureMotion } from '../src/editor/motion.js';
import { editSessionsOf } from '../src/editor/sessions.js';
import { SYNC_LIMITS, SYNC_TOOLS } from '../src/editor/syncHits.js';
import { registryByName } from '../src/claude/registry.js';
import { analyseSong, clearSongCache, geminiListening, SONG_TOOLS } from '../src/claude/songNotes.js';
import { SYNC_MAP_TOOLS } from '../src/claude/syncMap.js';
import { makeApp, people, type Client } from './helpers.js';

const hasFfmpeg = (() => { try { execFileSync('ffmpeg', ['-version']); execFileSync('ffprobe', ['-version']); return true; } catch { return false; } })();
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-song-'));
const midi = (m: number) => 440 * 2 ** ((m - 69) / 12);

/** Plucked notes (2 ms attack, decaying, a harmonic) written as f32 and encoded by ffmpeg to `ext`. */
function notesFile(name: string, sec: number, notes: { at: number; dur: number; m: number; amp?: number }[], ext = 'm4a'): string {
  const sr = 44100, x = new Float32Array(Math.round(sec * sr));
  for (const n of notes) for (let i = 0; i < n.dur * sr; i++) {
    const k = Math.round(n.at * sr) + i; if (k >= x.length) break;
    const t = i / sr, f = midi(n.m), fade = Math.min(1, (n.dur - t) / 0.02);
    x[k]! += (n.amp ?? 0.25) * Math.min(1, t / 0.002) * Math.exp(-t * 3) * fade * (Math.sin(2 * Math.PI * f * t) + 0.4 * Math.sin(4 * Math.PI * f * t));
  }
  const raw = path.join(dir, `${name}.f32`), out = path.join(dir, `${name}.${ext}`);
  fs.writeFileSync(raw, Buffer.from(x.buffer));
  execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'f32le', '-ar', String(sr), '-ac', '1', '-i', raw, ...(ext === 'm4a' ? ['-c:a', 'aac', '-b:a', '160k'] : []), out]);
  return out;
}
/** A white box falls and lands every second (lands at 0.5, 1.5, 2.5, 3.5 s), then jumps back up. */
function landingsVideo(): string {
  const out = path.join(dir, 'land.mp4');
  execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'color=c=black:s=192x192:r=30:d=4', '-f', 'lavfi', '-i', 'color=c=white:s=32x32:r=30:d=4',
    '-filter_complex', "[0][1]overlay=x=80:y='if(lt(mod(t\\,1)\\,0.5)\\,mod(t\\,1)*2*140\\,140)'", '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', out]);
  return out;
}
const decode = (f: string) => decodeMono('ffmpeg', f, 600);
afterAll(() => fs.rmSync(dir, { recursive: true, force: true }));

describe.skipIf(!hasFfmpeg)('song_notes analysis', () => {
  it('finds the key of an A minor progression (Am – Dm – E – Am)', async () => {
    const chords = [[57, 60, 64], [62, 65, 69], [64, 68, 71], [57, 60, 64]];
    const notes = Array.from({ length: 16 }, (_, b) => { const c = chords[Math.floor(b / 2) % 4]!; return [...c.map(m => ({ at: b * 0.75, dur: 0.75, m, amp: 0.12 })), { at: b * 0.75, dur: 0.75, m: c[0]! - 12, amp: 0.18 }]; }).flat();
    const r = analyseSong(await decode(notesFile('aminor', 12.5, notes)), BEAT_SR);
    expect(r.key?.name).toBe('A minor');
    expect(r.key!.confidence).toBeGreaterThan(0.5);
    expect(r.key!.camelot).toBe('8A');
  });

  it('a melody of 4 notes at known times gives 4 onsets within ±15 ms, with their pitches', async () => {
    const T = [0.4, 0.95, 1.37, 2.12], P = [69, 72, 76, 74];
    const r = analyseSong(await decode(notesFile('melody', 3, T.map((at, i) => ({ at, dur: 0.45, m: P[i]! })))), BEAT_SR);
    expect(r.noteOnsets.length).toBe(4);
    r.noteOnsets.forEach((o, i) => { expect(Math.abs(o.t - T[i]!)).toBeLessThanOrEqual(0.015); });
    expect(r.noteOnsets.map(o => o.pitch)).toEqual(['A', 'C', 'E', 'D']);
    expect(r.energy.stepSec).toBe(0.25);
    expect(r.energy.db.length).toBeGreaterThanOrEqual(12); // 3 s every 0.25 s (+ the encoder's padding)
  });

  it('finds the section change (a quiet A minor arpeggio, then a loud C major one at 10 s)', async () => {
    const notes = [...Array.from({ length: 40 }, (_, k) => ({ at: k * 0.25, dur: 0.25, m: [57, 60, 64, 69][k % 4]!, amp: 0.08 })),
      ...Array.from({ length: 40 }, (_, k) => ({ at: 10 + k * 0.25, dur: 0.25, m: [48, 52, 55, 60][k % 4]!, amp: 0.4 }))];
    const r = analyseSong(await decode(notesFile('sections', 20, notes)), BEAT_SR);
    expect(r.sections.length).toBe(2);
    expect(Math.abs(r.sections[1]!.fromSec - 10)).toBeLessThanOrEqual(0.3);
    expect(r.sections[0]!.label).not.toBe(r.sections[1]!.label);
    expect(r.sections[1]!.energy).toBe('high');
  });
});

describe.skipIf(!hasFfmpeg)('find_impacts', () => {
  it('finds the 4 landings (motion stops) to the frame, and the sudden starts', async () => {
    const m = await measureMotion('ffmpeg', 'ffprobe', landingsVideo());
    const imp = findImpacts(m);
    const stops = imp.filter(x => x.kind === 'stop').map(x => x.t);
    expect(stops.length).toBe(4);
    stops.forEach((t, i) => expect(Math.abs(t - (0.5 + i))).toBeLessThanOrEqual(1 / 30 + 1e-6));
    expect(imp.filter(x => x.kind === 'start' && x.t > 0.5).map(x => x.t)).toEqual([1, 2, 3]);
  });
});

describe.skipIf(!hasFfmpeg)('sync_hits and song_notes in Edit', () => {
  type App = Awaited<ReturnType<typeof makeApp>>;
  let a: App, owner: Client, u: AuthUser, sid: string, refId = '';
  const env = () => ({ ctx: a.ctx, user: u, source: 'mcp' as const });
  const tool = (n: string) => [...SYNC_TOOLS, ...SONG_TOOLS, ...SYNC_MAP_TOOLS].find(t => t.name === n)!;
  const NOTES = [0.8, 1.7, 2.9, 3.6];
  const upload = async (file: string, contentType: string) => {
    const buf = fs.readFileSync(file);
    const p = (await owner.req('POST', '/v1/editor/uploads/presign', { contentType, bytes: buf.length })).body;
    const url = new URL(p.url);
    await a.app.inject({ method: 'PUT', url: url.pathname + url.search, headers: { 'content-type': contentType }, payload: buf });
    return p.uploadId as string;
  };

  beforeAll(async () => {
    clearSongCache();
    a = await makeApp({ SUITE_MODE: 'mock' });
    ({ owner } = await people(a, 0, { topUp: 0 }) as any);
    const [row] = await a.ctx.db.select().from(users).where(eq(users.id, owner.id));
    const studioId = ((await a.ctx.db.execute(sql`select studio_id from users where id = ${owner.id}`)) as any).rows[0].studio_id;
    u = { id: row!.id, studioId, email: row!.email, role: 'owner', studioName: 'Test Studio', sessionId: null };
    const video = await upload(landingsVideo(), 'video/mp4');
    const music = await upload(notesFile('music', 5, NOTES.map(at => ({ at, dur: 0.5, m: 57 }))), 'audio/mp4');
    const project = M.blankProject();
    project.assets.push({ id: 'v1', kind: 'video', upload: video, durationSec: 4, width: 192, height: 192, hasAudio: false },
      { id: 'a1', kind: 'audio', upload: music, durationSec: 5 });
    (project.tracks[0]!.items as M.VideoClip[]).push({ id: 'c1', asset: 'v1', inSec: 0, outSec: 4, speed: 1 });
    project.tracks.push({ id: 'music', kind: 'music', items: [{ id: 'm1', asset: 'a1', startSec: 0, inSec: 0, outSec: 5 } as M.AudioClip] });
    sid = (await owner.req('POST', '/v1/edit-sessions', { takeId: M.BLANK_SOURCE, project })).body.id;
    expect(sid).toBeTruthy();
  }, 60_000);
  afterAll(async () => { await a?.close(); });

  it('song_notes in Edit lists the music\'s hits with timeline times; find_impacts gives the landings', async () => {
    expect(registryByName.get('song_notes')?.members).toBe(true);
    expect(registryByName.get('sync_hits')?.members).toBe(false);
    const r = await tool('song_notes').run(env(), { sessionId: sid }) as any;
    expect(r.noteOnsets.length).toBe(4);
    r.noteOnsets.forEach((o: any, i: number) => { expect(Math.abs(o.tl - NOTES[i]!)).toBeLessThanOrEqual(0.015); });
    expect(r.lyricsNote).toMatch(/auto_captions/);
    expect(r.listening).toBeUndefined();
    const imp = await tool('find_impacts').run(env(), { sessionId: sid, itemId: 'c1', kinds: ['stop'] }) as any;
    expect(imp.impacts.map((x: any) => x.t)).toEqual([0.5, 1.5, 2.5, 3.5]);
  }, 60_000);

  it('lands 4 impacts on 4 notes, each within a frame, smooth and within limits, as one undoable step', async () => {
    const svc = editSessionsOf(a.ctx);
    const before = await svc.row(u, sid);
    const r = await tool('sync_hits').run(env(), { sessionId: sid, clipId: 'c1', impacts: [0.5, 1.5, 2.5, 3.5], notes: { itemId: 'm1' } }) as any;
    expect(r.applied).toBe(true);
    expect(r.landings).toHaveLength(4);
    r.landings.forEach((l: any, i: number) => {
      expect(Math.abs(l.landedSec - NOTES[i]!)).toBeLessThanOrEqual(1 / 30 + 0.015); // the note's frame (onset ±15 ms, rounded to the frame)
      expect(Math.abs(l.landedSec - l.targetSec)).toBeLessThanOrEqual(1 / 30);
    });
    const after = await svc.row(u, sid);
    expect(after.revision).toBe(before.revision + 1);
    const p = after.project as M.EditProject, main = M.mainTrack(p).items as M.VideoClip[];
    expect(main).toHaveLength(5);
    // The project's own timeline puts piece k+1 (impact k's frame) on the target frame.
    const sp = M.timeline(p);
    r.landings.forEach((l: any, i: number) => expect(Math.abs(sp[i + 1]!.startSec - l.targetSec)).toBeLessThan(0.5 / 30));
    for (const c of main) for (const [, v] of c.speedCurve!.points) { expect(v).toBeGreaterThanOrEqual(SYNC_LIMITS.minSpeed); expect(v).toBeLessThanOrEqual(SYNC_LIMITS.maxSpeed); }
    // Smooth: where two pieces meet, the speed is the same on both sides.
    for (let k = 0; k + 1 < main.length; k++) expect(main[k]!.speedCurve!.points.at(-1)![1]).toBeCloseTo(main[k + 1]!.speedCurve!.points[0]![1], 5);
    // One undo restores the clip.
    await svc.undo(u, sid, { entryId: r.entry.id });
    const undone = await svc.row(u, sid);
    expect((M.mainTrack(undone.project as M.EditProject).items as M.VideoClip[]).map(c => [c.id, c.inSec, c.outSec, c.speedCurve])).toEqual([['c1', 0, 4, undefined]]);
  }, 60_000);

  it('refuses a pair that needs a speed outside 0.25–4× and changes nothing', async () => {
    const svc = editSessionsOf(a.ctx), rev = (await svc.row(u, sid)).revision;
    const r = await tool('sync_hits').run(env(), { sessionId: sid, clipId: 'c1', impacts: [0.5, 1.5], targets: [0.1, 1.2] }) as any;
    expect(r.applied).toBe(false);
    expect(r.refused).toEqual([expect.objectContaining({ pair: 1, needSpeed: 5 })]);
    expect(r.message).toMatch(/pair 1 \(needs 5×\)/);
    expect((await svc.row(u, sid)).revision).toBe(rev);
    // impacts given in timeline seconds work the same
    const ok = await tool('sync_hits').run(env(), { sessionId: sid, clipId: 'c1', impacts: [0.5], impactsIn: 'timeline', targets: [0.6] }) as any;
    expect(ok.landings[0].landedSec).toBeCloseTo(0.6, 3);
  }, 60_000);

  it('sync_map pairs a reference\'s landings with its notes, reads the style, and its template re-lands new footage', async () => {
    // The reference: the falling box lands at 0.5, 1.5, 2.5, 3.5 s, on plucks at those times; one more strong pluck at 2.75 gets no action.
    const notes = notesFile('refsound', 4, [0.5, 1.5, 2.5, 3.5].map(at => ({ at, dur: 0.2, m: 64 })).concat([{ at: 2.75, dur: 0.2, m: 67 }]));
    const ref = path.join(dir, 'ref.mp4');
    execFileSync('ffmpeg', ['-y', '-v', 'error', '-i', landingsVideo(), '-i', notes, '-map', '0:v', '-map', '1:a', '-c:v', 'copy', '-c:a', 'aac', '-shortest', ref]);
    refId = await upload(ref, 'video/mp4');
    const m = await tool('sync_map').run(env(), { id: refId }) as any;
    expect(registryByName.get('sync_map')?.members).toBe(true);
    const stops = m.pairs.filter((p: any) => p.kind === 'stop');
    expect(stops.map((p: any) => p.t)).toEqual([0.5, 1.5, 2.5, 3.5]);
    for (const p of stops) { expect(Math.abs(p.offsetMs)).toBeLessThanOrEqual(60); expect(p.pitch).toBe('E'); }
    expect(m.unmatchedStrongOnsets.map((o: any) => o.t).some((t: number) => Math.abs(t - 2.75) <= 0.015)).toBe(true);
    expect(m.unmatchedImpacts.map((x: any) => x.kind)).toContain('start'); // the jumps back up play no note
    expect(m.style.kinds.stop).toBe(4);
    expect(m.style.strongOnsetsWithAction).toBeCloseTo(0.8, 1);
    expect(m.template.gapsSec.every((g: number) => Math.abs(g - 1) <= 0.03)).toBe(true);
    expect(m.labels).toBeUndefined();
    // The template on the owner's footage (the same landings, a fresh edit), stretched 1.2× so it really retimes.
    const project = M.blankProject();
    project.assets.push({ id: 'v1', kind: 'video', upload: refId, durationSec: 4, width: 192, height: 192, hasAudio: true });
    (project.tracks[0]!.items as M.VideoClip[]).push({ id: 'c1', asset: 'v1', inSec: 0, outSec: 4, speed: 1 });
    const sid2 = (await owner.req('POST', '/v1/edit-sessions', { takeId: M.BLANK_SOURCE, project })).body.id;
    const targets = m.template.targets.map((x: any) => x.t * 1.2);
    const r = await tool('sync_hits').run(env(), { sessionId: sid2, clipId: 'c1', impacts: stops.map((p: any) => p.t), targets }) as any;
    expect(r.applied).toBe(true);
    r.landings.forEach((l: any, i: number) => expect(Math.abs(l.landedSec - targets[i])).toBeLessThanOrEqual(1 / 30));
  }, 60_000);

  it('song_notes listening: a note without GEMINI_API_KEY; with one, Gemini is asked once (mocked) and its key never shows', async () => {
    const r = await tool('song_notes').run(env(), { sessionId: sid, listening: true }) as any;
    expect(r.listening.note).toMatch(/GEMINI_API_KEY/);
    const answer = { mood: 'tense', genre: 'test', instruments: ['synth pluck'], vocals: [], arc: [], moments: [{ t: 0.8, what: 'first pluck' }], summary: 'four plucks' };
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) => new Response(JSON.stringify({ candidates: [{ content: { parts: [{ text: JSON.stringify(answer) }] } }] }), { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);
    const cfg = a.ctx.config as { GEMINI_API_KEY?: string };
    cfg.GEMINI_API_KEY = 'test-gemini-key';
    try {
      const r2 = await tool('song_notes').run(env(), { sessionId: sid, listening: true }) as any;
      expect(r2.listening).toMatchObject({ mood: 'tense', instruments: ['synth pluck'], by: 'gemini-3.5-flash' });
      const again = await tool('song_notes').run(env(), { sessionId: sid, listening: true }) as any; // cached
      expect(again.listening.mood).toBe('tense');
      expect(fetchMock).toHaveBeenCalledTimes(1);
      const [url, init] = fetchMock.mock.calls[0]!;
      expect(String(url)).toContain('/models/gemini-3.5-flash:generateContent');
      expect(String(url)).not.toContain('test-gemini-key');
      expect((init.headers as Record<string, string>)['x-goog-api-key']).toBe('test-gemini-key');
      const body = JSON.parse(String(init.body));
      expect(body.contents[0].parts[1].inline_data.data.length).toBeGreaterThan(100);
      expect(JSON.stringify(r2)).not.toContain('test-gemini-key');
      // sync_map labels: one call on the video (mocked), merged into the pairs by time.
      fetchMock.mockImplementationOnce(async () => new Response(JSON.stringify({ candidates: [{ content: { parts: [{ text: JSON.stringify({ actions: [{ t: 0.55, label: 'box lands' }, { t: 1.5, label: 'box lands' }] }) }] } }] }), { status: 200 }));
      const sm = await tool('sync_map').run(env(), { id: refId, labels: true }) as any;
      expect(sm.labels.actions).toHaveLength(2);
      expect(sm.pairs.filter((p: any) => p.label === 'box lands').map((p: any) => p.t)).toEqual([0.5, 1.5]);
      // A silent clip has no notes to map: a plain refusal, not an ffmpeg error.
      await expect(tool('sync_map').run(env(), { sessionId: sid, itemId: 'c1' })).rejects.toThrow(/no sound/);
      expect(String(fetchMock.mock.calls.at(-1)![0])).toContain(':generateContent');
      expect(JSON.parse(String(fetchMock.mock.calls.at(-1)![1].body)).contents[0].parts[1].inline_data.mime_type).toBe('video/mp4');
      // A failed call is a note, never an error.
      fetchMock.mockImplementationOnce(async () => new Response('nope', { status: 500 }));
      const failed = await geminiListening(a.ctx, path.join(dir, 'music.m4a'));
      expect(failed.note).toMatch(/failed/);
    } finally { cfg.GEMINI_API_KEY = undefined; vi.unstubAllGlobals(); }
  }, 60_000);
});
