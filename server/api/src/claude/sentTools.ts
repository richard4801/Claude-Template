// One Claude (owner, 2026-11-11): Claude can see and change the images a generation sends to the model ("It can change
// what images go in when necessary"). get_sent_images shows what would go (MUSE's pick or a changed list, each with its
// role and why); set_sent_images replaces the list, adds to it, drops from it, or resets it to automatic. The Suite keeps
// the choice in the composer's draft (the app shows "Images sent · Changed by Claude"); the outfit sheet, Fill angles and
// Dress up keep it per person and character until reset. Free: nothing is generated; Generate still needs the go-ahead.
import { and, desc, eq } from 'drizzle-orm';
import { badRequest } from '../errors.js';
import { claudeThreads } from '../camera/schema.js';
import { ownChat, pageOf } from './chatTools.js';
import type { EditTool, ToolEnv } from '../editor/mcpTools.js';
import { ImageInSchema, SentImageInSchema, sentImagesOf, type SentInput, type SentPage, type SentView } from '../images/sent.js';
import { assistOf, sentOfDraft } from '../suite/assist.js';
import { resolveAssist } from '../suite/screen.js';
import type { Draft } from '../suite/drafts.js';

const PAGES_ = ['suite', 'outfit', 'fill_angles', 'dress_up'] as const;
const SCOPE: Record<Exclude<SentPage, 'photo'>, string> = { outfit: 'outfit', fill_angles: 'sheet', dress_up: 'dressup' };
const IMG = { description: 'An image of this studio: {url} or {asset} as MUSE gives it, an upload id (an attached image), or a take\'s frame {takeId, at (seconds)}' };
const ITEM = { type: 'object', properties: { image: IMG, role: { type: 'string', enum: ['person', 'outfit', 'product', 'location', 'style', 'pose', 'other'] }, label: { type: 'string', maxLength: 60 } }, required: ['image', 'role'] };
const TARGET = {
  chatId: { type: 'string', description: 'This chat (filled in for you in the app; Claude Code passes it): its page gives the draft or the character' },
  page: { type: 'string', enum: [...PAGES_], description: 'suite (the open composer: Shot, Photo, Talking, UGC, Swap, Recast; default when a shot is open), outfit (the new-outfit sheet), fill_angles (Fill the character sheet), dress_up' },
  assistId: { type: 'string', description: 'Suite: the draft on screen (filled in for you); also a camera Shot draft (sd_…) or camera session (cs_…)' },
  cameraSessionId: { type: 'string', description: 'The camera session open on the Camera page (filled in for you): its Shot draft' },
  modelId: { type: 'string', description: 'outfit / fill_angles / dress_up: the character (filled in on her page)' },
  request: { type: 'object', description: 'outfit / dress_up: what the sheet is set to, as its request takes it (description, images, base, outfitImage, imageModel …), so the pick matches' },
};

/** The ids the person's page has open (the chat's page, else their latest chat's), for calls without them (MCP). */
async function withPage(env: ToolEnv, a: Record<string, unknown>) {
  const page0 = typeof a.page === 'string' ? a.page : undefined;
  // Any draft id (sa_, a camera Shot draft sd_, a camera session cs_) reaches the draft on screen.
  if (typeof a.assistId === 'string' && a.assistId) return { ...a, assistId: await resolveAssist(env, { assistId: a.assistId }) };
  if (typeof a.modelId === 'string' && a.modelId) return a;
  if ((!page0 || page0 === 'suite') && typeof a.cameraSessionId === 'string' && a.cameraSessionId) return { ...a, assistId: await resolveAssist(env, { assistId: a.cameraSessionId }) };
  const [t] = typeof a.chatId === 'string' && a.chatId
    ? [await ownChat(env.ctx, env.user, a.chatId).catch(() => null)]
    : await env.ctx.db.select().from(claudeThreads).where(and(eq(claudeThreads.ownerId, env.user.id), eq(claudeThreads.studioId, env.user.studioId))).orderBy(desc(claudeThreads.updatedAt)).limit(1);
  const ids = (t ? pageOf(t)?.ids : undefined) ?? {};
  const page = typeof a.page === 'string' ? a.page : undefined;
  if ((!page || page === 'suite') && (ids.assistId || ids.cameraSessionId)) return { ...a, assistId: await resolveAssist(env, { assistId: ids.assistId ?? ids.cameraSessionId }) };
  if (ids.modelId) return { ...a, modelId: ids.modelId };
  return a;
}

/** Where the call points: the Suite's draft, or a page with a character. */
function target(a: Record<string, unknown>) {
  const page = (typeof a.page === 'string' ? a.page : a.assistId ? 'suite' : '') as (typeof PAGES_)[number] | '';
  if (!page) throw badRequest('page: suite, outfit, fill_angles or dress_up (open the Suite or a character first)');
  if (page === 'suite') { if (typeof a.assistId !== 'string' || !a.assistId) throw badRequest('assistId: open the AI Suite first'); return { page, assistId: a.assistId }; }
  if (typeof a.modelId !== 'string' || !a.modelId) throw badRequest('modelId: open the character first, or pass modelId');
  return { page, modelId: a.modelId };
}

