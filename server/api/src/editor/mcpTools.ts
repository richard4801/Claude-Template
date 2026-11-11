// Edit-suite tools for Claude (plans/claude-editing.md A): read and change an edit session, run AI helpers (free ones
// run; paid ones need `confirm: true` AND the owner's yes in the app), look at frames, and ask an online MUSE app to
// save or export. Guardrails: no posting, no deleting takes, no spend without the owner, every call logged in the
// session history and every change undoable. Owner only (the MCP server already admits only owner tokens).
import { and, desc, eq, inArray } from 'drizzle-orm';
import { takes, uploads } from '../db/schema.js';
import { ApiError, badRequest } from '../errors.js';
import type { AuthUser, Ctx } from '../ctx.js';
import { approximateFrame, contactSheet } from './frame.js';
import { energyCurve, findCuts, findPeaks, measureMotion } from './motion.js';
import { LOOKS } from './lookpack.js';
import * as M from './model.js';
import { LAYER_OP_NAMES, OP_NAMES } from './ops.js';
import { paletteFiles } from './photo.js';
import { CAPTION_STYLE_LABELS, CAPTION_STYLES, HOOKS, TRANSITION_LABELS } from './presets.js';
import { editorAi } from './service.js';
import { editSessionsOf } from './sessions.js';

const num = (d?: string, min?: number, max?: number) => ({ type: 'number', ...(d ? { description: d } : {}), ...(min !== undefined ? { minimum: min } : {}), ...(max !== undefined ? { maximum: max } : {}) });
const str = (d?: string, max?: number) => ({ type: 'string', ...(d ? { description: d } : {}), ...(max ? { maxLength: max } : {}) });
const bool = (d: string) => ({ type: 'boolean', description: d });
const obj = (properties: Record<string, unknown>, required: string[] = []) => ({ type: 'object', properties, required, additionalProperties: false });
const SID = str('Edit session id (es_…), from open_edit');
const t2 = (s: number) => { const m = Math.floor(s / 60); return `${m}:${(s - m * 60).toFixed(1).padStart(4, '0')}`; };

/**
 * The shape workstream 2's MCP registry takes (`registerMcpTools`, mcp/tools.ts): owner-only is enforced before `run`;
 * `scope` is checked against the token (OAuth edit:read / edit:write; personal tokens have all scopes).
 */
export type ToolEnv = { ctx: Ctx; user: AuthUser; source?: 'mcp' | 'chat'; scopes?: string[] };
export type EditTool = { name: string; title: string; description: string; inputSchema: Record<string, unknown>; scope: 'edit:read' | 'edit:write';
  readOnly?: boolean; idempotent?: boolean; run: (env: ToolEnv, args: Record<string, unknown>) => Promise<unknown> };

const sessionId = (_env: ToolEnv, a: Record<string, unknown>) => {
  const id = a.sessionId;
  if (typeof id !== 'string' || !id) throw badRequest('sessionId: required (open_edit gives it)');
  return id;
};
/** MCP content blocks the server passes through as they are (images); the rest of the object is the structured result. */
export const withImage = (png: Buffer, meta: Record<string, unknown>) => ({ mcpContent: [{ type: 'image', data: png.toString('base64'), mimeType: 'image/png' }, { type: 'text', text: JSON.stringify(meta) }], structuredContent: meta });

