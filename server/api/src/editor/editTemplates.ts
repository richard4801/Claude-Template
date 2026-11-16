// Edit templates (plans/edit-templates.md §2): effects and transitions as ONE JSON spec each, expanded on the server into
// ordinary edit items for a target (a clip, a cut, every selected clip or cut, or the whole edit). The apps receive normal
// project items, so a template needs no app model code unless it names a primitive the apps don't have yet (`requires`,
// gated like BLEND_NEXT_LIVE). Not the photo presets (templates_* / src/templates) and not caption kits.
//
// Pure: no database, no files, no processes. Pack scripts are text the spec may name (source.scripts); nothing here, or
// anywhere on the server, runs them.
import { ApiError, badRequest } from '../errors.js';
import { EFFECT_IDS } from './effects.js';
import * as M from './model.js';
import { applyOps } from './ops.js';

// ------------------------------------------------------------------ the spec
export type TplKind = 'transition' | 'effect';
export type TplTarget = 'clip' | 'cut' | 'edit';
/** live: works on any video; matte: live, plus a paid subject matte per apply; primitive: needs a value the apps don't
 * draw yet (N1–N8); reference: only the pack's reference clip (Claude makes it per video on the Mac). */
export type TplLevel = 'live' | 'matte' | 'primitive' | 'reference';
export type Expr = number | string;
export type Param = { key: string; label: string; type: 'number' | 'enum' | 'bool' | 'text' | 'upload' | 'times';
  options?: string[]; min?: number; max?: number; unit?: string; default?: unknown;
  /** Shown only once this primitive is live (e.g. "N2" for the white line); until then the default is used. */
  needs?: Primitive };
export type KeySpec = { t: Expr; v: Expr; ease?: M.Ease | string };
export type Unit = 'norm' | 'sec' | 'frames';
export type MaskSpec = { shape: M.MaskShape; x?: Expr; y?: Expr; width?: Expr; height?: Expr; rotation?: Expr; feather?: Expr; invert?: boolean };
/** A shape copy: hold-eased rect keys over the copy (t 0–1; rect [x, y, w, h] from the top-left, 0–1 of the frame). */
export type ShapeKey = { t: number; rect: [number, number, number, number]; rot?: number };
export type When = { param: string; is?: unknown; not?: unknown };
export type Step =
  | { do: 'split'; on?: string; at: Expr; names: [string, string]; when?: When }
  | { do: 'freeze'; on?: string; sec: Expr; as: string; when?: When }
  | { do: 'set'; on: string; fields?: Record<string, unknown>; keys?: Partial<Record<M.KfProp, KeySpec[]>>; unit?: Unit; when?: When }
  | { do: 'transition'; on?: string; kind: string; sec: Expr; when?: When }
  | { do: 'add'; as?: string; track: 'video' | 'image' | 'adjust' | 'text' | 'sfx'; source?: string; in?: Expr; start: Expr; length: Expr;
      hold?: boolean; copyLook?: boolean; fields?: Record<string, unknown>; keys?: Partial<Record<M.KfProp, KeySpec[]>>; unit?: Unit;
      mask?: MaskSpec | '$shape'; wash?: Expr; matte?: boolean; text?: Expr;
      for?: 'shape' | 'notes' | 'cells' | 'ranges' | 'media'; notes?: { count: Expr; step: Expr; only?: 'last' | 'notLast' }; when?: When }
  | { do: 'wash'; on: string; color: Expr; when?: When }
  | { do: 'jitter'; on: string; prop: 'x' | 'y' | 'opacity' | 'rotation'; amount: Expr; step: Expr; when?: When }
  | { do: 'matte'; on: string; name?: string; aboveText?: boolean; when?: When };
export type EditTemplateSpec = {
  v: 1; id: string; name: string; description: string; kind: TplKind; target: TplTarget; level: TplLevel;
  /** Primitives a project needs to read it (gated; "Needs the next MUSE update" until the apps have them). */
  requires?: Primitive[];
  /** Why it is not ready (reference / primitive), in one plain line. */
  why?: string;
  /** How its timing works, for the tile ("one stage per note", "0.3 s before the cut"). */
  timing?: string;
  /** Suggested target when applying from the library: each selected cut, each cut on a note. */
  each?: 'selected' | 'note-cut';
  params?: Param[];
  steps?: Step[];
  shapes?: Record<string, ShapeKey[][]>;
  source?: { pack?: string; templateId?: string; by?: string; scripts?: string[]; native?: string };
};

// ------------------------------------------------------------------ the primitive gate
/** The new picture values templates will need (plan §4). None is in the apps yet: a template that requires one is not
 * appliable and never reaches a project. Flip one to true only when model.ts, both apps and the render draw it (P3),
 * exactly like BLEND_NEXT_LIVE. */
export type Primitive = 'N1' | 'N2' | 'N3' | 'N4' | 'N5' | 'N6' | 'N7' | 'N8' | 'N9';
export const PRIMITIVES: Record<Primitive, { live: boolean; what: string }> = {
  N1: { live: false, what: 'invert and colour split effects with keyframed amount' },
  N2: { live: false, what: 'a white line around masks' },
  N3: { live: false, what: 'a free on-device subject cut-out' },
  N4: { live: false, what: 'text as a mask' },
  N5: { live: false, what: 'write-on text' },
  N6: { live: false, what: 'audio low-pass keyframes' },
  N7: { live: false, what: 'one-frame pictures' },
  N8: { live: false, what: 'a shatter transition' },
  N9: { live: false, what: 'tracked masks and anchors' },
};
export const primitiveLive = (n: Primitive) => !!PRIMITIVES[n]?.live;
/** Whether a template can be applied now, and if not, why (one plain line for the tile and for Claude). */
export function readiness(spec: Pick<EditTemplateSpec, 'level' | 'requires' | 'why' | 'name'>): { ready: true } | { ready: false; state: 'not_ready' | 'needs_update'; reason: string } {
  const missing = (spec.requires ?? []).filter(n => !primitiveLive(n));
  if (spec.level === 'reference') return { ready: false, state: 'not_ready', reason: spec.why ?? 'Only the reference clip for now: ask Claude on the Mac to make it for your shots' };
  if (missing.length || spec.level === 'primitive') {
    const list = missing.map(n => PRIMITIVES[n].what).join(' and ');
    return { ready: false, state: 'not_ready', reason: spec.why ?? (list ? `Needs ${list}, which MUSE doesn't draw yet` : 'Needs a picture value MUSE doesn\'t draw yet') };
  }
  return { ready: true };
}

// ------------------------------------------------------------------ expressions
/** A small arithmetic language for spec values: numbers, $vars ($cut, $next.in, $lead …), + − × ÷ %, comparisons,
 * parentheses and min, max, abs, round, floor, ceil, clamp, lerp, if. No strings, no calls out: data, not code. */
