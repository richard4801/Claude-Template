// The server render draws every field of the edit model or lists it in `unsupported` (the owner's rule: nothing is lost
// silently). For every field, in every place it can appear, the project is planned with and without it: the ffmpeg
// plan must change, or `unsupported` must name what is left out. The key tables are typed against model.ts, so a new
// field in the model fails `tsc` here until it is drawn or listed.
import { describe, expect, it } from 'vitest';
import type { Look } from '../src/editor/look.js';
import * as M from '../src/editor/model.js';
import { planRender } from '../src/editor/render.js';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

type Obj = Record<string, unknown>;
/** A probe: `prep` sets up both projects (e.g. gives the clip a mask), `mut` then sets the field on one of them. */
type Probe = { prep?: (o: Obj, p: M.EditProject) => void; mut: (o: Obj, p: M.EditProject) => void };
/** Not drawn by design: ids, labels, references the caller resolves into `files`, metadata. The reason is the value. */
type Meta = { meta: string };
type Entry = Probe | Meta;
type Table<T> = { [K in keyof Required<T>]: Entry };
const set = (k: string, v: unknown): Probe => ({ mut: o => { o[k] = v; } });
const meta = (why: string): Meta => ({ meta: why });

const base = (): M.EditProject => ({
  version: 2, sourceTakeId: 'ta', canvas: { width: 1080, height: 1920, fps: 30, background: '#000000' },
  assets: [
    { id: 'a', kind: 'video', take: 'ta', durationSec: 3 }, { id: 'b', kind: 'video', take: 'tb', durationSec: 3 },
    { id: 'mt', kind: 'video', upload: 'up_mt', durationSec: 3 }, { id: 'im', kind: 'image', upload: 'up_im' },
    { id: 'm', kind: 'audio', upload: 'up_m', durationSec: 6 }, { id: 'v', kind: 'audio', upload: 'up_v', durationSec: 6 },
    { id: 'lut', kind: 'lut', upload: 'up_lut' }, { id: 'font', kind: 'font', upload: 'up_font' },
  ],
  tracks: [
    { id: 'main', kind: 'main', items: [
      { id: 'c1', asset: 'a', inSec: 0, outSec: 1.5, speed: 1 } as M.VideoClip,
      { id: 'c2', asset: 'b', inSec: 0, outSec: 1.5, speed: 1, transitionIn: { kind: 'fade', durationSec: 0.3 } } as M.VideoClip,
    ] },
    { id: 'ov', kind: 'video', items: [{ id: 'o1', asset: 'b', inSec: 0, outSec: 1, speed: 1, startSec: 0.5 } as M.VideoClip] },
    { id: 'img', kind: 'image', items: [{ id: 'i1', asset: 'im', startSec: 0.2, durationSec: 1 } as M.ImageItem] },
    { id: 'adj', kind: 'adjust', items: [{ id: 'a1', startSec: 0.2, durationSec: 1, adjust: { saturation: -0.5 } } as M.AdjustItem] },
    { id: 'tx', kind: 'text', items: [{ id: 't1', startSec: 0.2, durationSec: 1, text: 'Hello there', style: { font: 'sans', weight: 400, sizePct: 0.06, color: '#FFFFFF', align: 'center' } } as M.TextItem] },
    { id: 'cap', kind: 'caption', items: [], caption: { asset: 'a', words: [{ text: 'one', startSec: 0.1, endSec: 0.4 }, { text: 'two', startSec: 0.5, endSec: 0.8 }, { text: 'three', startSec: 0.9, endSec: 1.2 }],
      style: { font: 'sans', weight: 700, sizePct: 0.05, color: '#FFFFFF', align: 'center', preset: 'plain', highlightColor: '#FFD400' } } },
    { id: 'mus', kind: 'music', items: [{ id: 'mu', asset: 'm', startSec: 0, inSec: 0, outSec: 2 } as M.AudioClip] },
    { id: 'voi', kind: 'voice', items: [{ id: 'vo', asset: 'v', startSec: 0.5, inSec: 0, outSec: 1 } as M.AudioClip] },
    { id: 'sfx', kind: 'sfx', items: [{ id: 'sx', asset: 'v', startSec: 1, inSec: 0, outSec: 0.5 } as M.AudioClip] },
  ],
});
const files: Record<string, string> = { a: '/x/a.mp4', b: '/x/b.mp4', mt: '/x/mt.mp4', im: '/x/im.png', m: '/x/m.m4a', v: '/x/v.m4a', lut: '/x/l.cube', font: '/x/f.ttf' };
const sizes = { a: { width: 800, height: 1280, hasAudio: true }, b: { width: 1280, height: 720, hasAudio: true }, mt: { width: 720, height: 1280, hasAudio: false },
  im: { width: 800, height: 800, hasAudio: false }, m: { width: 0, height: 0, hasAudio: true }, v: { width: 0, height: 0, hasAudio: true } };

