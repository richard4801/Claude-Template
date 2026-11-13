// Live suggestion chips (owner request 2026-11-12): the three chips over Claude's chat input follow what is on screen
// now and what just happened, instead of a fixed list per page. Free, fast and deterministic: rules over facts the
// server already holds (the open edit, the Suite draft, the person's last job, the chat's last reply) plus a few the app
// reports (the timeline selection, the platform view, unsaved changes, a clip just imported). No model call.
//
// Every chip names the tools it leads to; a chip whose tools this person's chat doesn't have (a member on Edit) is never
// shown, so a chip can't promise something impossible on that screen. Order is stable: the three chips with the highest
// priority are picked, then shown in the catalog's fixed order (an app keeps chips that stay in their old places).
import { and, desc, eq, isNull, ne } from 'drizzle-orm';
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { parse } from '../camera/validate.js';
import type { AuthUser, Ctx } from '../ctx.js';
import { jobs } from '../db/schema.js';
import { claudeMessages, claudeThreads } from '../camera/schema.js';
import { editorJobs, editSessions } from '../editor/schema.js';
import type * as M from '../editor/model.js';
import { suiteAssists } from '../suite/schema.js';
import { chipsFor, type Chip } from './cards.js';
import { PAGES, type PageName } from './page.js';
import { CHAT_REGISTRY } from './registry.js';

/** A live chip: what the app shows (label ≤ 4 words, verb first; Phosphor icon), what it sends, and why it's there. */
export type LiveChip = Chip & { id: string; tools: string[]; why: string };

/** Platform views (the Mac's EditSuite.SafeArea insets as canvas fractions: left, top, right, bottom). */
/**
 * Platform preview views (the apps' PreviewSkin raw values). The safe boxes (left, top, right, bottom as canvas fractions)
 * are the Mac's defaults (PreviewLayouts); the server only uses them when the app didn't send `offSafe` itself. YouTube
 * (desktop) has no box; Clean is no view.
 */
export const SAFE_VIEWS = ['tiktok', 'reels', 'shorts', 'facebook', 'youtube'] as const;
export type SafeView = (typeof SAFE_VIEWS)[number];
export const SAFE_AREAS: Partial<Record<SafeView, readonly [number, number, number, number]>> = {
  tiktok: [0.03, 0.11, 0.17, 0.29], reels: [0.03, 0.1, 0.16, 0.3], shorts: [0.03, 0.09, 0.17, 0.3], facebook: [0.03, 0.1, 0.16, 0.28] };
const VIEW_NAMES: Record<SafeView, string> = { tiktok: 'TikTok', reels: 'Reels', shorts: 'Shorts', facebook: 'Facebook', youtube: 'YouTube' };

/** What the rules read. All optional: a fact nobody knows is simply not there. */
export type Facts = {
  page?: PageName;
  tool?: string;
  /** The tools this person's chat has (owner: all; member: the members' ones). */
  can: (tool: string) => boolean;
  edit?: EditFacts;
  suite?: SuiteFacts;
  /** The person's latest job (a shot, a swap, an edit helper), if it ended or started lately. */
  job?: JobFacts;
  /** Claude's last reply in this chat (follow-ups). */
  reply?: string;
  /** The app's own: what is selected, the platform view, unsaved, a clip just imported. */
  app?: AppFacts;
};
export type EditFacts = { sessionId: string; mainClips: number; overlayClips: number; hasCaptions: boolean; captionWords: number;
  musicId?: string; beatsMarked: boolean; texts: { id: string; x: number; y: number }[]; durationSec: number; blank: boolean };
export type SuiteFacts = { tool?: string; promptEmpty: boolean; hasCharacter: boolean; rigSet: boolean; hasClip: boolean; hasOutfit: boolean };
export type JobFacts = { id: string; title: string; state: 'running' | 'done' | 'failed'; agoSec: number; video: boolean; editor: boolean; error?: string };
export type AppFacts = { selKind?: 'video' | 'audio' | 'text' | 'image' | 'caption'; selId?: string; view?: SafeView; unsaved?: boolean;
  /** Text ids the app sees outside the platform view's safe area (it knows the live project; the server's copy can lag). */
  offSafe?: string[];
  overlap?: boolean; imported?: 'video' | 'image' | 'audio'; importedId?: string };

