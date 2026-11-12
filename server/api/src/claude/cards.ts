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
const CHAT_ID = str('This chat (filled in for you in the app)');
const chatOf = (env: { user: AuthUser }, a: Record<string, unknown>) => (typeof a.chatId === 'string' && a.chatId ? a.chatId : env.user.chatId);

const PlanIn = z.object({ chatId: z.string().optional(), planId: z.string().regex(/^[A-Za-z0-9_-]{1,40}$/).optional(), title: z.string().trim().min(1).max(80).optional(),
  steps: z.array(z.object({ text: z.string().trim().min(1).max(140), done: z.boolean().optional() }).strict()).min(1).max(8).optional(),
  done: z.array(z.number().int().min(0).max(7)).max(8).optional() }).strict();
const ClipIn = z.object({ chatId: z.string().optional(), id: z.string().min(1).max(300), title: z.string().trim().max(60).optional(), summary: z.string().trim().max(160).optional(),
  durationSec: z.number().positive().max(36000).optional(),
  moments: z.array(z.object({ from: z.number().min(0), to: z.number().min(0).optional(), label: z.string().trim().min(1).max(80) }).strict()).min(1).max(8) }).strict();

export const CARD_TOOLS: EditTool[] = [
  {
    name: 'show_plan', title: 'Show a plan (checklist)', scope: 'edit:read',
    description: 'Puts a plan in the chat as a checklist card (title + 1–8 short steps) when the person asks for a plan or the work has several steps. Call it again with the same planId as you go: `done: [0, 1]` ticks those steps (0-based), or send `steps` to rewrite them. Write each step as a plain action ("Watch the clip and lock her look"). Free; changes nothing in MUSE.',
    inputSchema: obj({ chatId: CHAT_ID, planId: str('Your id for this plan ("swap"); the same id updates it', 40), title: str('"Plan: outfit swap"', 80),
      steps: { type: 'array', maxItems: 8, items: obj({ text: str('One step', 140), done: { type: 'boolean' } }, ['text']) },
      done: { type: 'array', items: { type: 'integer', minimum: 0, maximum: 7 }, description: 'Steps now finished (0-based)' } }),
    run: async (env, a) => {
      const b = parse(PlanIn, a);
      const chat = await ownChat(env.ctx, env.user, chatOf(env, a));
      const planId = b.planId ?? 'plan';
      const old = await planRow(env.ctx, chat.id, planId);
      const prev = old ? ((old.tool!.ui as { card: PlanCard }).card) : undefined;
      let steps = b.steps ? b.steps.map(s => ({ text: s.text, done: !!s.done })) : prev?.steps;
      if (!steps) throw badRequest('steps: the plan\'s steps (1–8)');
      if (b.done) steps = steps.map((s, i) => ({ ...s, done: s.done || b.done!.includes(i) }));
      const card: PlanCard = { kind: 'plan', planId, title: b.title ?? prev?.title ?? 'Plan', steps };
      if (old) { await replaceCard(env.ctx, env.user, old, card); return { ok: true, updated: true, planId, done: steps.filter(s => s.done).length, of: steps.length }; }
      await postCard(env.ctx, env.user, chat.id, card);
      return { ok: true, planId, note: 'The person sees the checklist. Tick steps with show_plan {planId, done: [n]} as you finish them.' };
    },
  },
  {
    name: 'show_clip', title: 'Show a clip with its key moments', scope: 'edit:read',
    description: 'After you WATCHED a video, puts it in the chat as a "Clip analysis" card: the video (play), its length, one line on what you found and its key moments ({from, to?, label} in seconds as watch labels them, 1–8), each of which the person can click to jump there. Use it when the moments matter for what comes next (where the face is clear, where a cut is). Free.',
    inputSchema: obj({ chatId: CHAT_ID, id: str('The video, as you watched it (take, clip, upload, job id or /uploads/… link)', 300), title: str('Default "Clip analysis"', 60),
      summary: str('One line ("Three moments in your clip")', 160), durationSec: { type: 'number', description: 'Its length (from watch)' },
      moments: { type: 'array', minItems: 1, maxItems: 8, items: obj({ from: { type: 'number', minimum: 0 }, to: { type: 'number', minimum: 0 }, label: str('What happens', 80) }, ['from', 'label']) } }, ['id', 'moments']),
    run: async (env, a) => {
      const b = parse(ClipIn, a);
      const chat = await ownChat(env.ctx, env.user, chatOf(env, a));
      const v = await videoOf(env.ctx, env.user, b.id);
      const moments = b.moments.map(m => compact({ from: m.from, to: m.to !== undefined && m.to > m.from ? m.to : undefined, label: m.label }) as Moment).sort((x, y) => x.from - y.from);
      if (b.durationSec !== undefined && moments.some(m => m.from > b.durationSec! + 0.5)) throw badRequest('moments: a moment starts after the video ends');
      const card: MediaCard = compact({ kind: 'media' as const, title: b.title || 'Clip analysis', summary: b.summary, durationSec: b.durationSec,
        video: compact({ id: v.id, kind: v.kind, url: `/uploads/${v.key.replace(/^\/?uploads\//, '')}`, title: v.title }), moments }) as MediaCard;
      await postCard(env.ctx, env.user, chat.id, card);
      return { ok: true, note: 'The person sees the clip with its moments; clicking one plays it from there.' };
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