function plan(p: M.EditProject) {
  const r = planRender(p, files, sizes, '/x/out.mp4', { maxSide: 640 });
  // Text stills, colour cubes, masks and still lists live in temporary files: their contents are part of the plan, their
  // names are not.
  const contents = r.temp.filter(t => fs.existsSync(t) && fs.statSync(t).isFile()).map(t => t.endsWith('.gray') ? createHash('sha1').update(fs.readFileSync(t)).digest('hex')
    : /\.(cube|ffconcat)$/.test(t) ? fs.readFileSync(t, 'utf8') : '');
  const texts = [...contents, ...r.stills.map(x => JSON.stringify([x.svg, x.crop])), JSON.stringify(r.sprites)].join('\n');
  for (const t of r.temp) fs.rmSync(t, { force: true, recursive: true });
  const tmp = (x: string) => x.replace(/muse-[a-z]+-[^/'"\\\s]+/g, 'TEMP');
  return { args: tmp(JSON.stringify([r.chunks, r.joinArgs, r.soundArgs])) + tmp(texts), unsupported: new Set(r.unsupported) };
}

// ------------------------------------------------------------------ the model's shapes
const track = (id: string) => (p: M.EditProject) => p.tracks.find(t => t.id === id)! as unknown as Obj;
const item = (id: string) => (p: M.EditProject) => p.tracks.flatMap(t => t.items).find(i => i.id === id)! as unknown as Obj;
const caption = (p: M.EditProject) => p.tracks.find(t => t.id === 'cap')!.caption! as unknown as Obj;

const KF: Record<M.KfProp, [number, number]> = { x: [0.3, 0.7], y: [0.3, 0.7], scale: [1, 1.6], rotation: [0, 30], opacity: [1, 0.4], volume: [1, 0.3],
  exposure: [0, 0.5], contrast: [0, 0.4], saturation: [0, -0.6], temperature: [0, 0.5], tint: [0, 0.5],
  maskX: [0.4, 0.6], maskY: [0.4, 0.6], maskWidth: [0.3, 0.6], maskHeight: [0.3, 0.6], maskRotation: [0, 40], maskFeather: [0.1, 0.4],
  vignette: [0, 0.6], grain: [0, 0.5], leak: [0, 0.5] };
const kfProbe = (prop: M.KfProp): Probe => ({
  prep: o => { if (M.MASK_KF_PROPS.includes(prop as M.MaskKfProp)) o.mask = { shape: 'rect' }; },
  mut: o => { o.keyframes = { ...(o.keyframes as Obj ?? {}), [prop]: [{ t: 0, v: KF[prop][0] }, { t: 0.5, v: KF[prop][1] }] }; },
});
const keyframeFields: Table<M.Keyframe> = {
  t: { prep: o => { o.keyframes = { scale: [{ t: 0, v: 1 }, { t: 0.5, v: 1.5 }] }; }, mut: o => { (o.keyframes as { scale: M.Keyframe[] }).scale[1]!.t = 0.8; } },
  v: { prep: o => { o.keyframes = { scale: [{ t: 0, v: 1 }, { t: 0.5, v: 1.5 }] }; }, mut: o => { (o.keyframes as { scale: M.Keyframe[] }).scale[1]!.v = 1.8; } },
  ease: { prep: o => { o.keyframes = { scale: [{ t: 0, v: 1 }, { t: 0.5, v: 1.5 }] }; }, mut: o => { (o.keyframes as { scale: M.Keyframe[] }).scale[0]!.ease = 'easeIn'; } },
};
const sub = (key: string, init: Obj, field: string, v: unknown): Probe => ({ prep: o => { o[key] = { ...init }; }, mut: o => { (o[key] as Obj)[field] = v; } });
const transformFields: Table<M.Transform> = { x: set('transform', { x: 0.3 }), y: set('transform', { y: 0.3 }), scale: set('transform', { scale: 1.5 }),
  rotation: set('transform', { rotation: 20 }), flipX: set('transform', { flipX: true }), flipY: set('transform', { flipY: true }) };
const cropFields: Table<M.Crop> = { left: set('crop', { left: 0.1 }), top: set('crop', { top: 0.1 }), right: set('crop', { right: 0.1 }), bottom: set('crop', { bottom: 0.1 }) };
const adjustFields: Table<M.Adjust> = { exposure: set('adjust', { exposure: 0.5 }), contrast: set('adjust', { contrast: 0.3 }), saturation: set('adjust', { saturation: 0.3 }),
  temperature: set('adjust', { temperature: 0.3 }), tint: set('adjust', { tint: 0.3 }), highlights: set('adjust', { highlights: 0.3 }), shadows: set('adjust', { shadows: 0.3 }) };
const filterFields: Table<M.FilterRef> = { id: sub('filter', { id: 'mono', amount: 1 }, 'id', 'warm'), amount: sub('filter', { id: 'mono', amount: 1 }, 'amount', 0.4) };
const maskFields: Table<M.Mask> = { shape: sub('mask', { shape: 'rect' }, 'shape', 'circle'), x: sub('mask', { shape: 'rect' }, 'x', 0.3), y: sub('mask', { shape: 'rect' }, 'y', 0.3),
  width: sub('mask', { shape: 'rect' }, 'width', 0.3), height: sub('mask', { shape: 'rect' }, 'height', 0.3), rotation: sub('mask', { shape: 'rect' }, 'rotation', 30),
  feather: sub('mask', { shape: 'rect' }, 'feather', 0.4), invert: sub('mask', { shape: 'rect' }, 'invert', true) };
const lookFields: Table<Look> = { lut: set('look', { lut: 'pack:bw-classic' }), strength: sub('look', { lut: 'pack:bw-classic' }, 'strength', 0.5),
  curves: set('look', { curves: { rgb: [[0, 0.1], [1, 0.9]] } }), hsl: set('look', { hsl: { red: { sat: -0.5 } } }), lift: set('look', { lift: 0.3 }), sharpen: set('look', { sharpen: 0.5 }), chromatic: set('look', { chromatic: 0.5 }),
  halation: set('look', { halation: { amount: 0.5 } }), leak: set('look', { leak: { kind: 'warm', amount: 0.5 } }), vignette: set('look', { vignette: { amount: 0.5 } }),
  grain: set('look', { grain: { amount: 0.5 } }) };
const animFields = (k: 'animIn' | 'animOut'): Table<M.Anim> => ({ kind: set(k, { kind: 'fade', durationSec: 0.3 }), durationSec: sub(k, { kind: 'fade', durationSec: 0.3 }, 'durationSec', 0.6) });
const loopFields: Table<M.AnimLoop> = { kind: set('animLoop', { kind: 'pulse', periodSec: 1 }), periodSec: sub('animLoop', { kind: 'pulse', periodSec: 1 }, 'periodSec', 0.5),
  amount: sub('animLoop', { kind: 'pulse', periodSec: 1 }, 'amount', 0.9) };
const chromaFields: Table<M.Chroma> = { color: set('chroma', { color: '#00FF00' }), similarity: sub('chroma', { color: '#00FF00' }, 'similarity', 0.2),
  smoothness: sub('chroma', { color: '#00FF00' }, 'smoothness', 0.3), spill: sub('chroma', { color: '#00FF00' }, 'spill', 0.2) };
const matteFields: Table<M.AlphaMatte> = { asset: set('alphaMatte', { asset: 'mt' }), invert: sub('alphaMatte', { asset: 'mt' }, 'invert', true) };
const curveFields: Table<M.SpeedCurve> = { preset: meta('a label: the points are what plays'), points: set('speedCurve', { preset: 'custom', points: [[0, 1], [0.5, 3], [1, 1]] }) };
const transitionFields: Table<M.Transition> = { kind: sub('transitionIn', { kind: 'fade', durationSec: 0.3 }, 'kind', 'slideLeft'),
  durationSec: sub('transitionIn', { kind: 'fade', durationSec: 0.3 }, 'durationSec', 0.5) };

const visualFields = (kfs: M.KfProp[], fit: M.Fit = 'contain') => ({
  fit: set('fit', fit), opacity: set('opacity', 0.5),
  ...nest('transform', transformFields), ...nest('crop', cropFields), ...nest('adjust', adjustFields), ...nest('filter', filterFields),
  ...nest('mask', maskFields), ...nest('look', lookFields), ...nest('keyframe', keyframeFields),
  ...Object.fromEntries(kfs.map(k => [`keyframes.${k}`, kfProbe(k)])),
});
function nest(prefix: string, t: Record<string, Entry>): Record<string, Entry> { return Object.fromEntries(Object.entries(t).map(([k, v]) => [`${prefix}.${k}`, v])); }

const CLIP_KFS: M.KfProp[] = ['x', 'y', 'scale', 'rotation', 'opacity', 'volume', ...M.COLOR_KF_PROPS, ...M.MASK_KF_PROPS, ...M.LOOK_KF_PROPS];
// The top-level keys of each item type (nested objects are probed through the tables above; `nested` marks them).
const nested: Entry = meta('probed field by field');
const clipKeys: Table<M.VideoClip> = {
  id: meta('an id'), asset: set('asset', 'mt'), inSec: set('inSec', 0.5), outSec: set('outSec', 1.2), speed: set('speed', 2), speedCurve: nested, startSec: set('startSec', 0.2),
  volume: set('volume', 0.5), muted: set('muted', true), fadeInSec: set('fadeInSec', 0.3), fadeOutSec: set('fadeOutSec', 0.6), audioAsset: set('audioAsset', 'm'),
  effect: meta('effects library (2026-11-09): reference in effects.ts; the render follows (WS16)'),
  chroma: nested, transitionIn: nested, alphaMatte: nested, holdSec: { mut: o => { o.holdSec = 1; o.speed = 1; } }, blend: set('blend', 'screen'),
  animIn: nested, animOut: nested, animLoop: nested, voiceEffect: set('voiceEffect', 'radio'), enhance: set('enhance', true),
  fit: nested, transform: nested, crop: nested, opacity: nested, keyframes: nested, filter: nested, adjust: nested, look: nested, mask: nested,
};
const clipFields = (main: boolean) => ({
  ...Object.fromEntries(Object.entries(clipKeys).filter(([, v]) => !('meta' in v && v === nested))),
  ...visualFields(CLIP_KFS, main ? 'contain' : 'cover'), ...nest('chroma', chromaFields), ...nest('alphaMatte', matteFields), ...nest('speedCurve', curveFields),
  ...nest('animIn', animFields('animIn')), ...nest('animOut', animFields('animOut')),
  ...(main ? { 'startSec': meta('main clips play back to back (validation refuses startSec)'), 'blend': meta('overlay tracks only (validation refuses it on main)') }
    : { ...nest('animLoop', loopFields) }),
});
const imageKeys: Table<M.ImageItem> = { id: meta('an id'), asset: set('asset', 'im'), startSec: set('startSec', 0.4), durationSec: set('durationSec', 0.5), blend: set('blend', 'multiply'),
  animIn: nested, animOut: nested, animLoop: nested, fit: nested, transform: nested, crop: nested, opacity: nested, keyframes: nested, filter: nested, adjust: nested, look: nested, mask: nested,
  transitionIn: meta('overlay cross-dissolve (2026-11-09): needs a previous item it overlaps; the render follows (WS16)'),
  effect: meta('effects library (2026-11-09): reference in effects.ts; the render follows (WS16)') };
const imageFields = { startSec: imageKeys.startSec, durationSec: imageKeys.durationSec, blend: imageKeys.blend,
  ...visualFields(['x', 'y', 'scale', 'rotation', 'opacity', ...M.COLOR_KF_PROPS, ...M.MASK_KF_PROPS, ...M.LOOK_KF_PROPS], 'cover'),
  ...nest('animIn', animFields('animIn')), ...nest('animOut', animFields('animOut')), ...nest('animLoop', loopFields) };

const styleKeys = (k: string): Table<M.TextStyle> => {
  const s = (f: string, v: unknown): Probe => ({ mut: o => { (o[k] as Obj)[f] = v; } });
  // Alignment shows only between lines of different lengths (the block is centred on the item).
  const narrow = (o: Obj) => { (o[k] as Obj).maxWidthPct = 0.12; };
  return { font: s('font', 'serif'), weight: s('weight', 900), sizePct: s('sizePct', 0.1), color: s('color', '#FF0000'), align: { prep: narrow, mut: o => { (o[k] as Obj).align = 'left'; } }, maxWidthPct: s('maxWidthPct', 0.3),
    lineHeight: s('lineHeight', 1.8), letterSpacing: s('letterSpacing', 0.2), uppercase: s('uppercase', true), stroke: s('stroke', { color: '#000000', widthPct: 0.1 }),
    shadow: s('shadow', { color: '#000000', opacity: 0.6, blurPct: 0.2, dyPct: 0.1 }), background: s('background', { color: '#000000', opacity: 0.6, paddingPct: 0.2, radiusPct: 0.3 }),
    fontAsset: s('fontAsset', 'font') };
};
const styleParts = (k: string) => {
  const s2 = (f: string, init: Obj, g: string, v: unknown): Probe => ({ prep: o => { (o[k] as Obj)[f] = { ...init }; }, mut: o => { ((o[k] as Obj)[f] as Obj)[g] = v; } });
  const sh = { color: '#000000', opacity: 0.6, blurPct: 0.2, dyPct: 0.1 }, bg = { color: '#000000', opacity: 0.6, paddingPct: 0.2, radiusPct: 0.3 }, st = { color: '#000000', widthPct: 0.1 };
  return {
    'stroke.color': s2('stroke', st, 'color', '#FF0000'), 'stroke.widthPct': s2('stroke', st, 'widthPct', 0.2),
    'shadow.color': s2('shadow', sh, 'color', '#FF0000'), 'shadow.opacity': s2('shadow', sh, 'opacity', 0.2), 'shadow.blurPct': s2('shadow', sh, 'blurPct', 0.6), 'shadow.dyPct': s2('shadow', sh, 'dyPct', -0.2),
    'background.color': s2('background', bg, 'color', '#FF0000'), 'background.opacity': s2('background', bg, 'opacity', 0.2), 'background.paddingPct': s2('background', bg, 'paddingPct', 0.5),
    'background.radiusPct': s2('background', bg, 'radiusPct', 0.8),
  } satisfies Record<`stroke.${keyof NonNullable<M.TextStyle['stroke']>}` | `shadow.${keyof NonNullable<M.TextStyle['shadow']>}` | `background.${keyof NonNullable<M.TextStyle['background']>}`, Entry>;
};
const textKeys: Table<M.TextItem> = { id: meta('an id'), startSec: set('startSec', 0.4), durationSec: set('durationSec', 0.5), text: set('text', 'Another line of words'), style: nested,
  transform: nested, opacity: set('opacity', 0.5), keyframes: nested, animIn: nested, animOut: nested, animLoop: nested, template: meta('the template it came from (a label)') };
const textFields = { startSec: textKeys.startSec, durationSec: textKeys.durationSec, text: textKeys.text, opacity: textKeys.opacity,
  ...nest('style', { ...styleKeys('style'), ...styleParts('style') }), ...nest('transform', transformFields), ...nest('keyframe', keyframeFields),
  ...Object.fromEntries((['x', 'y', 'scale', 'rotation', 'opacity'] as M.KfProp[]).map(k => [`keyframes.${k}`, kfProbe(k)])),
  ...nest('animIn', { ...animFields('animIn'), typewriter: set('animIn', { kind: 'typewriter', durationSec: 0.5 }) }), ...nest('animOut', animFields('animOut')), ...nest('animLoop', loopFields),
  'animLoop.kinds': { mut: (o: Obj) => { o.animLoop = { kind: 'spin', periodSec: 1 }; } } };

const captionStyleKeys: Table<Omit<M.CaptionStyle, keyof M.TextStyle>> = { preset: { mut: o => { (o.style as Obj).preset = 'karaoke'; } },
  highlightColor: { prep: o => { (o.style as Obj).preset = 'karaoke'; }, mut: o => { (o.style as Obj).highlightColor = '#00FF00'; } },
  y: { mut: o => { (o.style as Obj).y = 0.3; } }, wordsPerPage: { mut: o => { (o.style as Obj).wordsPerPage = 1; } },
  maxLines: { prep: o => { (o.style as Obj).maxWidthPct = 0.1; }, mut: o => { (o.style as Obj).maxLines = 1; } } };
const captionKeys: Table<M.CaptionTrack> = { asset: set('asset', 'b'), words: set('words', [{ text: 'hey', startSec: 0.2, endSec: 0.9 }]), style: nested,
  language: meta('which language the words are in (the words are what is drawn)'), original: meta('the untranslated words, kept to switch back; not drawn') };
const wordKeys: Table<M.CaptionWord> = { text: { mut: o => { (o.words as Obj[])[0]!.text = 'uno'; } }, startSec: { mut: o => { (o.words as Obj[])[0]!.startSec = 0.2; } },
  endSec: { mut: o => { (o.words as Obj[])[2]!.endSec = 1.5; } } }; // the page's tail
const captionFields = { asset: captionKeys.asset, words: captionKeys.words, ...nest('word', wordKeys),
  ...nest('style', Object.fromEntries(Object.entries({ ...styleKeys('style'), ...styleParts('style') }).filter(([k]) => k !== 'fontAsset'))), ...nest('style', captionStyleKeys) };

const audioKeys: Table<M.AudioClip> = { id: meta('an id'), asset: set('asset', 'mt'), strongBeats: meta('beat marks for snapping (not heard)'), beats: meta('beat marks for snapping (not heard)'),
  startSec: set('startSec', 0.3), inSec: set('inSec', 0.5), outSec: set('outSec', 1.5), speed: set('speed', 1.5), volume: set('volume', 0.5), muted: set('muted', true),
  fadeInSec: set('fadeInSec', 0.3), fadeOutSec: set('fadeOutSec', 0.3), keyframes: { mut: o => { o.keyframes = { volume: [{ t: 0, v: 1 }, { t: 0.5, v: 0.2 }] }; } },
  voiceEffect: set('voiceEffect', 'phone'), enhance: set('enhance', true) };
const adjustItemKeys: Table<M.AdjustItem> = { id: meta('an id'), startSec: set('startSec', 0.5), durationSec: set('durationSec', 0.4), adjust: nested, filter: nested, keyframes: nested,
  opacity: set('opacity', 0.5) };
const adjustItemFields = { startSec: adjustItemKeys.startSec, durationSec: adjustItemKeys.durationSec, opacity: adjustItemKeys.opacity,
  ...nest('adjust', Object.fromEntries(Object.entries(adjustFields).filter(([k]) => k !== 'highlights' && k !== 'shadows'))), ...nest('filter', filterFields),
  ...Object.fromEntries((['opacity', ...M.COLOR_KF_PROPS] as M.KfProp[]).map(k => [`keyframes.${k}`, kfProbe(k)])) };

const duckKeys: Table<M.Duck> = { level: sub('duck', { under: ['voice'] }, 'level', 0.1), fadeSec: sub('duck', { under: ['voice'] }, 'fadeSec', 1), attackSec: sub('duck', { under: ['voice'] }, 'attackSec', 1),
  releaseSec: sub('duck', { under: ['voice'] }, 'releaseSec', 1), under: set('duck', { under: ['voice'] }) };
const trackKeys = (kind: M.TrackKind): Partial<Table<M.Track>> => {
  const audible = ['main', 'video', 'music', 'voice', 'sfx'].includes(kind), visible = ['main', 'video', 'image', 'text', 'caption', 'adjust'].includes(kind);
  return { ...(audible ? { muted: set('muted', true), volume: set('volume', 0.5) } : {}), ...(visible ? { hidden: set('hidden', true) } : {}) };
};
const allTrackKeys: Table<M.Track> = { id: meta('an id'), kind: meta('which kind of track (probed per kind)'), name: meta('a label'), muted: nested, hidden: nested, volume: nested,
  items: meta('probed item by item'), caption: meta('probed field by field'), duck: meta('probed field by field') };
const canvasKeys: Table<M.Canvas> = { width: set('width', 720), height: set('height', 720), fps: set('fps', 24), background: { prep: (_o, p) => { (p.tracks[0]!.items[0] as M.VideoClip).fit = 'contain'; }, mut: o => { o.background = '#FF0000'; } }, // shows where a clip leaves the frame empty
  fill: { prep: (_o, p) => { (p.tracks[0]!.items[0] as M.VideoClip).fit = 'contain'; }, mut: o => { o.fill = 'blur'; } } };
const projectKeys: Table<M.EditProject> = { version: meta('always 2'), sourceTakeId: meta('which take the project edits (a reference)'), canvas: nested, assets: meta('resolved by the caller into files'),
  tracks: nested, mute: { mut: (_o, p) => { p.mute = true; } } };
const assetKeys: Table<M.Asset> = { id: meta('an id'), kind: meta('the kind of file'), take: meta('a reference the caller resolves into files'), upload: meta('a reference the caller resolves into files'),
  library: meta('a reference the caller resolves into files (missing → listed)'), reverseOf: meta('the reversed copy is a file of its own; clips play it as any asset'), url: meta('a reference the caller resolves into files'), durationSec: meta('the file is probed'),
  width: meta('the file is probed'), height: meta('the file is probed'), hasAudio: meta('the file is probed'), name: meta('display only'),
  derivedFrom: meta('a steadied or slowed copy is a file of its own; clips play it as any asset') };

// ------------------------------------------------------------------ every place a field can be
/** coveredBy: while the whole place is listed under this name, its fields are too. */
type Place = { name: string; get: (p: M.EditProject) => Obj; fields: Record<string, Entry>; coveredBy?: string };
const places: Place[] = [
  { name: 'main clip', get: item('c1'), fields: clipFields(true) },
  { name: 'main clip (with a transition in)', get: item('c2'), fields: nest('transitionIn', transitionFields) },
  { name: 'overlay clip', get: item('o1'), fields: clipFields(false) },
  { name: 'image', get: item('i1'), fields: imageFields },
  { name: 'text', get: item('t1'), fields: textFields },
  { name: 'captions', get: caption, fields: captionFields },
  { name: 'music clip', get: item('mu'), fields: audioKeys },
  { name: 'voice clip', get: item('vo'), fields: audioKeys },
  { name: 'sfx clip', get: item('sx'), fields: audioKeys },
  { name: 'adjustment layer', get: item('a1'), fields: adjustItemFields },
  { name: 'music ducking', get: track('mus'), fields: nest('duck', duckKeys) },
  ...['main', 'ov', 'img', 'adj', 'tx', 'cap', 'mus', 'voi', 'sfx'].map(id => ({ name: `track ${id}`, get: track(id), fields: trackKeys(base().tracks.find(t => t.id === id)!.kind) as Record<string, Entry>,
    coveredBy: undefined })),
  { name: 'canvas', get: p => p.canvas as unknown as Obj, fields: canvasKeys },
  { name: 'project', get: p => p as unknown as Obj, fields: projectKeys },
  { name: 'asset', get: p => p.assets[0] as unknown as Obj, fields: assetKeys },
];
void allTrackKeys;

describe('the server render draws every field of the model, or lists it', () => {
  it('no field is read nowhere', () => {
    const silent: string[] = [];
    let probes = 0;
    const plain = plan(base()).unsupported;
    for (const pl of places) {
      for (const [name, e] of Object.entries(pl.fields)) {
        if ('meta' in e) continue;
        const a = base(), b = base();
        e.prep?.(pl.get(a), a); e.prep?.(pl.get(b), b);
        e.mut(pl.get(b), b);
        const pa = plan(a), pb = plan(b);
        probes++;
        // Listed: the field changes what `unsupported` names (e.g. hiding a listed track), or what holds it is listed as a whole (the place, or the
        // object `prep` gave it, e.g. a mask's feather while masks are listed).
        const listed = [...pb.unsupported].some(u => !pa.unsupported.has(u)) || [...pa.unsupported].some(u => !pb.unsupported.has(u)) || !!pl.coveredBy && pb.unsupported.has(pl.coveredBy)
          || [...pa.unsupported].some(u => !plain.has(u));
        if (pa.args === pb.args && !listed) silent.push(`${pl.name}: ${name} (unsupported: ${[...pb.unsupported].join(', ') || 'none'})`);
      }
    }
    expect(probes).toBeGreaterThan(250);
    expect(silent).toEqual([]);
  });
});