// ------------------------------------------------------------------ facts from what the server holds (pure)

const num = (v: unknown, d: number) => (typeof v === 'number' && Number.isFinite(v) ? v : d);

/** The open edit, as the rules need it. */
export function editFacts(sessionId: string, p: M.EditProject): EditFacts {
  let mainClips = 0, overlayClips = 0, captionWords = 0, hasCaptions = false, musicId: string | undefined, beatsMarked = false, end = 0;
  const texts: EditFacts['texts'] = [];
  for (const t of p.tracks ?? []) {
    if (t.kind === 'caption' && t.caption && t.caption.words.length) { hasCaptions = true; captionWords += t.caption.words.length; }
    for (const it of t.items ?? []) {
      const i = it as unknown as Record<string, unknown>;
      const start = num(i.startSec, 0), len = typeof i.durationSec === 'number' ? i.durationSec : (num(i.outSec, 0) - num(i.inSec, 0)) / num(i.speed, 1);
      end = Math.max(end, start + Math.max(0, len));
      if (t.kind === 'main') mainClips++;
      else if (t.kind === 'video' || t.kind === 'image') overlayClips++;
      else if (t.kind === 'music' && !musicId) { musicId = String(i.id); beatsMarked = Array.isArray(i.strongBeats) && i.strongBeats.length > 0; }
      else if (t.kind === 'text' && typeof i.text === 'string' && !(i as { pin?: unknown }).pin) {
        const tr = (i.transform ?? {}) as { x?: number; y?: number };
        texts.push({ id: String(i.id), x: num(tr.x, 0.5), y: num(tr.y, 0.5) });
      }
    }
  }
  return { sessionId, mainClips, overlayClips, hasCaptions, captionWords, ...(musicId ? { musicId } : {}), beatsMarked, texts, durationSec: end,
    blank: p.sourceTakeId === 'blank' && mainClips === 0 };
}

const safeHint = (v: SafeView) => { const b = SAFE_AREAS[v]; return b ? ` (keep it at least ${Math.round(b[1] * 100)}% from the top and ${Math.round(b[3] * 100)}% from the bottom)` : ''; };

/** Text whose centre sits outside the platform's safe area (under its buttons or captions); none for a view without a box. */
export function outsideSafe(texts: EditFacts['texts'], view: SafeView): string[] {
  const box = SAFE_AREAS[view];
  if (!box) return [];
  const [l, t, r, b] = box;
  return texts.filter(x => x.x < l || x.x > 1 - r || x.y < t || x.y > 1 - b).map(x => x.id);
}

type Tok = { t?: string; kind?: string; text?: string };
/** The Suite composer's shared draft, as the rules need it (the screen's clip and pictures included). */
export function suiteFacts(d: Record<string, unknown>): SuiteFacts {
  const toks = (Array.isArray(d.tokens) ? d.tokens : []) as Tok[];
  const text = toks.filter(x => x.t === 'text').map(x => x.text ?? '').join(' ').trim();
  const screen = (d.screen ?? {}) as { request?: Record<string, unknown>; inputs?: { kind?: string }[] };
  const req = screen.request ?? {};
  const rig = (d.rig ?? {}) as Record<string, unknown>;
  const hasCharacter = toks.some(x => x.t === 'mention') || typeof req.modelId === 'string' || typeof d.modelId === 'string';
  const hasClip = typeof d.clipId === 'string' || typeof req.clipId === 'string' || !!req.extend || (screen.inputs ?? []).some(i => i?.kind === 'video');
  return { ...(typeof d.tool === 'string' ? { tool: d.tool } : {}), promptEmpty: !text, hasCharacter, rigSet: Object.values(rig).some(v => v !== undefined && v !== null),
    hasClip, hasOutfit: typeof d.outfitId === 'string' || typeof req.outfitId === 'string' };
}