/** A short, readable picture of the project for Claude (ids it can use in ops). */
export function summary(p: M.EditProject) {
  const spans = M.timeline(p);
  const name = (a?: M.Asset) => (a ? (a.take ? `take ${a.take}` : a.upload ? `upload ${a.upload}` : `library ${a.library}`) : '?');
  return {
    canvas: p.canvas, durationSec: M.durationSec(p),
    tracks: p.tracks.map(t => ({
      id: t.id, kind: t.kind, ...(t.muted ? { muted: true } : {}), ...(t.hidden ? { hidden: true } : {}), ...(t.duck ? { duck: t.duck } : {}),
      ...(t.caption ? { captions: { words: t.caption.words.length, style: t.caption.style.preset, text: t.caption.words.slice(0, 40).map(w => w.text).join(' ') } } : {}),
      items: t.items.map((it, i) => {
        const span = M.itemSpan(p, t, it), base = { id: it.id, at: `${t2(span.startSec)}–${t2(span.endSec)}` };
        if (t.kind === 'text') return { ...base, text: (it as M.TextItem).text, template: (it as M.TextItem).template, ...((it as M.TextItem).pin ? { pinnedTo: (it as M.TextItem).pin } : {}) };
        const c = it as M.VideoClip;
        return { ...base, ...(c.asset ? { source: name(p.assets.find(a => a.id === c.asset)) } : {}), ...(c.inSec !== undefined ? { sourceRange: `${t2(c.inSec)}–${t2(c.outSec)}` } : {}),
          ...(c.speed !== undefined && c.speed !== 1 ? { speed: c.speed } : {}), ...(c.speedCurve ? { speedCurve: c.speedCurve.preset } : {}),
          ...(c.transitionIn ? { transitionIn: `${c.transitionIn.kind} ${c.transitionIn.durationSec}s` } : {}), ...(c.look ? { look: c.look } : {}),
          ...(c.adjust ? { adjust: c.adjust } : {}), ...(c.mask ? { mask: c.mask.shape } : {}), ...(c.volume !== undefined ? { volume: c.volume } : {}),
          ...(c.layers?.length ? { layers: c.layers.map(l => ({ id: l.id, name: l.name, ...(l.hidden ? { hidden: true } : {}), ...(l.aboveText ? { textBehind: true } : {}), ...(l.recolor ? { recolor: l.recolor } : {}),
            ...(l.look ? { look: l.look } : {}), ...(l.adjust ? { adjust: l.adjust } : {}), ...(l.blur ? { blur: l.blur } : {}), ...(l.opacity !== undefined ? { opacity: l.opacity } : {}), pinnable: !!l.track })) } : {}),
          ...(c.layerBase ? { background: c.layerBase } : {}),
          ...(t.kind === 'main' ? { position: i + 1, startsAt: t2(spans[i]!.startSec) } : {}) };
      }),
    })),
  };
}

/** Runs (free) or proposes (paid) an editor AI job for a session. */
async function helper(env: ToolEnv, a: Record<string, unknown>, o: { kind: 'captions' | 'cuts' | 'matte' | 'denoise' | 'beats' | 'layers'; label: string; options?: Record<string, unknown>; reasons?: string[]; itemKey?: string }) {
  const svc = editSessionsOf(env.ctx), ai = editorAi(env.ctx);
  const s = await svc.row(env.user, sessionId(env, a));
  const p = s.project as M.EditProject;
  const itemId = typeof a[o.itemKey ?? 'itemId'] === 'string' ? (a[o.itemKey ?? 'itemId'] as string) : undefined;
  const asset = svc.sourceAsset(p, s.takeId, itemId);
  const source = asset.take ? { takeId: asset.take } : asset.upload ? { uploadId: asset.upload, durationSec: asset.durationSec } : null;
  if (!source) throw badRequest('That item has no stored media to analyse');
  const body = { kind: o.kind, source, options: o.options ?? {} };
  const est = await ai.estimate(env.user, body);
  if (est.usd > 0) {
    if (a.confirm !== true) {
      await svc.log(s, `Priced ${o.label}: about $${est.usd.toFixed(2)}`);
      return { needsConfirmation: true, estimateUsd: est.usd, message: `${o.label} costs about $${est.usd.toFixed(2)}. Call again with confirm: true to ask the owner; it runs only after they approve it in the MUSE app.` };
    }
    // The owner's yes on the price shown is the go-ahead (layers above $1 per clip need it said: acceptUsd).
    const pend = await svc.askOwner(s, { kind: o.kind, label: o.label, estimateUsd: est.usd, args: { ...body, ...(o.kind === 'layers' ? { acceptUsd: est.usd } : {}), ...(itemId ? { itemId } : {}), ...(o.reasons ? { reasons: o.reasons } : {}) } });
    return { waitingForOwner: true, pendingId: pend.id, estimateUsd: est.usd, message: 'The owner has been asked in the MUSE app. The result is applied to the edit when the job finishes (see get_edit history).' };
  }
  const job = await ai.start(env.user, body);
  svc.track(String(job.id), { sessionId: s.id, studioId: s.studioId, ownerId: s.ownerId, kind: o.kind, itemId, reasons: o.reasons, label: o.label });
  await svc.log(s, `Started ${o.label} (free)`);
  // Free helpers are quick: wait a little so Claude sees the result at once.
  const t0 = Date.now();
  for (;;) {
    const r = await ai.get(env.user, String(job.id));
    if (r.state !== 'running') {
      await new Promise(res => setTimeout(res, 50)); // let the session apply it
      const after = await svc.row(env.user, s.id);
      return { state: r.state, revision: after.revision, applied: after.revision > s.revision, ...(r.result ? { result: brief(o.kind, r.result as Record<string, unknown>) } : {}), ...(r.error ? { error: r.error } : {}) };
    }
    if (Date.now() - t0 > 60_000) return { state: 'running', jobId: job.id, message: 'Still running; the result is applied to the edit when it finishes.' };
    await new Promise(res => setTimeout(res, 250));
  }
}
/** One free edit op as its own tool (layers), on the session's current revision. */
async function oneOp(env: ToolEnv, a: Record<string, unknown>, op: string, keys: string[]) {
  const svc = editSessionsOf(env.ctx), id = sessionId(env, a), s = await svc.row(env.user, id);
  const o: Record<string, unknown> = { op };
  for (const k of keys) if (a[k] !== undefined) o[k] = a[k];
  return svc.applyClaude(env.user, id, { baseRevision: s.revision, ops: [o] });
}
/** Beats for Claude: the tempo, the counts, and the beat times themselves (the clip's own seconds), so a cut can land on one. */
const beatsBrief = (r: Record<string, unknown>) => {
  const t = (v: unknown) => (Array.isArray(v) ? v : []).filter((x): x is number => typeof x === 'number').slice(0, 600).map(x => Math.round(x * 1000) / 1000);
  const beats = t(r.beats), strong = t(r.strong);
  return { bpm: r.bpm, beats: beats.length, strong: strong.length, beatTimes: beats, strongTimes: strong };
};
const brief = (kind: string, r: Record<string, unknown>) => kind === 'cuts' ? { cuts: r.cuts, savedSec: r.savedSec } : kind === 'beats' ? beatsBrief(r)
  : kind === 'captions' ? { language: r.language, words: (r.words as unknown[])?.length } : { done: true };

