// Claude panel cards (owner's chosen chat reference, 2026-11-12; plans/design/claude-panel): Claude's replies can carry
// structured parts the apps draw as cards instead of plain bubbles. Plain text stays plain. Each card is a tool line in
// the chat (role 'tool', tool.name 'card', tool.ui.card), stored and streamed like the other lines the app acts on:
//   plan     a checklist that ticks as steps finish (show_plan again with the same planId updates it in place)
//   media    "Clip analysis": the video, its length and timestamped key moments (each one seeks the player)
//   changes  "What I changed": rows like "Outfit → Hoodie", each with Undo (made by the server from the change itself)
//   approve  a go-ahead with its price lines and Total (actions.ts and suite_request_shot put these up)
// The live activity strip is not a card: the apps build it from uiCall steps (uiControl.ts stepOf) and job progress.
import { and, desc, eq } from 'drizzle-orm';
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { AuthUser, Ctx } from '../ctx.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { compact, uid } from '../lib/util.js';
import { parse } from '../camera/validate.js';
import { claudeMessages, claudeThreads } from '../camera/schema.js';
import type { EditTool } from '../editor/mcpTools.js';
import { ownChat, uiLine } from './chatTools.js';
import { videoOf } from './watch.js';
import { PAGES, type PageName } from './page.js';
import { balance, type PriceLine } from './priceLines.js';
export { balance, type PriceLine };

// ------------------------------------------------------------------ the card shapes

export type PlanCard = { kind: 'plan'; planId: string; title: string; steps: { text: string; done: boolean }[] };
export type Moment = { from: number; to?: number; label: string };
export type MediaCard = { kind: 'media'; title: string; summary?: string; video: { id: string; kind: string; url: string; title?: string }; durationSec?: number; moments: Moment[] };
/** How one changes row is undone. draft: put these draft keys back as they were (null = remove); tokens: the prompt's
 * mentions / words / moves (only that part). The server holds the before-values; the app only asks for the row. */
export type Undo = { kind: 'draft'; assistId: string; before: Record<string, unknown>; tokens?: 'mention' | 'text' | 'move'; remix?: string };
export type ChangeRow = { what: string; to: string; undo?: Undo; undone?: boolean };
export type ChangesCard = { kind: 'changes'; title: string; rows: ChangeRow[] };
export type ApproveCard = { kind: 'approve'; title: string; subtitle?: string; lines: PriceLine[]; totalUsd?: number;
  answer: { actionId: string } | { assistId: string; pendingId: string }; approveLabel: string; declineLabel: string; status?: string };
export type Card = PlanCard | MediaCard | ChangesCard | ApproveCard;

/** What the app may see of a card: the undo's before-values stay on the server (they can be large and are not the app's). */
export function publicCard(c: Card): Card {
  if (c.kind !== 'changes') return c;
  return { ...c, rows: c.rows.map(r => compact({ what: r.what, to: r.to, undoable: !!r.undo && !r.undone, undone: r.undone || undefined }) as unknown as ChangeRow) };
}

const lineOf = (c: Card) => c.kind === 'plan' ? `${c.title}: ${c.steps.filter(s => s.done).length} of ${c.steps.length} done`
  : c.kind === 'media' ? `${c.title}: ${c.moments.length} moment${c.moments.length === 1 ? '' : 's'}`
  : c.kind === 'changes' ? `${c.title}: ${c.rows.map(r => `${r.what} → ${r.to}`).join(', ')}`
  : `${c.title}${c.totalUsd !== undefined ? ` · $${c.totalUsd.toFixed(2)}` : ''}`;

/** Puts a card in the chat (stored, streamed, sent to the person's apps). The app gets the public card. */
export async function postCard(ctx: Ctx, u: AuthUser, threadId: string, card: Card) {
  const tool = await uiLine(ctx, u, threadId, 'card', lineOf(card), { card: publicCard(card) });
  // The full card (undo before-values) is kept on the stored row only.
  if (card.kind === 'changes') await saveFull(ctx, threadId, tool.id, card);
  return tool;
}