// ------------------------------------------------------------------ the rules

type Rule = { id: string; label: string; icon: string; tools: string[]; prio: number; prompt: string; why: string };
const LIVE_SEC = 15 * 60;
const quote = (s: string) => `“${s.replace(/\s+/g, ' ').trim().slice(0, 60)}”`;

/**
 * The catalog's order is the order chips are shown in (stable: a chip keeps its place while it stays), so it runs from
 * "what just happened" to "the page's own" ones. Each rule here returns a chip when its facts hold.
 */
function candidates(f: Facts): Rule[] {
  const out: Rule[] = [];
  const add = (r: Rule) => out.push(r);
  const j = f.job, e = f.edit, s = f.suite, a = f.app ?? {};

  // --- what just happened: a job ended, a clip came in, Claude asked something
  if (j && j.state === 'failed' && j.agoSec < LIVE_SEC) {
    add({ id: 'job.why', label: 'Why did it fail?', icon: 'warning', tools: ['queue_list'], prio: 100, why: 'last job failed',
      prompt: `My job ${quote(j.title)} (${j.id}) failed. Read why (queue_list) and tell me in plain words what went wrong and what to change. Don't run anything again yet.` });
    if (j.video && !j.editor) add({ id: 'job.retry', label: 'Run it again', icon: 'arrow-clockwise', tools: ['job_retry'], prio: 70, why: 'last job failed',
      prompt: `Run my failed job ${quote(j.title)} (${j.id}) again with the same settings (job_retry). Tell me the price before it starts.` });
  }
  if (j && j.state === 'done' && j.agoSec < LIVE_SEC && j.video && !j.editor)
    add({ id: 'job.watch', label: 'Watch the new take', icon: 'play-circle', tools: ['watch'], prio: 80, why: 'a job just finished',
      prompt: `Watch my new take ${quote(j.title)} from job ${j.id} (watch) and tell me what works and what to fix.` });
  if (f.page === 'edit' && a.imported === 'video')
    add({ id: 'edit.watchNew', label: 'Watch the new clip', icon: 'play-circle', tools: ['watch', 'get_edit'], prio: 85, why: 'a clip was just imported',
      prompt: `Watch the clip I just imported${a.importedId ? ` (${a.importedId})` : ''} (watch) and tell me its best moments for this edit.` });
  if (f.page === 'edit' && a.imported === 'audio')
    add({ id: 'edit.listenNew', label: 'Listen to the track', icon: 'music-notes', tools: ['listen'], prio: 84, why: 'a sound was just imported',
      prompt: `Listen to the sound I just imported${a.importedId ? ` (${a.importedId})` : ''} (listen) and tell me where its beat and drop are.` });
  const reply = (f.reply ?? '').trim();
  if (reply && /\?\s*$/.test(reply.split('\n').filter(Boolean).pop() ?? ''))
    add({ id: 'reply.yes', label: 'Yes, go ahead', icon: 'check', tools: [], prio: 78, why: 'Claude asked a question', prompt: 'Yes, go ahead.' });
  if (reply && /(^|\n)\s*(1[.)]|option 1|a\))/i.test(reply) && /(^|\n)\s*(2[.)]|option 2|b\))/i.test(reply))
    add({ id: 'reply.first', label: 'Go with option 1', icon: 'check', tools: [], prio: 74, why: 'Claude offered options', prompt: 'Go with option 1.' });

  // --- the open edit
  if (f.page === 'edit' && e) {
    if (a.overlap) add({ id: 'edit.overlap', label: 'Fix the overlap', icon: 'warning', tools: ['get_edit', 'apply_edit_ops'], prio: 95, why: 'clips overlap',
      prompt: 'Some clips on my timeline overlap. Find them (get_edit) and fix them so nothing overlaps (apply_edit_ops). Tell me what you moved.' });
    const off = a.view ? (a.offSafe ?? outsideSafe(e.texts, a.view)) : [];
    if (a.view && off.length) add({ id: 'edit.safe', label: 'Fix the safe area', icon: 'frame-corners', tools: ['get_edit', 'apply_edit_ops'], prio: 90,
      why: `${off.length} text outside the ${VIEW_NAMES[a.view]} safe area`,
      prompt: `In the ${VIEW_NAMES[a.view]} view, my text ${off.slice(0, 6).join(', ')} sits outside the safe area (under the app's buttons). Move it inside the safe area${safeHint(a.view)} with apply_edit_ops, keeping its look.` });
    if (a.selId && (a.selKind === 'video' || a.selKind === 'image'))
      add({ id: 'edit.trimSel', label: 'Trim this clip', icon: 'scissors', tools: ['watch', 'apply_edit_ops'], prio: 76, why: 'a clip is selected',
        prompt: `Watch the selected clip ${a.selId} and trim it to its strongest part (apply_edit_ops). Tell me what you cut.` });
    if (a.selId && a.selKind === 'audio' && a.selId === e.musicId && !e.beatsMarked)
      add({ id: 'edit.beatsSel', label: 'Find the beats', icon: 'metronome', tools: ['detect_beats'], prio: 76, why: 'the music is selected',
        prompt: `Find the beats in the selected music ${a.selId} (detect_beats) and mark them on the timeline.` });
    if (a.selId && a.selKind === 'text')
      add({ id: 'edit.styleSel', label: 'Restyle this text', icon: 'text-t', tools: ['get_edit', 'apply_edit_ops'], prio: 75, why: 'a text is selected',
        prompt: `Restyle the selected text ${a.selId} so it reads well and fits my edit's look (apply_edit_ops). Tell me what you changed.` });
    if (e.blank) {
      add({ id: 'edit.findTakes', label: 'Find takes to use', icon: 'magnifying-glass', tools: ['library_find'], prio: 60, why: 'the edit is empty',
        prompt: 'This edit is empty. Find takes in my library that would work for it (library_find) and suggest which to add.' });
    } else {
      if (!e.hasCaptions && e.mainClips > 0) add({ id: 'edit.captions', label: 'Add captions', icon: 'text-aa', tools: ['auto_captions'], prio: 62, why: 'no captions yet',
        prompt: 'Add captions to this edit (auto_captions). Tell me the price first if it isn\'t free.' });
      if (e.hasCaptions) add({ id: 'edit.captionStyle', label: 'Restyle the captions', icon: 'text-aa', tools: ['list_caption_styles', 'apply_edit_ops'], prio: 35, why: 'captions are on',
        prompt: 'Pick a caption style that fits this edit (list_caption_styles) and apply it (apply_edit_ops). Tell me which one and why.' });
      if (e.musicId && !e.beatsMarked) add({ id: 'edit.beat', label: 'Cut to the beat', icon: 'scissors', tools: ['detect_beats', 'apply_edit_ops'], prio: 58, why: 'music without beats',
        prompt: `Find the beats in my music ${e.musicId} (detect_beats) and cut the clips to them (apply_edit_ops).` });
      if (e.musicId && e.beatsMarked) add({ id: 'edit.drop', label: 'Cut to the drop', icon: 'lightning', tools: ['find_action_peaks', 'apply_edit_ops'], prio: 58, why: 'music with beats marked',
        prompt: `Cut my edit so its biggest moment lands on the drop: use the strong beats marked on ${e.musicId} and the action peaks (find_action_peaks), then apply_edit_ops.` });
      if (!e.musicId && e.mainClips > 0 && !e.hasCaptions) add({ id: 'edit.silences', label: 'Cut the silences', icon: 'waveform', tools: ['cut_silences'], prio: 40, why: 'no music, no captions',
        prompt: 'Cut the quiet parts out of my main video (cut_silences, free). Tell me how much shorter it is.' });
      add({ id: 'edit.watch', label: 'Watch my edit', icon: 'play-circle', tools: ['watch'], prio: 30, why: 'the edit',
        prompt: 'Watch my edit and tell me what to fix.' });
    }
    if (a.unsaved) add({ id: 'edit.save', label: 'Save a version', icon: 'archive', tools: ['save_version'], prio: 45, why: 'unsaved changes',
      prompt: 'Save a version of this edit (save_version).' });
  }

  // --- the Suite composer
  if (f.page === 'suite' && s) {
    const tool = f.tool ?? s.tool ?? 'shot';
    const clipTool = ['swap', 'remix', 'recast', 'extend'].includes(tool);
    if (clipTool && s.hasClip) add({ id: 'suite.watchClip', label: 'Watch my clip', icon: 'play-circle', tools: ['watch'], prio: 66, why: 'a clip is in',
      prompt: 'Watch my clip and tell me the key moments.' });
    if (clipTool && !s.hasClip) add({ id: 'suite.findClip', label: 'Find a clip', icon: 'magnifying-glass', tools: ['library_find'], prio: 64, why: 'no clip yet',
      prompt: 'Find a clip in my library that would work here (library_find) and tell me which.' });
    if (!s.hasCharacter && tool !== 'extend') add({ id: 'suite.cast', label: 'Pick a character', icon: 'user', tools: ['suite_cast', 'suite_set_draft'], prio: 56, why: 'no character',
      prompt: 'Help me pick the character for this (suite_cast), then put her in the composer (suite_set_draft).' });
    if (s.promptEmpty) add({ id: 'suite.write', label: 'Write the prompt', icon: 'pencil-simple', tools: ['suite_set_draft'], prio: 60, why: 'empty prompt',
      prompt: tool === 'photo' ? 'Write the prompt for these photos.' : 'Write the prompt for this shot.' });
    if (!s.promptEmpty && !s.rigSet && tool !== 'photo' && !clipTool) add({ id: 'suite.fill', label: 'Build from my idea', icon: 'sliders-horizontal', tools: ['suite_options', 'suite_set_draft'], prio: 70, why: 'idea written, rig empty',
      prompt: 'Fill in the composer from my idea in the prompt: the character, the prompt and every Setup row, using only options the composer offers (suite_options, then suite_set_draft). Then tell me in a few lines what you set.' });
    if (s.rigSet && tool !== 'photo') add({ id: 'suite.cinematic', label: 'Make it more cinematic', icon: 'aperture', tools: ['suite_set_draft'], prio: 42, why: 'the rig is set',
      prompt: 'Make this shot more cinematic: change the camera, light, look and style rows with suite_set_draft. Keep my prompt and character. Tell me briefly what you changed.' });
    if (tool === 'photo' && s.hasOutfit) add({ id: 'suite.outfit', label: 'Look at the outfit', icon: 'eye', tools: ['suite_see'], prio: 44, why: 'an outfit is picked',
      prompt: 'Look at the outfit and describe it.' });
    if (!s.promptEmpty && s.hasCharacter) add({ id: 'suite.price', label: 'Check the price', icon: 'coins', tools: ['suite_estimate'], prio: 38, why: 'ready to price',
      prompt: 'What will this cost, line by line?' });
    add({ id: 'suite.explain', label: 'Explain the settings', icon: 'info', tools: ['suite_get_draft'], prio: 20, why: 'the composer',
      prompt: 'Explain the settings in the composer now, row by row, in plain words. Don\'t change anything.' });
  }

  // --- the queue: what is running or failed now
  if (f.page === 'queue' && j?.state === 'running') add({ id: 'queue.running', label: 'What’s running', icon: 'stack', tools: ['queue_list'], prio: 50, why: 'a job runs',
    prompt: 'What is running right now?' });
  if (f.page === 'queue' && j?.state === 'failed') add({ id: 'queue.clear', label: 'Clear failed jobs', icon: 'x', tools: ['queue_clear_failed'], prio: 40, why: 'a job failed',
    prompt: 'Clear the failed jobs.' });
  return out;
}

