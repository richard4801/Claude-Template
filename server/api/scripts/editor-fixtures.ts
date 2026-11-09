// Writes the shared editor v2 fixtures (plans/video-editor.md "Editor v2") from the reference implementation, into
// test/fixtures/editor and the Android/Mac test resource copies. Run: npx tsx scripts/editor-fixtures.ts
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as M from '../src/editor/model.js';
import { CAPTION_STYLES, CAPTION_STYLE_LABELS, FILTERS, HOOKS, TRANSITION_LABELS } from '../src/editor/presets.js';
import { suggestCuts } from '../src/editor/cuts.js';
import { runChain, voiceChain } from '../src/editor/audio.js';
import { applyPatch, diff } from '../src/editor/jsonpatch.js';
import { applyOps, OP_NAMES } from '../src/editor/ops.js';
import * as K from '../src/editor/look.js';
import { applyKit, kitOf, validateKit } from '../src/editor/kit.js';
import { CUBE_SIZE, LOOK_IDS, grade, packLook } from '../src/editor/lookpack.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../../..');
export const FIXTURE_DIRS = [
  path.join(repo, 'server/api/test/fixtures/editor'),
  path.join(repo, 'android/core/src/test/resources/editor'),
  path.join(repo, 'mac/MuseCore/Tests/MuseCoreTests/Fixtures/editor'),
];

const W = (text: string, s: number, e: number) => ({ text, startSec: s, endSec: e });
const words = [W('Okay', 0.2, 0.5), W('so', 0.55, 0.7), W('um', 0.9, 1.2), W('this', 1.6, 1.8), W('serum', 1.85, 2.3), W('changed', 2.35, 2.7), W('my', 2.75, 2.9),
  W('skin.', 2.95, 3.4), W('Honestly', 4.6, 5.1), W('uh', 5.2, 5.4), W('I', 5.6, 5.7), W('use', 5.75, 5.95), W('it', 6.0, 6.1), W('every', 6.15, 6.5), W('single', 6.55, 6.9),
  W('day!', 6.95, 7.4), W('Like', 8.0, 8.2), W('seriously', 8.25, 8.9)];

const src: M.Asset = { id: 'src', kind: 'video', take: 'take_src', durationSec: 10, width: 1080, height: 1920, hasAudio: true };
const canvas: M.Canvas = { width: 1080, height: 1920, fps: 30, background: '#000000' };
const proj = (tracks: M.Track[], assets: M.Asset[] = [src], extra: Partial<M.EditProject> = {}): M.EditProject => ({ version: 2, sourceTakeId: 'take_src', canvas, assets, tracks, ...extra });
const main = (items: M.VideoClip[]): M.Track => ({ id: 'main', kind: 'main', items });
const clip = (id: string, a: number, b: number, o: Partial<M.VideoClip> = {}): M.VideoClip => ({ id, asset: 'src', inSec: a, outSec: b, speed: 1, ...o });
const captionTrack = (preset: M.CaptionPreset = 'highlight', wordsPerPage?: number): M.Track =>
  ({ id: 'cap', kind: 'caption', items: [], caption: { asset: 'src', words, style: { ...CAPTION_STYLES[preset], ...(wordsPerPage ? { wordsPerPage } : {}) } } });
const music: M.Asset = { id: 'song', kind: 'audio', library: 'music_upbeat_01', durationSec: 30 };
const vo: M.Asset = { id: 'vo', kind: 'audio', upload: 'up_vo', durationSec: 4 };
const pip: M.Asset = { id: 'pip', kind: 'video', take: 'take_pip', durationSec: 6, width: 720, height: 1280, hasAudio: true };
const img: M.Asset = { id: 'logo', kind: 'image', upload: 'up_logo', width: 512, height: 512 };

// ------------------------------------------------------------------ projects with expected answers
const projects: { name: string; project: M.EditProject }[] = [
  { name: 'single clip', project: proj([main([clip('c1', 0.5, 9.8)])]) },
  { name: 'cut and speeds', project: proj([main([clip('c1', 0, 2), clip('c2', 2, 4, { speed: 0.5 }), clip('c3', 4, 10, { speed: 2 })])]) },
  { name: 'transitions', project: proj([main([clip('c1', 0, 4), clip('c2', 4, 7, { transitionIn: { kind: 'fade', durationSec: 0.5 } }), clip('c3', 7, 10, { transitionIn: { kind: 'slideLeft', durationSec: 1 }, volume: 0.8 })])]) },
  { name: 'captions through cuts', project: proj([main([clip('c1', 0, 3.5), clip('c2', 4.5, 10, { speed: 1.5 })]), captionTrack('highlight')]) },
  { name: 'captions single', project: proj([main([clip('c1', 0, 10)]), captionTrack('single')]) },
  { name: 'captions pop 2', project: proj([main([clip('c1', 1, 9, { transitionIn: undefined })]), captionTrack('pop')]) },
  {
    name: 'music ducking', project: proj([
      main([clip('c1', 0, 10, { fadeOutSec: 1 })]), captionTrack('karaoke'),
      { id: 'mus', kind: 'music', volume: 0.8, duck: { level: 0.25, fadeSec: 0.3, under: ['speech', 'voice'] }, items: [{ id: 'm1', asset: 'song', startSec: 0, inSec: 5, outSec: 15, fadeInSec: 1, fadeOutSec: 2 } as M.AudioClip] },
      { id: 'voice', kind: 'voice', items: [{ id: 'v1', asset: 'vo', startSec: 6, inSec: 0, outSec: 3.5 } as M.AudioClip] },
    ], [src, music, vo]),
  },
  {
    name: 'volume keyframes', project: proj([
      main([clip('c1', 0, 6, { keyframes: { volume: [{ t: 0, v: 1, ease: 'easeInOut' }, { t: 2, v: 0.2, ease: 'hold' }, { t: 4, v: 1.5 }] } }), clip('c2', 6, 10, { muted: true, transitionIn: { kind: 'black', durationSec: 0.6 } })]),
      { id: 'sfx', kind: 'sfx', muted: false, items: [{ id: 's1', asset: 'song', startSec: 1, inSec: 0, outSec: 0.5, volume: 1.5 } as M.AudioClip] },
    ], [src, music]),
  },
  {
    name: 'pip text image look', project: proj([
      main([clip('c1', 0, 10, { filter: { id: 'film', amount: 0.7 }, adjust: { exposure: 0.2 } })]),
      { id: 'pipt', kind: 'video', items: [{ id: 'p1', asset: 'pip', startSec: 1, inSec: 0.5, outSec: 5, speed: 1, fit: 'contain', transform: { x: 0.75, y: 0.25, scale: 0.4 }, chroma: { color: '#00FF00', similarity: 0.4, smoothness: 0.08, spill: 0.5 }, volume: 0, keyframes: { scale: [{ t: 0, v: 0.2, ease: 'easeOut' }, { t: 0.5, v: 0.4 }] } } as M.VideoClip] },
      { id: 'imgs', kind: 'image', items: [{ id: 'i1', asset: 'logo', startSec: 0, durationSec: 2, transform: { x: 0.1, y: 0.1, scale: 0.2 }, animIn: { kind: 'pop', durationSec: 0.4 }, animOut: { kind: 'fade', durationSec: 0.5 }, filter: { id: 'mono', amount: 1 } } as M.ImageItem] },
      { id: 'txt', kind: 'text', items: [{ id: 't1', startSec: 0, durationSec: 3, text: HOOKS[0]!.text, style: HOOKS[0]!.style, transform: HOOKS[0]!.transform, animIn: HOOKS[0]!.animIn, template: HOOKS[0]!.id } as M.TextItem,
        { id: 't2', startSec: 3, durationSec: 4, text: HOOKS[3]!.text, style: HOOKS[3]!.style, transform: HOOKS[3]!.transform, animIn: HOOKS[3]!.animIn, animOut: { kind: 'slideDown', durationSec: 0.5 } } as M.TextItem] },
    ], [src, pip, img]),
  },
  {
    name: 'speed curves, new transitions, attack/release ducking', project: proj([
      main([clip('c1', 0, 3, { speed: 1, speedCurve: { preset: 'hero', points: M.SPEED_PRESETS.hero } }), clip('c2', 3, 5.5, { speed: 0.5, transitionIn: { kind: 'whip', durationSec: 0.4 } }),
        clip('c3', 5.5, 8, { transitionIn: { kind: 'spin', durationSec: 0.5 } }), clip('c4', 8, 10, { speed: 1, speedCurve: { preset: 'custom', points: [[0, 0.1], [0.5, 2], [1, 10]] }, transitionIn: { kind: 'glitch', durationSec: 0.3 } })]),
      captionTrack('highlighter'),
      { id: 'mus', kind: 'music', duck: { level: 0.25, attackSec: 0.2, releaseSec: 0.6, under: ['speech'] }, items: [{ id: 'm1', asset: 'song', startSec: 0, inSec: 0, outSec: 20 } as M.AudioClip] },
    ], [src, music]),
  },
];

