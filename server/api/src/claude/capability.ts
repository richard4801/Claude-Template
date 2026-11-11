// A chat hears about abilities shipped since its last turn (owner, 2026-11-11: old chats kept saying "I can't upload…").
// Each chat stores the tools it last saw (name → short hash of description + schema: claude_threads.tools_seen, 0033).
// On its next turn (the in-app turn's facts, a phone turn the Mac claims, or the first MCP tool result that names the
// chat) a changed list adds one note: what is new or changed, and "check your tools again". The MCP server is stateless
// HTTP with no server-to-client stream, so it can't push tools/list_changed; Claude Code reads tools/list per process.
import { createHash } from 'node:crypto';
import { and, eq } from 'drizzle-orm';
import type { AuthUser, Ctx } from '../ctx.js';
import { claudeMessages, claudeThreads } from '../camera/schema.js';
import { MUSE_TOOLS } from '../mcp/tools.js';
import { registryByName, toolsForUser } from './registry.js';

type Tool = { name: string; title?: string; description: string; inputSchema: unknown };
const short = (t: Tool) => createHash('sha256').update(`${t.description}\n${JSON.stringify(t.inputSchema)}`).digest('hex').slice(0, 10);

/** The tools this person can use (the chat registry, plus the owner's MCP-only tools), name → hash. */
export function toolHashes(u: Pick<AuthUser, 'role'>): Record<string, string> {
  const tools: Tool[] = [...toolsForUser(u), ...(u.role === 'owner' ? MUSE_TOOLS.filter(t => !registryByName.has(t.name)) : [])];
  return Object.fromEntries(tools.map(t => [t.name, short(t)]).sort(([a], [b]) => a!.localeCompare(b!)));
}
export const capabilityVersion = (u: Pick<AuthUser, 'role'>) => createHash('sha256').update(JSON.stringify(toolHashes(u))).digest('hex').slice(0, 12);

const MAX_LINES = 40;
const titleOf = (name: string) => (registryByName.get(name) ?? MUSE_TOOLS.find(t => t.name === name))?.title ?? '';

/** The note for this chat's turn when MUSE changed since its last one (and remembers the new list), else null. A chat
 * that never had a reply just records the list. Never throws (a turn must not fail over this). */
export async function capabilityNote(ctx: Ctx, u: AuthUser, threadId: string): Promise<string | null> {
  try {
    const [t] = await ctx.db.select({ id: claudeThreads.id, seen: claudeThreads.toolsSeen }).from(claudeThreads)
      .where(and(eq(claudeThreads.id, threadId), eq(claudeThreads.ownerId, u.id)));
    if (!t) return null;
    const now = toolHashes(u), seen = t.seen ?? null;
    const fresh = Object.keys(now).filter(n => !seen || !(n in seen));
    const changed = seen ? Object.keys(now).filter(n => n in seen && seen[n] !== now[n]) : [];
    if (seen && !fresh.length && !changed.length) return null;
    await ctx.db.update(claudeThreads).set({ toolsSeen: now }).where(eq(claudeThreads.id, t.id));
    const [replied] = await ctx.db.select({ id: claudeMessages.id }).from(claudeMessages).where(and(eq(claudeMessages.threadId, t.id), eq(claudeMessages.role, 'assistant'))).limit(1);
    if (!replied) return null; // nothing said yet in this chat that could be out of date
    const lines = seen ? [...fresh.map(n => `- new: ${n}${titleOf(n) ? ` (${titleOf(n)})` : ''}`), ...changed.map(n => `- changed: ${n}${titleOf(n) ? ` (${titleOf(n)})` : ''}`)] : [];
    const list = lines.length > MAX_LINES ? [...lines.slice(0, MAX_LINES), `- …and ${lines.length - MAX_LINES} more`] : lines;
    return `[MUSE was updated since this chat's last turn.${list.length ? ` New or changed tools:\n${list.join('\n')}\n` : ' '}Anything you said earlier in this chat that you couldn't do may now be possible: check your current tools again before answering, and don't repeat an earlier "I can't".]`;
  } catch (e) {
    ctx.log.warn({ err: (e as Error).message }, 'capability note failed');
    return null;
  }
}