/** The catalog order: ids in the order chips are shown (rules not listed come after, in rule order). */
const ORDER = ['job.why', 'job.watch', 'edit.watchNew', 'edit.listenNew', 'edit.overlap', 'edit.safe', 'reply.yes', 'reply.first', 'job.retry',
  'edit.trimSel', 'edit.beatsSel', 'edit.styleSel', 'edit.findTakes', 'edit.captions', 'edit.beat', 'edit.drop', 'edit.silences', 'edit.captionStyle', 'edit.save', 'edit.watch',
  'suite.watchClip', 'suite.findClip', 'suite.fill', 'suite.write', 'suite.cast', 'suite.cinematic', 'suite.outfit', 'suite.price', 'suite.explain',
  'queue.running', 'queue.clear'];

const words = (s: string) => s.trim().split(/\s+/).length;

/** The tools the page's fixed chips (cards.ts chipsFor) lead to. */
export const FILL_TOOLS: Record<string, string[]> = {
  'Watch my clip': ['watch'], 'Write the prompt': ['suite_set_draft'], 'Check the price': ['suite_estimate'], 'Look at the outfit': ['suite_see'], 'Set the rig': ['suite_set_draft'],
  'Watch my edit': ['watch'], 'Cut to the beat': ['detect_beats', 'apply_edit_ops'], 'Add captions': ['auto_captions'],
  'Watch this take': ['watch'], 'Make a variation': ['suite_set_draft'], 'Edit it': ['open_edit'],
  'Watch the reference': ['watch'], 'Plan the shots': ['set_slot_briefs'],
  'Look at her': ['see_photos'], 'New outfit': ['outfit_make'], 'Plan a shoot': ['show_plan'],
  'Find a take': ['library_find'], 'Sort my library': ['library_collect'], 'Best of today': ['list_takes'],
  'What’s running': ['queue_list'], 'Why it failed': ['queue_list'], 'Clear failed': ['queue_clear_failed'],
  'Block the shot': [], 'Render guides': [], 'What can you do': [], 'Start a shot': [],
};