// Wave 1 (plans/edit-parity.md): a freeze frame (hold) with a transition into it, mirrored and blended overlays, blur fill.
projects.push({
  name: 'wave 1: hold, mirror, blend, blur fill', project: proj([
    main([clip('c1', 0, 4), clip('c2', 4, 4.1, { holdSec: 1.5, transitionIn: { kind: 'fade', durationSec: 0.4 } }), clip('c3', 4, 10, { fadeInSec: 0.5, fit: 'contain' })]),
    captionTrack('highlight'),
    { id: 'pipt', kind: 'video', items: [{ id: 'p1', asset: 'pip', startSec: 1, inSec: 0, outSec: 4, speed: 1, fit: 'contain', blend: 'screen', transform: { x: 0.7, y: 0.3, scale: 0.5, rotation: 15, flipX: true } } as M.VideoClip] },
    { id: 'imgs', kind: 'image', items: [{ id: 'i1', asset: 'logo', startSec: 0, durationSec: 3, blend: 'multiply', transform: { scale: 0.3, flipY: true } } as M.ImageItem] },
    { id: 'txt', kind: 'text', items: [{ id: 't1', startSec: 0, durationSec: 2, text: 'Mirror', style: HOOKS[0]!.style, transform: { flipX: true } } as M.TextItem] },
  ], [src, pip, img], { canvas: { ...canvas, fill: 'blur' } }),
});

function expectFor(p: M.EditProject) {
  const e: Record<string, unknown> = { durationSec: M.durationSec(p), timeline: M.timeline(p) };
  e.captionWords = M.captionWords(p);
  e.captionPages = M.captionPages(p).map(pg => ({ startSec: pg.startSec, endSec: pg.endSec, words: pg.words.map(w => w.index) }));
  const d = M.durationSec(p);
  e.captionAt = Array.from({ length: Math.ceil(d / 0.25) + 1 }, (_, i) => { const t = Math.round(i * 0.25 * 100) / 100; return { t, at: M.captionAt(p, t) }; });
  const env: Record<string, M.GainPoint[]> = {};
  for (const t of p.tracks) if (['main', 'video', 'music', 'voice', 'sfx'].includes(t.kind)) for (const it of t.items) env[`${t.id}/${it.id}`] = M.audioEnvelope(p, t.id, it.id);
  e.envelopes = env;
  const colors: Record<string, number[]> = {};
  for (const t of p.tracks) for (const it of t.items) if ('filter' in it || 'adjust' in it) colors[it.id] = M.colorMatrix((it as M.VideoClip).adjust, (it as M.VideoClip).filter, FILTERS);
  e.colorMatrices = colors;
  e.toV1 = M.toV1(p);
  e.pieces = Object.fromEntries((M.mainTrack(p).items as M.VideoClip[]).filter(c => c.speedCurve).map(c => [c.id, M.speedPieces(c)]));
  e.srt = M.toSrt(p);
  return e;
}

