// Writes the shared editor v2 fixtures (plans/video-editor.md "Editor v2") from the reference implementation, into
// test/fixtures/editor and the Android/Mac test resource copies. Run: npx tsx scripts/editor-fixtures.ts
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as M from '../src/editor/model.js';
import { CAPTION_STYLES, FILTERS, HOOKS } from '../src/editor/presets.js';
import { suggestCuts } from '../src/editor/cuts.js';

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
];

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
  { name: 'speed too fast', project: mut(p => (p.tracks[0].items[0].speed = 8)), ok: false, field: 'edits.tracks.0.items.0.speed' },
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
  { name: 'caption word bad', project: (() => { const p = JSON.parse(JSON.stringify(projects[3]!.project)); p.tracks[1].caption.words[2].endSec = 0.1; return p; })(), ok: false, field: 'edits.tracks.1.caption.words.2.endSec' },
];
for (const v of validation) {
  let got: { ok: boolean; field?: string };
  try { M.validate(v.project as M.EditProject, FILTERS); got = { ok: true }; } catch (e) { got = { ok: false, field: (e as M.EditProblem).field }; }
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

function round<T>(o: T): T { return JSON.parse(JSON.stringify(o, (_k, v) => (typeof v === 'number' ? Math.round(v * 1e6) / 1e6 : v))); }

const files: Record<string, unknown> = {
  'presets.json': { filters: FILTERS, captionStyles: CAPTION_STYLES, hooks: HOOKS },
  'projects.json': projects.map(x => ({ ...x, expect: expectFor(x.project) })),
  'validation.json': validation,
  'functions.json': { keyframes, transitions, anims, colors, cuts: cutsCases, v1: v1cases, suggestCuts: suggest },
};
for (const dir of FIXTURE_DIRS) {
  fs.mkdirSync(dir, { recursive: true });
  for (const [name, body] of Object.entries(files)) fs.writeFileSync(path.join(dir, name), JSON.stringify(body, null, 1) + '\n');
}
console.log(`wrote ${Object.keys(files).length} fixtures to ${FIXTURE_DIRS.length} places`);
