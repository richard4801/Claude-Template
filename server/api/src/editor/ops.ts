// Edit-session ops (plans/video-editor.md "Edit ops", plans/claude-editing.md A): the vocabulary Claude (MCP
// apply_edit_ops) uses to change a project. Each op is applied to a copy, the result is validated with the reference
// rules, and the session stores the JSON Patch it made (the apps apply patches, so they don't need these ops).
import { badRequest } from '../errors.js';
import * as M from './model.js';
import type { Look } from './look.js';
import { CAPTION_STYLES, HOOKS } from './presets.js';
import { packLook } from './lookpack.js';
import { applyPatch, PatchError, type PatchOp } from './jsonpatch.js';

export type EditOp = { op: string; [k: string]: unknown };
type P = M.EditProject;
const RATIOS: Record<string, [number, number]> = { '9:16': [9, 16], '1:1': [1, 1], '4:5': [4, 5], '16:9': [16, 9] };
export const OP_NAMES = ['trim', 'split', 'delete', 'move', 'speed', 'add_text', 'add_hook', 'edit_text', 'caption_style', 'look', 'adjust',
  'transition', 'mask', 'transform', 'keyframe', 'remove_keyframe', 'volume', 'duck', 'voice', 'add_music', 'ratio', 'patch',
  // wave 1 (plans/edit-parity.md): mirror, freeze frame, blend modes, the background fill
  'flip', 'freeze', 'blend', 'fill'] as const;

const r3 = (v: number) => Math.round(v * 1000) / 1000;
const t2 = (s: number) => { const m = Math.floor(s / 60), r = s - m * 60; return `${m}:${r.toFixed(1).padStart(4, '0')}`; };
const num = (o: EditOp, k: string, req = false): number | undefined => {
  const v = o[k];
  if (v === undefined || v === null) { if (req) throw badRequest(`${o.op}.${k}: required`); return undefined; }
  if (typeof v !== 'number' || !Number.isFinite(v)) throw badRequest(`${o.op}.${k}: must be a number`);
  return v;
};
const str = (o: EditOp, k: string, req = false): string | undefined => {
  const v = o[k];
  if (v === undefined || v === null) { if (req) throw badRequest(`${o.op}.${k}: required`); return undefined; }
  if (typeof v !== 'string') throw badRequest(`${o.op}.${k}: must be text`);
  return v;
};

/** Every item with its track. */
function find(p: P, id: string): { track: M.Track; item: M.Item; index: number } {
  for (const track of p.tracks) { const index = track.items.findIndex(i => i.id === id); if (index >= 0) return { track, item: track.items[index]!, index }; }
  throw badRequest(`no item ${id}`);
}
function newId(p: P, prefix: string) {
  const used = new Set([...p.tracks.flatMap(t => [t.id, ...t.items.map(i => i.id)]), ...p.assets.map(a => a.id)]);
  for (let n = 1; ; n++) if (!used.has(`${prefix}${n}`)) return `${prefix}${n}`;
}
/** A track of `kind` with room for [start, end), or a new one placed above the others of its kind. */
function trackFor(p: P, kind: M.TrackKind, start: number, end: number): M.Track {
  for (const t of p.tracks.filter(x => x.kind === kind)) {
    if (t.items.every(it => { const s = M.itemSpan(p, t, it); return s.endSec <= start + 1e-6 || s.startSec >= end - 1e-6; })) return t;
  }
  const t: M.Track = { id: newId(p, kind), kind, items: [] };
  p.tracks.push(t);
  return t;
}
const sortTrack = (t: M.Track) => { t.items.sort((a, b) => ((a as { startSec: number }).startSec ?? 0) - ((b as { startSec: number }).startSec ?? 0)); };
const targets = (p: P, o: EditOp, key = 'itemId'): M.Item[] => {
  const id = o[key];
  if (id === 'all') return M.mainTrack(p).items;
  if (typeof id !== 'string') throw badRequest(`${o.op}.${key}: an item id or "all"`);
  return [find(p, id).item];
};