/** Stored lines carry the full card under ui.full; the app is sent ui.card. */
async function saveFull(ctx: Ctx, threadId: string, toolId: string, card: Card) {
  const rows = await ctx.db.select().from(claudeMessages).where(and(eq(claudeMessages.threadId, threadId), eq(claudeMessages.role, 'tool'))).orderBy(desc(claudeMessages.createdAt)).limit(20);
  const row = rows.find(r => r.tool?.id === toolId);
  if (row) await ctx.db.update(claudeMessages).set({ tool: { ...row.tool!, ui: { card: publicCard(card), full: card } } }).where(eq(claudeMessages.id, row.id));
}

/** A stored card line of this person's own chat. */
async function cardRow(ctx: Ctx, u: AuthUser, messageId: string) {
  const [m] = await ctx.db.select().from(claudeMessages).where(eq(claudeMessages.id, messageId));
  if (!m || m.role !== 'tool' || m.tool?.name !== 'card') throw notFound('Card');
  const [t] = await ctx.db.select({ id: claudeThreads.id }).from(claudeThreads).where(and(eq(claudeThreads.id, m.threadId), eq(claudeThreads.ownerId, u.id), eq(claudeThreads.studioId, u.studioId)));
  if (!t) throw notFound('Card');
  const ui = (m.tool.ui ?? {}) as { card?: Card; full?: Card };
  const card = ui.full ?? ui.card;
  if (!card) throw notFound('Card');
  return { m, card };
}

/** Rewrites a stored card and sends the line again (same message id: the apps replace it in place). */
export async function replaceCard(ctx: Ctx, u: AuthUser, m: typeof claudeMessages.$inferSelect, card: Card) {
  const tool = { ...m.tool!, summary: lineOf(card), ui: card.kind === 'changes' ? { card: publicCard(card), full: card } : { card } };
  await ctx.db.update(claudeMessages).set({ tool }).where(eq(claudeMessages.id, m.id));
  const sent = { ...tool, ui: { card: publicCard(card) } };
  void ctx.hub.emitTo(u.id, { type: 'claude', op: 'message', threadId: m.threadId, message: compact({ id: m.id, threadId: m.threadId, role: 'tool', source: m.source, text: '', tool: sent, createdAt: m.createdAt }) });
  void ctx.hub.emitTo(u.id, { type: 'claude', op: 'card', threadId: m.threadId, messageId: m.id, card: publicCard(card) });
}

/** The newest plan card with this id in the chat (show_plan updates it rather than adding a second one). */
async function planRow(ctx: Ctx, threadId: string, planId: string) {
  const rows = await ctx.db.select().from(claudeMessages).where(and(eq(claudeMessages.threadId, threadId), eq(claudeMessages.role, 'tool'))).orderBy(desc(claudeMessages.createdAt)).limit(200);
  return rows.find(r => r.tool?.name === 'card' && ((r.tool.ui as { card?: Card } | undefined)?.card as PlanCard | undefined)?.planId === planId);
}

// ------------------------------------------------------------------ price lines (approve cards)

/** The breakdown in an estimate answer (`breakdown: {lines, totalUsd}`), whatever the screen nests it under. */
export function breakdownOf(e: unknown): { lines: PriceLine[]; totalUsd: number } | null {
  if (!e || typeof e !== 'object') return null;
  const o = e as Record<string, unknown>;
  const b = o.breakdown as { lines?: unknown; totalUsd?: unknown } | undefined;
  if (b && Array.isArray(b.lines) && typeof b.totalUsd === 'number') {
    const lines = b.lines.filter((l): l is PriceLine => !!l && typeof (l as PriceLine).label === 'string' && typeof (l as PriceLine).usd === 'number');
    return { lines, totalUsd: b.totalUsd };
  }
  for (const k of ['estimate', 'quote', 'price']) if (o[k] && typeof o[k] === 'object') { const x = breakdownOf(o[k]); if (x) return x; }
  return null;
}

// ------------------------------------------------------------------ "What I changed" from a Suite draft change

