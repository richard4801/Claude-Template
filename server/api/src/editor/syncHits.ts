// sync_hits (free, one undoable step): retime one main-track clip so each chosen moment of it (an impact: a landing, a
// contact) lands exactly on a chosen timeline time (a note). The clip is split at the impacts; each piece gets a smooth
// speed curve (ease between the speeds of its neighbours, so no jumps) whose length puts its end exactly on its target,
// to the project's frame. Speeds stay within 0.25–4×; a pair that would need more is refused with the speed it needs.
// Only the clip's length changes (the rest of the main track moves with it, as a speed change does today).
import { ApiError, badRequest } from '../errors.js';
import type { EditTool, ToolEnv } from './mcpTools.js';
import * as M from './model.js';
import { applyOps } from './ops.js';
import { editSessionsOf } from './sessions.js';

export const SYNC_LIMITS = { minSpeed: 0.25, maxSpeed: 4, minPieceSec: M.LIMITS.minClipSourceSec, maxHits: 64 } as const;
const r6 = (v: number) => Math.round(v * 1e6) / 1e6, r3 = (v: number) => Math.round(v * 1000) / 1000;

export type Refusal = { pair: number; impactSec: number; targetSec: number; needSpeed: number; why: string };
export type Landing = { pair: number; impactSec: number; targetSec: number; landedSec: number; offFrames: number; speed: number };

/** Length on the timeline of source [0, len] played on curve [[0,a],[0.5,m],[1,b]] (as the engines render it). */
const pieceLen = (len: number, a: number, m: number, b: number) => M.clipLength({ inSec: 0, outSec: len, speed: 1, speedCurve: { preset: 'custom', points: [[0, a], [0.5, m], [1, b]] } });

/** The curve for one piece: from speed a to speed b through a middle speed chosen so the piece lasts `dur`. Null if no
 * middle speed within the limits does it. */
function curveFor(len: number, dur: number, a: number, b: number): [number, number][] | null {
  const { minSpeed: lo, maxSpeed: hi } = SYNC_LIMITS;
  if (pieceLen(len, a, hi, b) > dur || pieceLen(len, a, lo, b) < dur) return null;
  let l = Math.log(lo), h = Math.log(hi);
  for (let k = 0; k < 60; k++) { const mid = (l + h) / 2; if (pieceLen(len, a, Math.exp(mid), b) > dur) l = mid; else h = mid; }
  return [[0, r6(a)], [0.5, r6(Math.exp((l + h) / 2))], [1, r6(b)]];
}

/**
 * The retimed project (pure). impacts: source seconds of the clip, ascending; targets: timeline seconds, ascending, one
 * each. Throws ApiError 400 'sync_refused' (with `refused`) when a pair needs a speed outside the limits.
 */