/** The three chips for these facts: highest priority first picks, catalog order shows; the page's own chips fill up. */
export function suggest(f: Facts, n = 3): LiveChip[] {
  const ok = candidates(f).filter(r => r.tools.every(t => f.can(t)) && words(r.label) <= 4);
  const picked = [...ok].sort((x, y) => y.prio - x.prio).slice(0, n);
  const rank = (id: string) => { const i = ORDER.indexOf(id); return i < 0 ? ORDER.length : i; };
  const out: LiveChip[] = picked.sort((x, y) => rank(x.id) - rank(y.id)).map(r => ({ id: r.id, label: r.label, prompt: r.prompt, icon: r.icon, tools: r.tools, why: r.why }));
  // Fill from the page's own chips (the old fixed list), then the general ones, when the live facts give fewer than three:
  // the same tool check (a member on Edit never gets "Cut to the beat").
  // With live facts for the page (the edit, the draft) its fixed chips could contradict them ("Cut to the beat" with no
  // music): only the general ones fill then.
  const live = (f.page === 'edit' && f.edit) || (f.page === 'suite' && f.suite);
  for (const c of [...(live ? [] : chipsFor(f.page, f.tool)), ...chipsFor(undefined)]) {
    if (out.length >= n) break;
    const tools = FILL_TOOLS[c.label] ?? [];
    if (!tools.every(t => f.can(t)) || out.some(o => o.label === c.label || o.prompt === c.prompt)) continue;
    out.push({ ...c, id: `page.${c.label.toLowerCase().replace(/[^a-z]+/g, '-').replace(/^-|-$/g, '')}`, tools, why: 'the page' });
  }
  return out;
}