type Tok = { t: string; kind?: string; label?: string; text?: string; id?: string };
const toks = (d: Record<string, unknown>) => (Array.isArray(d.tokens) ? d.tokens as Tok[] : []);
const same = (a: unknown, b: unknown) => JSON.stringify(a ?? null) === JSON.stringify(b ?? null);
const cap = (s: string) => (s ? s[0]!.toUpperCase() + s.slice(1) : s);
const words = (s: string, n = 6) => { const w = s.trim().split(/\s+/); return w.length > n ? `${w.slice(0, n).join(' ')}…` : s.trim(); };
const idWords = (v: unknown) => (typeof v === 'string' ? cap(v.replace(/[_-]+/g, ' ')) : typeof v === 'number' ? String(v) : '');
const BACKGROUND: Record<string, string> = { keep: 'Keep', photo: 'New photo', describe: 'Describe it' };
const RIG_NAMES: Record<string, string> = { body: 'Camera', lens: 'Lens', focalMm: 'Focal length', aperture: 'Aperture', height: 'Angle', shotSize: 'Framing',
  lighting: 'Lighting', palette: 'Palette', stock: 'Film look', gradeLook: 'Look', genre: 'Style', era: 'Era', tempo: 'Tempo', format: 'Format' };
const QUALITY: Record<string, string> = { draft: 'Draft', standard: 'Standard', hd: 'HD', cinema: 'Cinema' };
const mmss = (s: number) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;

/** Names the person knows things by: outfits, clips, models (the caller looks them up). */
export type Names = { outfit?: (id: string) => string | undefined; clip?: (id: string) => string | undefined; engine?: (id: string) => string | undefined };

function remixWords(k: string, v: unknown, n: Names): string {
  if (!v || typeof v !== 'object') return 'Off';
  const o = v as Record<string, unknown>;
  if (typeof o.words === 'string' && o.words.trim()) return cap(words(o.words));
  if (o.mode === 'photo') return typeof o.name === 'string' && o.name ? o.name : 'New photo';
  if (o.kind === 'outfit' && typeof o.outfitId === 'string') return n.outfit?.(o.outfitId) ?? 'Outfit';
  if (o.kind === 'product') return 'Product';
  if (o.kind === 'model') return 'Her';
  if (o.kind === 'face') return 'Face swap';
  return k === 'look' ? 'Changed' : 'On';
}

/**
 * The rows of a "What I changed" card for one Suite draft change, each with how to undo it. Only what really changed
 * gets a row; the screen field (the app's own report) and bookkeeping are ignored.
 */