export function evalExpr(e: Expr, vars: (name: string) => unknown): number {
  if (typeof e === 'number') return e;
  if (typeof e !== 'string' || e.length > 300) throw badRequest('template: a value must be a number or a short expression');
  const s = e;
  let i = 0;
  const ws = () => { while (i < s.length && /\s/.test(s[i]!)) i++; };
  const fail = (why: string): never => { throw badRequest(`template: "${s}" ${why}`); };
  const FN: Record<string, (...a: number[]) => number> = {
    min: Math.min, max: Math.max, abs: Math.abs, round: Math.round, floor: Math.floor, ceil: Math.ceil,
    clamp: (v, a, b) => Math.min(b!, Math.max(a!, v!)), lerp: (a, b, t) => a! + (b! - a!) * t!, if: (c, a, b) => (c ? a! : b!),
  };
  const primary = (): number => {
    ws();
    const c = s[i];
    if (c === '(') { i++; const v = cmp(); ws(); if (s[i] !== ')') fail('is missing a )'); i++; return v; }
    if (c === '-') { i++; return -primary(); }
    if (c === '+') { i++; return primary(); }
    const num = /^(\d+\.?\d*|\.\d+)/.exec(s.slice(i));
    if (num) { i += num[0].length; return Number(num[0]); }
    const v = /^\$[A-Za-z_][\w.]*/.exec(s.slice(i));
    if (v) {
      i += v[0].length;
      const x = vars(v[0].slice(1));
      if (typeof x === 'boolean') return x ? 1 : 0;
      if (typeof x !== 'number' || !Number.isFinite(x)) fail(`uses ${v[0]}, which is not a number here`);
      return x as number;
    }
    const f = /^[a-z]+(?=\s*\()/.exec(s.slice(i));
    if (f && FN[f[0]]) {
      i += f[0].length; ws(); i++; // (
      const args: number[] = [];
      ws();
      if (s[i] !== ')') for (;;) { args.push(cmp()); ws(); if (s[i] === ',') { i++; continue; } break; }
      if (s[i] !== ')') fail('is missing a )');
      i++;
      return FN[f[0]]!(...args);
    }
    return fail(`can't be read at "${s.slice(i, i + 12)}"`);
  };
  const mul = (): number => {
    let v = primary();
    for (;;) {
      ws();
      const o = s[i];
      if (o !== '*' && o !== '/' && o !== '%') return v;
      i++;
      const r = primary();
      v = o === '*' ? v * r : o === '/' ? v / r : ((v % r) + r) % r;
    }
  };
  const add = (): number => {
    let v = mul();
    for (;;) { ws(); const o = s[i]; if (o !== '+' && o !== '-') return v; i++; const r = mul(); v = o === '+' ? v + r : v - r; }
  };
  const cmp = (): number => {
    const v = add();
    ws();
    const m = /^(<=|>=|==|!=|<|>)/.exec(s.slice(i));
    if (!m) return v;
    i += m[0].length;
    const r = add();
    return ({ '<': v < r, '>': v > r, '<=': v <= r, '>=': v >= r, '==': Math.abs(v - r) < 1e-9, '!=': Math.abs(v - r) >= 1e-9 } as Record<string, boolean>)[m[0]] ? 1 : 0;
  };
  const out = cmp();
  ws();
  if (i < s.length) fail(`has something extra at "${s.slice(i, i + 12)}"`);
  if (!Number.isFinite(out)) fail('is not a finite number');
  return out;
}

// ------------------------------------------------------------------ targets
export type Target = { itemId: string } | { cutAfter: string } | { itemIds: string[] } | { cutsAfter: string[] }
  | { each: 'clip' | 'cut' | 'note-cut' } | { edit: true };
export type MatteRequest = { itemId: string; reveal: number; layer?: { clip: string; name: string; aboveText: boolean } };
export type Expansion = { project: M.EditProject; labels: string[]; notes: string[]; added: string[]; mattes: MatteRequest[]; tracksAdded: number; targets: string[] };
export type ExpandOptions = {
  params?: Record<string, unknown>;
  /** Note times (timeline seconds) the caller knows (song_notes); else the music's beats, else even steps. */
  notes?: number[];
  /** The pack's media for this template (uploads), for sources like "pack:overlay". */
  media?: { uploadId: string; role: string; kind: 'image' | 'video' | 'audio'; durationSec?: number }[];
};

const r3 = (v: number) => Math.round(v * 1000) / 1000;
const r6 = (v: number) => Math.round(v * 1e6) / 1e6;
const t2 = (s: number) => { const m = Math.floor(s / 60); return `${m}:${(s - m * 60).toFixed(1).padStart(4, '0')}`; };
const clone = <T>(x: T): T => JSON.parse(JSON.stringify(x)) as T;

/** Item ids a target names, in timeline order (cuts by the clip after them). */
export function resolveTargets(p: M.EditProject, spec: Pick<EditTemplateSpec, 'target'>, t: Target, notes: number[] = []): string[] {
  const main = M.mainTrack(p).items, tl = M.timeline(p);
  const isMain = (id: string) => main.some(c => c.id === id);
  const anyItem = (id: string) => p.tracks.some(tr => tr.items.some(x => x.id === id));
  if (!t || typeof t !== 'object') throw badRequest('target: {itemId}, {cutAfter}, {itemIds}, {cutsAfter}, {each: "clip"|"cut"|"note-cut"} or {edit: true}');
  if (spec.target === 'edit') return ['$edit'];
  if ('edit' in t) throw badRequest('target: this template goes on a clip or a cut, not the whole edit');
  if (spec.target === 'clip') {
    const ids = 'itemId' in t ? [t.itemId] : 'itemIds' in t ? t.itemIds : 'each' in t && t.each === 'clip' ? main.map(c => c.id) : null;
    if (!ids) throw badRequest('target: this template goes on a clip ({itemId} or {itemIds}, or {each: "clip"})');
    for (const id of ids) if (typeof id !== 'string' || !anyItem(id)) throw badRequest(`target: no item ${String(id)}`);
    return [...new Set(ids)];
  }
  // A cut: the clip after it. {cutAfter: c1} → the clip after c1.
  const after = (id: string) => {
    const k = main.findIndex(c => c.id === id);
    if (k < 0) throw badRequest(`target.cutAfter: ${id} is not a main-track clip`);
    if (k + 1 >= main.length) throw badRequest(`target.cutAfter: ${id} is the last clip (no cut after it)`);
    return main[k + 1]!.id;
  };
  if ('cutAfter' in t) return [after(t.cutAfter)];
  if ('cutsAfter' in t) return [...new Set(t.cutsAfter.map(after))];
  if ('itemId' in t && isMain(t.itemId)) return [t.itemId === main[0]?.id ? after(t.itemId) : t.itemId];
  if ('itemIds' in t) return [...new Set(t.itemIds.filter(isMain).map(id => (id === main[0]?.id ? after(id) : id)))];
  if ('each' in t && t.each === 'cut') return main.slice(1).map(c => c.id);
  if ('each' in t && t.each === 'note-cut') {
    const tol = 1.5 / (p.canvas.fps || 30);
    const ids = tl.slice(1).filter(s => notes.some(n => Math.abs(n - (s.startSec + s.transitionSec / 2)) <= tol)).map(s => s.id);
    if (!ids.length) throw badRequest('target: no cut lies on a note (song_notes or detect_beats first, or pick the cuts)');
    return ids;
  }
  throw badRequest('target: this template goes on a cut ({cutAfter: clipId}, {cutsAfter}, or {each: "cut" | "note-cut"})');
}

/** The music's beats on the timeline (detect_beats stores them per music clip in its own seconds). */
export function musicNotes(p: M.EditProject): number[] {
  const out: number[] = [];
  for (const t of p.tracks.filter(x => x.kind === 'music')) for (const c of t.items as M.AudioClip[]) {
    for (const b of c.beats ?? []) {
      if (b < c.inSec || b > c.outSec) continue;
      out.push(r3(c.startSec + (b - c.inSec) / (c.speed ?? 1)));
    }
  }
  return [...new Set(out)].sort((a, b) => a - b);
}

// ------------------------------------------------------------------ expansion
const findItem = (p: M.EditProject, id: string) => {
  for (const track of p.tracks) { const item = track.items.find(i => i.id === id); if (item) return { track, item }; }
  return null;
};
const newId = (p: M.EditProject, prefix: string, taken: Set<string>) => {
  const used = new Set([...p.tracks.flatMap(t => [t.id, ...t.items.map(i => i.id)]), ...p.assets.map(a => a.id), ...taken]);
  for (let n = 1; ; n++) if (!used.has(`${prefix}${n}`)) { taken.add(`${prefix}${n}`); return `${prefix}${n}`; }
};
const sortTrack = (t: M.Track) => { t.items.sort((a, b) => ((a as { startSec: number }).startSec ?? 0) - ((b as { startSec: number }).startSec ?? 0)); };

/** Param values: the caller's, checked against the spec, else the defaults (hidden params always take the default). */
export function paramValues(spec: EditTemplateSpec, given: Record<string, unknown> = {}): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  const known = new Set((spec.params ?? []).map(q => q.key));
  for (const k of Object.keys(given)) if (!known.has(k)) throw badRequest(`params.${k}: not a setting of ${spec.name} (${[...known].join(', ') || 'it has none'})`);
  for (const q of spec.params ?? []) {
    let v = q.needs && !primitiveLive(q.needs) ? undefined : given[q.key];
    if (v === undefined) v = q.default;
    switch (q.type) {
      case 'number': {
        if (typeof v !== 'number' || !Number.isFinite(v)) throw badRequest(`params.${q.key}: a number`);
        if ((q.min !== undefined && v < q.min) || (q.max !== undefined && v > q.max)) throw badRequest(`params.${q.key}: ${q.min ?? '…'}–${q.max ?? '…'}${q.unit ? ` ${q.unit}` : ''}`);
        break;
      }
      case 'enum': if (typeof v !== 'string' || !q.options?.includes(v)) throw badRequest(`params.${q.key}: one of ${q.options?.join(', ')}`); break;
      case 'bool': if (typeof v !== 'boolean') throw badRequest(`params.${q.key}: true or false`); break;
      case 'text': if (typeof v !== 'string' || v.length > M.LIMITS.maxText) throw badRequest(`params.${q.key}: text up to ${M.LIMITS.maxText} characters`); break;
      case 'upload': if (v !== undefined && v !== null && (typeof v !== 'string' || !/^[\w-]{1,80}$/.test(v))) throw badRequest(`params.${q.key}: an upload id`); break;
      case 'times': {
        if (v === undefined || v === null) { v = []; break; }
        if (!Array.isArray(v) || v.length > 100 || v.some(r => !Array.isArray(r) || r.length !== 2 || r.some(x => typeof x !== 'number' || !Number.isFinite(x)) || r[1] <= r[0]))
          throw badRequest(`params.${q.key}: up to 100 [startSec, endSec] ranges`);
        break;
      }
    }
    out[q.key] = v;
  }
  return out;
}