// ------------------------------------------------------------------ gathering the facts (the route)

const ID = z.string().regex(/^[A-Za-z0-9_-]{1,80}$/);
export const SuggestQuery = z.object({
  page: z.enum(PAGES).optional(), tool: z.string().regex(/^[a-z]{1,20}$/).optional(),
  sessionId: ID.optional(), assistId: ID.optional(), takeId: ID.optional(), referenceId: ID.optional(), chatId: ID.optional(),
  selKind: z.enum(['video', 'audio', 'text', 'image', 'caption']).optional(), selId: ID.optional(),
  // The apps' preview skins; clean / off = no platform view.
  view: z.enum([...SAFE_VIEWS, 'clean', 'off']).optional(),
  unsaved: z.enum(['0', '1']).optional(), overlap: z.enum(['0', '1']).optional(),
  imported: z.enum(['video', 'image', 'audio']).optional(), importedId: ID.optional(),
  // The open edit as the app sees it now (it wins over the server's copy, which can lag; a member's edit has none).
  clips: z.coerce.number().int().min(0).max(9999).optional(), captions: z.enum(['0', '1']).optional(), musicId: ID.optional(),
  beats: z.enum(['0', '1']).optional(), blank: z.enum(['0', '1']).optional(),
  offSafe: z.string().regex(/^[A-Za-z0-9_-]{1,80}(,[A-Za-z0-9_-]{1,80}){0,19}$/).optional(),
}).strict();