export function draftChanges(assistId: string, before: Record<string, unknown>, after: Record<string, unknown>, n: Names = {}): ChangeRow[] {
  const rows: ChangeRow[] = [];
  const undo = (keys: string[], extra: Partial<Undo> = {}): Undo => ({ kind: 'draft', assistId, before: Object.fromEntries(keys.map(k => [k, before[k] ?? null])), ...extra });
  // The prompt's parts: the @model, the words, the #moves.
  const tb = toks(before), ta = toks(after);
  const part = (list: Tok[], t: string) => list.filter(x => x.t === t);
  const model = (list: Tok[]) => part(list, 'mention').find(x => x.kind === 'character')?.label;
  if (!same(model(tb), model(ta))) rows.push({ what: 'Model', to: model(ta) ?? 'None', undo: undo(['tokens'], { tokens: 'mention' }) });
  const text = (list: Tok[]) => part(list, 'text').map(x => x.text ?? '').join('').trim();
  if (text(tb) !== text(ta)) rows.push({ what: 'Prompt', to: text(ta) ? `“${words(text(ta))}”` : 'Empty', undo: undo(['tokens'], { tokens: 'text' }) });
  const moves = (list: Tok[]) => part(list, 'move').map(x => x.label ?? x.id).join(', ');
  if (moves(tb) !== moves(ta)) rows.push({ what: 'Movement', to: moves(ta) || 'Auto', undo: undo(['tokens'], { tokens: 'move' }) });
  if (!same(before.outfitId, after.outfitId)) rows.push({ what: 'Outfit', to: typeof after.outfitId === 'string' ? n.outfit?.(after.outfitId) ?? 'Outfit' : 'None', undo: undo(['outfitId']) });
  // The rig, row by row (one Undo puts the whole rig back: rows of one rig are set together).
  const rb = (before.rig ?? {}) as Record<string, unknown>, ra = (after.rig ?? {}) as Record<string, unknown>;
  for (const k of new Set([...Object.keys(rb), ...Object.keys(ra)])) {
    if (same(rb[k], ra[k])) continue;
    const v = ra[k];
    rows.push({ what: RIG_NAMES[k] ?? idWords(k), to: v === undefined || v === null ? 'Auto' : k === 'focalMm' ? `${v} mm` : k === 'aperture' && typeof v === 'number' ? `f/${v}` : idWords(v), undo: undo(['rig']) });
  }
  const simple: [string, string, (v: unknown) => string][] = [
    ['quality', 'Quality', v => QUALITY[String(v)] ?? idWords(v)], ['aspect', 'Shape', v => String(v ?? '')], ['duration', 'Length', v => `${v} s`],
    ['takes', 'Takes', v => String(v)], ['sound', 'Sound', v => (v ? 'On' : 'Off')], ['count', 'Photos', v => String(v)],
    ['speaking', 'Speaking', v => (v === undefined || v === null ? 'Auto' : v ? 'Yes' : 'No')],
    ['engineModel', 'Video model', v => (typeof v === 'string' ? n.engine?.(v) ?? v : 'Auto')], ['resolution', 'Resolution', v => (typeof v === 'string' ? v : 'Auto')],
    ['background', 'Background', v => BACKGROUND[String(v)] ?? 'Keep'], ['directed', 'Movement', v => (v ? 'Directed' : 'Chips')],
    ['clipId', 'Clip', v => (typeof v === 'string' ? n.clip?.(v) ?? 'Clip' : 'None')],
    ['range', 'Part used', v => (Array.isArray(v) && v.length === 2 ? `${mmss(Number(v[0]))}–${mmss(Number(v[1]))}` : 'Whole clip')],
  ];
  for (const [k, what, fmt] of simple) if (!same(before[k], after[k])) rows.push({ what, to: fmt(after[k]), undo: undo([k]) });
  if (!same(before.tool, after.tool) && (after.tool === 'remix' || after.tool === 'swap') && (before.tool === 'remix' || before.tool === 'swap'))
    rows.push({ what: 'Swap', to: after.tool === 'remix' ? 'New Swap' : 'Swap', undo: undo(['tool']) });
  // New Swap's toggles, each on its own.
  const xb = (before.remix ?? {}) as Record<string, unknown>, xa = (after.remix ?? {}) as Record<string, unknown>;
  for (const k of ['background', 'outfit', 'character', 'look']) {
    if (same(xb[k], xa[k])) continue;
    rows.push({ what: cap(k === 'look' ? 'Look' : k), to: remixWords(k, xa[k], n), undo: undo(['remix'], { remix: k }) });
  }
  return rows;
}

/** Applies one row's undo to the draft as it is NOW (later changes to other parts stay). */
export function undoDraft(now: Record<string, unknown>, u: Undo): Record<string, unknown> {
  const d = { ...now };
  if (u.tokens) {
    const b = toks(u.before as Record<string, unknown>), cur = toks(now);
    const isPart = (x: Tok) => x.t === u.tokens;
    const back = b.filter(isPart), rest = cur.filter(x => !isPart(x));
    // Order as the composer writes it: mentions, words, moves.
    const order = ['mention', 'text', 'move'];
    d.tokens = [...rest, ...back].sort((x, y) => order.indexOf(x.t) - order.indexOf(y.t));
    return d;
  }
  if (u.remix) {
    const before = ((u.before.remix ?? {}) as Record<string, unknown>)[u.remix];
    const cur = { ...((now.remix ?? {}) as Record<string, unknown>) };
    if (before === undefined || before === null) delete cur[u.remix]; else cur[u.remix] = before;
    if (Object.keys(cur).length) d.remix = cur; else delete d.remix;
    return d;
  }
  for (const [k, v] of Object.entries(u.before)) { if (v === null || v === undefined) delete d[k]; else d[k] = v; }
  return d;
}

// ------------------------------------------------------------------ quick-action chips (contextual to the page)