async function current(env: ToolEnv, a: Record<string, unknown>): Promise<{ page: string; tool?: string; sentImages: SentView | null; error?: string }> {
  const t = target(a), svc = sentImagesOf(env.ctx);
  try {
    if (t.page === 'suite') {
      const v = await assistOf(env.ctx).get(env.user, t.assistId!);
      const d = v.draft as Draft & { outfitId?: string; count?: number };
      const tool = d.tool ?? 'shot';
      if (tool === 'photo') {
        const req = v.request as { modelId?: string; outfitId?: string };
        const est = svc.estimators.photo;
        if (!est) throw new Error('not ready');
        return { page: 'suite', tool, sentImages: await est(env.user, { ...(req.modelId ? { modelId: req.modelId } : {}), ...(req.outfitId ? { outfitId: req.outfitId } : {}), count: d.count ?? 1, ...sentOfDraft(d), draft: d }) };
      }
      const e = await env.ctx.suite.estimate(env.user, v.request) as { sentImages?: SentView };
      return { page: 'suite', tool, sentImages: e.sentImages ?? null };
    }
    const est = svc.estimators[t.page];
    if (!est) throw new Error('not ready');
    const body = { ...((a.request && typeof a.request === 'object' ? a.request : {}) as Record<string, unknown>), modelId: t.modelId };
    return { page: t.page, sentImages: await est(env.user, body) };
  } catch (e) {
    return { page: t.page, sentImages: null, error: (e as Error).message };
  }
}

export const SENT_PROMPT = `Images sent: MUSE picks the images each generation sends to the model by itself (her face, face ¾ or profile, a body angle, the outfit's angles, products and references), ranked and cut to the model's limit. You may change them when you judge it necessary: drop a misleading reference, add the outfit's side view, use a specific take frame, send her back view for a walk-away shot. get_sent_images shows what would go (each with its role and why); set_sent_images replaces the list (order = "Image 1, 2, …" in the prompt), adds, drops or resets to automatic. Only images of this studio; a model takes a limited number (you are told the limit if you go over). Always tell the person what you changed and why, in one line. Changing images is free; generating still needs their go-ahead.`;

export const SENT_TOOLS: EditTool[] = [
  {
    name: 'get_sent_images', title: 'The images a generation sends', scope: 'edit:read', readOnly: true, idempotent: true,
    description: 'What the generation being set up would send to the model, in order: each image with its role (person, outfit, product, location, style, pose, other), label and why MUSE picked it; whether it was changed (and by whom) and the model\'s limit. On the Suite (the open composer) by default; page outfit / fill_angles / dress_up with the character for the others. Free.',
    inputSchema: { type: 'object', properties: TARGET, additionalProperties: false },
    run: async (env, a) => current(env, await withPage(env, a)),
  },
  {
    name: 'set_sent_images', title: 'Change the images sent', scope: 'edit:write',
    description: 'Changes the images the generation sends. list replaces MUSE\'s pick (in that order: "Image n" in the prompt follows it); add puts images after MUSE\'s pick; exclude drops images from it; reset: true goes back to automatic. Only this studio\'s images (an upload id, a take\'s frame {takeId, at}, or {url}/{asset} as MUSE gives them). Over the model\'s limit is refused. Tell the person what you changed. Returns what will now be sent. Free.',
    inputSchema: { type: 'object', properties: { ...TARGET, list: { type: 'array', items: ITEM, maxItems: 16 }, add: { type: 'array', items: ITEM, maxItems: 8 },
      exclude: { type: 'array', items: IMG, maxItems: 16 }, reset: { type: 'boolean' } }, additionalProperties: false },
    run: async (env, a0) => {
      const a = await withPage(env, a0);
      const t = target(a), svc = sentImagesOf(env.ctx);
      let input: SentInput | null = null;
      if (a.reset !== true) {
        const list = a.list === undefined ? undefined : SentImageInSchema.array().max(16).safeParse(a.list);
        const add = a.add === undefined ? undefined : SentImageInSchema.array().max(8).safeParse(a.add);
        const exclude = a.exclude === undefined ? undefined : ImageInSchema.array().max(16).safeParse(a.exclude);
        for (const [k, p] of [['list', list], ['add', add], ['exclude', exclude]] as const) if (p && !p.success) throw badRequest(`${k}: ${p.error.issues[0]?.path.join('.')} ${p.error.issues[0]?.message}`);
        if (!list && !add?.data?.length && !exclude?.data?.length) throw badRequest('Give list, add or exclude (or reset: true)');
        input = list ? { sentImages: list.data!, sentImagesBy: 'claude' } : { addImages: add?.data ?? [], excludeImages: exclude?.data ?? [], sentImagesBy: 'claude' };
        await svc.resolve(env.user.studioId, input, 'claude'); // every image checked (this studio's) before it is kept
      }
      const prev = await current(env, a);
      const scope = t.page === 'suite' ? '' : `${SCOPE[t.page as Exclude<SentPage, 'photo'>]}:${t.modelId}`;
      const kept = scope ? svc.storedFor(env.user, scope) : null;
      if (t.page === 'suite') await assistOf(env.ctx).setSent(env.user, t.assistId!, input);
      else svc.store(env.user, scope, input);
      const now = await current(env, a);
      if (now.error && input) { // e.g. over the model's limit: undo, say why
        if (t.page === 'suite') await assistOf(env.ctx).setSent(env.user, t.assistId!, sentOfPrev(prev));
        else svc.store(env.user, scope, kept);
        throw badRequest(now.error);
      }
      return { ...now, message: input ? 'Changed. Tell the person what you changed and why.' : 'Back to MUSE\'s own pick.' };
    },
  },
];
/** The choice before a refused change (the Suite's draft keeps the previous one). */
function sentOfPrev(prev: { sentImages: SentView | null }): SentInput | null {
  const v = prev.sentImages;
  return v?.changed ? { sentImages: v.images.map(x => ({ image: x.image as { url?: string; asset?: string }, role: x.role, label: x.label })), sentImagesBy: v.changedBy ?? 'claude' } : null;
}