/** Applies ops in order to a copy of the project; returns it and one label per op. Throws bad_request on a bad op. */
export function applyOps(project: P, ops: EditOp[]): { project: P; labels: string[] } {
  if (!Array.isArray(ops) || !ops.length || ops.length > 100) throw badRequest('ops: 1–100 operations');
  let p: P = JSON.parse(JSON.stringify(project));
  const labels: string[] = [];
  ops.forEach((o, i) => {
    if (!o || typeof o !== 'object' || typeof o.op !== 'string') throw badRequest(`ops.${i}: needs "op"`);
    try { labels.push(applyOne(p, o, next => { p = next; })); } catch (e) {
      const err = e as Error & { message: string };
      if ((err as { code?: string }).code === 'bad_request' && !err.message.startsWith('ops.')) throw badRequest(`ops.${i}.${err.message}`);
      throw e;
    }
  });
  return { project: p, labels };
}

function applyOne(p: P, o: EditOp, replace: (next: P) => void): string {
  switch (o.op) {
    case 'trim': {
      const c = find(p, str(o, 'clipId', true)!).item as M.VideoClip;
      const a = num(o, 'inSec'), b = num(o, 'outSec');
      if (a === undefined && b === undefined) throw badRequest('trim: inSec and/or outSec');
      if (a !== undefined) c.inSec = a;
      if (b !== undefined) c.outSec = b;
      return `Trimmed to ${t2(c.inSec)}–${t2(c.outSec)}`;
    }
    case 'split': {
      const at = num(o, 'at', true)!;
      const spans = M.timeline(p), main = M.mainTrack(p);
      const k = spans.findIndex(s => at > s.startSec + 0.05 && at < s.endSec - 0.05);
      if (k < 0) throw badRequest('split.at: not inside a clip (or too close to a cut)');
      const c = main.items[k] as M.VideoClip, src = M.clipSourceAt(c, at - spans[k]!.startSec);
      if (c.holdSec !== undefined) {
        // A freeze frame splits into two holds of the same frame.
        const a = r3(at - spans[k]!.startSec), b = r3(c.holdSec - a);
        if (a < M.HOLD_MIN_SEC || b < M.HOLD_MIN_SEC) throw badRequest('split.at: too close to the freeze frame\'s edge');
        const { transitionIn: _t, ...restH } = c;
        main.items.splice(k, 1, { ...c, holdSec: a, fadeOutSec: undefined }, { ...restH, id: newId(p, 'c'), holdSec: b, fadeInSec: undefined });
        return `Split at ${t2(at)}`;
      }
      if (src - c.inSec < M.LIMITS.minClipSourceSec || c.outSec - src < M.LIMITS.minClipSourceSec) throw badRequest('split.at: too close to the clip edge');
      const { transitionIn, ...rest } = c;
      const x = (src - c.inSec) / (c.outSec - c.inSec);
      const left: M.VideoClip = { ...c, outSec: src, ...(c.speedCurve ? { speedCurve: M.subCurve(c.speedCurve, 0, x) } : {}) };
      const right: M.VideoClip = { ...rest, id: newId(p, 'c'), inSec: src, ...(c.speedCurve ? { speedCurve: M.subCurve(c.speedCurve, x, 1) } : {}) };
      void transitionIn;
      main.items.splice(k, 1, left, right);
      return `Split at ${t2(at)}`;
    }
    case 'delete': {
      const { track, item, index } = find(p, str(o, 'itemId', true)!);
      if (track.kind === 'main' && track.items.length === 1) throw badRequest('delete: the last clip can\'t be deleted');
      const span = M.itemSpan(p, track, item);
      track.items.splice(index, 1);
      if (track.kind === 'main') { const nx = track.items[index] as M.VideoClip | undefined; if (index === 0 && nx?.transitionIn) delete nx.transitionIn; }
      else if (o.ripple === true) {
        const len = span.endSec - span.startSec;
        for (const it of track.items.slice(index)) (it as { startSec: number }).startSec = Math.max(0, (it as { startSec: number }).startSec - len);
      }
      if (!track.items.length && track.kind !== 'main' && track.kind !== 'caption') p.tracks = p.tracks.filter(t => t !== track);
      return track.kind === 'main' ? 'Deleted a clip' : `Deleted ${track.kind === 'text' ? 'text' : track.kind}`;
    }
    case 'move': {
      const { track, item, index } = find(p, str(o, 'itemId', true)!);
      if (track.kind === 'main') {
        const to = num(o, 'index', true)!;
        if (!Number.isInteger(to) || to < 0 || to >= track.items.length) throw badRequest('move.index: a clip position');
        track.items.splice(index, 1);
        track.items.splice(to, 0, item);
        for (const [k, it] of track.items.entries()) if (k === 0 && (it as M.VideoClip).transitionIn) delete (it as M.VideoClip).transitionIn;
        return `Moved a clip to position ${to + 1}`;
      }
      const s = num(o, 'startSec', true)!;
      (item as { startSec: number }).startSec = Math.max(0, s);
      sortTrack(track);
      return `Moved to ${t2(s)}`;
    }
    case 'speed': {
      const c = find(p, str(o, 'clipId', true)!).item as M.VideoClip;
      const sp = num(o, 'speed'), curve = o.curve;
      if (sp !== undefined) { c.speed = sp; delete c.speedCurve; }
      if (curve === null) delete c.speedCurve;
      else if (typeof curve === 'string') {
        if (!(curve in M.SPEED_PRESETS)) throw badRequest(`speed.curve: one of ${Object.keys(M.SPEED_PRESETS).join(', ')}`);
        c.speedCurve = { preset: curve as M.SpeedPreset, points: M.SPEED_PRESETS[curve as keyof typeof M.SPEED_PRESETS] };
      } else if (curve && typeof curve === 'object') c.speedCurve = { preset: 'custom', points: (curve as { points: [number, number][] }).points };
      if (sp === undefined && curve === undefined) throw badRequest('speed: speed or curve');
      return c.speedCurve ? `Speed curve · ${c.speedCurve.preset}` : `Speed ${c.speed}×`;
    }
    case 'add_text': case 'add_hook': {
      const hook = o.op === 'add_hook' ? HOOKS.find(h => h.id === (str(o, 'template', true))) : (o.template ? HOOKS.find(h => h.id === str(o, 'template')) : undefined);
      if ((o.op === 'add_hook' || o.template !== undefined) && !hook) throw badRequest(`${o.op}.template: one of ${HOOKS.map(h => h.id).join(', ')}`);
      const text = str(o, 'text') ?? hook?.text;
      if (!text) throw badRequest(`${o.op}.text: required`);
      const start = num(o, 'startSec') ?? 0, dur = num(o, 'durationSec') ?? hook?.durationSec ?? 3;
      const t = trackFor(p, 'text', start, start + dur);
      const it: M.TextItem = { id: newId(p, 't'), startSec: start, durationSec: dur, text, style: { ...(hook?.style ?? CAPTION_STYLES.plain), ...((o.style as object) ?? {}) } as M.TextStyle,
        transform: { ...(hook?.transform ?? { x: 0.5, y: 0.2 }), ...((o.transform as object) ?? {}) }, ...(hook ? { animIn: hook.animIn, template: hook.id } : {}), ...(hook?.animOut ? { animOut: hook.animOut } : {}) };
      if (!hook) { const s = it.style as M.TextStyle & Partial<M.CaptionStyle>; delete s.preset; delete s.highlightColor; delete s.y; delete s.wordsPerPage; delete s.maxLines; }
      t.items.push(it); sortTrack(t);
      return `Added ${hook ? 'hook' : 'text'} “${text.slice(0, 32)}”`;
    }
    case 'edit_text': {
      const it = find(p, str(o, 'itemId', true)!).item as M.TextItem;
      if (typeof it.text !== 'string') throw badRequest('edit_text.itemId: not a text item');
      const tx = str(o, 'text'); if (tx !== undefined) it.text = tx;
      const s = num(o, 'startSec'); if (s !== undefined) it.startSec = s;
      const d = num(o, 'durationSec'); if (d !== undefined) it.durationSec = d;
      if (o.style && typeof o.style === 'object') it.style = { ...it.style, ...(o.style as object) } as M.TextStyle;
      if (o.transform && typeof o.transform === 'object') it.transform = { ...it.transform, ...(o.transform as object) };
      return 'Edited text';
    }
    case 'caption_style': {
      const t = p.tracks.find(x => x.kind === 'caption' && x.caption);
      if (!t) throw badRequest('caption_style: no captions yet (run auto_captions first)');
      const preset = str(o, 'preset');
      if (preset !== undefined && !(preset in CAPTION_STYLES)) throw badRequest(`caption_style.preset: one of ${Object.keys(CAPTION_STYLES).join(', ')}`);
      const { op: _op, preset: _p, ...rest } = o;
      t.caption!.style = { ...(preset ? CAPTION_STYLES[preset as M.CaptionPreset] : t.caption!.style), ...rest } as M.CaptionStyle;
      return `Caption style · ${t.caption!.style.preset}`;
    }
    case 'look': {
      const items = targets(p, o);
      let base: Look | null | undefined;
      if (o.look === null) base = null;
      else if (typeof o.look === 'string') { base = packLook(o.look); if (!base) throw badRequest('look.look: a look id from list_looks'); }
      const { op: _o, itemId: _i, look: _l, ...parts } = o;
      for (const it of items) {
        const v = it as M.VideoClip;
        if (base === null) { delete v.look; continue; }
        v.look = { ...(base ?? v.look ?? {}), ...(parts as Look) };
      }
      return base === null ? 'Removed the look' : `Look${typeof o.look === 'string' ? ` · ${o.look}` : ''}${o.strength !== undefined ? ` ${Math.round(Number(o.strength) * 100)} %` : ''}`;
    }
    case 'adjust': {
      const { op: _o, itemId: _i, ...a } = o;
      for (const it of targets(p, o)) { const v = it as M.VideoClip; v.adjust = { ...(v.adjust ?? {}), ...(a as M.Adjust) }; }
      return 'Adjusted colour';
    }
    case 'transition': {
      const kind = str(o, 'kind', true)!, d = num(o, 'durationSec') ?? 0.4;
      const main = M.mainTrack(p);
      const list = o.clipId === 'all' ? main.items.slice(1) : [find(p, str(o, 'clipId', true)!).item];
      for (const c of list as M.VideoClip[]) {
        if (main.items.indexOf(c) <= 0) throw badRequest('transition.clipId: a main clip after the first');
        if (kind === 'cut') delete c.transitionIn; else c.transitionIn = { kind: kind as M.TransitionKind, durationSec: d };
      }
      return kind === 'cut' ? 'Removed transition' : `Transition · ${kind}`;
    }
    case 'mask': {
      const v = find(p, str(o, 'itemId', true)!).item as M.VideoClip;
      if (o.mask === null) delete v.mask; else v.mask = o.mask as M.Mask;
      return o.mask === null ? 'Removed mask' : `Mask · ${(o.mask as M.Mask)?.shape}`;
    }
    case 'transform': {
      const v = find(p, str(o, 'itemId', true)!).item as M.VideoClip;
      v.transform = { ...(v.transform ?? {}), ...((o.transform as object) ?? {}) };
      return 'Moved / scaled';
    }
    case 'keyframe': case 'remove_keyframe': {
      const v = find(p, str(o, 'itemId', true)!).item as M.VideoClip;
      const prop = str(o, 'prop', true)! as M.KfProp, t = num(o, 't', true)!;
      const list = (v.keyframes ??= {})[prop] ??= [];
      const k = list.findIndex(x => Math.abs(x.t - t) < 1e-3);
      if (o.op === 'remove_keyframe') { if (k < 0) throw badRequest('remove_keyframe: no key at t'); list.splice(k, 1); }
      else { const kf: M.Keyframe = { t, v: num(o, 'v', true)!, ...(o.ease ? { ease: o.ease as M.Ease } : {}) }; if (k >= 0) list[k] = kf; else list.push(kf); list.sort((a, b) => a.t - b.t); }
      if (!list.length) delete v.keyframes![prop];
      return o.op === 'keyframe' ? `Keyframe · ${prop} at ${t2(t)}` : `Removed ${prop} keyframe`;
    }
    case 'volume': {
      const v = find(p, str(o, 'itemId', true)!).item as M.AudioClip;
      for (const k of ['volume', 'fadeInSec', 'fadeOutSec'] as const) { const x = num(o, k); if (x !== undefined) v[k] = x; }
      if (typeof o.muted === 'boolean') v.muted = o.muted;
      return 'Changed sound';
    }
    case 'duck': {
      const t = o.trackId ? p.tracks.find(x => x.id === o.trackId) : p.tracks.find(x => x.kind === 'music');
      if (!t || t.kind !== 'music') throw badRequest('duck.trackId: a music track');
      if (o.enabled === false) { delete t.duck; return 'Auto-duck off'; }
      const db = num(o, 'levelDb');
      t.duck = { ...(t.duck ?? { under: ['voice', 'speech'] }), ...(db !== undefined ? { level: Math.pow(10, db / 20) } : {}),
        ...(num(o, 'attackSec') !== undefined ? { attackSec: num(o, 'attackSec') } : {}), ...(num(o, 'releaseSec') !== undefined ? { releaseSec: num(o, 'releaseSec') } : {}),
        ...(Array.isArray(o.under) ? { under: o.under as M.Duck['under'] } : {}) };
      return 'Auto-duck music';
    }
    case 'voice': {
      const v = find(p, str(o, 'itemId', true)!).item as M.VideoClip;
      if (o.effect !== undefined) v.voiceEffect = o.effect as M.VoiceEffect;
      if (o.enhance !== undefined) v.enhance = o.enhance === true;
      return `Voice · ${v.voiceEffect ?? 'none'}${v.enhance ? ' + enhance' : ''}`;
    }
    case 'add_music': {
      const ref = (o.asset ?? {}) as { upload?: string; library?: string; take?: string; durationSec?: number };
      const refs = [ref.upload, ref.library, ref.take].filter(Boolean);
      if (refs.length !== 1) throw badRequest('add_music.asset: one of upload or take (with durationSec)');
      // 2026-11-08 audit: there is no music library yet, so a library track would be silent in every app.
      if (ref.library) throw badRequest('add_music.asset.library: there is no music library yet · use an upload or a take');
      const d = Number(ref.durationSec);
      if (!(d > 0)) throw badRequest('add_music.asset.durationSec: required');
      const aid = newId(p, 'm');
      p.assets.push({ id: aid, kind: ref.take ? 'video' : 'audio', ...(ref.upload ? { upload: ref.upload } : ref.library ? { library: ref.library } : { take: ref.take! }), durationSec: d });
      const start = num(o, 'startSec') ?? 0, inS = num(o, 'inSec') ?? 0, outS = num(o, 'outSec') ?? Math.min(d, inS + Math.max(0.5, M.durationSec(p) - start));
      const t = trackFor(p, 'music', start, start + (outS - inS));
      t.items.push({ id: newId(p, 'mu'), asset: aid, startSec: start, inSec: inS, outSec: outS } as M.AudioClip); sortTrack(t);
      return 'Added music';
    }
    case 'ratio': {
      const r = RATIOS[str(o, 'ratio', true)!];
      if (!r) throw badRequest(`ratio.ratio: one of ${Object.keys(RATIOS).join(', ')}`);
      const long = Math.max(p.canvas.width, p.canvas.height), even = (v: number) => Math.max(16, Math.round(v / 2) * 2);
      [p.canvas.width, p.canvas.height] = r[0] >= r[1] ? [even(long), even((long * r[1]) / r[0])] : [even((long * r[0]) / r[1]), even(long)];
      return `Shape ${o.ratio}`;
    }
    case 'flip': {
      const v = find(p, str(o, 'itemId', true)!).item as M.VideoClip;
      const tr = { ...(v.transform ?? {}) };
      for (const k of ['x', 'y'] as const) {
        const val = o[k];
        if (val === undefined) continue;
        if (typeof val !== 'boolean') throw badRequest(`flip.${k}: true or false`);
        const key = k === 'x' ? 'flipX' : 'flipY';
        if (val) tr[key] = true; else delete tr[key];
      }
      v.transform = tr;
      return 'Mirrored';
    }
    case 'freeze': {
      // A freeze frame at timeline `at` for durationSec: the clip there splits and a hold of that frame goes between.
      const at = num(o, 'at', true)!, dur = num(o, 'durationSec') ?? 1;
      if (dur < M.HOLD_MIN_SEC || dur > M.HOLD_MAX_SEC) throw badRequest(`freeze.durationSec: ${M.HOLD_MIN_SEC}–${M.HOLD_MAX_SEC}`);
      const spans = M.timeline(p), main = M.mainTrack(p);
      const k = spans.findIndex(s => at >= s.startSec && at < s.endSec);
      if (k < 0) throw badRequest('freeze.at: not inside a clip');
      const c = main.items[k] as M.VideoClip;
      const local = at - spans[k]!.startSec, src = M.clipSourceAt(c, local);
      const dur0 = p.assets.find(a => a.id === c.asset)?.durationSec ?? c.outSec;
      const frame = r3(Math.min(src, dur0 - M.LIMITS.minClipSourceSec));
      const { transitionIn: _t, speedCurve: _s, keyframes: _k, fadeInSec: _fi, fadeOutSec: _fo, ...base } = c;
      const hold: M.VideoClip = { ...base, id: newId(p, 'c'), inSec: frame, outSec: r3(frame + M.LIMITS.minClipSourceSec), speed: 1, holdSec: r3(dur) };
      const insertAt = local < 0.05 ? k : k + 1;
      if (local >= 0.05 && spans[k]!.endSec - at >= 0.05 && c.holdSec === undefined) {
        // Cut the clip at the frame (both pieces need 0.1 s of source), then the hold goes between them.
        if (src - c.inSec >= M.LIMITS.minClipSourceSec && c.outSec - src >= M.LIMITS.minClipSourceSec) {
          const { transitionIn: _tr, ...rest } = c;
          const x = (src - c.inSec) / (c.outSec - c.inSec);
          main.items.splice(k, 1, { ...c, outSec: src, ...(c.speedCurve ? { speedCurve: M.subCurve(c.speedCurve, 0, x) } : {}) },
            { ...rest, id: newId({ ...p, assets: [...p.assets, { id: hold.id } as M.Asset] }, 'c'), inSec: src, ...(c.speedCurve ? { speedCurve: M.subCurve(c.speedCurve, x, 1) } : {}) });
        }
      }
      main.items.splice(insertAt, 0, hold);
      return `Freeze frame ${dur.toFixed(1)} s at ${t2(at)}`;
    }
    case 'blend': {
      const { track, item } = find(p, str(o, 'itemId', true)!);
      const mode = str(o, 'mode', true)! as M.BlendMode;
      if (!M.BLEND_MODES.includes(mode)) throw badRequest(`blend.mode: one of ${M.BLEND_MODES.join(', ')}`);
      if (track.kind !== 'video' && track.kind !== 'image') throw badRequest('blend: only overlays (video and image tracks) blend');
      const v = item as M.VideoClip | M.ImageItem;
      if (mode === 'normal') delete v.blend; else v.blend = mode;
      return `Blend ${mode}`;
    }
    case 'fill': {
      const kind = str(o, 'kind', true)!;
      if (kind !== 'color' && kind !== 'blur') throw badRequest('fill.kind: color or blur');
      const c = str(o, 'color');
      if (c !== undefined) p.canvas.background = c;
      if (kind === 'blur') p.canvas.fill = 'blur'; else delete p.canvas.fill;
      return kind === 'blur' ? 'Blurred background' : 'Background colour';
    }
    case 'patch': {
      if (!Array.isArray(o.patch)) throw badRequest('patch.patch: a JSON Patch array');
      try { replace(applyPatch(p, o.patch as PatchOp[])); } catch (e) { if (e instanceof PatchError) throw badRequest(`patch.patch: ${e.message}`); throw e; }
      return 'Changed the project';
    }
    default: throw badRequest(`op: one of ${OP_NAMES.join(', ')}`);
  }
}