export type Chip = { label: string; prompt: string; icon: string };
/** The chips over the composer: three things Claude is most often asked on this page. Phosphor names. */
export function chipsFor(page: PageName | undefined, tool?: string): Chip[] {
  const c = (label: string, prompt: string, icon: string): Chip => ({ label, prompt, icon });
  const price = c('Check the price', 'What will this cost, line by line?', 'coins');
  switch (page) {
    case 'suite':
      if (tool === 'swap' || tool === 'remix' || tool === 'recast' || tool === 'extend') return [c('Watch my clip', 'Watch my clip and tell me the key moments.', 'play-circle'), c('Write the prompt', 'Write the prompt for this shot.', 'pencil-simple'), price];
      if (tool === 'photo') return [c('Write the prompt', 'Write the prompt for these photos.', 'pencil-simple'), c('Look at the outfit', 'Look at the outfit and describe it.', 'eye'), price];
      return [c('Write the prompt', 'Write the prompt for this shot.', 'pencil-simple'), c('Set the rig', 'Set up the rig for this shot.', 'aperture'), price];
    case 'edit': return [c('Watch my edit', 'Watch my edit and tell me what to fix.', 'play-circle'), c('Cut to the beat', 'Cut this to the beat.', 'scissors'), c('Add captions', 'Add captions to this edit.', 'text-aa')];
    case 'take': return [c('Watch this take', 'Watch this take and tell me what works.', 'play-circle'), c('Make a variation', 'Set up a variation of this take.', 'pencil-simple'), c('Edit it', 'Open this take in Edit.', 'film-strip')];
    case 'recreate': return [c('Watch the reference', 'Watch the reference video and break it down.', 'play-circle'), c('Plan the shots', 'Plan the shots to recreate this.', 'check-square'), price];
    case 'character': case 'cast': return [c('Look at her', 'Look at her pictures and tell me what is missing.', 'eye'), c('New outfit', 'Make a new outfit for her.', 'pencil-simple'), c('Plan a shoot', 'Plan a shoot with her.', 'check-square')];
    case 'library': return [c('Find a take', 'Find the take I am thinking of.', 'magnifying-glass'), c('Sort my library', 'Sort my library into collections.', 'squares-four'), c('Best of today', 'Which of today’s takes are best?', 'play-circle')];
    case 'queue': return [c('What’s running', 'What is running right now?', 'stack'), c('Why it failed', 'Why did my last job fail?', 'warning'), c('Clear failed', 'Clear the failed jobs.', 'x')];
    case 'camera': return [c('Block the shot', 'Block this shot with me.', 'video-camera'), c('Render guides', 'Render the guides.', 'play-circle'), price];
    default: return [c('What can you do', 'What can you do on this page?', 'chat-circle'), c('Start a shot', 'Help me start a new shot.', 'video-camera'), c('Watch my clip', 'Watch my latest clip.', 'play-circle')];
  }
}

// ------------------------------------------------------------------ tools Claude uses to put cards up

const str = (d: string, max?: number) => ({ type: 'string', description: d, ...(max ? { maxLength: max } : {}) });
const obj = (properties: Record<string, unknown>, required: string[] = []) => ({ type: 'object', properties, required, additionalProperties: false });
const CHAT_ID = str('Optional: this chat (filled in for you; left out = the chat you are talking in)');

/** The chat a card goes to: the one named (must be the person's own), else the chat the request came from, else the
 * person's most recent chat (Claude Code over MCP has no chat of its own). Never fails just because chatId is missing. */
async function chatFor(env: { ctx: Ctx; user: AuthUser }, a: Record<string, unknown>) {
  if (typeof a.chatId === 'string' && a.chatId) return ownChat(env.ctx, env.user, a.chatId);
  if (env.user.chatId) { const t = await ownChat(env.ctx, env.user, env.user.chatId).catch(() => null); if (t) return t; }
  const [t] = await env.ctx.db.select().from(claudeThreads).where(and(eq(claudeThreads.ownerId, env.user.id), eq(claudeThreads.studioId, env.user.studioId)))
    .orderBy(desc(claudeThreads.updatedAt)).limit(1);
  if (!t) throw badRequest('chatId: no Claude chat is open; open the Claude panel first');
  return t;
}