// ------------------------------------------------------------------ validation cases
const good = projects[8]!.project;
const mut = (f: (p: any) => void) => { const p = JSON.parse(JSON.stringify(good)); f(p); return p; };
const validation: { name: string; project: unknown; ok: boolean; field?: string }[] = [
  ...projects.map(x => ({ name: x.name, project: x.project, ok: true })),
  { name: 'wrong version', project: mut(p => (p.version = 3)), ok: false, field: 'edits.version' },
  { name: 'canvas too big', project: mut(p => (p.canvas.width = 5000)), ok: false, field: 'edits.canvas.width' },
  { name: 'no main first', project: mut(p => p.tracks.reverse()), ok: false, field: 'edits.tracks.0.kind' },
  { name: 'unknown asset', project: mut(p => (p.tracks[0].items[0].asset = 'nope')), ok: false, field: 'edits.tracks.0.items.0.asset' },
  { name: 'speed too fast', project: mut(p => (p.tracks[0].items[0].speed = 12)), ok: false, field: 'edits.tracks.0.items.0.speed' },
  { name: 'past the source end', project: mut(p => (p.tracks[0].items[0].outSec = 10.2)), ok: false, field: 'edits.tracks.0.items.0.outSec' },
  { name: 'too short clip', project: mut(p => { p.tracks[0].items[0].inSec = 0; p.tracks[0].items[0].outSec = 0.05; }), ok: false, field: 'edits.tracks.0.items.0.outSec' },
  { name: 'output too short', project: mut(p => { p.tracks[0].items[0].outSec = 0.3; }), ok: false, field: 'edits' },
  { name: 'duplicate id', project: mut(p => (p.tracks[3].items[1].id = 't1')), ok: false, field: 'edits.tracks.3.items.1.id' },
  { name: 'overlapping texts', project: mut(p => (p.tracks[3].items[1].startSec = 2)), ok: false, field: 'edits.tracks.3.items.1.startSec' },
  { name: 'bad colour', project: mut(p => (p.tracks[3].items[0].style.color = 'red')), ok: false, field: 'edits.tracks.3.items.0.style.color' },
  { name: 'transition on first clip', project: mut(p => (p.tracks[0].items[0].transitionIn = { kind: 'fade', durationSec: 0.5 })), ok: false, field: 'edits.tracks.0.items.0.transitionIn' },
  { name: 'image asset on video track', project: mut(p => (p.tracks[1].items[0].asset = 'logo')), ok: false, field: 'edits.tracks.1.items.0.asset' },
  { name: 'unknown filter', project: mut(p => (p.tracks[0].items[0].filter.id = 'sepia9')), ok: false, field: 'edits.tracks.0.items.0.filter.id' },
  { name: 'keyframes out of order', project: mut(p => p.tracks[1].items[0].keyframes.scale.reverse()), ok: false, field: 'edits.tracks.1.items.0.keyframes.scale.1.t' },
  { name: 'volume keyframe on image', project: mut(p => (p.tracks[2].items[0].keyframes = { volume: [{ t: 0, v: 1 }] })), ok: false, field: 'edits.tracks.2.items.0.keyframes.volume' },
  { name: 'typewriter on image', project: mut(p => (p.tracks[2].items[0].animIn = { kind: 'typewriter', durationSec: 1 })), ok: false, field: 'edits.tracks.2.items.0.animIn.kind' },
  { name: 'startSec on main', project: mut(p => (p.tracks[0].items[0].startSec = 1)), ok: false, field: 'edits.tracks.0.items.0.startSec' },
  { name: 'asset with two refs', project: mut(p => (p.assets[1].upload = 'up_x')), ok: false, field: 'edits.assets.1' },
  { name: 'transition too long', project: (() => { const p = JSON.parse(JSON.stringify(projects[2]!.project)); p.tracks[0].items[1].transitionIn.durationSec = 1.6; return p; })(), ok: false, field: 'edits.tracks.0.items.1.transitionIn.durationSec' },
  { name: 'duck on voice', project: (() => { const p = JSON.parse(JSON.stringify(projects[6]!.project)); p.tracks[3].duck = { under: ['speech'] }; return p; })(), ok: false, field: 'edits.tracks.3.duck' },
  { name: 'speed curve ok', project: mut(p => { p.tracks[0].items[0].speedCurve = { preset: 'bullet', points: M.SPEED_PRESETS.bullet }; }), ok: true },
  { name: 'speed curve bad point', project: mut(p => { p.tracks[0].items[0].speedCurve = { preset: 'custom', points: [[0, 1], [0.5, 20], [1, 1]] }; }), ok: false, field: 'edits.tracks.0.items.0.speedCurve.points.1' },
  { name: 'speed curve must end at 1', project: mut(p => { p.tracks[0].items[0].speedCurve = { preset: 'custom', points: [[0, 1], [0.8, 2]] }; }), ok: false, field: 'edits.tracks.0.items.0.speedCurve.points' },
  { name: 'speed 0.1–10 now', project: mut(p => { p.tracks[0].items[0].speed = 0.1; p.tracks[0].items[0].outSec = 0.4; }), ok: true },
  { name: 'mask ok', project: mut(p => { p.tracks[1].items[0].mask = { shape: 'heart', feather: 0.2, invert: true }; }), ok: true },
  { name: 'mask bad shape', project: mut(p => { p.tracks[1].items[0].mask = { shape: 'blob' }; }), ok: false, field: 'edits.tracks.1.items.0.mask.shape' },
  { name: 'voice effect ok', project: mut(p => { p.tracks[0].items[0].voiceEffect = 'radio'; p.tracks[0].items[0].enhance = true; }), ok: true },
  { name: 'voice effect bad', project: mut(p => { p.tracks[0].items[0].voiceEffect = 'robot'; }), ok: false, field: 'edits.tracks.0.items.0.voiceEffect' },
  { name: 'adjust highlights', project: mut(p => { p.tracks[0].items[0].adjust = { highlights: -0.4, shadows: 2 }; }), ok: false, field: 'edits.tracks.0.items.0.adjust.shadows' },
  { name: 'palette look unknown without palettes', project: mut(p => { p.tracks[0].items[0].look = { lut: 'palette:teal_neon', strength: 0.8 }; }), ok: false, field: 'edits.tracks.0.items.0.look.lut' },
  { name: 'look ok', project: mut(p => { p.tracks[0].items[0].look = { ...packLook('film-cine'), curves: { rgb: [[0, 0.05], [1, 0.95]] } }; }), ok: true },
  { name: 'look with imported lut', project: mut(p => { p.assets.push({ id: 'cube1', kind: 'lut', upload: 'up_cube' }); p.tracks[2].items[0].look = { lut: 'cube1', strength: 0.6 }; }), ok: true },
  { name: 'look unknown pack', project: mut(p => { p.tracks[0].items[0].look = { lut: 'pack:nope' }; }), ok: false, field: 'edits.tracks.0.items.0.look.lut' },
  { name: 'look lut not a lut asset', project: mut(p => { p.tracks[0].items[0].look = { lut: 'logo' }; }), ok: false, field: 'edits.tracks.0.items.0.look.lut' },
  { name: 'look curve x not increasing', project: mut(p => { p.tracks[1].items[0].look = { curves: { r: [[0, 0], [0.5, 0.4], [0.5, 0.6], [1, 1]] } }; }), ok: false, field: 'edits.tracks.1.items.0.look.curves.r.2' },
  { name: 'look grain too big', project: mut(p => { p.tracks[0].items[0].look = { grain: { amount: 2 } }; }), ok: false, field: 'edits.tracks.0.items.0.look.grain.amount' },
  { name: 'look leak kind', project: mut(p => { p.tracks[0].items[0].look = { leak: { kind: 'green', amount: 0.3 } }; }), ok: false, field: 'edits.tracks.0.items.0.look.leak.kind' },
  { name: 'look unknown key', project: mut(p => { p.tracks[0].items[0].look = { bloom: 1 }; }), ok: false, field: 'edits.tracks.0.items.0.look.bloom' },
  { name: 'lut asset must be an upload', project: mut(p => { p.assets.push({ id: 'cube2', kind: 'lut', library: 'x' }); }), ok: false, field: 'edits.assets.3' },
  { name: 'hold ok', project: mut(p => { p.tracks[0].items[0].holdSec = 2; }), ok: true },
  { name: 'hold too long', project: mut(p => { p.tracks[0].items[0].holdSec = 31; }), ok: false, field: 'edits.tracks.0.items.0.holdSec' },
  { name: 'hold at 2x', project: mut(p => { p.tracks[0].items[0].holdSec = 2; p.tracks[0].items[0].speed = 2; }), ok: false, field: 'edits.tracks.0.items.0.holdSec' },
  { name: 'blend on overlay ok', project: mut(p => { p.tracks[1].items[0].blend = 'softLight'; p.tracks[2].items[0].blend = 'add'; }), ok: true },
  { name: 'blend on main', project: mut(p => { p.tracks[0].items[0].blend = 'screen'; }), ok: false, field: 'edits.tracks.0.items.0.blend' },
  { name: 'blend unknown', project: mut(p => { p.tracks[1].items[0].blend = 'dissolve'; }), ok: false, field: 'edits.tracks.1.items.0.blend' },
  { name: 'flip not a boolean', project: mut(p => { p.tracks[1].items[0].transform.flipX = 1; }), ok: false, field: 'edits.tracks.1.items.0.transform.flipX' },
  { name: 'text flip ok', project: mut(p => { p.tracks[3].items[0].transform = { ...(p.tracks[3].items[0].transform ?? {}), flipY: true }; }), ok: true },
  { name: 'fill blur ok', project: mut(p => { p.canvas.fill = 'blur'; }), ok: true },
  { name: 'fill unknown', project: mut(p => { p.canvas.fill = 'mirror'; }), ok: false, field: 'edits.canvas.fill' },
  { name: 'tint ok', project: mut(p => { p.tracks[0].items[0].adjust = { temperature: 0.3, tint: -0.4 }; }), ok: true },
  { name: 'tint too big', project: mut(p => { p.tracks[0].items[0].adjust = { tint: 1.5 }; }), ok: false, field: 'edits.tracks.0.items.0.adjust.tint' },
  { name: 'tint not a number', project: mut(p => { p.tracks[0].items[0].adjust = { tint: 'pink' }; }), ok: false, field: 'edits.tracks.0.items.0.adjust.tint' },
  { name: 'video anim ok', project: mut(p => { p.tracks[0].items[0].animIn = { kind: 'fade', durationSec: 0.5 }; p.tracks[1].items[0].animOut = { kind: 'zoom', durationSec: 0.4 }; }), ok: true },
  { name: 'video typewriter', project: mut(p => { p.tracks[1].items[0].animIn = { kind: 'typewriter', durationSec: 1 }; }), ok: false, field: 'edits.tracks.1.items.0.animIn.kind' },
  { name: 'video anim too long', project: mut(p => { p.tracks[0].items[0].animOut = { kind: 'slideUp', durationSec: 3 }; }), ok: false, field: 'edits.tracks.0.items.0.animOut.durationSec' },
  { name: 'colour keys ok', project: mut(p => { p.tracks[0].items[0].keyframes = { exposure: [{ t: 0, v: -0.3 }, { t: 1, v: 0.3 }] }; p.tracks[1].items[0].keyframes = { tint: [{ t: 0.5, v: 0.5 }] }; }), ok: true },
  { name: 'colour key on text', project: mut(p => { p.tracks[3].items[0].keyframes = { exposure: [{ t: 0, v: 0.2 }] }; }), ok: false, field: 'edits.tracks.3.items.0.keyframes.exposure' },
  { name: 'colour key too big', project: mut(p => { p.tracks[0].items[0].keyframes = { exposure: [{ t: 0, v: 1.5 }] }; }), ok: false, field: 'edits.tracks.0.items.0.keyframes.exposure.0.v' },
  { name: 'colour key on audio', project: mut(p => { p.tracks.push({ id: 'mus', kind: 'music', items: [{ id: 'a9', asset: p.tracks[0].items[0].asset, startSec: 0, inSec: 0, outSec: 1, keyframes: { exposure: [{ t: 0, v: 0.1 }] } }] }); }), ok: false, field: 'edits.tracks.4.items.0.keyframes.exposure' },
  { name: 'colour keys on an image ok', project: mut(p => { p.tracks[2].items[0].keyframes = { tint: [{ t: 0, v: -0.2 }, { t: 1, v: 0.4 }], saturation: [{ t: 0.5, v: 1 }] }; }), ok: true },
  { name: 'caption word bad', project: (() => { const p = JSON.parse(JSON.stringify(projects[3]!.project)); p.tracks[1].caption.words[2].endSec = 0.1; return p; })(), ok: false, field: 'edits.tracks.1.caption.words.2.endSec' },
];
for (const v of validation) {
  let got: { ok: boolean; field?: string };
  try { M.validate(v.project as M.EditProject, FILTERS, LOOK_IDS); got = { ok: true }; } catch (e) { got = { ok: false, field: (e as M.EditProblem).field }; }
  if (got.ok !== v.ok || got.field !== v.field) throw new Error(`validation case "${v.name}": expected ${JSON.stringify(v)} got ${JSON.stringify(got)}`);
}

