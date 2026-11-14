// One Claude (plans/one-claude.md): ONE tool list for every chat, from the AI Suite, Edit and Recreate tool sets plus the
// chat tools. Each tool says where it is meant to be used (pages), whether it needs the person's go-ahead (gate), and
// whether members may use it (members: what members can already do in the app; never providers, keys, prices or
// studio defaults). The list sent to Claude is the same on every page (prompt caching); the page fills ids in.
import type { AuthUser } from '../ctx.js';
import { EDIT_TOOLS, type EditTool } from '../editor/mcpTools.js';
import { RECREATE_TOOLS } from '../recreate/mcpTools.js';
import { SUITE_TOOLS } from '../suite/mcpTools.js';
import { CHAT_TOOLS } from './chatTools.js';
import { WATCH_TOOLS } from './watch.js';
import { LISTEN_TOOLS } from './listen.js';
import { SONG_TOOLS } from './songNotes.js';
import { SYNC_MAP_TOOLS } from './syncMap.js';
import { SYNC_TOOLS } from '../editor/syncHits.js';
import { ISSUE_TOOLS } from './issues.js';
import { TEMPLATE_PACK_TOOLS } from '../editor/templatePacks.js';
import { CARD_TOOLS } from './cards.js';
import { APP_TOOLS } from './appTools.js';
import { ACTION_TOOLS, SETTINGS_TOOLS } from './actions.js';
import { SENT_TOOLS } from './sentTools.js';
import { UI_TOOLS } from './uiControl.js';
import { PAGE_IDS, type PageName, type PageRef } from './page.js';

/** What a gated tool would do. Gated tools never act on Claude's word: without confirm they give the price or summary;
 * with confirm: true they put an approval in the app, and nothing happens until the person presses it. */
export type Gate = 'none' | 'spend' | 'delete' | 'post' | 'settings';
export type ChatTool = EditTool & { pages: (PageName | 'any')[]; gate: Gate; members: boolean };

/** Every tool that spends money (the price is shown on the person's button). Delete/post/settings: none yet. */
export const GATES: Record<string, Gate> = {
  suite_request_shot: 'spend', fill_slot: 'spend', auto_captions: 'spend', cut_fillers: 'spend', remove_background: 'spend', denoise: 'spend', find_layers: 'spend',
};
/** Recreate tools a member can't use: they act on edit sessions or the editing playbook, which are the owner's. */
const OWNER_ONLY = new Set(['apply_recipe', 'replace_slot', 'playbook_read', 'playbook_add', 'report_gap',
  // Full control: owner-only screens (archive, camera).
  'character_archive', 'camera_session_delete', 'warm_gpu', 'warm_gpu_on', 'camera_sessions_list']);

const tag = (tools: EditTool[], pages: ChatTool['pages'], members: (t: EditTool) => boolean): ChatTool[] =>
  tools.map(t => ({ ...t, pages, gate: GATES[t.name] ?? (t as { gate?: Gate }).gate ?? 'none', members: members(t) }));

