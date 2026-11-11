// Posts (plans/socials.md, stage 1): "now" hands off at once; scheduled posts wait in Postgres and a scheduler loop
// hands them off when due (so they survive restarts). With SOCIAL_MODE=simulated (dev) a handed-off post is marked
// posted with made-up stats after GEN_MS, like the mock; with "stub" it stays at handoff (no platform read-back yet).
import { and, desc, eq, lte, min } from 'drizzle-orm';
import { z } from 'zod';
import type { AuthUser, Ctx } from '../ctx.js';
import { accounts, models, posts, takes } from '../db/schema.js';
import { badRequest, notFound, ownerOrCreator } from '../errors.js';
import { compact, uid } from '../lib/util.js';

export const PLATFORMS = ['tiktok', 'instagram', 'facebook', 'youtube', 'x'] as const;
export const platformOf = (k: string) => { if (!(PLATFORMS as readonly string[]).includes(k)) throw badRequest(`Unknown platform ${k}`); return k; };
export function handleFor(platform: string, name: string) {
  if (platform === 'youtube') return name;
  if (platform === 'facebook') return `${name} (Page)`;
  return '@' + name.toLowerCase().replace(/\s+/g, '.');
}

const PostBody = z.object({
  modelId: z.string(), takeId: z.string(), platforms: z.array(z.string()).optional(), caption: z.unknown().optional(),
  aiLabel: z.unknown().optional(), paidPartnership: z.unknown().optional(), when: z.string().optional(),
});
type PostRow = typeof posts.$inferSelect;

export class PostScheduler {
  private loop: NodeJS.Timeout | null = null;
  private running = false;
  /** Earliest scheduled post still waiting (Infinity: none), and when the database was last read. Between due times
   * the loop doesn't touch the database (lets Neon sleep), except a slow safety poll every IDLE_POLL_SECONDS. */
  private nextDueAt = 0;
  private lastReadAt = 0;
  constructor(private ctx: Ctx) {}

  view(x: PostRow) {
    return compact({ id: x.id, modelId: x.modelId, takeId: x.takeId, title: x.title, thumb: x.thumb ?? undefined, platforms: x.platforms, caption: x.caption,
      aiLabel: x.aiLabel, paidPartnership: x.paidPartnership, when: x.when, state: x.state, createdAt: x.createdAt, postedAt: x.postedAt, stats: x.stats });
  }
  private emit(x: PostRow) { this.ctx.hub.emit(x.studioId, { type: 'post', post: this.view(x) }); }

  async list(studioId: string, state?: string, modelId?: string) {
    const conds = [eq(posts.studioId, studioId)];
    if (state) conds.push(eq(posts.state, state as PostRow['state']));
    if (modelId) conds.push(eq(posts.modelId, modelId));
    return (await this.ctx.db.select().from(posts).where(and(...conds)).orderBy(desc(posts.createdAt))).map(x => this.view(x));
  }

  async create(user: AuthUser, body: unknown) {
    const p = PostBody.safeParse(body);
    if (!p.success) throw badRequest('modelId and takeId are required');
    const b = p.data;
    const [m] = await this.ctx.db.select().from(models).where(and(eq(models.id, b.modelId), eq(models.studioId, user.studioId)));
    if (!m) throw notFound('Model');
    const [t] = await this.ctx.db.select().from(takes).where(and(eq(takes.id, b.takeId), eq(takes.studioId, user.studioId)));
    if (!t) throw notFound('Take');
    const platforms = [...new Set(b.platforms ?? [])].map(platformOf);
    if (!platforms.length) throw badRequest('Pick at least one account');
    const linked = await this.ctx.db.select().from(accounts).where(eq(accounts.modelId, m.id));
    const missing = platforms.find(k => !linked.some(a => a.platform === k));
    if (missing) throw badRequest(`Connect ${missing} first`);
    const when = b.when ?? 'now';
    const at = when === 'now' ? Date.now() : Date.parse(when);
    if (Number.isNaN(at)) throw badRequest('when must be "now" or an ISO time');
    // Labels are the user's choice: only an explicit `true` turns one on. MUSE never sets them by itself.
    const [x] = await this.ctx.db.insert(posts).values({
      id: uid('p'), studioId: user.studioId, userId: user.id, modelId: m.id, takeId: t.id, title: t.title, thumb: t.thumb, platforms,
      caption: typeof b.caption === 'string' ? b.caption : b.caption == null ? '' : String(b.caption),
      aiLabel: b.aiLabel === true, paidPartnership: b.paidPartnership === true, when, dueAt: at, state: 'scheduled', createdAt: Date.now(),
    }).returning();
    this.nextDueAt = Math.min(this.nextDueAt, at);
    if (when === 'now') return this.view(await this.handoff(x!));
    this.emit(x!);
    return this.view(x!);
  }