/**
 * Expands a template onto `targets` of a copy of the project: one pass per target, in timeline order. Throws bad_request
 * (or 409 for gates and the track limit) with a plain reason; never returns a project the apps can't read (the caller
 * still validates it like any other change).
 */
export function expandTemplate(project: M.EditProject, spec: EditTemplateSpec, target: Target, o: ExpandOptions = {}): Expansion {
  const r = readiness(spec);
  if (!r.ready) throw new ApiError(409, r.state, `${spec.name}: ${r.reason}`);
  const params = paramValues(spec, o.params);
  const known = o.notes?.length ? [...o.notes].sort((a, b) => a - b) : musicNotes(project);
  const targets = resolveTargets(project, spec, target, known);
  let p = clone(project);
  const out: Expansion = { project: p, labels: [], notes: [], added: [], mattes: [], tracksAdded: 0, targets };
  const tracks0 = p.tracks.length;
  const taken = new Set<string>();
  for (const tid of targets) p = expandOne(p, spec, tid, params, known, o, out, taken);
  out.project = p;
  out.tracksAdded = p.tracks.length - tracks0;
  if (p.tracks.length > M.LIMITS.maxTracks) {
    const free = Math.max(0, M.LIMITS.maxTracks - tracks0);
    throw new ApiError(409, 'too_many_tracks', `${spec.name} needs ${out.tracksAdded} free track${out.tracksAdded === 1 ? '' : 's'}; this edit has ${free} (an edit holds ${M.LIMITS.maxTracks}) · remove a track, or apply it to fewer ${spec.target === 'cut' ? 'cuts' : 'clips'}`);
  }
  out.labels.unshift(`${spec.name}${targets.length > 1 ? ` × ${targets.length}` : ''}`);
  return out;
}