const MAX_STEPS = 8, MAX_MOMENTS = 8;
const clip = (s: string, n: number) => (s.length > n ? `${s.slice(0, n - 1).trimEnd()}…` : s);
const firstStr = (o: Record<string, unknown>, keys: string[]) => { for (const k of keys) if (typeof o[k] === 'string' && (o[k] as string).trim()) return (o[k] as string).trim(); return undefined; };
const firstNum = (o: Record<string, unknown>, keys: string[]) => { for (const k of keys) { const v = o[k]; const n = typeof v === 'string' && v.trim() !== '' ? Number(v) : v; if (typeof n === 'number' && Number.isFinite(n)) return n; } return undefined; };
const isTrue = (v: unknown) => v === true || v === 'done' || v === 'true' || v === 'completed' || v === 'complete';

/** A plan step as Claude writes it: "Watch the clip", {text}, {title}, {label}, {step}, {name}; done may be a flag or a status. */
function stepOfInput(x: unknown): { text: string; done: boolean } | null {
  if (typeof x === 'string') return x.trim() ? { text: clip(x.trim(), 140), done: false } : null;
  if (!x || typeof x !== 'object') return null;
  const o = x as Record<string, unknown>;
  const text = firstStr(o, ['text', 'title', 'label', 'step', 'name', 'description']);
  return text ? { text: clip(text, 140), done: isTrue(o.done) || isTrue(o.status) || isTrue(o.checked) } : null;
}

/** More than eight steps don't fit the card: the first seven stay, the rest are joined into the eighth. */
export function fitSteps(list: { text: string; done: boolean }[]): { steps: { text: string; done: boolean }[]; merged?: number } {
  if (list.length <= MAX_STEPS) return { steps: list };
  const rest = list.slice(MAX_STEPS - 1);
  return { steps: [...list.slice(0, MAX_STEPS - 1), { text: clip(rest.map(s => s.text).join(' · '), 140), done: rest.every(s => s.done) }], merged: list.length };
}

/** show_plan's input, read loosely: unknown keys are ignored, `id` means planId, steps may be plain strings. */
export function planInput(a: Record<string, unknown>) {
  const rawId = firstStr(a, ['planId', 'id', 'plan_id']);
  const planId = rawId ? (rawId.replace(/[^A-Za-z0-9_-]+/g, '_').slice(0, 40) || 'plan') : undefined;
  const title = firstStr(a, ['title', 'name', 'heading']);
  const raw = Array.isArray(a.steps) ? a.steps : Array.isArray(a.items) ? a.items : typeof a.steps === 'string' ? a.steps.split(/\n+/) : undefined;
  const all = raw?.map(stepOfInput).filter((s): s is { text: string; done: boolean } => !!s);
  if (raw && !all!.length) throw badRequest('steps: write each step as a short line, e.g. ["Watch the clip", "Swap the outfit"]');
  const fit = all ? fitSteps(all) : undefined;
  const doneRaw = Array.isArray(a.done) ? a.done : typeof a.done === 'number' ? [a.done] : [];
  const done = doneRaw.map(v => (typeof v === 'string' ? Number(v) : v)).filter((n): n is number => typeof n === 'number' && Number.isInteger(n) && n >= 0);
  return { planId, title: title ? clip(title, 80) : undefined, steps: fit?.steps, merged: fit?.merged, done };
}