// ------------------------------------------------------------------ small function tables
const kfCases = [
  { keys: [{ t: 0, v: 0 }, { t: 1, v: 10 }] },
  { keys: [{ t: 0.5, v: 1, ease: 'easeIn' }, { t: 1.5, v: 3, ease: 'easeOut' }, { t: 2.5, v: 0, ease: 'easeInOut' }, { t: 3.5, v: 2, ease: 'hold' }, { t: 4, v: 5 }] },
] as { keys: M.Keyframe[] }[];
const keyframes = kfCases.map(c => ({ keys: c.keys, samples: Array.from({ length: 23 }, (_, i) => { const t = i * 0.2; return { t: Math.round(t * 10) / 10, v: Math.round(M.keyframeValue(c.keys, t) * 1e6) / 1e6 }; }) }));
const ps = [0, 0.1, 0.25, 0.5, 0.6, 0.75, 1];
const transitions = M.TRANSITIONS.flatMap(kind => ps.map(p => ({ kind, p, state: round(M.transitionState(kind, p)) })));
const animItems = [
  { durationSec: 3, animIn: { kind: 'pop', durationSec: 0.5 }, animOut: { kind: 'fade', durationSec: 0.5 } },
  { durationSec: 2, text: 'Hello world', animIn: { kind: 'typewriter', durationSec: 1 }, animOut: { kind: 'slideDown', durationSec: 0.4 } },
  { durationSec: 2, animIn: { kind: 'zoom', durationSec: 0.4 }, animOut: { kind: 'slideUp', durationSec: 0.4 } },
] as Parameters<typeof M.animState>[0][];
const anims = animItems.map(item => ({ item, samples: Array.from({ length: 16 }, (_, i) => { const t = Math.round(i * item.durationSec / 15 * 1000) / 1000; return { t, state: M.animState(item, t) }; }) }));
const colors = [
  { adjust: {}, filter: null }, { adjust: { exposure: 1 }, filter: null }, { adjust: { contrast: 0.5, saturation: -0.5 }, filter: null },
  { adjust: { temperature: -1 }, filter: null }, ...FILTERS.map(f => ({ adjust: { exposure: -0.1 }, filter: { id: f.id, amount: 0.8 } })),
  // Green ↔ magenta tint, alone and with the other steps and a preset tint.
  { adjust: { tint: 1 }, filter: null }, { adjust: { tint: -0.6, temperature: 0.5, contrast: 0.2 }, filter: null },
  { adjust: { tint: 0.4, saturation: -0.3 }, filter: { id: 'film', amount: 1 } },
].map(c => ({ ...c, matrix: M.colorMatrix(c.adjust, c.filter ?? undefined, FILTERS) }));
const cutsCases = [
  { project: projects[0]!.project, asset: 'src', cuts: [{ startSec: 0.7, endSec: 1.55 }, { startSec: 3.4, endSec: 4.6 }, { startSec: 9.75, endSec: 12 }] },
  { project: projects[2]!.project, asset: 'src', cuts: [{ startSec: 3.95, endSec: 4.3 }, { startSec: 6.9, endSec: 7.05 }, { startSec: 8, endSec: 8.5 }, { startSec: 8.4, endSec: 8.6 }] },
  { project: projects[1]!.project, asset: 'src', cuts: [{ startSec: 0, endSec: 10 }] },
].map(c => ({ ...c, result: M.applyCuts(c.project, c.asset, c.cuts) }));
const v1 = [
  { v1: { version: 1, sourceTakeId: 'take_src', sourceDurationSec: 10, segments: [{ inSec: 0, outSec: 3, speed: 1 }, { inSec: 4, outSec: 10, speed: 2, muted: true }], mute: false }, info: { width: 1080, height: 1920, fps: 30, hasAudio: true } },
  { v1: { version: 1, sourceTakeId: 'take_src', sourceDurationSec: 8.25, segments: [{ inSec: 0.5, outSec: 8.25, speed: 0.75 }], mute: true }, info: { width: 1440, height: 2560, fps: 24, hasAudio: false } },
] as { v1: M.EditListV1; info: { width: number; height: number; fps: number; hasAudio: boolean } }[];
const v1cases = v1.map(c => { const project = M.fromV1(c.v1, c.info); return { ...c, project, back: M.toV1(project) }; });
const suggest = [
  { words: words.map(w => ({ ...w })), durationSec: 10, options: {} },
  { words: words.map(w => ({ ...w })), durationSec: 10, options: { minSilenceSec: 0.4, keepPadSec: 0.05, fillers: true, repeats: true, extraFillers: ['like', 'honestly'] } },
  { words: [W('I', 0.1, 0.2), W('I', 0.3, 0.4), W('I', 0.45, 0.5), W('mean', 0.55, 0.8), W('so', 3, 3.2)], durationSec: 4, options: { repeats: true, fillers: false } },
].map(c => ({ ...c, result: suggestCuts(c.words, c.durationSec, c.options) }));