const TOOLS: EditTool[] = [
  {
    name: 'list_takes', title: 'List takes to edit', scope: 'edit:read', readOnly: true, idempotent: true,
    description: 'Recent video takes and edited versions in the studio (newest first), optionally filtered by title. Use a take id with open_edit.',
    inputSchema: obj({ recent: num('How many (default 20)', 1, 100), query: str('Words in the title', 80) }),
    run: async (env, a) => {
      editSessionsOf(env.ctx).owner(env.user);
      const rows = await env.ctx.db.select().from(takes).where(and(eq(takes.studioId, env.user.studioId), inArray(takes.kind, ['take', 'edit'] as never[]))).orderBy(desc(takes.createdAt)).limit(200);
      const q = typeof a.query === 'string' ? a.query.toLowerCase() : '';
      return { takes: rows.filter(t => t.mediaKey && (!q || t.title.toLowerCase().includes(q))).slice(0, Number(a.recent) || 20).map(t => {
        const m = (t.media ?? {}) as Record<string, unknown>;
        return { id: t.id, kind: t.kind, title: t.title, label: t.label, durationSec: m.durationSec, width: m.width, height: m.height, createdAt: t.createdAt,
          ...(m.parentTakeId ? { editOf: m.parentTakeId } : {}), ...(m.look ? { look: m.look } : {}) };
      }) };
    },
  },
  {
    name: 'open_edit', title: 'Open an edit', scope: 'edit:write',
    description: 'Opens the live edit session for a take (the same one the owner sees in the MUSE Edit suite; created if there is none). Returns the session id, its revision, a summary of the project and the studio\'s playbook: follow the owner\'s pinned rules (changes that break an enforced one are refused). Your changes appear live in the owner\'s apps with a "Claude" badge and can be undone.',
    inputSchema: obj({ takeId: str('A take or edited-version id from list_takes, or "blank" to start a new blank project (no source video: add clips with a patch op, an asset {take} plus a main-track item)'), fresh: bool('Start a new session from the take even if one is open') }, ['takeId']),
    run: async (env, a) => {
      const v = await editSessionsOf(env.ctx).open(env.user, { takeId: a.takeId, fresh: a.fresh, device: undefined });
      const s = await editSessionsOf(env.ctx).row(env.user, v.id);
      await editSessionsOf(env.ctx).log(s, 'Opened the edit');
      // workstream 1: the studio's playbook, read before every edit (pinned rules are enforced on apply_edit_ops).
      const playbook = await (await import('../recreate/playbook.js')).playbookBrief(env.ctx, env.user, { takeId: String(a.takeId) });
      return { sessionId: v.id, revision: v.revision, online: v.online, summary: summary(v.project), ...(playbook ? { playbook } : {}) };
    },
  },
  {
    name: 'get_edit', title: 'Get the edit', scope: 'edit:read', readOnly: true, idempotent: true,
    description: 'The edit session now: revision (send it as baseRevision with changes), a summary with item ids, the full project JSON, recent history (who changed what), apps online, and paid helpers waiting for the owner.',
    inputSchema: obj({ sessionId: SID, full: bool('Include the full project JSON (default true)') }, ['sessionId']),
    run: async (env, a) => {
      const svc = editSessionsOf(env.ctx), s = await svc.row(env.user, sessionId(env, a)), v = await svc.view(s);
      return { sessionId: v.id, revision: v.revision, summary: summary(v.project), ...(a.full === false ? {} : { project: v.project }), history: v.history?.slice(0, 20), online: v.online, pending: v.pending, requests: v.requests };
    },
  },
  {
    name: 'apply_edit_ops', title: 'Change the edit', scope: 'edit:write',
    description: `Applies changes to the edit as one undoable step. Send the revision you last read as baseRevision (a stale one is refused with the current revision: get_edit and try again). Ops (see plans/video-editor.md "Edit ops"): ${OP_NAMES.join(', ')}; layers: ${LAYER_OP_NAMES.join(', ')}. Examples: {"op":"trim","clipId":"c1","inSec":0.5,"outSec":6}, {"op":"split","at":3.2}, {"op":"delete","itemId":"c2"}, {"op":"speed","clipId":"c1","curve":"hero"}, {"op":"add_hook","template":"hook-bold","text":"Wait for it…"}, {"op":"caption_style","preset":"pop"}, {"op":"look","itemId":"all","look":"film-gold","strength":0.7}, {"op":"transition","clipId":"all","kind":"fade","durationSec":0.3}, {"op":"duck","levelDb":-12}, {"op":"ratio","ratio":"9:16"}. Times are seconds; timeline times for split/startSec, source times for trim.`,
    inputSchema: obj({ sessionId: SID, baseRevision: num('The revision your change is based on'), ops: { type: 'array', minItems: 1, maxItems: 100, items: { type: 'object' }, description: 'Operations, applied in order' } }, ['sessionId', 'baseRevision', 'ops']),
    run: async (env, a) => editSessionsOf(env.ctx).applyClaude(env.user, sessionId(env, a), a),
  },
  {
    name: 'undo_edit', title: 'Undo a change', scope: 'edit:write',
    description: 'Undoes one change in the history (default: your most recent one that is not undone yet).',
    inputSchema: obj({ sessionId: SID, entryId: num('History entry id from get_edit') }, ['sessionId']),
    run: async (env, a) => {
      const svc = editSessionsOf(env.ctx), id = sessionId(env, a);
      let entryId = a.entryId;
      if (entryId === undefined) {
        const h = await svc.history(env.user, id, 200);
        entryId = h.find(e => e.byClaude && e.kind === 'edit' && !e.undone)?.id;
        if (entryId === undefined) throw badRequest('Nothing of yours to undo');
      }
      return svc.undo(env.user, id, { entryId, author: 'claude' });
    },
  },
  {
    name: 'list_looks', title: 'List looks', scope: 'edit:read', readOnly: true, idempotent: true,
    description: 'The looks (colour grades) to use with the "look" op: the 32 MUSE looks by group, and suite looks made from palettes and film stocks.',
    inputSchema: obj({}),
    run: async () => ({ looks: LOOKS.map(l => ({ id: l.id, name: l.name, category: l.category, lut: `pack:${l.id}` })),
      suiteLooks: [...paletteFiles().keys()].map(id => ({ id, lut: `palette:${id}`, use: `{"op":"look","itemId":"all","lut":"palette:${id}","strength":1}` })) }),
  },
  {
    name: 'list_caption_styles', title: 'List caption styles and text templates', scope: 'edit:read', readOnly: true, idempotent: true,
    description: 'Caption styles for caption_style (preset ids and their names in the app), hook templates for add_hook, transition kinds, speed-curve presets, mask shapes and voice effects.',
    inputSchema: obj({}),
    run: async () => ({ captionStyles: CAPTION_STYLE_LABELS.map(([id, name]) => ({ id, name, highlightColor: CAPTION_STYLES[id].highlightColor })),
      hooks: HOOKS.map(h => ({ id: h.id, name: h.label, text: h.text })), transitions: TRANSITION_LABELS.map(([id, name]) => ({ id, name })),
      speedCurves: Object.keys(M.SPEED_PRESETS), maskShapes: M.MASK_SHAPES, voiceEffects: M.VOICE_EFFECTS }),
  },
  {
    name: 'auto_captions', title: 'Auto-captions', scope: 'edit:write',
    description: 'Transcribes the main video\'s speech into word-timed captions on the edit (replacing existing captions). Free when the video already has a transcript; otherwise it costs a little: without confirm you get the estimate; with confirm: true the owner is asked in the app.',
    inputSchema: obj({ sessionId: SID, language: str('Two-letter language code, or "auto"', 4), confirm: bool('Ask the owner to approve the cost') }, ['sessionId']),
    run: (env, a) => helper(env, a, { kind: 'captions', label: 'Auto-captions', options: a.language ? { language: a.language } : {} }),
  },
  {
    name: 'cut_silences', title: 'Cut silences (free)', scope: 'edit:write',
    description: 'Removes the quiet parts of the main video (from its sound level; free), keeping a little air around speech.',
    inputSchema: obj({ sessionId: SID, minSilenceSec: num('Shortest pause to cut (default 0.7)', 0.25, 5), keepPadSec: num('Air kept each side (default 0.12)', 0, 0.5) }, ['sessionId']),
    run: (env, a) => helper(env, a, { kind: 'cuts', label: 'Cut silences', reasons: ['silence'], options: { silenceOnly: true, ...(a.minSilenceSec ? { minSilenceSec: a.minSilenceSec } : {}), ...(a.keepPadSec !== undefined ? { keepPadSec: a.keepPadSec } : {}) } }),
  },
  {
    name: 'cut_fillers', title: 'Cut filler words', scope: 'edit:write',
    description: 'Removes "um", "uh" and similar (and repeated words) using the transcript. Free when captions already exist; otherwise it needs a transcription (estimate first, then confirm: true and the owner\'s approval).',
    inputSchema: obj({ sessionId: SID, repeats: bool('Also cut a word said twice in a row'), confirm: bool('Ask the owner to approve the cost') }, ['sessionId']),
    run: (env, a) => helper(env, a, { kind: 'cuts', label: 'Cut filler words', reasons: ['filler', 'repeat'], options: { fillers: true, repeats: a.repeats === true, minSilenceSec: 5 } }),
  },
  {
    name: 'remove_background', title: 'Remove background', scope: 'edit:write',
    description: 'Cuts the person out of a clip (green screen without a green screen): the clip gets an alpha matte, so green clothes and hair edges survive. To keep something else (a pet, a product, one of two people), pass points: where it is on a frame, [{x, y} 0–1 of the frame, t seconds into the clip, keep false for what to leave out]; it is followed through the clip. Paid: estimate first, then confirm: true; it runs after the owner approves in the app.',
    inputSchema: obj({ sessionId: SID, itemId: str('The clip (default: the main video)'),
      points: { type: 'array', maxItems: 10, items: { type: 'object' }, description: 'Tap to keep: [{x, y, t?, keep?}] (0–1 of the frame; t seconds into the source)' },
      confirm: bool('Ask the owner to approve the cost') }, ['sessionId']),
    run: (env, a) => helper(env, a, { kind: 'matte', label: Array.isArray(a.points) ? 'Keep what you tapped' : 'Remove background', ...(Array.isArray(a.points) ? { options: { points: a.points } } : {}) }),
  },
  {
    name: 'find_layers', title: 'Find layers', scope: 'edit:write',
    description: 'Layers (one paid run per clip, then everything is free): finds up to 5 things in a main clip (her, the dog, the car…) and follows each through the clip, so each becomes a layer you can recolour, re-look, blur, hide, put text behind, or pin text to (set_layer, layer_base, text_behind, pin_text). Mark each thing with points [{x, y} 0–1 of the frame, t seconds into the clip, keep false for what to leave out] and/or a box {x, y, w, h, t}; use get_frame to find where things are. Clips up to 60 s. Paid: estimate first, then confirm: true; it runs after the owner approves the price in the app. Replaces the clip\'s earlier layers.',
    inputSchema: obj({ sessionId: SID, itemId: str('The main clip (default: the first)'),
      objects: { type: 'array', minItems: 1, maxItems: 5, items: { type: 'object', properties: { name: str('What it is ("Her", "Dog")', 40), points: { type: 'array', items: { type: 'object' } }, box: { type: 'object' } }, required: ['name'] }, description: 'What to find: [{name, points?, box?}]' },
      confirm: bool('Ask the owner to approve the cost') }, ['sessionId', 'objects']),
    run: async (env, a) => {
      const svc = editSessionsOf(env.ctx), s = await svc.row(env.user, sessionId(env, a));
      const main = M.mainTrack(s.project as M.EditProject).items;
      const clip = typeof a.itemId === 'string' ? main.find(c => c.id === a.itemId) : main[0];
      if (!clip) throw badRequest('itemId: a clip on the main track (layers are on main clips)');
      return helper(env, { ...a, itemId: clip.id }, { kind: 'layers', label: 'Find layers', options: { objects: a.objects } });
    },
  },
  {
    name: 'set_layer', title: 'Change a layer (free)', scope: 'edit:write',
    description: 'Changes one layer of a clip (after find_layers). layer: its id or name. Any of: name; hidden; look (a look id from list_looks, a look object, or null); adjust {exposure, contrast, saturation, temperature, tint, highlights, shadows} −1…1 (merged; null clears); filter {id, amount} or null; recolor {color "#RRGGBB", amount 0–1} (keeps light and shade: "make her coat navy") or null; opacity, blur, feather 0–1; aboveText (text behind this layer). One undoable step.',
    inputSchema: obj({ sessionId: SID, itemId: str('The clip'), layer: str('Layer id or name'), name: str('New name', 40), hidden: bool('Hide the layer'), look: {}, adjust: { type: ['object', 'null'] }, filter: { type: ['object', 'null'] },
      recolor: { type: ['object', 'null'] }, opacity: num('0–1', 0, 1), blur: num('0–1', 0, 1), feather: num('Soften the edge, 0–1', 0, 1), aboveText: bool('Draw the layer over text and captions') }, ['sessionId', 'itemId', 'layer']),
    run: (env, a) => oneOp(env, a, 'set_layer', ['itemId', 'layer', 'name', 'hidden', 'look', 'adjust', 'filter', 'recolor', 'opacity', 'blur', 'feather', 'aboveText']),
  },
  {
    name: 'layer_base', title: 'Change the background layer (free)', scope: 'edit:write',
    description: 'The "Background" of a clip with layers (everything not in a layer): hidden; blur 0–1 ("blur everything but the dog"); look / adjust / filter for the background only; asset: an image or video asset id to show behind the layers instead (null puts the clip back).',
    inputSchema: obj({ sessionId: SID, itemId: str('The clip'), hidden: bool('Hide the background'), blur: num('0–1', 0, 1), look: {}, adjust: { type: ['object', 'null'] }, filter: { type: ['object', 'null'] },
      asset: { type: ['string', 'null'], description: 'An image or video asset of the project' } }, ['sessionId', 'itemId']),
    run: (env, a) => oneOp(env, a, 'layer_base', ['itemId', 'hidden', 'blur', 'look', 'adjust', 'filter', 'asset']),
  },
  {
    name: 'text_behind', title: 'Put text behind a layer (free)', scope: 'edit:write',
    description: 'Text and captions go behind a layer (she walks in front of the words) while its clip is on screen; behind: false puts them back in front.',
    inputSchema: obj({ sessionId: SID, itemId: str('The clip'), layer: str('Layer id or name'), behind: bool('true (default): text behind the layer') }, ['sessionId', 'itemId', 'layer']),
    run: (env, a) => oneOp(env, a, 'text_behind', ['itemId', 'layer', 'behind']),
  },
  {
    name: 'pin_text', title: 'Pin text to a layer (free)', scope: 'edit:write',
    description: 'A text item follows a layer around (its centre on the layer\'s centre, top or bottom, plus offset in canvas fractions). layer: null unpins.',
    inputSchema: obj({ sessionId: SID, textId: str('The text item'), itemId: str('The clip'), layer: { type: ['string', 'null'], description: 'Layer id or name, or null to unpin' },
      anchor: { type: 'string', enum: ['center', 'top', 'bottom'] }, offset: { type: 'object', description: '{x, y} canvas fractions, −1…1' } }, ['sessionId', 'textId']),
    run: (env, a) => oneOp(env, a, 'pin_text', ['textId', 'itemId', 'layer', 'anchor', 'offset']),
  },
  {
    name: 'detect_beats', title: 'Detect beats (free)', scope: 'edit:write',
    description: 'Finds the tempo and beats of a music clip and marks them on the timeline (for cutting to the beat). Returns bpm, beatTimes and strongTimes (the downbeats) in the clip\'s own seconds: add the clip\'s start on the timeline (minus its trim-in) for timeline seconds.',
    inputSchema: obj({ sessionId: SID, itemId: str('The music clip') }, ['sessionId', 'itemId']),
    run: (env, a) => helper(env, a, { kind: 'beats', label: 'Detect beats' }),
  },
  {
    // Workstream 1 (plans/recreate-edit.md "Action peaks"): frame-difference energy on a small grey proxy. Free.
    name: 'find_action_peaks', title: 'Find action peaks (free)', scope: 'edit:read', readOnly: true, idempotent: true,
    description: 'Finds the moments of strongest motion in a clip (a jump, a turn, a hair flip), for landing actions on beats. Free: frame differencing on a small proxy of the clip. Returns peaks [{t, strength 0–1}] in the clip\'s own seconds (not timeline seconds), the hard cuts it saw (left out of the peaks; flash: true for a one-frame flash), and an energy curve for drawing. Changes nothing.',
    inputSchema: obj({ sessionId: SID, itemId: str('The clip (default: the main video)'), minGapSec: num('Smallest gap between two peaks (default 0.25)', 0.05, 10),
      sensitivity: num('Higher finds fewer, bigger peaks (default 4)', 1, 12), max: num('At most this many peaks, strongest kept (default 200)', 1, 500) }, ['sessionId']),
    run: async (env, a) => {
      const svc = editSessionsOf(env.ctx), ai = editorAi(env.ctx);
      const s = await svc.row(env.user, sessionId(env, a));
      const asset = svc.sourceAsset(s.project as M.EditProject, s.takeId, typeof a.itemId === 'string' ? a.itemId : undefined);
      if (asset.kind !== 'video' || !(asset.take || asset.upload)) throw badRequest('That item has no stored video to analyse');
      const src = await ai.source(env.user, asset.take ? { takeId: asset.take } : { uploadId: asset.upload, durationSec: asset.durationSec });
      const c = env.ctx.config;
      const m = await ai.withLocalInput(src.key, input => measureMotion(c.FFMPEG_PATH, c.FFPROBE_PATH, input, { maxSec: 600 }));
      const cuts = findCuts(m);
      const peaks = findPeaks(m, { cuts, minGapSec: Number(a.minGapSec) || undefined, sensitivity: Number(a.sensitivity) || undefined, max: Number(a.max) || undefined });
      await svc.log(s, `Found ${peaks.length} action peak${peaks.length === 1 ? '' : 's'}`);
      return { itemId: a.itemId ?? null, assetId: asset.id, fps: m.fps, durationSec: Math.round(m.energy.length / m.fps * 1000) / 1000, peaks, cuts, energy: energyCurve(m) };
    },
  },
  {
    name: 'denoise', title: 'Clean up the voice', scope: 'edit:write',
    description: 'Separates the voice from music and noise and uses it as the clip\'s sound. Paid: estimate first, then confirm: true; it runs after the owner approves in the app.',
    inputSchema: obj({ sessionId: SID, itemId: str('The clip (default: the main video)'), confirm: bool('Ask the owner to approve the cost') }, ['sessionId']),
    run: (env, a) => helper(env, a, { kind: 'denoise', label: 'Clean up the voice' }),
  },
  {
    name: 'get_frame', title: 'Look at a frame', scope: 'edit:read', readOnly: true,
    description: 'A PNG of the edit at time t (seconds on the timeline), to check your changes. Exact when the owner\'s MUSE app has the edit open (it renders it); otherwise an approximate server render (approximate: true: the source frame with its look, text and captions only).',
    inputSchema: obj({ sessionId: SID, t: num('Seconds from the start', 0), width: num('Width in px (default 540)', 64, 1080) }, ['sessionId', 't']),
    run: async (env, a) => {
      const svc = editSessionsOf(env.ctx), s = await svc.row(env.user, sessionId(env, a));
      const t = Number(a.t), width = Number(a.width) || 540;
      if (!Number.isFinite(t) || t < 0) throw badRequest('t: seconds from the start');
      const exact = await svc.requestFrame(s, t, width);
      if (exact) {
        const [up] = await env.ctx.db.select().from(uploads).where(eq(uploads.id, exact.uploadId));
        const obj = up ? await env.ctx.storage.get(up.storageKey) : null;
        if (obj) {
          const chunks: Buffer[] = []; for await (const c of obj.body as AsyncIterable<Buffer>) chunks.push(Buffer.from(c));
          await svc.log(s, `Looked at ${t2(t)}`);
          return withImage(Buffer.concat(chunks), { t, revision: s.revision, approximate: false, renderedBy: exact.device });
        }
      }
      const f = await approximateFrame(env.ctx, s.studioId, s.project as M.EditProject, t, width);
      await svc.log(s, `Looked at ${t2(t)} (approximate)`);
      return withImage(f.png, { t, revision: s.revision, approximate: true, note: f.note, width: f.width, height: f.height });
    },
  },
  {
    name: 'get_contact_sheet', title: 'Contact sheet', scope: 'edit:read', readOnly: true,
    description: 'One image with a frame every N seconds (approximate renders, labelled with their times), for checking pacing and the order of shots.',
    inputSchema: obj({ sessionId: SID, everySec: num('Seconds between frames (default 1)', 0.25, 30) }, ['sessionId']),
    run: async (env, a) => {
      const svc = editSessionsOf(env.ctx), s = await svc.row(env.user, sessionId(env, a));
      const c = await contactSheet(env.ctx, s.studioId, s.project as M.EditProject, Number(a.everySec) || 1);
      await svc.log(s, `Looked at a contact sheet (${c.times.length} frames)`);
      return withImage(c.png, { times: c.times, revision: s.revision, approximate: true });
    },
  },
  {
    name: 'save_version', title: 'Save as a version', scope: 'edit:write',
    description: 'Asks the owner\'s MUSE app that has this edit open to render it and save it as a new edited version in the Gallery (only the apps encode video). If no app is open, say so to the owner.',
    inputSchema: obj({ sessionId: SID, name: str('A short name for the version', 60) }, ['sessionId']),
    run: async (env, a) => {
      const svc = editSessionsOf(env.ctx), s = await svc.row(env.user, sessionId(env, a));
      const r = svc.appRequest(s, 'save', { name: typeof a.name === 'string' ? a.name : undefined });
      await svc.log(s, r ? `Asked ${r.device} to save a version` : 'Tried to save (no app open)');
      if (!r) return { sent: false, message: 'Open MUSE on your Mac or phone with this edit to save it.' };
      return { sent: true, requestId: r.id, device: r.device, message: 'The app is rendering and saving it; get_edit shows the request when it is done.' };
    },
  },
  {
    name: 'export_video', title: 'Export the video', scope: 'edit:write',
    description: 'Asks the owner\'s MUSE app that has this edit open to export it (saved as a version and to the device). preset: {ratio?: "9:16"|"1:1"|"4:5"|"16:9", resolution?: "720p"|"1080p"|"4k", fps?: 24|30|60, codec?: "h264"|"hevc", captions?: "burn"|"srt"}. The AI-label and Content Credentials switches stay as the owner set them (off by default). Never posts anywhere.',
    inputSchema: obj({ sessionId: SID, preset: { type: 'object', description: 'Export settings' } }, ['sessionId']),
    run: async (env, a) => {
      const svc = editSessionsOf(env.ctx), s = await svc.row(env.user, sessionId(env, a));
      const preset = a.preset && typeof a.preset === 'object' ? { ...(a.preset as Record<string, unknown>) } : {};
      delete preset.aiLabel; delete preset.c2pa; // the owner's switches, never Claude's
      const r = svc.appRequest(s, 'export', { preset });
      await svc.log(s, r ? `Asked ${r.device} to export` : 'Tried to export (no app open)');
      if (!r) return { sent: false, message: 'Open MUSE on your Mac or phone with this edit to export it.' };
      return { sent: true, requestId: r.id, device: r.device };
    },
  },
];