/** show_clip's input, read loosely: unknown keys ignored, the video under id/videoId/takeId/url, moments as {from|start|at|t, to|end, label|text|title}. */
export function clipInput(a: Record<string, unknown>) {
  const id = firstStr(a, ['id', 'videoId', 'takeId', 'clipId', 'uploadId', 'jobId', 'url', 'video']);
  if (!id) throw badRequest('id: the video you watched (take, clip, upload or job id, or its /uploads/… link)');
  const raw = Array.isArray(a.moments) ? a.moments : Array.isArray(a.keyMoments) ? a.keyMoments : [];
  const all = raw.map(x => {
    if (!x || typeof x !== 'object') return null;
    const o = x as Record<string, unknown>;
    const from = firstNum(o, ['from', 'start', 'startSec', 'at', 't', 'time', 'sec']);
    const label = firstStr(o, ['label', 'text', 'title', 'what', 'description']);
    if (from === undefined || from < 0 || !label) return null;
    const to = firstNum(o, ['to', 'end', 'endSec']);
    return compact({ from, to: to !== undefined && to > from ? to : undefined, label: clip(label, 80) }) as Moment;
  }).filter((m): m is Moment => !!m).sort((x, y) => x.from - y.from);
  if (!all.length) throw badRequest('moments: at least one {from (seconds), label}');
  const durationSec = firstNum(a, ['durationSec', 'duration', 'lengthSec']);
  const title = firstStr(a, ['title']), summary = firstStr(a, ['summary', 'description']);
  return { id, title: title ? clip(title, 60) : undefined, summary: summary ? clip(summary, 160) : undefined,
    durationSec: durationSec !== undefined && durationSec > 0 ? durationSec : undefined, moments: all.slice(0, MAX_MOMENTS), dropped: Math.max(0, all.length - MAX_MOMENTS) };
}

export const CARD_TOOLS: EditTool[] = [
  {
    name: 'show_plan', title: 'Show a plan (checklist)', scope: 'edit:read',
    description: 'Puts a plan in the chat as a checklist card when the person asks for a plan or the work has several steps. Shape: '
      + '{planId?: "swap", title?: "Plan: outfit swap", steps?: ["Watch the clip", "Swap the outfit"], done?: [0]}. steps is a list of short plain '
      + 'lines (objects {text, done?} also work); at most 8 fit, more are joined into the 8th. Call it again with the same planId as you go: '
      + '`done: [0, 1]` ticks those steps (0-based), `steps` rewrites them. The chat is filled in for you. Free; changes nothing in MUSE.',
    inputSchema: { type: 'object', properties: { chatId: CHAT_ID, planId: str('Your id for this plan ("swap"); the same id updates it. Default "plan"', 40), title: str('"Plan: outfit swap"', 80),
      steps: { type: 'array', description: 'Short plain lines, e.g. ["Watch the clip", "Swap the outfit"] (1–8; more are joined into the last)', items: { anyOf: [{ type: 'string', maxLength: 140 }, obj({ text: str('One step', 140), done: { type: 'boolean' } }, ['text'])] } },
      done: { type: 'array', items: { type: 'integer', minimum: 0 }, description: 'Steps now finished (0-based)' } }, required: [] },
    run: async (env, a) => {
      const b = planInput(a);
      const chat = await chatFor(env, a);
      const planId = b.planId ?? 'plan';
      const old = await planRow(env.ctx, chat.id, planId);
      const prev = old ? ((old.tool!.ui as { card: PlanCard }).card) : undefined;
      let steps = b.steps ?? prev?.steps;
      if (!steps) throw badRequest(`steps: the plan's steps, e.g. ["Watch the clip", "Swap the outfit"] (no plan "${planId}" in this chat to update)`);
      // A tick past the last step (a merged plan) ticks the last one.
      if (b.done.length) steps = steps.map((s, i) => ({ ...s, done: s.done || b.done.some(n => Math.min(n, steps!.length - 1) === i) }));
      const card: PlanCard = { kind: 'plan', planId, title: b.title ?? prev?.title ?? 'Plan', steps };
      const note = b.merged ? `Only ${MAX_STEPS} steps fit the card: steps ${MAX_STEPS}–${b.merged} were joined into step ${MAX_STEPS}. Plan in at most ${MAX_STEPS} steps next time.` : undefined;
      if (old) { await replaceCard(env.ctx, env.user, old, card); return compact({ ok: true, updated: true, planId, done: steps.filter(s => s.done).length, of: steps.length, note }); }
      await postCard(env.ctx, env.user, chat.id, card);
      return { ok: true, planId, note: [note, 'The person sees the checklist. Tick steps with show_plan {planId, done: [n]} as you finish them.'].filter(Boolean).join(' ') };
    },
  },
  {
    name: 'show_clip', title: 'Show a clip with its key moments', scope: 'edit:read',
    description: 'After you WATCHED a video, puts it in the chat as a "Clip analysis" card: the video (play), its length, one line on what you found and its key moments, each of which the person can click to jump there. '
      + 'Shape: {id: "<the video as you watched it>", summary?: "Three moments", durationSec?: 22.1, moments: [{from: 3.2, to?: 5, label: "Face clear"}]} (seconds as watch labels them; at most 8 moments, more are dropped). '
      + 'Use it when the moments matter for what comes next (where the face is clear, where a cut is). The chat is filled in for you. Free.',
    inputSchema: { type: 'object', properties: { chatId: CHAT_ID, id: str('The video, as you watched it (take, clip, upload, job id or /uploads/… link)', 300), title: str('Default "Clip analysis"', 60),
      summary: str('One line ("Three moments in your clip")', 160), durationSec: { type: 'number', description: 'Its length (from watch)' },
      moments: { type: 'array', minItems: 1, description: '1–8 moments, e.g. [{from: 3.2, label: "Face clear"}]', items: obj({ from: { type: 'number', minimum: 0, description: 'Seconds' }, to: { type: 'number', minimum: 0, description: 'Seconds (optional)' }, label: str('What happens', 80) }, ['from', 'label']) } }, required: ['id', 'moments'] },
    run: async (env, a) => {
      const b = clipInput(a);
      const chat = await chatFor(env, a);
      const v = await videoOf(env.ctx, env.user, b.id);
      const moments = b.durationSec !== undefined ? b.moments.filter(m => m.from <= b.durationSec! + 0.5) : b.moments;
      if (!moments.length) throw badRequest('moments: every moment starts after the video ends');
      const card: MediaCard = compact({ kind: 'media' as const, title: b.title || 'Clip analysis', summary: b.summary, durationSec: b.durationSec,
        video: compact({ id: v.id, kind: v.kind, url: `/uploads/${v.key.replace(/^\/?uploads\//, '')}`, title: v.title }), moments }) as MediaCard;
      await postCard(env.ctx, env.user, chat.id, card);
      const skipped = b.dropped + (b.moments.length - moments.length);
      return { ok: true, note: ['The person sees the clip with its moments; clicking one plays it from there.', skipped ? `${skipped} moment${skipped === 1 ? ' was' : 's were'} left out (at most ${MAX_MOMENTS}, none past the end).` : ''].filter(Boolean).join(' ') };
    },
  },
];