const chromaKeys: M.Chroma[] = [{ color: '#00FF00' }, { color: '#00FF00', similarity: 0.3, smoothness: 0.15, spill: 0.2 }, { color: '#0000FF', similarity: 0.35, smoothness: 0.05, spill: 0.8 }];
const chromaColors: [number, number, number][] = [[0, 1, 0], [0.2, 0.7, 0.3], [0.3, 0.8, 0.35], [0.4, 0.75, 0.45], [0.9, 0.7, 0.6], [0.5, 0.5, 0.5], [0.1, 0.1, 0.9], [1, 1, 1], [0, 0, 0], [0.6, 0.9, 0.2]];
const masks = (['linear', 'mirror', 'circle', 'rect', 'heart', 'star'] as M.MaskShape[]).flatMap(shape => [
  { shape }, { shape, x: 0.4, y: 0.6, width: 0.6, height: 0.3, rotation: 30, feather: 0.2, invert: true },
] as M.Mask[]).map(m => ({ mask: m, samples: [[0.5, 0.5], [0.1, 0.1], [0.5, 0.2], [0.5, 0.8], [0.3, 0.55], [0.72, 0.5], [0.5, 0.36], [0.62, 0.62]].map(([u, v]) => [u, v, M.maskAlpha(m, u!, v!)]) }));
const tone = [[-1, 0], [0, 1], [0.5, -0.5], [1, 1]].map(([sh, hi]) => ({ shadows: sh, highlights: hi, samples: [0, 0.1, 0.25, 0.33, 0.5, 0.67, 0.8, 1].map(v => [v, Math.round(M.toneAdjust(v, sh, hi) * 1e6) / 1e6]) }));
const curveClips = [
  { inSec: 0, outSec: 3, speed: 1, speedCurve: { preset: 'hero', points: M.SPEED_PRESETS.hero } },
  { inSec: 2, outSec: 9, speed: 1, speedCurve: { preset: 'montage', points: M.SPEED_PRESETS.montage } },
  { inSec: 1, outSec: 2, speed: 1, speedCurve: { preset: 'custom', points: [[0, 0.1], [1, 10]] } },
] as M.VideoClip[];
const speedCurves = curveClips.map(c => ({ clip: c, length: Math.round(M.clipLength(c) * 1e6) / 1e6, curve: [0, 0.1, 0.33, 0.5, 0.9, 1].map(x => [x, Math.round(M.curveSpeed(c.speedCurve!, x) * 1e6) / 1e6]),
  timeAt: [c.inSec, c.inSec + 0.01, (c.inSec + c.outSec) / 2, c.outSec - 0.01, c.outSec].map(t => [t, Math.round(M.clipTimeAt(c, t) * 1e6) / 1e6]),
  sub: M.subCurve(c.speedCurve!, 0.25, 0.8) }));
const presetsTable = M.SPEED_PRESETS;
const impulse = Array.from({ length: 24 }, (_, i) => (i === 0 ? 1 : 0));
const voice = (['none', 'warm', 'radio', 'phone', 'deep'] as M.VoiceEffect[]).flatMap(v => [false, true].flatMap(enh => [44100, 48000].map(sr => {
  const chain = voiceChain({ voiceEffect: v, enhance: enh }, sr);
  return { voiceEffect: v, enhance: enh, sampleRate: sr, chain, impulse: Array.from(runChain(chain, impulse), x => Math.round(x * 1e9) / 1e9) };
})));
const chroma = chromaKeys.flatMap(key => chromaColors.map(rgb => ({ key, rgb, out: M.chromaKey(rgb[0], rgb[1], rgb[2], key) })));

function round<T>(o: T): T { return JSON.parse(JSON.stringify(o, (_k, v) => (typeof v === 'number' ? Math.round(v * 1e6) / 1e6 : v))); }

// ------------------------------------------------------------------ looks (filters)
const r4 = (v: number) => Math.round(v * 1e4) / 1e4;
/** 24×16 test picture: skin tones (shaded), colours, a grey ramp and a bright spot (for halation). */
function testImage(): K.Image {
  const w = 24, h = 16, d = new Float32Array(w * h * 3);
  const skins = [[241, 194, 167], [198, 134, 103], [110, 74, 52]], cols = [[120, 170, 230], [70, 120, 60], [200, 40, 40], [240, 200, 40]];
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    let c: number[];
    if (y < 6) c = skins[Math.floor(x / 8)]!.map(v => v * (0.8 + 0.3 * (1 - y / 6)));
    else if (y < 10) c = cols[Math.floor(x / 6)]!;
    else if (y < 13) { const v = (x / (w - 1)) * 255; c = [v, v, v]; }
    else c = (x > 16 && x < 21) ? [255, 250, 240] : [30, 30, 40];
    for (let k = 0; k < 3; k++) d[(y * w + x) * 3 + k] = Math.round(Math.min(255, c[k]!)) / 255;
  }
  return { width: w, height: h, data: d };
}
const pic = testImage();
const small = K.writeCube(5, 'test5', grade({ temp: 0.4, contrast: 0.2, shadows: ['#204060', 0.2], sat: -0.2 }));
const smallLut = K.parseCube(small);
const goldLut = K.parseCube(fs.readFileSync(path.join(repo, 'server/api/assets/lookpack/looks/film-gold.cube'), 'utf8'));
const M1 = M.colorMatrix({ exposure: 0.1, saturation: 0.2 }, { id: 'warm', amount: 0.5 }, FILTERS);
const renders: { name: string; look: K.Look; matrix: number[] | null; lut: string | null; frame: number; out: number[] }[] = [];
const addRender = (name: string, look: K.Look, o: { matrix?: number[] | null; lut?: string | null; frame?: number } = {}) => {
  const lut = o.lut === 'test5' ? smallLut : o.lut === 'pack:film-gold' ? goldLut : null;
  const out = K.renderLook(pic, look, { matrix: o.matrix ?? null, lut, frame: o.frame ?? 0, fps: 30 });
  renders.push({ name, look, matrix: o.matrix ?? null, lut: o.lut ?? null, frame: o.frame ?? 0, out: Array.from(out.data, r4) });
};
addRender('identity', {});
renders.push({ name: 'tone (highlights/shadows)', look: {}, matrix: null, lut: null, frame: 0, tone: { shadows: 0.6, highlights: -0.5 },
  out: Array.from(K.renderLook(pic, {}, { tone: { shadows: 0.6, highlights: -0.5 } }).data, r4) } as any);