function expandOne(p0: M.EditProject, spec: EditTemplateSpec, tid: string, params: Record<string, unknown>, known: number[], o: ExpandOptions, out: Expansion, taken: Set<string>): M.EditProject {
  let p = p0;
  const fps = p.canvas.fps || 30, frame = 1 / fps;
  const named = new Map<string, string>(); // name → item id
  const mainIds = () => M.mainTrack(p).items.map(c => c.id);
  let cut = 0;
  if (tid === '$edit') {
    // whole edit
  } else if (spec.target === 'cut') {
    const ids = mainIds(), k = ids.indexOf(tid);
    if (k < 1) throw badRequest(`target: ${tid} has no cut before it`);
    named.set('prev', ids[k - 1]!); named.set('next', tid); named.set('target', tid);
    const s = M.timeline(p)[k]!;
    cut = s.startSec + s.transitionSec / 2;
  } else {
    named.set('target', tid);
    const ids = mainIds(), k = ids.indexOf(tid);
    if (k > 0) named.set('prev', ids[k - 1]!);
    if (k >= 0 && k + 1 < ids.length) named.set('next', ids[k + 1]!);
  }
  const lastVisualTrack = { index: -1 };
  /** Item facts for $name.in / .out / .start / .end / .len / .speed / .scale. */
  const itemVar = (name: string, field: string): number | undefined => {
    const id = named.get(name);
    if (!id) return undefined;
    const f = findItem(p, id);
    if (!f) return undefined;
    const it = f.item as M.VideoClip, span = M.itemSpan(p, f.track, f.item);
    switch (field) {
      case 'in': return it.inSec; case 'out': return it.outSec; case 'start': return span.startSec; case 'end': return span.endSec;
      case 'len': return r6(span.endSec - span.startSec); case 'speed': return it.speed ?? 1; case 'scale': return it.transform?.scale ?? 1;
      case 'x': return it.transform?.x ?? 0.5; case 'y': return it.transform?.y ?? 0.5; case 'exposure': return it.adjust?.exposure ?? 0;
      case 'duration': return p.assets.find(a => a.id === it.asset)?.durationSec;
    }
    return undefined;
  };
  const baseVars = (local: Record<string, number> = {}) => (name: string): unknown => {
    if (name in local) return local[name];
    if (name === 'cut') return cut;
    if (name === 'fps') return fps;
    if (name === 'frame') return frame;
    if (name === 'duration') return M.durationSec(p);
    if (name in params) return params[name];
    const tgt = named.get('target');
    if (tgt && ['start', 'end', 'len', 'in', 'out', 'speed'].includes(name)) return itemVar('target', name);
    if (name.startsWith('base.')) return itemVar('target', name.slice(5));
    const dot = name.indexOf('.');
    if (dot > 0) return itemVar(name.slice(0, dot), name.slice(dot + 1));
    return undefined;
  };
  const num = (e: Expr, local?: Record<string, number>) => evalExpr(e, baseVars(local));
  /** A raw param (enum/text/upload) when the expression is just "$param"; else the number. */
  const raw = (e: Expr, local?: Record<string, number>): unknown => {
    if (typeof e === 'string') { const m = /^\$(\w+)$/.exec(e.trim()); if (m && m[1]! in params && typeof params[m[1]!] !== 'number') return params[m[1]!]; }
    if (typeof e === 'string' && !e.trim().startsWith('$') && !/^[\d(.+-]/.test(e.trim())) return e; // a literal word ("glitch")
    return num(e, local);
  };
  const on = (when?: When) => !when || ((when.is === undefined || params[when.param] === when.is) && (when.not === undefined || params[when.param] !== when.not));
  const ref = (name: string | undefined, f: string) => {
    const id = named.get(name ?? 'target');
    if (!id) throw badRequest(`${spec.name}: ${f} needs ${name === 'prev' ? 'a clip before' : name === 'next' ? 'a clip after' : `"${name}"`} the target`);
    const found = findItem(p, id);
    if (!found) throw badRequest(`${spec.name}: ${name} is gone`);
    return found;
  };
  /** Keys in item seconds: norm × len, frames × 1/fps, or seconds; sorted, one per time, clamped into the item. */
  const keysOf = (keys: Partial<Record<M.KfProp, KeySpec[]>> | undefined, unit: Unit, len: number, local: Record<string, number>): M.Keyframes => {
    const kf: M.Keyframes = {};
    for (const [prop, list] of Object.entries(keys ?? {}) as [M.KfProp, KeySpec[]][]) {
      const loc = { ...local, len };
      const ks = list.map(k => {
        const t = num(k.t, loc), at = unit === 'norm' ? t * len : unit === 'frames' ? t * frame : t;
        const e = k.ease === undefined ? undefined : typeof k.ease === 'string' && k.ease.startsWith('$') ? String(params[k.ease.slice(1)]) : k.ease;
        return { t: r6(Math.min(len, Math.max(0, at))), v: r6(num(k.v, loc)), ...(e && e !== 'linear' ? { ease: e as M.Ease } : {}) };
      }).sort((a, b) => a.t - b.t);
      const dedup: M.Keyframe[] = [];
      for (const k of ks) { if (dedup.length && Math.abs(dedup[dedup.length - 1]!.t - k.t) < 1e-6) dedup[dedup.length - 1] = k; else dedup.push(k); }
      kf[prop] = dedup;
    }
    return kf;
  };
  const evalFields = (fields: Record<string, unknown> | undefined, local: Record<string, number>): Record<string, unknown> => {
    const ev = (v: unknown): unknown => {
      if (typeof v === 'number') return v;
      if (typeof v === 'string') return v.startsWith('$') || /^[\d(]/.test(v) ? raw(v, local) : v;
      if (Array.isArray(v)) return v.map(ev);
      if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, ev(x)]));
      return v;
    };
    return (ev(fields ?? {}) as Record<string, unknown>);
  };
  /** A track of `kind` free over [a, b): above this template's last visual item, else a new one on top. */
  const trackFor = (kind: M.TrackKind, a: number, b: number): M.Track => {
    const visual = kind === 'video' || kind === 'image';
    for (let ti = 0; ti < p.tracks.length; ti++) {
      const t = p.tracks[ti]!;
      if (t.kind !== kind || (visual && ti <= lastVisualTrack.index) || t.hidden) continue;
      if (t.items.every(it => { const s = M.itemSpan(p, t, it); return s.endSec <= a + 1e-6 || s.startSec >= b - 1e-6; })) { if (visual) lastVisualTrack.index = ti; return t; }
    }
    const t: M.Track = { id: newId(p, kind, taken), kind, items: [] };
    // New visual tracks go above every overlay (and under nothing that draws later: text and captions draw last anyway).
    p.tracks.push(t);
    if (visual) lastVisualTrack.index = p.tracks.length - 1;
    return t;
  };
  /** The pack's entrance wash: a new layer's first frames lifted toward white (or cooled toward deep blue), k 0.6, 0.3;
   * thin layers (a slat, a stripe: under a quarter of the frame across) 0.9, 0.65, 0.35. Back to its own colour after. */
  const washKeys = (color: unknown, len: number, thin: boolean): M.Keyframes => {
    if (color !== 'white' && color !== 'blue') return {};
    const list = thin ? [0.9, 0.65, 0.35] : [0.6, 0.3];
    if (len < (list.length + 1) * frame) return {};
    const keys = (sign: number, scale: number) => [...list.map((k, j) => ({ t: r6(j * frame), v: r6(sign * k * scale), ease: 'hold' as M.Ease })), { t: r6(list.length * frame), v: 0 }];
    return color === 'white' ? { exposure: keys(1, 1) } : { temperature: keys(-1, 1), exposure: keys(-1, 0.35) };
  };
  const mergeKeys = (it: { keyframes?: M.Keyframes }, kf: M.Keyframes) => {
    if (!Object.keys(kf).length) return;
    it.keyframes = { ...(it.keyframes ?? {}), ...kf };
  };
  /** Visual fields a copy keeps from its source so it sits exactly where the shot itself is ("in place and unscaled"). */
  const LOOK_FIELDS = ['fit', 'crop', 'transform', 'look', 'adjust', 'filter', 'chroma', 'effect'] as const;

  for (const step of spec.steps ?? []) {
    if (!on(step.when)) continue;
    switch (step.do) {
      case 'split': {
        const { item } = ref(step.on, 'split');
        const at = num(step.at);
        const before = new Set(mainIds());
        try { p = applyOps(p, [{ op: 'split', at: r6(at) }]).project; } catch (e) { throw badRequest(`${spec.name}: can't split ${item.id} at ${t2(at)} (${(e as Error).message.replace(/^ops\.0\.split\.at: /, '')})`); }
        const ids = mainIds(), k = ids.indexOf(item.id);
        const fresh = ids.find(id => !before.has(id));
        if (k < 0 || !fresh) throw badRequest(`${spec.name}: the split at ${t2(at)} didn't land in ${item.id}`);
        named.set(step.names[0], item.id); named.set(step.names[1], fresh);
        out.labels.push(`split at ${t2(at)}`);
        break;
      }
      case 'freeze': {
        const { item } = ref(step.on, 'freeze');
        const span = M.itemSpan(p, M.mainTrack(p), item);
        const sec = num(step.sec);
        const before = new Set(mainIds());
        try { p = applyOps(p, [{ op: 'freeze', at: r6(Math.max(span.startSec, span.endSec - frame)), durationSec: r3(sec) }]).project; } catch (e) { throw badRequest(`${spec.name}: can't freeze ${item.id} (${(e as Error).message})`); }
        const added = mainIds().filter(id => !before.has(id));
        const hold = added.find(id => (findItem(p, id)!.item as M.VideoClip).holdSec !== undefined);
        if (!hold) throw badRequest(`${spec.name}: the freeze frame didn't land`);
        named.set(step.as, hold);
        out.labels.push(`freeze ${sec.toFixed(1)} s`);
        break;
      }
      case 'set': {
        const { track, item } = ref(step.on, 'set');
        const span = M.itemSpan(p, track, item), len = span.endSec - span.startSec;
        const f = evalFields(step.fields, { len });
        if (f.blend !== undefined && track.kind !== 'video' && track.kind !== 'image') delete f.blend;
        Object.assign(item, f);
        mergeKeys(item as { keyframes?: M.Keyframes }, keysOf(step.keys, step.unit ?? 'norm', len, {}));
        out.labels.push(`${item.id}: ${[...Object.keys(f), ...Object.keys(step.keys ?? {})].join(', ')}`);
        break;
      }
      case 'transition': {
        const { item } = ref(step.on ?? 'next', 'transition');
        const kind = raw(step.kind) as M.TransitionKind;
        if (!M.TRANSITIONS.includes(kind)) throw badRequest(`${spec.name}: unknown transition ${String(kind)}`);
        const ids = mainIds(), k = ids.indexOf(item.id);
        if (k < 1) throw badRequest(`${spec.name}: ${item.id} has no clip before it for a transition`);
        const a = M.clipLength(M.mainTrack(p).items[k - 1] as M.VideoClip), b = M.clipLength(item as M.VideoClip);
        const want = num(step.sec), most = Math.min(a, b) / 2;
        if (most < M.LIMITS.minTransitionSec) { out.notes.push(`${item.id}: too short for a transition (needs ${M.LIMITS.minTransitionSec * 2} s on each side)`); break; }
        const d = r3(Math.min(M.LIMITS.maxTransitionSec, Math.max(M.LIMITS.minTransitionSec, Math.min(want, most))));
        if (d < want - 1e-6) out.notes.push(`${item.id}: the ${kind} is ${d} s (half the shorter clip)`);
        (item as M.VideoClip).transitionIn = { kind, durationSec: d };
        out.labels.push(`${kind} ${d} s`);
        break;
      }
      case 'wash': {
        const { track, item } = ref(step.on, 'wash');
        const span = M.itemSpan(p, track, item);
        const mk = (item as M.VideoClip).mask;
        mergeKeys(item as { keyframes?: M.Keyframes }, washKeys(raw(step.color), span.endSec - span.startSec, !!mk && Math.min(mk.width ?? 1, mk.height ?? 1) < 0.25));
        break;
      }
      case 'jitter': {
        const { track, item } = ref(step.on, 'jitter');
        const span = M.itemSpan(p, track, item), len = span.endSec - span.startSec;
        const amt = num(step.amount), stepSec = Math.max(2 * frame, num(step.step));
        const times = known.filter(n => n > span.startSec && n < span.endSec - 2 * frame).map(n => n - span.startSec);
        const hits = times.length ? times : Array.from({ length: Math.floor(len / stepSec) }, (_, j) => (j + 1) * stepSec).filter(t => t < len - 2 * frame);
        const base = step.prop === 'opacity' ? 1 : step.prop === 'rotation' ? 0 : step.prop === 'x' ? ((item as M.TextItem).transform?.x ?? 0.5) : ((item as M.TextItem).transform?.y ?? 0.5);
        const ks: M.Keyframe[] = [{ t: 0, v: base }];
        hits.slice(0, 40).forEach((t, j) => {
          const off = step.prop === 'opacity' ? -amt : (j % 2 ? -amt : amt);
          ks.push({ t: r6(t), v: r6(Math.max(step.prop === 'opacity' ? 0 : -2, base + off)), ease: 'hold' }, { t: r6(Math.min(len, t + 2 * frame)), v: base });
        });
        mergeKeys(item as { keyframes?: M.Keyframes }, { [step.prop]: ks });
        out.labels.push(`${step.prop} jitter on ${hits.length} hit${hits.length === 1 ? '' : 's'}`);
        break;
      }
      case 'matte': {
        const { track, item } = ref(step.on, 'matte');
        if (track.kind !== 'main') throw badRequest(`${spec.name}: the subject layer is for main-track clips`);
        out.mattes.push({ itemId: item.id, reveal: 1, layer: { clip: item.id, name: step.name ?? 'Subject', aboveText: step.aboveText ?? true } });
        break;
      }
      case 'add': {
        // Each copy, note, cell, range or pack file adds one item, with its own loop variables.
        const loops: Record<string, number>[] = [];
        const shapeName = typeof params.shape === 'string' ? params.shape : undefined;
        let shapeCopies: ShapeKey[][] = [];
        if (step.for === 'shape' || step.mask === '$shape') {
          shapeCopies = (shapeName && spec.shapes?.[shapeName]) || [];
          if (!shapeCopies.length) throw badRequest(`${spec.name}: no shape "${shapeName}"`);
        }
        if (step.for === 'shape') shapeCopies.forEach((_, i) => loops.push({ i, n: shapeCopies.length }));
        else if (step.for === 'notes') {
          const n = Math.max(1, Math.min(12, Math.round(num(step.notes!.count)))), gap = Math.max(2 * frame, num(step.notes!.step));
          const end = tid === '$edit' ? M.durationSec(p) : spec.target === 'cut' ? cut : itemVar('target', 'end')!;
          const begin = spec.target === 'cut' ? Math.max(0, itemVar('prev', 'start') ?? 0) : itemVar('target', 'start') ?? 0;
          const from = known.filter(t => t < end - 2 * frame && t >= begin).slice(-n);
          const times = from.length >= n ? from : Array.from({ length: n }, (_, j) => r3(end - (n - j) * gap)).filter(t => t >= begin);
          if (!times.length) throw badRequest(`${spec.name}: no room for its notes before ${t2(end)}`);
          times.forEach((t, i) => {
            const nextNote = i + 1 < times.length ? times[i + 1]! : end;
            if (step.notes!.only === 'last' && i !== times.length - 1) return;
            if (step.notes!.only === 'notLast' && i === times.length - 1) return;
            loops.push({ i, n: times.length, note: t, nextNote, end });
          });
          if (!from.length && n > 1) out.notes.push('no beats on the music: its stages are evenly spaced (detect_beats or song_notes to put them on the notes)');
        } else if (step.for === 'cells') {
          const g = Math.round(Number(params.grid ?? 2));
          const ti = g * g - 1;
          for (let i = 0; i < g * g; i++) loops.push({ i, n: g * g, g, cx: ((i % g) + 0.5) / g, cy: (Math.floor(i / g) + 0.5) / g, tx: ((ti % g) + 0.5) / g, ty: (Math.floor(ti / g) + 0.5) / g, isTarget: i === ti ? 1 : 0, k: i - ti });
        } else if (step.for === 'ranges') {
          const hide = M.mergeRanges(((params.hideOn as number[][]) ?? []).map(r => ({ startSec: r[0]!, endSec: r[1]! })));
          let a = 0;
          const d = M.durationSec(p);
          for (const h of [...hide, { startSec: d, endSec: d }]) {
            const b = Math.min(d, h.startSec);
            if (b - a >= M.LIMITS.minItemSec) loops.push({ i: loops.length, rs: r6(a), re: r6(b) });
            a = Math.max(a, h.endSec);
          }
        } else if (step.for === 'media') {
          const list = (o.media ?? []).filter(m => m.kind === (step.track === 'sfx' ? 'audio' : step.track === 'video' ? 'video' : 'image') && m.role === 'overlay');
          list.slice(0, 24).forEach((_, i) => loops.push({ i, n: list.length }));
        } else loops.push({});
        for (const loc of loops) addItem(step, loc, step.for === 'shape' ? shapeCopies[loc.i!] : step.mask === '$shape' ? shapeCopies[0] : undefined);
        break;
      }
    }
  }
  return p;

  function addItem(step: Extract<Step, { do: 'add' }>, local: Record<string, number>, shape: ShapeKey[] | undefined) {
    let start = num(step.start, local), len = num(step.length, local);
    // A staggered shape copy (first key after 0) starts with that key.
    if (shape && shape[0]!.t > 0) { const d = shape[0]!.t * len; start += d; len -= d; }
    if (start < 0) { len += start; start = 0; }
    if (len < M.LIMITS.minItemSec) { out.notes.push(`${spec.name}: a piece was too short to add (${r3(len)} s)`); return; }
    const kindOf: Record<typeof step.track, M.TrackKind> = { video: 'video', image: 'image', adjust: 'adjust', text: 'text', sfx: 'sfx' };
    const track = trackFor(kindOf[step.track], start, start + len);
    const id = newId(p, step.track === 'video' ? 'v' : step.track === 'image' ? 'i' : step.track === 'adjust' ? 'adj' : step.track === 'text' ? 't' : 'sx', taken);
    const f = evalFields(step.fields, { ...local, len });
    let item: M.Item;
    const src = step.source;
    if (step.track === 'video' && src && !src.startsWith('pack:') && !src.startsWith('upload:') && !src.startsWith('param:')) {
      // A copy of a clip on the timeline ($next, $prev, a named piece, or main:<k> relative to the clip after the cut).
      let from: M.VideoClip;
      if (src.startsWith('main:')) {
        const ids = mainIds(), base = ids.indexOf(named.get('next') ?? named.get('target') ?? ids[0]!);
        const k = Math.max(0, Math.min(ids.length - 1, base + Math.round(num(src.slice(5), local))));
        from = findItem(p, ids[k]!)!.item as M.VideoClip;
      } else from = ref(src.replace(/^\$/, ''), 'a copy').item as M.VideoClip;
      const speed = step.hold ? 1 : (from.speed ?? 1);
      const dur = p.assets.find(a => a.id === from.asset)?.durationSec;
      let inSec = step.in !== undefined ? num(step.in, { ...local, len, srcIn: from.inSec, srcSpeed: from.speed ?? 1 }) : from.inSec;
      const need = step.hold ? M.LIMITS.minClipSourceSec : len * speed;
      if (inSec < 0) { out.notes.push(`${id}: the shot starts too early to play ${r3(-inSec)} s before its in-point; it starts at its first frame`); inSec = 0; }
      if (dur !== undefined && inSec + need > dur) { inSec = Math.max(0, dur - need); out.notes.push(`${id}: the shot ends before the piece does; it plays the shot's last ${r3(need)} s`); }
      if (dur !== undefined && need > dur + 1e-6) throw badRequest(`${spec.name}: ${from.id}'s source is too short (${r3(dur)} s) for a ${r3(len)} s piece`);
      const c: M.VideoClip = { id, asset: from.asset, inSec: r6(inSec), outSec: r6(inSec + need), speed, startSec: r6(start), muted: true,
        ...(step.hold ? { holdSec: r6(Math.max(M.HOLD_MIN_SEC, len)) } : {}) };
      if (step.copyLook !== false) for (const k of LOOK_FIELDS) if ((from as Record<string, unknown>)[k] !== undefined) (c as Record<string, unknown>)[k] = clone((from as Record<string, unknown>)[k]);
      item = c;
    } else if (step.track === 'adjust') {
      item = { id, startSec: r6(start), durationSec: r6(len) } as M.AdjustItem;
    } else if (step.track === 'text') {
      const tm = typeof step.text === 'string' ? /^\$(\w+)$/.exec(step.text.trim()) : null;
      const text = String(tm ? params[tm[1]!] ?? '' : step.text ?? '').slice(0, M.LIMITS.maxText);
      if (!text.trim()) { out.notes.push(`${spec.name}: no text, so no title`); return; }
      item = { id, startSec: r6(start), durationSec: r6(len), text, style: { font: 'condensed', weight: 900, sizePct: 0.16, color: '#FFFFFF', align: 'center', uppercase: true } } as M.TextItem;
    } else {
      // A file: an upload the person or the pack gave (an image, a sound, or a video to lay over).
      let upload: string | undefined;
      let kind: M.Asset['kind'] = step.track === 'sfx' ? 'audio' : step.track === 'image' ? 'image' : 'video';
      let durationSec: number | undefined;
      if (src?.startsWith('param:')) upload = params[src.slice(6)] as string | undefined;
      else if (src?.startsWith('upload:')) upload = src.slice(7);
      else if (src?.startsWith('pack:')) {
        const role = src.slice(5);
        const list = (o.media ?? []).filter(m => m.role === role && m.kind === kind);
        const m = list[step.for === 'media' ? local.i! : 0];
        upload = m?.uploadId; durationSec = m?.durationSec;
      }
      if (!upload) {
        if (step.track === 'sfx') { out.notes.push(`${spec.name}: the pack has no sound for it, so none was added`); return; }
        throw badRequest(`${spec.name}: needs ${src?.startsWith('param:') ? `params.${src.slice(6)} (an upload id: ${kind === 'image' ? 'a picture' : 'a file'} you uploaded)` : 'a file from its pack, which hasn\'t been sent'}`);
      }
      let asset = p.assets.find(a => a.upload === upload && a.kind === kind);
      if (!asset) { asset = { id: newId(p, kind === 'image' ? 'img' : kind === 'audio' ? 'snd' : 'vid', taken), kind, upload, ...(durationSec ? { durationSec } : {}) }; p.assets.push(asset); }
      if (step.track === 'image') item = { id, asset: asset.id, startSec: r6(start), durationSec: r6(len), fit: 'contain' } as M.ImageItem;
      else {
        kind = asset.kind;
        const inSec = 0, outSec = r6(Math.min(asset.durationSec ?? len, len));
        if (outSec - inSec < M.LIMITS.minClipSourceSec) { out.notes.push(`${spec.name}: its sound is too short to add`); return; }
        item = { id, asset: asset.id, startSec: r6(start), inSec, outSec, ...(step.track === 'video' ? { speed: 1, muted: true } : {}) } as M.AudioClip;
      }
    }
    Object.assign(item, f);
    // The mask: a fixed shape, or the template's shape copy as hold-eased keys (rect [x, y, w, h] from the top-left).
    if (step.mask && (step.track === 'video' || step.track === 'image')) {
      const vis = item as M.VideoClip;
      if (step.mask === '$shape' || shape) {
        const keys = (shape ?? []).map(k => ({ t: k.t, x: k.rect[0] + k.rect[2] / 2, y: k.rect[1] + k.rect[3] / 2, w: k.rect[2], h: k.rect[3], rot: k.rot ?? 0 }));
        const t0 = keys[0]?.t ?? 0;
        const first = keys[0] ?? { x: 0.5, y: 0.5, w: 1, h: 1, rot: 0 };
        vis.mask = { shape: 'rect', x: r6(first.x), y: r6(first.y), width: r6(first.w), height: r6(first.h), feather: 0.004, ...(first.rot ? { rotation: first.rot } : {}) };
        if (keys.length > 1) {
          const at = (t: number) => r6(Math.max(0, Math.min(len, ((t - t0) / Math.max(1e-6, 1 - t0)) * len)));
          const kk = (pick: (k: typeof keys[number]) => number) => keys.map(k => ({ t: at(k.t), v: r6(pick(k)), ease: 'hold' as M.Ease }));
          mergeKeys(vis, { maskX: kk(k => k.x), maskY: kk(k => k.y), maskWidth: kk(k => k.w), maskHeight: kk(k => k.h), ...(keys.some(k => k.rot) ? { maskRotation: kk(k => k.rot) } : {}) });
        }
      } else {
        const m = step.mask, loc = { ...local, len };
        const val = (e: Expr | undefined) => (e === undefined ? undefined : r6(num(e, loc)));
        vis.mask = Object.fromEntries(Object.entries({ shape: m.shape, x: val(m.x), y: val(m.y), width: val(m.width), height: val(m.height), rotation: val(m.rotation), feather: val(m.feather), invert: m.invert })
          .filter(([, v]) => v !== undefined)) as M.Mask;
      }
    }
    mergeKeys(item as { keyframes?: M.Keyframes }, keysOf(step.keys, step.unit ?? 'norm', len, local));
    if (step.wash !== undefined && (step.track === 'video' || step.track === 'image')) {
      const mk = (item as M.VideoClip).mask;
      mergeKeys(item as { keyframes?: M.Keyframes }, washKeys(raw(step.wash, local), len, !!mk && Math.min(mk.width ?? 1, mk.height ?? 1) < 0.25));
    }
    if (step.matte) {
      // A paid subject matte (Remove background, priced on Apply): the copy stays hidden until the matte arrives.
      const reveal = (item as M.VideoClip).opacity ?? 1;
      (item as M.VideoClip).opacity = 0;
      out.mattes.push({ itemId: id, reveal });
    }
    track.items.push(item);
    sortTrack(track);
    if (step.as) named.set(step.as, id);
    out.added.push(id);
    out.labels.push(`added ${step.track === 'video' ? 'a copy' : step.track} ${id} at ${t2(start)}`);
  }
}

