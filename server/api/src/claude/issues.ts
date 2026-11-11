// Claude reports its own issues (owner rule 2026-11-11: "it should report back autonomously when it faces an issue").
// Two ways in: Claude's own report (report_issue, for the owner and members) and tool errors captured on their own
// (MCP tools/call and the in-app turn). One row per (kind, normalised summary, page) per studio, with a count and when
// it was last seen. Only Claude's short summary is stored: no transcripts, and anything that looks like a secret is
// scrubbed first. The owner reads them (GET /v1/claude/issues) and marks them (POST /v1/claude/issues/:id).
import { createHash } from 'node:crypto';
import { and, desc, eq, gt, sql } from 'drizzle-orm';
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { AuthUser, Ctx } from '../ctx.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { compact, uid } from '../lib/util.js';
import { parse } from '../camera/validate.js';
import type { EditTool } from '../editor/mcpTools.js';
import { claudeIssues } from './schema.js';
import { ownChat, pageOf } from './chatTools.js';

export const ISSUE_KINDS = ['missing_tool', 'bug', 'blocked', 'confusing_ui'] as const;
export const SEVERITIES = ['low', 'medium', 'high'] as const;
export const STATUSES = ['new', 'triaged', 'fixed', 'wontfix'] as const;

/** Removes anything that looks like a credential: bearer tokens, key=value secrets, provider key shapes, JWTs, long
 * random strings, emails and signed-URL query strings. Then trims to max. */