  async remove(user: AuthUser, id: string) {
    const [p] = await this.ctx.db.select({ userId: posts.userId }).from(posts).where(and(eq(posts.id, id), eq(posts.studioId, user.studioId)));
    if (p) ownerOrCreator(user, p.userId, 'post');
    const r = await this.ctx.db.delete(posts).where(and(eq(posts.id, id), eq(posts.studioId, user.studioId))).returning();
    if (!r.length) throw notFound('Post');
    this.ctx.hub.emit(user.studioId, { type: 'post', op: 'delete', id });
  }

  /** Stage 1: the client opens each app with the caption on the clipboard. */
  private async handoff(x: PostRow) {
    const [u] = await this.ctx.db.update(posts).set({ state: 'handoff', handoffAt: Date.now() }).where(and(eq(posts.id, x.id), eq(posts.state, 'scheduled'))).returning();
    if (u) this.emit(u);
    return u ?? x;
  }

  start() {
    if (this.loop) return;
    this.loop = setInterval(() => { if (this.due()) void this.tick(); }, this.ctx.config.SCHEDULER_MS);
    this.loop.unref?.();
  }
  stop() { if (this.loop) clearInterval(this.loop); this.loop = null; }

  private due(now = Date.now()) {
    const idleMs = this.ctx.config.IDLE_POLL_SECONDS * 1000;
    if (!idleMs || this.ctx.config.socialMode === 'simulated') return true; // dev: simulated posting needs every tick
    return now >= this.nextDueAt || now - this.lastReadAt >= idleMs;
  }

  async tick(now = Date.now()) {
    if (this.running) return;
    this.running = true;
    try {
      this.lastReadAt = Date.now();
      for (const x of await this.ctx.db.select().from(posts).where(and(eq(posts.state, 'scheduled'), lte(posts.dueAt, now)))) await this.handoff(x);
      if (this.ctx.config.socialMode === 'simulated') {
        const due = await this.ctx.db.select().from(posts).where(and(eq(posts.state, 'handoff'), lte(posts.handoffAt, now - this.ctx.config.GEN_MS)));
        for (const x of due) {
          const views = 1240 + Math.floor(Math.random() * 900);
          const [u] = await this.ctx.db.update(posts).set({ state: 'posted', postedAt: now, stats: { views, likes: Math.floor(views * 0.11), comments: Math.floor(views * 0.008) } })
            .where(and(eq(posts.id, x.id), eq(posts.state, 'handoff'))).returning();
          if (u) this.emit(u);
        }
      }
      const [n] = await this.ctx.db.select({ at: min(posts.dueAt) }).from(posts).where(eq(posts.state, 'scheduled'));
      this.nextDueAt = n?.at == null ? Infinity : Number(n.at);
    } catch (e) {
      this.nextDueAt = 0;
      this.ctx.log.error({ err: (e as Error).message }, 'post scheduler tick failed');
    } finally { this.running = false; }
  }

  async connect(user: AuthUser, modelId: string, platform: string) {
    const k = platformOf(platform);
    const [m] = await this.ctx.db.select().from(models).where(and(eq(models.id, modelId), eq(models.studioId, user.studioId)));
    if (!m) throw notFound('Model');
    // Stub: no platform developer apps yet, so "connecting" links the handle after a short delay, like the mock.
    await new Promise(r => setTimeout(r, Math.min(this.ctx.config.GEN_MS, 900)));
    const a = { studioId: user.studioId, modelId: m.id, platform: k, handle: handleFor(k, m.name), connectedAt: Date.now(), canPostDirect: false, connectedBy: user.id };
    await this.ctx.db.insert(accounts).values(a).onConflictDoUpdate({ target: [accounts.modelId, accounts.platform], set: { handle: a.handle, connectedAt: a.connectedAt, connectedBy: user.id } });
    this.ctx.hub.emit(user.studioId, { type: 'account', modelId: m.id, account: accountView(a) });
    return { account: accountView(a) };
  }
}

export const accountView = (a: { modelId: string; platform: string; handle: string; connectedAt: number; canPostDirect: boolean }) =>
  ({ modelId: a.modelId, platform: a.platform, handle: a.handle, connectedAt: a.connectedAt, canPostDirect: a.canPostDirect });
