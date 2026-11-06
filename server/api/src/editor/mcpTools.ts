// Edit-suite tools for Claude (plans/claude-editing.md A): read and change an edit session, run AI helpers (free ones
// run; paid ones need `confirm: true` AND the owner's yes in the app), look at frames, and ask an online MUSE app to
// save or export. Guardrails: no posting, no deleting takes, no spend without the owner, every call logged in the
// session history and every change undoable. Owner only (the MCP server already admits only owner tokens).
import { and, desc, eq, inArray } from 'drizzle-orm';
import { takes, uploads } from '../db/schema.js';
import { ApiError, badRequest } from '../errors.js';
import type { AuthUser, Ctx } from '../ctx.js';
import { approximateFrame, contactSheet } from './frame.js';
import { LOOKS } from './lookpack.js';
import * as M from './model.js';
import { OP_NAMES } from './ops.js';
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
        if (t.kind === 'text') return { ...base, text: (it as M.TextItem).text, template: (it as M.TextItem).template };
        const c = it as M.VideoClip;
        return { ...base, ...(c.asset ? { source: name(p.assets.find(a => a.id === c.asset)) } : {}), ...(c.inSec !== undefined ? { sourceRange: `${t2(c.inSec)}–${t2(c.outSec)}` } : {}),
          ...(c.speed !== undefined && c.speed !== 1 ? { speed: c.speed } : {}), ...(c.speedCurve ? { speedCurve: c.speedCurve.preset } : {}),
          ...(c.transitionIn ? { transitionIn: `${c.transitionIn.kind} ${c.transitionIn.durationSec}s` } : {}), ...(c.look ? { look: c.look } : {}),
          ...(c.adjust ? { adjust: c.adjust } : {}), ...(c.mask ? { mask: c.mask.shape } : {}), ...(c.volume !== undefined ? { volume: c.volume } : {}),
          ...(t.kind === 'main' ? { position: i + 1, startsAt: t2(spans[i]!.startSec) } : {}) };
      }),
    })),
  };
}

/** Runs (free) or proposes (paid) an editor AI job for a session. */
async function helper(env: ToolEnv, a: Record<string, unknown>, o: { kind: 'captions' | 'cuts' | 'matte' | 'denoise' | 'beats'; label: string; options?: Record<string, unknown>; reasons?: string[]; itemKey?: string }) {
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
    const pend = await svc.askOwner(s, { kind: o.kind, label: o.label, estimateUsd: est.usd, args: { ...body, ...(itemId ? { itemId } : {}), ...(o.reasons ? { reasons: o.reasons } : {}) } });
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
const brief = (kind: string, r: Record<string, unknown>) => kind === 'cuts' ? { cuts: r.cuts, savedSec: r.savedSec } : kind === 'beats' ? { bpm: r.bpm, beats: (r.beats as unknown[])?.length, strong: (r.strong as unknown[])?.length }
  : kind === 'captions' ? { language: r.language, words: (r.words as unknown[])?.length } : { done: true };

export const EDIT_TOOLS: EditTool[] = [
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
    description: 'Opens the live edit session for a take (the same one the owner sees in the MUSE Edit suite; created if there is none). Returns the session id, its revision and a summary of the project. Your changes appear live in the owner\'s apps with a "Claude" badge and can be undone.',
    inputSchema: obj({ takeId: str('A take or edited-version id from list_takes'), fresh: bool('Start a new session from the take even if one is open') }, ['takeId']),
    run: async (env, a) => {
      const v = await editSessionsOf(env.ctx).open(env.user, { takeId: a.takeId, fresh: a.fresh, device: undefined });
      const s = await editSessionsOf(env.ctx).row(env.user, v.id);
      await editSessionsOf(env.ctx).log(s, 'Opened the edit');
      return { sessionId: v.id, revision: v.revision, online: v.online, summary: summary(v.project) };
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
    description: `Applies changes to the edit as one undoable step. Send the revision you last read as baseRevision (a stale one is refused with the current revision: get_edit and try again). Ops (see plans/video-editor.md "Edit ops"): ${OP_NAMES.join(', ')}. Examples: {"op":"trim","clipId":"c1","inSec":0.5,"outSec":6}, {"op":"split","at":3.2}, {"op":"delete","itemId":"c2"}, {"op":"speed","clipId":"c1","curve":"hero"}, {"op":"add_hook","template":"hook-bold","text":"Wait for it…"}, {"op":"caption_style","preset":"pop"}, {"op":"look","itemId":"all","look":"film-gold","strength":0.7}, {"op":"transition","clipId":"all","kind":"fade","durationSec":0.3}, {"op":"duck","levelDb":-12}, {"op":"ratio","ratio":"9:16"}. Times are seconds; timeline times for split/startSec, source times for trim.`,
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
    description: 'Cuts the person out of a clip (green screen without a green screen). Paid: estimate first, then confirm: true; it runs after the owner approves in the app.',
    inputSchema: obj({ sessionId: SID, itemId: str('The clip (default: the main video)'), confirm: bool('Ask the owner to approve the cost') }, ['sessionId']),
    run: (env, a) => helper(env, a, { kind: 'matte', label: 'Remove background' }),
  },
  {
    name: 'detect_beats', title: 'Detect beats (free)', scope: 'edit:write',
    description: 'Finds the tempo and beats of a music clip and marks them on the timeline (for cutting to the beat).',
    inputSchema: obj({ sessionId: SID, itemId: str('The music clip') }, ['sessionId', 'itemId']),
    run: (env, a) => helper(env, a, { kind: 'beats', label: 'Detect beats' }),
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

/** Errors tools may throw are ApiErrors (the MCP server turns them into tool errors Claude can read). */
export const isToolError = (e: unknown) => e instanceof ApiError;