addRender('matrix only', {}, { matrix: M1 });
addRender('curves', { curves: { rgb: [[0, 0.05], [0.3, 0.25], [0.7, 0.78], [1, 0.97]], b: [[0, 0.08], [1, 0.95]] } });
addRender('lut half strength + lift', { lut: 'pack:test5', strength: 0.5, lift: 0.6 }, { lut: 'test5' });
addRender('pack look film-gold', packLook('film-gold')!, { lut: 'pack:film-gold', frame: 3 });
addRender('sharpen + chromatic', { sharpen: 0.8, chromatic: 1 });
addRender('halation', { halation: { amount: 0.8, radius: 0.3, threshold: 0.6 } });
addRender('vignette dark + grain', { vignette: { amount: 0.6, size: 0.3, softness: 0.5 }, grain: { amount: 0.7, size: 1 } }, { frame: 7 });
addRender('vignette light + leak', { vignette: { amount: -0.5 }, leak: { kind: 'rose', amount: 0.7, angle: 140 } }, { frame: 45 });
addRender('everything', { lut: 'pack:test5', strength: 0.8, curves: { rgb: [[0, 0], [0.5, 0.55], [1, 1]] }, lift: 0.3, sharpen: 0.4, chromatic: 0.5,
  halation: { amount: 0.4 }, leak: { kind: 'amber', amount: 0.4 }, vignette: { amount: 0.4 }, grain: { amount: 0.4, size: 2 } }, { matrix: M1, lut: 'test5', frame: 12 });
const curvesCases = [[[0, 0], [1, 1]], [[0, 0.1], [0.25, 0.2], [0.5, 0.6], [0.75, 0.8], [1, 0.9]], [[0.1, 0], [0.4, 0.9], [0.45, 0.95], [0.9, 1]], [[0, 1], [0.5, 0.2], [1, 0]]] as K.CurvePoint[][];
const looks = {
  image: { width: pic.width, height: pic.height, data: Array.from(pic.data, r4) },
  matrix: M1,
  cubes: { test5: small },
  lutSamples: [...[[0, 0, 0], [1, 1, 1], [0.5, 0.25, 0.75], [0.13, 0.87, 0.42], [0.99, 0.01, 0.5]].map(c => ({ lut: 'test5', rgb: c, out: K.lutSample(smallLut, c[0]!, c[1]!, c[2]!).map(r4) })),
    ...[[0.2, 0.3, 0.4], [0.8, 0.6, 0.5], [0.95, 0.85, 0.75]].map(c => ({ lut: 'pack:film-gold', rgb: c, out: K.lutSample(goldLut, c[0]!, c[1]!, c[2]!).map(r4) }))],
  curves: curvesCases.map(pts => { const f = K.curveFn(pts)!; return { points: pts, samples: Array.from({ length: 21 }, (_, i) => [i / 20, r4(f(i / 20))]) }; }),
  hash: [[0, 0, 0], [1, 0, 0], [0, 1, 0], [5, 7, 3], [1023, 767, 59], [12345, 6789, 100000]].map(([x, y, f]) => ({ x, y, frame: f, v: K.hash01(x!, y!, f!) })),
  vignette: [{ amount: 0.5 }, { amount: 0.5, size: 0.2, softness: 0.3 }].map(v => ({ vignette: v, samples: [[0.5, 0.5], [0, 0], [1, 0.5], [0.25, 0.75], [0.9, 0.1]].map(([u, w]) => [u, w, r4(K.vignetteMask(v as K.Vignette, u!, w!))]) })),
  leak: (['warm', 'rainbow'] as K.LeakKind[]).map(kind => ({ leak: { kind, amount: 0.8, angle: 60 }, samples: [[0.5, 0.5, 0], [1, 0, 0], [0.9, 0.2, 2.5], [0, 1, 1]].map(([u, v, t]) => ({ u, v, t, out: K.leakColor({ kind, amount: 0.8, angle: 60 }, u!, v!, t!).map(r4) })) })),
  radii: [{ short: 16, sharpen: K.sharpenRadius(16), halation: K.halationRadius(16, { amount: 1, radius: 0.3 }), grain: K.grainCell(16, { amount: 1, size: 1 }) },
    { short: 1080, sharpen: K.sharpenRadius(1080), halation: K.halationRadius(1080, { amount: 1 }), grain: K.grainCell(1080, { amount: 1, size: 2 }) },
    { short: 1440, sharpen: K.sharpenRadius(1440), halation: K.halationRadius(1440, { amount: 1, radius: 1 }), grain: K.grainCell(1440, { amount: 1 }) }],
  badCubes: [
    { name: 'no size', text: '0 0 0\n' }, { name: 'too few', text: 'LUT_3D_SIZE 2\n0 0 0\n1 1 1\n' }, { name: 'size 65', text: 'LUT_3D_SIZE 65\n' },
    { name: '1D', text: 'LUT_1D_SIZE 16\n' }, { name: 'bad number', text: 'LUT_3D_SIZE 2\n' + '0 0 x\n'.repeat(8) }, { name: 'too many', text: 'LUT_3D_SIZE 2\n' + '0 0 0\n'.repeat(9) },
  ],
  goodCube: { text: '# a comment\nTITLE "tiny"\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\nLUT_3D_SIZE 2\n' + '0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n', size: 2, title: 'tiny' },
  renders,
  pack: { cubeSize: CUBE_SIZE, ids: [...LOOK_IDS] },
};
for (const b of looks.badCubes) { let ok = true; try { K.parseCube(b.text); } catch { ok = false; } if (ok) throw new Error(`bad cube "${b.name}" parsed`); }