/** The chip text the chat shows for a call (structuredContent.label), from what the tool did. */
export function chipLabel(name: string, args: Record<string, unknown>, r: Record<string, unknown>): string {
  const st = (r.structuredContent ?? r) as Record<string, unknown>;
  switch (name) {
    case 'list_takes': return `Listed ${(r.takes as unknown[] | undefined)?.length ?? 0} takes`;
    case 'open_edit': return 'Opened the edit';
    case 'get_edit': return 'Read the edit';
    case 'apply_edit_ops': return (r.changes as string[] | undefined)?.join(' · ') || 'Edited';
    case 'undo_edit': return String((r.entry as { label?: string } | null | undefined)?.label ?? 'Undid a change');
    case 'list_looks': return 'Looked at the looks';
    case 'list_caption_styles': return 'Looked at caption styles';
    case 'get_frame': return `Looked at ${t2(Number(st.t ?? args.t ?? 0))}${st.approximate ? ' (approximate)' : ''}`;
    case 'get_contact_sheet': return `Contact sheet · ${(st.times as unknown[] | undefined)?.length ?? 0} frames`;
    case 'save_version': return r.sent ? `Asked ${String(r.device)} to save a version` : 'Could not save (no app open)';
    case 'export_video': return r.sent ? `Asked ${String(r.device)} to export` : 'Could not export (no app open)';
    default: {
      const title = TOOLS.find(t => t.name === name)?.title ?? name;
      if (r.needsConfirmation) return `${title} · about $${Number(r.estimateUsd).toFixed(2)}`;
      if (r.waitingForOwner) return `${title} · waiting for your OK`;
      return r.applied ? `${title} · applied` : r.state === 'running' ? `${title} · running` : title;
    }
  }
}
/** Every tool's result carries `label` (in structuredContent for image results) for the chat's tool chips. */
export const EDIT_TOOLS: EditTool[] = TOOLS.map(t => ({
  ...t,
  run: async (env: ToolEnv, a: Record<string, unknown>) => {
    const r = (await t.run(env, a)) as Record<string, unknown>;
    const label = chipLabel(t.name, a, r);
    return r.mcpContent ? { ...r, structuredContent: { ...(r.structuredContent as object), label } } : { ...r, label };
  },
}));

/** Errors tools may throw are ApiErrors (the MCP server turns them into tool errors Claude can read). */
export const isToolError = (e: unknown) => e instanceof ApiError;