// ------------------------------------------------------------------ checking a spec someone saves
export const SPEC_LIMITS = { bytes: 64_000, steps: 40, params: 12, keys: 40, shapes: 12 } as const;
const STEP_KINDS = ['split', 'freeze', 'set', 'transition', 'add', 'wash', 'jitter', 'matte'];
const SLUG = /^[a-z0-9][a-z0-9-]{1,63}$/;
/** A spec as sent (by Claude or Save as template): its shape checked, values normalised. Expressions are checked when applied. */
export function checkSpec(raw: unknown): EditTemplateSpec {
  let s = raw;
  if (typeof s === 'string') { try { s = JSON.parse(s); } catch { throw badRequest('spec: JSON'); } }
  if (!s || typeof s !== 'object' || Array.isArray(s)) throw badRequest('spec: an object {v: 1, id, name, kind, target, level, params?, steps}');
  if (Buffer.byteLength(JSON.stringify(s)) > SPEC_LIMITS.bytes) throw badRequest(`spec: at most ${SPEC_LIMITS.bytes / 1000} KB`);
  const x = s as Record<string, unknown>;
  const spec = { ...x, v: 1 } as EditTemplateSpec;
  if (typeof spec.id !== 'string' || !SLUG.test(spec.id)) throw badRequest('spec.id: a short slug like "window-open-next"');
  if (typeof spec.name !== 'string' || !spec.name.trim() || spec.name.length > 60) throw badRequest('spec.name: 1–60 characters');
  if (typeof spec.description !== 'string') spec.description = '';
  if (spec.description.length > 600) throw badRequest('spec.description: at most 600 characters');
  if (!['transition', 'effect'].includes(spec.kind)) throw badRequest('spec.kind: transition or effect (photo presets are templates_manage; caption styles are caption_style)');
  if (!['clip', 'cut', 'edit'].includes(spec.target)) throw badRequest('spec.target: clip, cut or edit');
  if (!['live', 'matte', 'primitive', 'reference'].includes(spec.level)) throw badRequest('spec.level: live, matte, primitive or reference');
  if (spec.requires !== undefined && (!Array.isArray(spec.requires) || spec.requires.some(n => !(n in PRIMITIVES)))) throw badRequest(`spec.requires: from ${Object.keys(PRIMITIVES).join(', ')}`);
  if (spec.params !== undefined) {
    if (!Array.isArray(spec.params) || spec.params.length > SPEC_LIMITS.params) throw badRequest(`spec.params: at most ${SPEC_LIMITS.params}`);
    for (const q of spec.params) {
      if (!q || typeof q.key !== 'string' || !/^[a-zA-Z]\w{0,30}$/.test(q.key)) throw badRequest('spec.params: each needs a key (letters)');
      if (!['number', 'enum', 'bool', 'text', 'upload', 'times'].includes(q.type)) throw badRequest(`spec.params.${q.key}.type: number, enum, bool, text, upload or times`);
      if (typeof q.label !== 'string') q.label = q.key;
    }
    paramValues(spec, {}); // defaults must be valid
  }
  if (spec.steps !== undefined && (!Array.isArray(spec.steps) || spec.steps.length > SPEC_LIMITS.steps)) throw badRequest(`spec.steps: at most ${SPEC_LIMITS.steps}`);
  for (const [j, st] of (spec.steps ?? []).entries()) {
    if (!st || typeof st !== 'object' || !STEP_KINDS.includes((st as Step).do)) throw badRequest(`spec.steps.${j}.do: one of ${STEP_KINDS.join(', ')}`);
    const fields = (st as { fields?: Record<string, unknown> }).fields;
    if (fields !== undefined) {
      if (!fields || typeof fields !== 'object') throw badRequest(`spec.steps.${j}.fields: an object`);
      const e = fields.effect as { id?: unknown } | undefined;
      if (e !== undefined && (!e || typeof e !== 'object' || !EFFECT_IDS.includes(e.id as never))) throw badRequest(`spec.steps.${j}.fields.effect.id: one of ${EFFECT_IDS.join(', ')} (new effects need the next app update)`);
      for (const k of ['id', 'asset', 'startSec', 'inSec', 'outSec', 'layers', 'alphaMatte']) if (k in fields) throw badRequest(`spec.steps.${j}.fields.${k}: set by the template itself`);
    }
    const ks = (st as { keys?: Record<string, unknown[]> }).keys;
    if (ks !== undefined) for (const [prop, list] of Object.entries(ks)) if (!Array.isArray(list) || list.length > SPEC_LIMITS.keys) throw badRequest(`spec.steps.${j}.keys.${prop}: at most ${SPEC_LIMITS.keys} keys`);
  }
  if (spec.shapes !== undefined) {
    if (!spec.shapes || typeof spec.shapes !== 'object' || Object.keys(spec.shapes).length > SPEC_LIMITS.shapes) throw badRequest(`spec.shapes: at most ${SPEC_LIMITS.shapes}`);
    for (const [k, copies] of Object.entries(spec.shapes)) {
      if (!Array.isArray(copies) || !copies.length || copies.length > 16 || copies.some(c => !Array.isArray(c) || !c.length || c.some(q => typeof q?.t !== 'number' || q.t < 0 || q.t > 1 || !Array.isArray(q.rect) || q.rect.length !== 4 || q.rect.some((v: unknown) => typeof v !== 'number' || v < -1 || v > 2))))
        throw badRequest(`spec.shapes.${k}: copies [[{t 0–1, rect [x, y, w, h]}]] (≤ 16 copies)`);
    }
  }
  if (spec.source?.scripts !== undefined && (!Array.isArray(spec.source.scripts) || spec.source.scripts.some(p => typeof p !== 'string' || p.length > 200))) throw badRequest('spec.source.scripts: pack file paths (kept as text, never run)');
  if ((spec.level === 'live' || spec.level === 'matte') && !spec.steps?.length) throw badRequest('spec.steps: a live template needs its steps');
  return spec;
}