// ------------------------------------------------------------------ JSON Patch (edit sessions)
const pp = (x: unknown) => JSON.parse(JSON.stringify(x));
const basePj = projects[8]!.project;
const patchPairs: { name: string; a: unknown; b: unknown }[] = [
  { name: 'same', a: { x: 1 }, b: { x: 1 } },
  { name: 'scalar change and added key', a: { x: 1, y: 'a' }, b: { x: 2, y: 'a', z: [1, 2] } },
  { name: 'removed key, nested', a: { o: { p: 1, q: { r: true } } }, b: { o: { q: { r: false } } } },
  { name: 'array same length', a: { l: [1, { k: 2 }, 3] }, b: { l: [1, { k: 5 }, 4] } },
  { name: 'array different length', a: { l: [1, 2, 3] }, b: { l: [1, 3] } },
  { name: 'type change and escapes', a: { 'a/b': 1, 't~x': { v: null } }, b: { 'a/b': '1', 't~x': { v: [null] } } },
  { name: 'root replace', a: [1], b: { not: 'an array' } },
  ...['trim', 'look', 'transition', 'add_hook'].map(op => {
    const ops: Record<string, unknown> = { trim: { op: 'trim', clipId: 'c1', inSec: 0.5, outSec: 9 }, look: { op: 'look', itemId: 'all', look: 'film-gold', strength: 0.6 },
      transition: { op: 'split', at: 4 }, add_hook: { op: 'add_hook', template: 'hook-question' } };
    return { name: `project: ${op}`, a: pp(basePj), b: applyOps(basePj, [ops[op] as never]).project };
  }),
];
const jsonpatch = patchPairs.map(c => { const d = diff(c.a, c.b); const back = applyPatch(c.a, d); if (JSON.stringify(back) !== JSON.stringify(c.b) && c.name !== 'same') throw new Error(`patch ${c.name}`); return { ...c, patch: d, inverse: diff(c.b, c.a) }; });

// Every op Claude can apply (apply_edit_ops), on one project: what the apps must decode, validate and play (2026-11-08 audit).
const opsBase = projects[8]!.project;
const opsFor: Record<string, unknown[]> = {
  trim: [{ op: 'trim', clipId: 'c1', inSec: 1, outSec: 8 }], split: [{ op: 'split', at: 4 }], delete: [{ op: 'split', at: 4 }, { op: 'delete', itemId: 'c2' }],
  move: [{ op: 'move', itemId: 't2', startSec: 6 }], speed: [{ op: 'speed', clipId: 'c1', curve: 'hero' }],
  add_text: [{ op: 'add_text', text: 'Hello', startSec: 7, durationSec: 2 }], add_hook: [{ op: 'add_hook', template: 'hook-stop' }],
  edit_text: [{ op: 'edit_text', itemId: 't1', text: 'New hook', style: { color: '#FFE600' } }],
  look: [{ op: 'look', itemId: 'all', look: 'film-gold', strength: 0.6, grain: { amount: 0.3 } }], adjust: [{ op: 'adjust', itemId: 'c1', exposure: 0.2, highlights: -0.3 }],
  transition: [{ op: 'split', at: 4 }, { op: 'transition', clipId: 'all', kind: 'whip', durationSec: 0.3 }],
  mask: [{ op: 'mask', itemId: 'p1', mask: { shape: 'circle', feather: 0.2 } }], transform: [{ op: 'transform', itemId: 'p1', transform: { x: 0.3 } }],
  keyframe: [{ op: 'keyframe', itemId: 'p1', prop: 'opacity', t: 1, v: 0.5, ease: 'easeOut' }], remove_keyframe: [{ op: 'remove_keyframe', itemId: 'p1', prop: 'scale', t: 0.5 }],
  volume: [{ op: 'volume', itemId: 'c1', volume: 0.6, fadeInSec: 0.5 }],
  duck: [{ op: 'add_music', asset: { upload: 'up_music', durationSec: 30 }, startSec: 0 }, { op: 'duck', levelDb: -12, attackSec: 0.2, releaseSec: 0.6 }],
  voice: [{ op: 'voice', itemId: 'c1', effect: 'radio', enhance: true }], add_music: [{ op: 'add_music', asset: { upload: 'up_music', durationSec: 30 }, startSec: 1 }],
  ratio: [{ op: 'ratio', ratio: '1:1' }],
  flip: [{ op: 'flip', itemId: 'p1', x: true }, { op: 'flip', itemId: 'i1', y: true }], freeze: [{ op: 'freeze', at: 2, durationSec: 1.2 }],
  blend: [{ op: 'blend', itemId: 'p1', mode: 'overlay' }], fill: [{ op: 'fill', kind: 'blur', color: '#202020' }], patch: [{ op: 'patch', patch: [{ op: 'replace', path: '/canvas/background', value: '#111111' }] }],
};
for (const n of OP_NAMES) if (n !== 'caption_style' && !opsFor[n]?.length) throw new Error(`ops fixture: no case for ${n}`);
const opsFixture = OP_NAMES.map(name => {
  // caption_style needs captions: it runs on the first project that has them.
  const base = name === 'caption_style' ? projects.find(x => x.project.tracks.some(t => t.kind === 'caption' && t.caption))!.project : opsBase;
  const ops = name === 'caption_style' ? [{ op: 'caption_style', preset: 'karaoke', wordsPerPage: 2 }] : opsFor[name]!;
  return { name, ops, project: applyOps(base, ops as never).project };
});

