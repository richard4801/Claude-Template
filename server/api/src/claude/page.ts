// One Claude (plans/one-claude.md): the page the owner (or a member) is on, as the app reports it. Claude reads it each
// turn ("Sees: Edit, Beach reel") and its ids fill a tool's missing argument (the edit that is open, the shot being set up).
import { z } from 'zod';

export const PAGES = ['home', 'cast', 'character', 'suite', 'edit', 'recreate', 'library', 'take', 'queue', 'settings', 'memory', 'camera'] as const;
export type PageName = (typeof PAGES)[number];
/** The ids a page has open: they fill tools' arguments of the same name. */
export const PAGE_IDS = ['assistId', 'sessionId', 'referenceId', 'takeId', 'modelId', 'cameraSessionId'] as const;
export type PageIds = Partial<Record<(typeof PAGE_IDS)[number], string>>;
export type PageRef = { name: PageName; label?: string; sub?: string; tool?: string; ids?: PageIds; busy?: boolean };

const ID = z.string().regex(/^[A-Za-z0-9_-]{1,80}$/);
export const PageSchema = z.object({
  name: z.enum(PAGES), label: z.string().trim().max(120).optional(), sub: z.string().trim().max(60).optional(),
  tool: z.string().regex(/^[a-z]{1,20}$/).optional(),
  ids: z.object(Object.fromEntries(PAGE_IDS.map(k => [k, ID.optional()])) as Record<(typeof PAGE_IDS)[number], z.ZodOptional<typeof ID>>).strict().optional(),
  /** The person is in the middle of something here (typing, playing, a dialog): Claude asks before taking them away. */
  busy: z.boolean().optional(),
}).strict();

const NAMES: Record<PageName, string> = { home: 'Home', cast: 'Cast', character: 'Character', suite: 'AI Suite', edit: 'Edit', recreate: 'Recreate',
  library: 'Library', take: 'Take', queue: 'Queue', settings: 'Settings', memory: 'Claude\'s memory', camera: 'Camera' };

/** "Edit, Beach reel (rev 14)" — what the panel's "Sees:" line and Claude's facts say. */
export function pageLine(p: PageRef | null | undefined): string {
  if (!p) return 'no page reported';
  const tool = p.tool ? `, ${p.tool[0]!.toUpperCase()}${p.tool.slice(1)}` : '';
  return `${NAMES[p.name]}${tool}${p.label ? `, ${p.label}` : ''}${p.sub ? ` (${p.sub})` : ''}`;
}

/** An old per-place thread's page (0029 carries old chats over without moving data). */
export function pageOfContext(kind: string, contextId: string, contextKey?: string | null): PageRef | undefined {
  if (kind === 'suite') return { name: 'suite', tool: contextKey?.startsWith('suite:') ? contextKey.slice(6) : 'shot', ids: { assistId: contextId } };
  if (kind === 'edit') return { name: 'edit', ids: { sessionId: contextId } };
  if (kind === 'recreate') return contextId === 'start' ? { name: 'recreate' } : { name: 'recreate', ids: { referenceId: contextId } };
  if (kind === 'camera') return { name: 'camera', ids: { cameraSessionId: contextId } };
  return undefined;
}