export function syncHits(p0: M.EditProject, clipId: string, impacts: number[], targets: number[]): { project: M.EditProject; landings: Landing[] } {
  if (!impacts.length || impacts.length !== targets.length) throw badRequest('impacts and targets: the same number of moments, at least one');
  if (impacts.length > SYNC_LIMITS.maxHits) throw badRequest(`At most ${SYNC_LIMITS.maxHits} hits in one call`);
  const fps = p0.canvas.fps || 30;
  const main = M.mainTrack(p0), k0 = main.items.findIndex(i => i.id === clipId);
  if (k0 < 0) throw badRequest(`clipId: ${clipId} is not a clip on the main track (get_edit lists them)`);
  const c = main.items[k0] as M.VideoClip;
  if (c.holdSec !== undefined) throw badRequest('That clip is a freeze frame: it has no motion to retime');
  const span = M.timeline(p0)[k0]!;
  const T0 = span.startSec;
  const T = targets.map(t => Math.round(t * fps) / fps); // frame-accurate
  const I = impacts.map(Number);
  for (let k = 0; k < I.length; k++) {
    if (!(I[k]! >= c.inSec + SYNC_LIMITS.minPieceSec - 1e-9 && I[k]! <= c.outSec - SYNC_LIMITS.minPieceSec + 1e-9))
      throw badRequest(`impact ${k + 1} (${I[k]} s of the source) must be inside ${clipId} (${c.inSec}–${c.outSec} s of its source) and at least ${SYNC_LIMITS.minPieceSec} s from its ends: trim the clip or drop that pair`);
    if (k && I[k]! - I[k - 1]! < SYNC_LIMITS.minPieceSec - 1e-9) throw badRequest(`impacts ${k} and ${k + 1} are less than ${SYNC_LIMITS.minPieceSec} s apart in the source (they must also be in order)`);
    if (!(T[k]! > (k ? T[k - 1]! : T0) + 1e-9)) throw badRequest(`target ${k + 1} (${r3(T[k]!)} s) must come after ${k ? `target ${k}` : `the clip's start on the timeline (${r3(T0)} s)`}`);
  }
  // Each piece's average speed (source length over the time it gets), checked against the limits.
  const n = I.length, src = [c.inSec, ...I], tl = [T0, ...T];
  const avg = I.map((_, k) => (src[k + 1]! - src[k]!) / (tl[k + 1]! - tl[k]!));
  const refused: Refusal[] = [];
  avg.forEach((s, k) => {
    if (s < SYNC_LIMITS.minSpeed - 1e-9 || s > SYNC_LIMITS.maxSpeed + 1e-9) refused.push({ pair: k + 1, impactSec: I[k]!, targetSec: r3(T[k]!), needSpeed: Math.round(s * 100) / 100,
      why: `${r3(src[k + 1]! - src[k]!)} s of the clip ${k ? `after impact ${k}` : 'from its start'} would have to fill ${r3(tl[k + 1]! - tl[k]!)} s: ${s > 1 ? 'faster' : 'slower'} than ${s > 1 ? SYNC_LIMITS.maxSpeed : SYNC_LIMITS.minSpeed}×` });
  });
  if (refused.length) {
    const e = new ApiError(400, 'sync_refused', `Can't land ${refused.map(r => `pair ${r.pair} (needs ${r.needSpeed}×)`).join(', ')} within ${SYNC_LIMITS.minSpeed}–${SYNC_LIMITS.maxSpeed}×. Drop that pair, pick a nearer note or impact, or trim the clip so less (or more) of it has to fit.`);
    (e as ApiError & { refused?: Refusal[] }).refused = refused;
    throw e;
  }
  // Speeds where the pieces meet: the geometric mean of the two pieces' average speeds (the curve eases through it).
  const clamp = (v: number) => Math.min(SYNC_LIMITS.maxSpeed, Math.max(SYNC_LIMITS.minSpeed, v));
  const tailLen = c.outSec - I[n - 1]!;
  const tailSpeed = clamp(c.speedCurve ? M.curveSpeed(c.speedCurve, (I[n - 1]! - c.inSec) / (c.outSec - c.inSec)) : (c.speed ?? 1));
  const meet = [avg[0]!, ...I.map((_, k) => (k + 1 < n ? Math.sqrt(avg[k]! * avg[k + 1]!) : Math.sqrt(avg[k]! * tailSpeed)))];
  // Split at the impacts (the same split the app does), then give each piece its curve.
  let p = JSON.parse(JSON.stringify(p0)) as M.EditProject;
  const at = I.map(s => T0 + M.clipTimeAt(c, s));
  p = applyOps(p, [...at].reverse().map(a => ({ op: 'split', at: a })) as never).project;
  const m2 = M.mainTrack(p);
  const pieces = m2.items.slice(k0, k0 + n + 1) as M.VideoClip[];
  const bounds = [...src, c.outSec];
  pieces.forEach((pc, k) => {
    pc.inSec = r6(bounds[k]!); pc.outSec = r6(bounds[k + 1]!);
    const len = pc.outSec - pc.inSec;
    if (k < n) {
      const pts = curveFor(len, tl[k + 1]! - tl[k]!, meet[k]!, meet[k + 1]!) ?? [[0, r6(avg[k]!)], [1, r6(avg[k]!)]] as [number, number][];
      pc.speedCurve = { preset: 'custom', points: pts }; pc.speed = r3(avg[k]!);
    } else {
      // The tail eases from the last meeting speed back to the clip's own speed.
      pc.speedCurve = { preset: 'custom', points: [[0, r6(meet[n]!)], [1, r6(tailSpeed)]] }; pc.speed = r3(tailSpeed);
      void tailLen;
    }
  });
  // Where each impact now lands: the start of the piece after it.
  const sp = M.timeline(p);
  const landings: Landing[] = I.map((s, k) => {
    const landed = sp[k0 + k + 1]!.startSec;
    return { pair: k + 1, impactSec: r3(s), targetSec: r3(T[k]!), landedSec: r3(landed), offFrames: Math.round(Math.abs(landed - T[k]!) * fps * 100) / 100, speed: r3(avg[k]!) };
  });
  const worst = Math.max(...landings.map(l => l.offFrames));
  if (worst > 0.5) throw new ApiError(500, 'server_error', `sync_hits missed a target by ${worst} frames; nothing was changed`);
  return { project: p, landings };
}

const num = (d: string, min?: number) => ({ type: 'number', description: d, ...(min !== undefined ? { minimum: min } : {}) });
const nums = (d: string) => ({ type: 'array', items: { type: 'number', minimum: 0 }, maxItems: SYNC_LIMITS.maxHits, description: d });

async function run(env: ToolEnv, a: Record<string, unknown>) {
  const svc = editSessionsOf(env.ctx);
  const id = typeof a.sessionId === 'string' && a.sessionId ? a.sessionId : (() => { throw badRequest('sessionId: required (open_edit gives it)'); })();
  const s = await svc.row(env.user, id);
  if (a.baseRevision !== undefined && Number(a.baseRevision) !== s.revision) throw new ApiError(409, 'stale_revision', `The edit moved on (revision ${s.revision}, you sent ${a.baseRevision}) · get it again and re-apply`);
  const p = s.project as M.EditProject;
  const clipId = String(a.clipId ?? '');
  const main = M.mainTrack(p), k0 = main.items.findIndex(i => i.id === clipId);
  if (k0 < 0) throw badRequest(`clipId: ${clipId} is not a clip on the main track (get_edit lists them)`);
  const c = main.items[k0] as M.VideoClip, span = M.timeline(p)[k0]!;
  if (!Array.isArray(a.impacts) || !a.impacts.length) throw badRequest('impacts: the moments of the clip that must land (seconds)');
  const impactsIn = a.impactsIn === 'timeline' ? 'timeline' : 'source';
  const impacts = (a.impacts as unknown[]).map(Number).map(v => (impactsIn === 'timeline' ? M.clipSourceAt(c, v - span.startSec) : v));
  let targets: number[];
  if (Array.isArray(a.targets)) targets = (a.targets as unknown[]).map(Number);
  else if (a.notes && typeof a.notes === 'object') {
    // The next N note hits of the music item, in timeline seconds (song_notes' tl).
    const o = a.notes as { itemId?: string; fromSec?: number; toSec?: number; band?: string; minStrength?: number };
    if (!o.itemId) throw badRequest('notes.itemId: the music item whose notes to land on');
    const { songOf, placement } = await import('../claude/songNotes.js');
    const place = placement(p, o.itemId);
    if (!place) throw badRequest(`notes.itemId: the edit has no item ${o.itemId}`);
    const { song } = await songOf(env.ctx, env.user, { sessionId: id, itemId: o.itemId });
    const from = o.fromSec ?? span.startSec, to = o.toSec ?? Infinity, minS = o.minStrength ?? 0;
    targets = song.noteOnsets.filter(x => (!o.band || x.band === o.band) && x.strength >= minS).map(x => place.toTimeline(x.t))
      .filter((t): t is number => t !== null && t > from + 1e-6 && t <= to).slice(0, impacts.length);
    if (targets.length < impacts.length) throw badRequest(`Only ${targets.length} note hit(s) of ${o.itemId} between ${r3(from)} and ${to === Infinity ? 'the end' : `${r3(to)} s`} for ${impacts.length} impacts: widen the window, lower minStrength or drop a band filter`);
  } else throw badRequest('targets (timeline seconds) or notes: {itemId, fromSec, toSec, band}');
  let r: ReturnType<typeof syncHits>;
  try { r = syncHits(p, clipId, impacts, targets); }
  catch (e) {
    const ref = (e as { refused?: Refusal[] }).refused;
    if (ref) return { applied: false, refused: ref, message: (e as Error).message };
    throw e;
  }
  const label = `Synced ${r.landings.length} hit${r.landings.length === 1 ? '' : 's'} on ${clipId}`;
  const done = await svc.applyClaude(env.user, id, { baseRevision: s.revision, label, ops: [{ op: 'patch', patch: [{ op: 'replace', path: '/tracks', value: r.project.tracks }] }] });
  return { applied: true, ...done, landings: r.landings, pieces: r.landings.length + 1,
    next: 'Check it: watch_closer around each landedSec (timeline) and listen to the edit; undo_edit with entry.id reverts the whole sync.' };
}

export const SYNC_TOOLS: EditTool[] = [{
  name: 'sync_hits', title: 'Land moments on notes (free)', scope: 'edit:write',
  description: 'Retimes ONE main-track clip so each impact (a moment of the clip: a landing, a contact, a hit) lands exactly on its target (a note on the timeline), frame-accurate, as one undoable step. The clip is split at the impacts and each piece gets a smooth speed ramp (eased, no jumps) within 0.25–4×; the rest of the main track moves by the clip\'s change in length (as a speed change does). impacts: seconds of the clip\'s source (impactsIn "source", default; find_impacts gives these) or of the timeline now (impactsIn "timeline"). targets: timeline seconds, one per impact, in order; or notes: {itemId of the music, fromSec, toSec (timeline seconds), band?, minStrength?} to use the next note hits from song_notes. A pair that needs a speed outside the limits is refused (nothing changes) with the speed it needs: drop it or pick another note. Returns where each impact landed (landedSec): verify with watch_closer and listen.',
  inputSchema: { type: 'object', additionalProperties: false, required: ['sessionId', 'clipId', 'impacts'], properties: {
    sessionId: { type: 'string', description: 'Edit session id (es_…), filled in for you in Edit' }, baseRevision: num('The revision your change is based on'),
    clipId: { type: 'string', description: 'The main-track clip (c1, …)' }, impacts: nums('The moments that must land, ascending'),
    impactsIn: { type: 'string', enum: ['source', 'timeline'], description: 'source (default): the clip\'s own seconds; timeline: where they are on the timeline now' },
    targets: nums('Timeline seconds, one per impact, ascending'),
    notes: { type: 'object', additionalProperties: false, description: 'Instead of targets: the next note hits of a music item', properties: {
      itemId: { type: 'string' }, fromSec: num('Timeline seconds (default the clip\'s start)', 0), toSec: num('Timeline seconds', 0), band: { type: 'string', enum: ['low', 'mid', 'high'] }, minStrength: num('0–1', 0) } } } },
  run,
}];