// Wave 1 reference functions.
const RGB = (r: number, g: number, b: number) => [r, g, b] as [number, number, number];
const blendCases = M.BLEND_MODES.flatMap(mode => [
  { mode, top: RGB(0.2, 0.5, 0.9), below: RGB(0.6, 0.3, 0.1), a: 1 },
  { mode, top: RGB(0.8, 0.1, 0.45), below: RGB(0.2, 0.7, 0.5), a: 1 },
  { mode, top: RGB(0.6, 0.6, 0.6), below: RGB(0.1, 0.24, 0.9), a: 0.5 },
  { mode, top: RGB(1, 0, 0.5), below: RGB(0.5, 0.5, 0.5), a: 0 },
].map(c => ({ ...c, out: M.blendPixel(c.mode, c.top, c.below, c.a) })));
const cornerCases = [
  { canvas: { width: 1080, height: 1920 }, w: 720, h: 1280, fit: 'contain' as M.Fit, t: {} },
  { canvas: { width: 1080, height: 1920 }, w: 720, h: 1280, fit: 'contain' as M.Fit, t: { flipX: true } },
  { canvas: { width: 1080, height: 1920 }, w: 512, h: 512, fit: 'contain' as M.Fit, t: { x: 0.7, y: 0.3, scale: 0.5, rotation: 15, flipX: true } },
  { canvas: { width: 1920, height: 1080 }, w: 1080, h: 1920, fit: 'cover' as M.Fit, t: { flipX: true, flipY: true, rotation: -90 } },
].map(c => ({ ...c, corners: M.itemCorners(c.canvas, c.w, c.h, c.fit, c.t) }));
const tiny = Array.from({ length: 4 * 3 * 3 }, (_, i) => Math.round(((i * 37) % 100) / 100 * 1000) / 1000);
// Colour keyframes (M): adjustAt and the colour matrix it gives, over time.
const colorKeyItems = [
  { adjust: { exposure: 0.1, saturation: 0.2 }, keyframes: { exposure: [{ t: 0, v: -0.5 }, { t: 2, v: 0.5, ease: 'easeInOut' }] } },
  { adjust: { tint: 0.3 }, filter: { id: 'warm', amount: 0.5 }, keyframes: { temperature: [{ t: 0.5, v: -1 }, { t: 1.5, v: 1 }], tint: [{ t: 1, v: -0.4 }] } },
  // A static field next to keyed ones stays; a key that comes out 0 is written as 0.
  { adjust: { saturation: 0.3, contrast: -0.1 }, keyframes: { exposure: [{ t: 0, v: 0.4 }, { t: 1, v: 0 }], contrast: [{ t: 2, v: 0.25 }] } },
  // An image item's tint keys (adjustAt reads only adjust and keyframes).
  { asset: 'img', startSec: 0, durationSec: 3, adjust: undefined, keyframes: { tint: [{ t: 0, v: 0.6, ease: 'hold' }, { t: 1.25, v: -0.6 }] } },
] as unknown as { adjust?: M.Adjust; filter?: M.FilterRef; keyframes: M.Keyframes }[];
// Auto adjust: synthetic frames (deterministic) → the suggestion.
const frame = (n: number, f: (k: number) => [number, number, number]) => Array.from({ length: n }, (_, k) => f(k)).flat().map(v => Math.round(v * 1e4) / 1e4);
const autoAdjustCases = [
  { name: 'dark warm green', rgb: frame(300, k => { const v = 0.15 + 0.1 * (k % 10) / 10; return [v * 1.2, v * 1.15, v * 0.8]; }) },
  { name: 'balanced grey ramp', rgb: frame(200, k => { const v = (k % 100) / 99 * 0.92 + 0.04; return [v, v, v]; }), base: { highlights: 0.2, tint: 0.5 } },
  { name: 'bright saturated blue', rgb: frame(150, k => [0.1 + 0.002 * k, 0.4, 0.95]) },
  { name: 'black', rgb: frame(16, () => [0, 0, 0]) },
].map(c => ({ ...c, out: M.autoAdjust(c.rgb, c.base as M.Adjust | undefined) }));
const colorKeys = colorKeyItems.map(item => ({ item, samples: [0, 0.5, 1, 1.25, 2, 3].map(t => { const adjust = M.adjustAt(item, t); return { t, adjust: adjust ?? null, matrix: M.colorMatrix(adjust, item.filter, FILTERS) }; }) }));
// Style kits (M): kitOf every fixture project; applyKit of three kits onto three projects; validateKit cases.
const kitList = [
  { version: 1, look: { lut: 'pack:film-gold', strength: 0.6, grain: { amount: 0.2 } }, filter: { id: 'warm', amount: 0.5 }, adjust: { contrast: 0.1, tint: -0.2 },
    transition: { kind: 'whip', durationSec: 0.6 }, captionStyle: CAPTION_STYLES.neon, textStyle: HOOKS[3]!.style, background: '#202020', fill: 'blur' },
  { version: 1, transition: { kind: 'fade', durationSec: 2 } },
  kitOf(projects[8]!.project),
] as unknown[];
const kitProblem = (k: unknown) => { try { validateKit(k, FILTERS, LOOK_IDS, new Set()); return null; } catch (e) { return (e as M.EditProblem).field; } };
const kits = {
  kitOf: projects.map(x => ({ name: x.name, kit: kitOf(x.project) })),
  apply: [1, 2, 9].flatMap(pi => kitList.map((kit, ki) => ({ project: pi, kit: ki, result: applyKit(projects[pi]!.project, kit as never) }))),
  kits: kitList,
  validate: [
    { version: 1 }, kitList[0], { version: 2 }, { version: 1, mask: {} }, { version: 1, adjust: { tint: 2 } }, { version: 1, transition: { kind: 'fade', durationSec: 5 } },
    { version: 1, transition: { kind: 'swirl', durationSec: 0.5 } }, { version: 1, look: { lut: 'cube' } }, { version: 1, captionStyle: { ...CAPTION_STYLES.pop, highlightColor: 'yellow' } },
    { version: 1, textStyle: { ...HOOKS[0]!.style, sizePct: 9 } }, { version: 1, fill: 'mirror' }, { version: 1, background: 'red' }, { version: 1, filter: { id: 'nope', amount: 1 } },
    { version: 1, look: { vignette: { amount: 3 } } }, 'kit',
  ].map(kit => ({ kit, field: kitProblem(kit) })),
};
const wave1 = projects[projects.length - 1]!.project;
const holdClip = (wave1.tracks[0]!.items[1]) as M.VideoClip;
const holdFns = { clip: holdClip, length: M.clipLength(holdClip), sourceAt: [0, 0.7, 1.5].map(t => ({ t, src: M.clipSourceAt(holdClip, t) })), timeAt: M.clipTimeAt(holdClip, 4.05),
  cuts: [{ cuts: [{ startSec: 3.9, endSec: 4.2 }], project: M.applyCuts(wave1, 'src', [{ startSec: 3.9, endSec: 4.2 }]) }, { cuts: [{ startSec: 5, endSec: 6 }], project: M.applyCuts(wave1, 'src', [{ startSec: 5, endSec: 6 }]) }] };
const wave1Fns = {
  blend: blendCases, corners: cornerCases, hold: holdFns,
  blurFill: { w: 4, h: 3, radius: 1, rgb: tiny, out: M.blurFill(tiny, 4, 3, 1), darken: M.BLUR_FILL_DARKEN,
    radii: [{ width: 1080, height: 1920 }, { width: 720, height: 1280 }, { width: 2160, height: 3840 }, { width: 16, height: 16 }].map(c => ({ ...c, radius: M.blurFillRadius(c) })),
    clipAt: [0, 3.5, 3.79, 3.8, 3.81, 4.2, 5.3, 5.5, 8].map(t => ({ t, at: M.blurFillClip(wave1, t) })) },
};

const files: Record<string, unknown> = {
  'jsonpatch.json': jsonpatch,
  'ops.json': opsFixture,
  'looks.json': looks,
  'presets.json': { filters: FILTERS, captionStyles: CAPTION_STYLES, hooks: HOOKS, captionStyleLabels: CAPTION_STYLE_LABELS, transitionLabels: TRANSITION_LABELS },
  'projects.json': projects.map(x => ({ ...x, expect: expectFor(x.project) })),
  'validation.json': validation,
  'functions.json': { kits, colorKeys, autoAdjust: autoAdjustCases, keyframes, transitions, anims, colors, cuts: cutsCases, v1: v1cases, suggestCuts: suggest, chroma, masks, tone, speedCurves, speedPresets: presetsTable, voice, wave1: wave1Fns, duckTimes: [{ under: ['speech'] }, { fadeSec: 0.4, under: ['speech'] }, { attackSec: 0.2, releaseSec: 0.6, under: ['voice'] }].map(d => ({ duck: d, times: M.duckTimes(d as M.Duck) })) },
};
for (const dir of FIXTURE_DIRS) {
  fs.mkdirSync(dir, { recursive: true });
  for (const [name, body] of Object.entries(files)) fs.writeFileSync(path.join(dir, name), JSON.stringify(body, null, 1) + '\n');
}
console.log(`wrote ${Object.keys(files).length} fixtures to ${FIXTURE_DIRS.length} places`);