/** The app's own view of the open edit over the server's (or alone, when there is no shared session). */
export function withAppEdit(e: EditFacts | undefined, q: SuggestQuery): EditFacts | undefined {
  const any = q.clips !== undefined || q.captions !== undefined || q.musicId !== undefined || q.beats !== undefined || q.blank !== undefined;
  if (!any) return e;
  const b: EditFacts = e ?? { sessionId: q.sessionId ?? '', mainClips: 0, overlayClips: 0, hasCaptions: false, captionWords: 0, beatsMarked: false, texts: [], durationSec: 0, blank: false };
  const out: EditFacts = { ...b };
  if (q.clips !== undefined) out.mainClips = q.clips;
  if (q.captions !== undefined) out.hasCaptions = q.captions === '1';
  if (q.musicId !== undefined) out.musicId = q.musicId;
  else if (q.clips !== undefined && !e) delete out.musicId;
  if (q.beats !== undefined) out.beatsMarked = q.beats === '1';
  if (q.blank !== undefined) out.blank = q.blank === '1' && out.mainClips === 0;
  return out;
}
export type SuggestQuery = z.infer<typeof SuggestQuery>;

/** Reads the facts the server holds for this person (each read on its own: one missing never blocks the others). */
export async function gatherFacts(ctx: Ctx, u: AuthUser, q: SuggestQuery, now = Date.now()): Promise<Facts> {
  const mine = new Set(CHAT_REGISTRY.filter(t => u.role === 'owner' || t.members).map(t => t.name));
  const f: Facts = { ...(q.page ? { page: q.page } : {}), ...(q.tool ? { tool: q.tool } : {}), can: t => mine.has(t),
    app: { ...(q.selKind ? { selKind: q.selKind } : {}), ...(q.selId ? { selId: q.selId } : {}), ...(q.view && q.view !== 'off' && q.view !== 'clean' ? { view: q.view } : {}),
      unsaved: q.unsaved === '1', overlap: q.overlap === '1', ...(q.imported ? { imported: q.imported } : {}), ...(q.importedId ? { importedId: q.importedId } : {}),
      ...(q.offSafe ? { offSafe: q.offSafe.split(',') } : {}) } };
  const safe = async <T>(p: Promise<T>): Promise<T | undefined> => { try { return await p; } catch { return undefined; } };
  await Promise.all([
    (async () => {
      if (q.page !== 'edit' || !q.sessionId || u.role !== 'owner') return;
      const [s] = (await safe(ctx.db.select({ id: editSessions.id, project: editSessions.project }).from(editSessions)
        .where(and(eq(editSessions.id, q.sessionId), eq(editSessions.studioId, u.studioId))))) ?? [];
      if (s) f.edit = editFacts(s.id, s.project as unknown as M.EditProject);
    })(),
    (async () => {
      if (q.page !== 'suite' || !q.assistId) return;
      const [a] = (await safe(ctx.db.select({ draft: suiteAssists.draft }).from(suiteAssists)
        .where(and(eq(suiteAssists.id, q.assistId), eq(suiteAssists.studioId, u.studioId), eq(suiteAssists.userId, u.id))))) ?? [];
      if (a) f.suite = suiteFacts(a.draft);
    })(),
    (async () => {
      // The person's latest render job and (owner) editor job; the newer one wins.
      const [r] = (await safe(ctx.db.select({ id: jobs.id, title: jobs.title, state: jobs.state, kind: jobs.kind, request: jobs.request, error: jobs.error, createdAt: jobs.createdAt, finishedAt: jobs.finishedAt })
        .from(jobs).where(and(eq(jobs.studioId, u.studioId), eq(jobs.userId, u.id), isNull(jobs.hiddenAt))).orderBy(desc(jobs.createdAt)).limit(1))) ?? [];
      const [ej] = (await safe(ctx.db.select({ id: editorJobs.id, kind: editorJobs.kind, state: editorJobs.state, error: editorJobs.error, createdAt: editorJobs.createdAt, finishedAt: editorJobs.finishedAt })
        .from(editorJobs).where(and(eq(editorJobs.studioId, u.studioId), eq(editorJobs.userId, u.id))).orderBy(desc(editorJobs.createdAt)).limit(1))) ?? [];
      const at = (x?: { createdAt: number; finishedAt: number | null }) => (x ? x.finishedAt ?? x.createdAt : -1);
      if (r && at(r) >= at(ej)) {
        if (r.state === 'queued' || r.state === 'running' || r.state === 'done' || r.state === 'failed')
          f.job = { id: r.id, title: r.title, state: r.state === 'queued' ? 'running' : r.state, agoSec: Math.max(0, (now - at(r)) / 1000),
            video: r.kind === 'render' && !(r.request?.engine === 'photo' || r.request?.tool === 'photo'), editor: false, ...(r.error ? { error: r.error } : {}) };
      } else if (ej && ej.state !== 'cancelled') {
        f.job = { id: ej.id, title: ej.kind, state: ej.state, agoSec: Math.max(0, (now - at(ej)) / 1000), video: false, editor: true, ...(ej.error ? { error: ej.error } : {}) };
      }
    })(),
    (async () => {
      if (!q.chatId) return;
      const [t] = (await safe(ctx.db.select({ id: claudeThreads.id }).from(claudeThreads)
        .where(and(eq(claudeThreads.id, q.chatId), eq(claudeThreads.ownerId, u.id), eq(claudeThreads.studioId, u.studioId))))) ?? [];
      if (!t) return;
      const [m] = (await safe(ctx.db.select({ role: claudeMessages.role, text: claudeMessages.text }).from(claudeMessages)
        .where(and(eq(claudeMessages.threadId, t.id), ne(claudeMessages.role, 'tool'))).orderBy(desc(claudeMessages.createdAt)).limit(1))) ?? [];
      // Only when Claude spoke last (after the person's next message the follow-ups no longer fit).
      if (m?.role === 'assistant' && m.text) f.reply = m.text.slice(-1200);
    })(),
  ]);
  if (q.page === 'edit') { const e = withAppEdit(f.edit, q); if (e) f.edit = e; }
  return f;
}

/** A short key for the chip set (the apps skip redraws while it stays the same). */
export const chipsKey = (c: { id: string }[]) => c.map(x => x.id).join('|');

/**
 * GET /v1/claude/suggestions: the live chips for what is on screen now. The apps call it when the page or what is on it
 * changes (debounced ~1 s) and after each Claude reply; they keep their own fixed copy for when the server can't answer.
 */
export function registerSuggestionRoutes(app: FastifyInstance, ctx: Ctx) {
  app.get('/v1/claude/suggestions', async req => {
    const q = parse(SuggestQuery, req.query ?? {});
    const chips = suggest(await gatherFacts(ctx, req.user, q));
    return { chips: chips.map(c => ({ id: c.id, label: c.label, prompt: c.prompt, icon: c.icon, why: c.why })), key: chipsKey(chips) };
  });
}