export const CHAT_REGISTRY: ChatTool[] = [
  ...tag(CHAT_TOOLS, ['any'], () => true),
  // Claude watches videos (plans/claude-video-vision.md Stage 1): free, studio-scoped, on every page.
  ...tag(WATCH_TOOLS, ['any'], () => true),
  ...tag(LISTEN_TOOLS, ['any'], () => true),
  // Editing to individual notes (claude/songNotes.ts): song_notes and find_impacts are free reads, everyone, own studio.
  ...tag(SONG_TOOLS, ['any'], () => true),
  ...tag(SYNC_MAP_TOOLS, ['any'], () => true),
  // Claude reports what stopped it (claude/issues.ts): everyone, every page, free.
  ...tag(ISSUE_TOOLS, ['any'], () => true),
  // Template pack intake (editor/templatePacks.ts, plans/edit-templates.md §1): the owner's, free.
  ...tag(TEMPLATE_PACK_TOOLS, ['any'], () => false),
  // Chat cards (claude/cards.ts): a plan checklist and a clip's key moments, drawn as cards in the person's panel; free.
  ...tag(CARD_TOOLS, ['any'], () => true),
  // Full control B1 (claude/appTools.ts): the screens' free read/organise actions, as the person (routes decide what members may do).
  ...tag(APP_TOOLS, ['any'], t => !OWNER_ONLY.has(t.name)),
  // Full control B2 (claude/actions.ts): spend/delete/post actions behind the person's Approve card.
  ...tag(ACTION_TOOLS, ['any'], t => !OWNER_ONLY.has(t.name)),
  // Studio settings (never keys, providers or prices): the owner's, behind her go-ahead to change.
  ...tag(SETTINGS_TOOLS, ['any', 'settings'], () => false),
  // The MUSE window itself (claude/uiControl.ts): a fallback when no tool covers it; everyone, their own app only.
  ...tag(UI_TOOLS, ['any'], () => true),
  // Images sent (images/sent.ts): see and change what a generation sends; free, own studio, everyone.
  ...tag(SENT_TOOLS, ['suite', 'character', 'cast'], () => true),
  ...tag(SUITE_TOOLS, ['suite'], () => true),
  // Editing with Claude is the owner's (editor/sessions.ts owner()).
  ...tag(EDIT_TOOLS, ['edit', 'recreate'], () => false),
  ...tag(SYNC_TOOLS, ['edit', 'recreate'], () => false),
  ...tag(RECREATE_TOOLS, ['recreate'], t => !OWNER_ONLY.has(t.name)),
];
export const registryByName = new Map(CHAT_REGISTRY.map(t => [t.name, t]));

/** The tools a person's chat has: the owner every one, a member only those members may use. */
export const toolsForUser = (u: Pick<AuthUser, 'role'>) => CHAT_REGISTRY.filter(t => u.role === 'owner' || t.members);

/** Arguments the page or the chat fills in when Claude leaves them out (Claude may still name another item). */
export const BOUND = ['chatId', ...PAGE_IDS] as const;

/** Claude's view of a tool: the bound ids are optional (filled in), everything else as the tool says. */
export function claudeSchema(t: EditTool) {
  const s = t.inputSchema as { properties?: Record<string, unknown>; required?: string[] };
  const props = { ...(s.properties ?? {}) };
  delete props.chatId;
  return { ...s, properties: props, required: (s.required ?? []).filter(r => !(BOUND as readonly string[]).includes(r)) };
}

/** Fills the chat's id and the page's open ids into a call, and says plainly when a page tool has nothing to act on. */
export function bindArgs(t: EditTool, input: Record<string, unknown>, chatId: string, page: PageRef | undefined): Record<string, unknown> | { missing: string } {
  const props = (t.inputSchema as { properties?: Record<string, unknown>; required?: string[] }).properties ?? {};
  const out = { ...input };
  if ('chatId' in props) out.chatId = chatId; // always this chat: a chat can't act as another
  for (const k of PAGE_IDS) if (k in props && (out[k] === undefined || out[k] === '') && page?.ids?.[k]) out[k] = page.ids[k];
  const req = (t.inputSchema as { required?: string[] }).required ?? [];
  const missing = req.find(k => (PAGE_IDS as readonly string[]).includes(k) && (out[k] === undefined || out[k] === ''));
  return missing ? { missing } : out;
}

/** The plain message when nothing on the page fills a needed id. */
export function missingHint(name: string, key: string) {
  const where: Record<string, string> = { assistId: 'the AI Suite (open_page {page:"suite"})', sessionId: 'an edit (open_edit on a take, or open_page {page:"edit", id})',
    referenceId: 'a Recreate reference (open_page {page:"recreate", id})', takeId: 'a take', modelId: 'a character', cameraSessionId: 'a camera session' };
  return `${name} needs ${key}: nothing like that is open on this page. Open ${where[key] ?? 'the right page'} or pass ${key}.`;
}