// ------------------------------------------------------------------ Save as template: a selection → a spec
/** What the person selected, as a template: the target's picture fields and normalised keys, and the overlays, sounds
 * and adjustment layers over it (copies of a neighbour become $next / $prev). Claude can add params afterwards. */
export function specFromSelection(p: M.EditProject, sel: { itemIds: string[]; cutAt?: number }, meta: { id: string; name: string; kind: TplKind; target?: TplTarget; description?: string }): EditTemplateSpec {
  if (!Array.isArray(sel.itemIds) || !sel.itemIds.length) throw badRequest('from.itemIds: the selected item(s)');
  const main = M.mainTrack(p), tl = M.timeline(p);
  const first = findItem(p, sel.itemIds[0]!);
  if (!first) throw badRequest(`from.itemIds: no item ${sel.itemIds[0]}`);
  const steps: Step[] = [];
  const target: TplTarget = meta.target ?? (sel.cutAt !== undefined ? 'cut' : 'clip');
  let anchor: { start: number; end: number; next?: M.VideoClip; prev?: M.VideoClip; ref: string };
  if (target === 'cut') {
    const at = sel.cutAt ?? M.itemSpan(p, first.track, first.item).startSec;
    const k = tl.findIndex(s => s.index > 0 && Math.abs(s.startSec + s.transitionSec / 2 - at) < 0.1);
    if (k < 1) throw badRequest('from.cutAt: a cut on the main track (timeline seconds)');
    const nx = main.items[k] as M.VideoClip;
    if (nx.transitionIn) steps.push({ do: 'transition', on: 'next', kind: nx.transitionIn.kind, sec: nx.transitionIn.durationSec });
    anchor = { start: tl[k]!.startSec + tl[k]!.transitionSec / 2, end: tl[k]!.startSec + tl[k]!.transitionSec / 2, next: nx, prev: main.items[k - 1] as M.VideoClip, ref: '$cut' };
  } else {
    const it = first.item as M.VideoClip, span = M.itemSpan(p, first.track, first.item), len = span.endSec - span.startSec;
    const k = main.items.findIndex(c => c.id === it.id);
    anchor = { start: span.startSec, end: span.endSec, ref: '$start', ...(k > 0 ? { prev: main.items[k - 1] as M.VideoClip } : {}), ...(k >= 0 && k + 1 < main.items.length ? { next: main.items[k + 1] as M.VideoClip } : {}) };
    const fields: Record<string, unknown> = {};
    for (const f of ['effect', 'look', 'adjust', 'filter', 'mask', 'blend', 'opacity', 'animIn', 'animOut', 'animLoop'] as const) if ((it as Record<string, unknown>)[f] !== undefined) fields[f] = clone((it as Record<string, unknown>)[f]);
    const keys: Partial<Record<M.KfProp, KeySpec[]>> = {};
    for (const [prop, list] of Object.entries(it.keyframes ?? {}) as [M.KfProp, M.Keyframe[]][]) {
      if (prop === 'volume') continue;
      keys[prop] = list.map(k => ({ t: r6(len > 0 ? k.t / len : 0), v: prop === 'scale' && (it.transform?.scale ?? 1) !== 1 ? `${r6(k.v / (it.transform?.scale ?? 1))} * $base.scale` : k.v, ...(k.ease ? { ease: k.ease } : {}) }));
    }
    if (Object.keys(fields).length || Object.keys(keys).length) steps.push({ do: 'set', on: 'target', ...(Object.keys(fields).length ? { fields } : {}), ...(Object.keys(keys).length ? { keys, unit: 'norm' } : {}) });
  }
  // Overlays, adjustment layers, text and sounds over the anchor (the clip's span, or ±2 s round the cut), or selected.
  const lo = target === 'cut' ? anchor.start - 2 : anchor.start, hi = target === 'cut' ? anchor.end + 2 : anchor.end;
  const picked = new Set(sel.itemIds);
  for (const t of p.tracks) {
    if (t.kind === 'main' || t.kind === 'caption' || t.kind === 'music' || t.kind === 'voice') continue;
    for (const it of t.items) {
      const s = M.itemSpan(p, t, it);
      if (!picked.has(it.id) && (s.endSec <= lo + 1e-6 || s.startSec >= hi - 1e-6)) continue;
      if (sel.itemIds.length > 1 && !picked.has(it.id)) continue;
      const off = r6(s.startSec - anchor.start), len = r6(s.endSec - s.startSec);
      const start = off === 0 ? anchor.ref : `${anchor.ref} ${off < 0 ? '-' : '+'} ${Math.abs(off)}`;
      const { id: _i, startSec: _s, asset: _a, inSec: _in, outSec: _out, keyframes, ...rest } = it as M.VideoClip & Record<string, unknown>;
      const keys = keyframes ? Object.fromEntries(Object.entries(keyframes).map(([k, list]) => [k, (list as M.Keyframe[]).map(q => ({ t: q.t, v: q.v, ...(q.ease ? { ease: q.ease } : {}) }))])) : undefined;
      const base = { start, length: len, ...(keys ? { keys, unit: 'sec' as Unit } : {}) };
      if (t.kind === 'video') {
        const c = it as M.VideoClip;
        const nb = anchor.next?.asset === c.asset ? { name: '$next', clip: anchor.next } : anchor.prev?.asset === c.asset ? { name: '$prev', clip: anchor.prev } : null;
        const { muted: _m, speed: _sp, holdSec, transitionIn: _ti, alphaMatte, ...fields } = rest as M.VideoClip & Record<string, unknown>;
        if (nb) {
          const d = r6(c.inSec - nb.clip.inSec);
          steps.push({ do: 'add', track: 'video', source: nb.name, in: d === 0 ? `${nb.name}.in` : `${nb.name}.in ${d < 0 ? '-' : '+'} ${Math.abs(d)}`, ...base, copyLook: false, fields, ...(holdSec !== undefined ? { hold: true } : {}), ...(alphaMatte ? { matte: true } : {}) });
        } else {
          const a = p.assets.find(x => x.id === c.asset);
          if (!a?.upload) continue; // a take of its own: only neighbours and uploads travel with a template
          steps.push({ do: 'add', track: 'video', source: `upload:${a.upload}`, ...base, fields });
        }
      } else if (t.kind === 'image') {
        const a = p.assets.find(x => x.id === (it as M.ImageItem).asset);
        if (!a?.upload) continue;
        const { transitionIn: _ti, ...fields } = rest;
        steps.push({ do: 'add', track: 'image', source: `upload:${a.upload}`, ...base, fields });
      } else if (t.kind === 'adjust') {
        const { durationSec: _d, ...fields } = rest;
        steps.push({ do: 'add', track: 'adjust', ...base, fields });
      } else if (t.kind === 'text') {
        const { durationSec: _d, text, pin: _pin, ...fields } = rest as unknown as M.TextItem & Record<string, unknown>;
        steps.push({ do: 'add', track: 'text', text: text.startsWith('$') ? ` ${text}` : text, ...base, fields });
      } else if (t.kind === 'sfx') {
        const a = p.assets.find(x => x.id === (it as M.AudioClip).asset);
        if (!a?.upload) continue;
        const { speed: _sp, ...fields } = rest;
        steps.push({ do: 'add', track: 'sfx', source: `upload:${a.upload}`, ...base, fields });
      }
    }
  }
  if (!steps.length) throw badRequest('from: the selection has nothing a template keeps (an effect, look, colour, mask, keyframes, or overlays and sounds over it)');
  return checkSpec({ v: 1, id: meta.id, name: meta.name, description: meta.description ?? '', kind: meta.kind, target, level: steps.some(s => s.do === 'add' && s.matte) ? 'matte' : 'live', steps, source: { by: 'selection' } });
}