export function scrub(s: unknown, max: number): string | null {
  if (typeof s !== 'string') return null;
  let t = s
    .replace(/\b(bearer|basic|token)\s+[A-Za-z0-9._~+/=-]{8,}/gi, '$1 [redacted]')
    .replace(/\b((?:api[_-]?)?key|secret|password|passwd|pwd|token|auth(?:orization)?|signature|credential)s?(["']?\s*[:=]\s*["']?)[^\s"'&,;]{4,}/gi, '$1$2[redacted]')
    .replace(/\b(?:sk|pk|rk|r8|fal|ghp|gho|github_pat|xox[abp]|AKIA|mt|pat)[-_][A-Za-z0-9_-]{8,}/g, '[redacted]')
    .replace(/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*/g, '[redacted]')
    .replace(/(https?:\/\/[^\s?#]+)\?[^\s#]*/g, '$1?[query removed]')
    .replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, '[email]')
    .replace(/\b(?=[A-Za-z0-9+/_-]*\d)(?=[A-Za-z0-9+/_-]*[A-Za-z])[A-Za-z0-9+/_-]{32,}={0,2}/g, '[redacted]')
    .replace(/\s+/g, ' ').trim();
  if (t.length > max) t = `${t.slice(0, max - 1)}…`;
  return t || null;
}

/** What makes two reports "the same": words only, ids and numbers dropped, so "es_ab12 failed at 3.2 s" = "es_cd34 failed at 5 s". */
export function normalise(s: string) {
  return s.toLowerCase().replace(/\b[a-z]{1,6}_[a-z0-9]{4,}\b/g, '#').replace(/[0-9]+(?:\.[0-9]+)?/g, '#').replace(/[^a-z#]+/g, ' ').trim().split(' ').slice(0, 24).join(' ');
}
const keyOf = (parts: string[]) => createHash('sha256').update(parts.join('|')).digest('hex').slice(0, 32);

type Input = { source: 'claude' | 'auto'; kind: string; severity: string; summary: string; asked?: string | null; page?: string | null;
  tried?: string | null; error?: string | null; tool?: string | null };

/** Stores a report, or counts it on the one already there (same kind, summary and page). A fixed or won't-fix report
 * that comes back is reopened as new. */
export async function recordIssue(ctx: Ctx, u: Pick<AuthUser, 'id' | 'studioId' | 'role'>, i: Input) {
  const now = Date.now();
  const page = i.page ? normalise(i.page).slice(0, 40) || null : null;
  const dedupeKey = keyOf([i.kind, i.source === 'auto' ? `${i.tool ?? ''}:${normalise(i.error ?? '')}` : normalise(i.summary), page ?? '']);
  const vals = { summary: i.summary, asked: i.asked ?? null, page, tried: i.tried ?? null, error: i.error ?? null, tool: i.tool ?? null,
    severity: i.severity, reporterId: u.id, reporterRole: u.role, lastSeen: now, updatedAt: now };
  const [row] = await ctx.db.insert(claudeIssues).values({ id: uid('ci'), studioId: u.studioId, dedupeKey, source: i.source, kind: i.kind, ...vals, firstSeen: now })
    .onConflictDoUpdate({ target: [claudeIssues.studioId, claudeIssues.dedupeKey], set: { ...vals, count: sql`${claudeIssues.count} + 1`,
      severity: sql`case when ${claudeIssues.severity} = 'high' or excluded.severity = 'high' then 'high' when ${claudeIssues.severity} = 'medium' or excluded.severity = 'medium' then 'medium' else 'low' end`,
      status: sql`case when ${claudeIssues.status} in ('fixed', 'wontfix') then 'new' else ${claudeIssues.status} end` } })
    .returning();
  return row!;
}

// Rate limits (in memory, per process): Claude's own reports per person, and captured errors per studio and per error.
const hits = new Map<string, number[]>();
function allow(key: string, n: number, windowMs: number) {
  const now = Date.now(), t = (hits.get(key) ?? []).filter(x => now - x < windowMs);
  if (t.length >= n) { hits.set(key, t); return false; }
  t.push(now); hits.set(key, t);
  if (hits.size > 5000) for (const [k, v] of hits) if (!v.length || now - v[v.length - 1]! > windowMs) hits.delete(k);
  return true;
}
/** Tests only. */
export const resetIssueLimits = () => hits.clear();

/** Auto-capture: a tool call that threw or returned an error, as kind=bug. Never throws, never blocks the turn.
 * A plain refusal the caller can fix (bad arguments, nothing open, no balance, a wrong scope) is low; a server error is high. */
export function captureToolError(ctx: Ctx, u: Pick<AuthUser, 'id' | 'studioId' | 'role'> | undefined, tool: string, e: unknown, where: 'mcp' | 'chat') {
  if (!u?.studioId || tool === 'report_issue') return;
  const api = e instanceof ApiError ? e : null;
  const code = api?.code ?? (typeof e === 'string' ? 'tool_error' : 'server_error');
  const msg = api?.message ?? (typeof e === 'string' ? e : (e as Error)?.message ?? String(e));
  const status = api?.status ?? 500;
  const error = scrub(`${code}: ${msg}`, 500) ?? code;
  const sig = `${u.studioId}:${tool}:${normalise(error)}`;
  if (!allow(`studio:${u.studioId}`, 60, 10 * 60_000) || !allow(sig, 1, 60_000)) return; // ≤ 60 / 10 min per studio, the same error once a minute
  const severity = status >= 500 ? 'high' : status === 402 || status === 403 ? 'low' : 'medium';
  void recordIssue(ctx, u, { source: 'auto', kind: 'bug', severity, summary: scrub(`${tool} failed (${where}): ${code}`, 200)!, tool, error })
    .catch(err => ctx.log.warn({ err: (err as Error).message, tool }, 'claude issue capture failed'));
}

const str = (d: string, max?: number) => ({ type: 'string', description: d, ...(max ? { maxLength: max } : {}) });

export const ISSUE_TOOLS: EditTool[] = [{
  name: 'report_issue', title: 'Report a MUSE problem', scope: 'edit:read',
  description: 'Reports something in MUSE that stopped you doing what the person asked: a tool that doesn\'t exist (missing_tool), an error or wrong result (bug), a page, file or item you can\'t reach (blocked), or something on screen that confused them (confusing_ui). Call it BEFORE telling the person, then tell them it was reported. Write your own short summary: no quotes of the conversation, no personal details, never a key, password or token. Repeats of the same problem are counted, so report it each time. Free.',
  inputSchema: { type: 'object', additionalProperties: false, required: ['summary', 'asked', 'kind'], properties: {
    chatId: str('This chat (filled in for you in the app)'),
    summary: str('What went wrong, in one plain sentence ("No tool to delete a Library item")', 200),
    asked: str('What the person wanted, in your words ("Delete the three blurry takes")', 300),
    page: str('The page you were on (edit, suite, library…); left out = the page the chat is on', 40),
    tried: str('The tools or steps you tried, in order', 500),
    error: str('The error text a tool gave, if any', 500),
    kind: { type: 'string', enum: [...ISSUE_KINDS] },
    severity: { type: 'string', enum: [...SEVERITIES], description: 'high: the person is stuck; medium: a workaround exists; low: a rough edge' },
  } },
  run: async (env, a) => {
    const summary = scrub(a.summary, 200), asked = scrub(a.asked, 300);
    if (!summary) throw badRequest('summary: one plain sentence');
    if (!asked) throw badRequest('asked: what the person wanted');
    if (typeof a.kind !== 'string' || !(ISSUE_KINDS as readonly string[]).includes(a.kind)) throw badRequest(`kind: one of ${ISSUE_KINDS.join(', ')}`);
    const severity = typeof a.severity === 'string' && (SEVERITIES as readonly string[]).includes(a.severity) ? a.severity : 'medium';
    let page = scrub(a.page, 40);
    if (!page && typeof a.chatId === 'string' && a.chatId) {
      page = (await ownChat(env.ctx, env.user, a.chatId).then(pageOf).catch(() => undefined))?.name ?? null;
    }
    if (!allow(`report:${env.user.id}`, 30, 60 * 60_000)) return { reported: false, note: 'Too many reports this hour; tell the person what went wrong instead.' };
    const r = await recordIssue(env.ctx, env.user, { source: 'claude', kind: a.kind, severity, summary, asked, page, tried: scrub(a.tried, 500), error: scrub(a.error, 500) });
    return { reported: true, id: r.id, seen: r.count, note: 'Reported to the MUSE team. Tell the person in one line that it was reported.' };
  },
}];

export const issueView = (r: typeof claudeIssues.$inferSelect) => compact({ id: r.id, source: r.source, kind: r.kind, severity: r.severity, summary: r.summary,
  asked: r.asked ?? undefined, page: r.page ?? undefined, tried: r.tried ?? undefined, error: r.error ?? undefined, tool: r.tool ?? undefined,
  reporter: r.reporterRole, count: r.count, firstSeen: r.firstSeen, lastSeen: r.lastSeen, status: r.status, note: r.note ?? undefined, updatedAt: r.updatedAt });

const ownerOnly = (u: AuthUser) => { if (u.role !== 'owner') throw new ApiError(403, 'owner_only', 'Claude\'s reports are for the studio owner'); };

const ListQuery = z.object({ since: z.coerce.number().int().min(0).optional(), status: z.enum(STATUSES).optional(),
  source: z.enum(['claude', 'auto']).optional(), limit: z.coerce.number().int().min(1).max(200).optional() }).strict();

/** The owner's list (route and MCP tool share it). */
export async function listIssues(ctx: Ctx, u: AuthUser, query: unknown) {
  ownerOnly(u);
  const q = parse(ListQuery, query ?? {});
  const where = and(eq(claudeIssues.studioId, u.studioId), q.since !== undefined ? gt(claudeIssues.updatedAt, q.since) : undefined,
    q.status ? eq(claudeIssues.status, q.status) : undefined, q.source ? eq(claudeIssues.source, q.source) : undefined);
  const rows = await ctx.db.select().from(claudeIssues).where(where)
    .orderBy(q.since !== undefined ? claudeIssues.updatedAt : desc(claudeIssues.updatedAt)).limit(q.limit ?? 100);
  return { issues: rows.map(issueView), now: Date.now() };
}

/** The owner marks a report (status and/or a note). */
export async function markIssue(ctx: Ctx, u: AuthUser, id: string, body: unknown) {
  ownerOnly(u);
  const b = parse(z.object({ status: z.enum(STATUSES).optional(), note: z.string().trim().max(1000).optional() }).strict()
    .refine(x => x.status !== undefined || x.note !== undefined, 'status or note'), body ?? {});
  const [r] = await ctx.db.update(claudeIssues).set(compact({ status: b.status, note: b.note !== undefined ? scrub(b.note, 1000) : undefined, updatedAt: Date.now() }))
    .where(and(eq(claudeIssues.id, id), eq(claudeIssues.studioId, u.studioId))).returning();
  if (!r) throw notFound('Report');
  return issueView(r);
}

/** The same list for the owner's MCP connection (a personal token works on /mcp, not on /v1): the hourly check polls it.
 * Not in the chat registry, so a member's connection never sees them. */
export const ISSUE_ADMIN_TOOLS: EditTool[] = [
  { name: 'claude_issues', title: 'Claude\'s reports (owner)', scope: 'edit:read', readOnly: true, idempotent: true,
    description: 'Owner only: what Claude could not do in MUSE (its own reports and captured tool errors), deduped with a count. since (ms) returns those seen or changed after it, oldest first; pass the last updatedAt you saw.',
    inputSchema: { type: 'object', additionalProperties: false, properties: { since: { type: 'integer', minimum: 0 }, status: { type: 'string', enum: [...STATUSES] },
      source: { type: 'string', enum: ['claude', 'auto'] }, limit: { type: 'integer', minimum: 1, maximum: 200 } } },
    run: (env, a) => listIssues(env.ctx, env.user, a) },
  { name: 'claude_issue_mark', title: 'Mark a Claude report (owner)', scope: 'edit:write',
    description: 'Owner only: sets a report\'s status (new, triaged, fixed, wontfix) and/or a note. A fixed report that happens again comes back as new.',
    inputSchema: { type: 'object', additionalProperties: false, required: ['id'], properties: { id: str('The report id (ci_…)', 80), status: { type: 'string', enum: [...STATUSES] }, note: str('Note', 1000) } },
    run: (env, a) => { const { id, ...rest } = a; return markIssue(env.ctx, env.user, String(id ?? ''), rest); } },
];

/** The owner's view of Claude's reports. `since` (ms) returns those seen or changed after it, oldest first, so a poller
 * can pass the last `updatedAt` it saw; without it, the newest first. */
export async function registerIssueRoutes(app: FastifyInstance, ctx: Ctx) {
  app.get('/v1/claude/issues', async req => listIssues(ctx, req.user, req.query));
  app.post<{ Params: { id: string } }>('/v1/claude/issues/:id', async req => markIssue(ctx, req.user, req.params.id, req.body));
}