// ------------------------------------------------------------------ routes

export async function registerCardRoutes(app: FastifyInstance, ctx: Ctx, undoDraftIn: (u: AuthUser, assistId: string, fn: (d: Record<string, unknown>) => Record<string, unknown>) => Promise<unknown>) {
  // Undo one row of a "What I changed" card: the server puts back what it changed (only that part, as it is now).
  app.post<{ Params: { id: string } }>('/v1/claude/cards/:id/undo', async req => {
    const b = parse(z.object({ row: z.number().int().min(0).max(40) }).strict(), req.body ?? {});
    const { m, card } = await cardRow(ctx, req.user, req.params.id);
    if (card.kind !== 'changes') throw badRequest('Only a "What I changed" card has Undo');
    const row = card.rows[b.row];
    if (!row?.undo) throw notFound('Change');
    if (row.undone) throw new ApiError(409, 'already_undone', 'That change was already undone');
    await undoDraftIn(req.user, row.undo.assistId, d => undoDraft(d, row.undo!));
    const next: ChangesCard = { ...card, rows: card.rows.map((r, i) => (i === b.row ? { ...r, undone: true } : r)) };
    await replaceCard(ctx, req.user, m, next);
    return { ok: true, card: publicCard(next) };
  });
  // The quick-action chips for a page (the apps also fall back to their own copy when offline).
  app.get('/v1/claude/chips', async req => {
    const q = parse(z.object({ page: z.enum(PAGES).optional(), tool: z.string().regex(/^[a-z]{1,20}$/).optional() }).strict(), req.query ?? {});
    return { chips: chipsFor(q.page, q.tool) };
  });
}

export const cardId = () => uid('card');
