// Money: per-user token wallets, holds, settlement, caps, and the real RunPod balance.
//
// - Every user has a token wallet (1 token = TOKEN_USD). Members are funded by the owner (transfer / reclaim).
// - The owner's wallet is the real money: RunPod clientBalance − every member's unspent tokens − owners' holds.
//   That number is also the owner's "available to send", so tokens handed out can never exceed real credit.
// - Jobs hold the estimated price from the requester's wallet, settle to the actual cost when done, and release the
//   hold in full on failure. Fixed-price work (shoots, outfit sets, sheet fills, LoRA sets) is charged at once.
// - Caps: per job, per user per day (owner-configurable per user), and per studio per day.
// All money operations for a studio run one at a time (single API instance), so two jobs can't overspend a wallet.
import { and, eq, gte, inArray, sql } from 'drizzle-orm';
import type { Ctx, AuthUser } from '../ctx.js';
import { ledger, studioSettings, users, wallets } from '../db/schema.js';
import { ApiError } from '../errors.js';
import { dayStart, monthStart } from '../lib/util.js';
import { videosLeft } from '../pricing.js';

export type RunpodBalance = { source: 'runpod' | 'simulated' | 'unavailable'; balance: number | null; spendPerHour?: number; reason?: string };
type Who = { id: string; studioId: string; role: 'owner' | 'member' };

const SPEND_KINDS = ['settle', 'charge', 'overhead', 'warmup'];
const EPS = 1e-9;

class Mutex {
  private tail = new Map<string, Promise<unknown>>();
  run<T>(key: string, fn: () => Promise<T>): Promise<T> {
    const prev = this.tail.get(key) ?? Promise.resolve();
    const next = prev.catch(() => {}).then(fn);
    this.tail.set(key, next);
    next.finally(() => { if (this.tail.get(key) === next) this.tail.delete(key); }).catch(() => {});
    return next;
  }
}

export class Money {
  private lock = new Mutex();
  private rpCache: { at: number; value: RunpodBalance } | null = null;
  constructor(private ctx: Ctx) {}

  get rate() { return this.ctx.config.TOKEN_USD; }
  /** Dollars → tokens, rounded up to the next whole token (an estimate of $0.6739 holds 68 tokens at $0.01). */
  toTokens(usd: number) { return Math.ceil(Math.round((usd / this.rate) * 1e6) / 1e6 - EPS); }
  toUsd(tokens: number) { return Math.round(tokens * this.rate * 1e8) / 1e8; }

  // ------------------------------------------------------------------ RunPod balance
  /** The real RunPod credit (cached 30 s), the dev stand-in, or "unavailable". The API key is never logged. */
  async runpodBalance(studioId: string): Promise<RunpodBalance> {
    const c = this.ctx.config;
    if (c.balanceMode === 'simulated') {
      const s = await this.settings(studioId);
      return { source: 'simulated', balance: s.simBalance };
    }
    if (!this.ctx.runpod.configured) return { source: 'unavailable', balance: null, reason: 'RUNPOD_API_KEY is not set' };
    if (this.rpCache && Date.now() - this.rpCache.at < c.BALANCE_CACHE_SEC * 1000) return this.rpCache.value;
    try {
      const me = await this.ctx.runpod.myself();
      const value: RunpodBalance = { source: 'runpod', balance: Number(me.clientBalance), spendPerHour: Number(me.currentSpendPerHr) };
      this.rpCache = { at: Date.now(), value };
      return value;
    } catch (e) {
      this.ctx.log.warn({ err: (e as Error).message }, 'RunPod balance unavailable');
      const value: RunpodBalance = { source: 'unavailable', balance: null, reason: 'RunPod did not answer' };
      this.rpCache = { at: Date.now() - (c.BALANCE_CACHE_SEC - 5) * 1000, value }; // retry in 5 s
      return value;
    }
  }
  invalidateRunpodCache() { this.rpCache = null; }

  async settings(studioId: string) {
    const [s] = await this.ctx.db.select().from(studioSettings).where(eq(studioSettings.studioId, studioId));
    if (s) return s;
    await this.ctx.db.insert(studioSettings).values({ studioId, simBalance: 0 }).onConflictDoNothing();
    return (await this.ctx.db.select().from(studioSettings).where(eq(studioSettings.studioId, studioId)))[0]!;
  }

  // ------------------------------------------------------------------ wallets
  async wallet(userId: string, studioId: string) {
    const [w] = await this.ctx.db.select().from(wallets).where(eq(wallets.userId, userId));
    if (w) return w;
    await this.ctx.db.insert(wallets).values({ userId, studioId, tokens: 0, held: 0, updatedAt: Date.now() }).onConflictDoNothing();
    return (await this.ctx.db.select().from(wallets).where(eq(wallets.userId, userId)))[0]!;
  }

  /** Σ members' unspent tokens (spendable + held) and Σ owners' held tokens, for the studio. */
  private async pools(studioId: string) {
    const rows = await this.ctx.db.select({ role: users.role, tokens: wallets.tokens, held: wallets.held })
      .from(wallets).innerJoin(users, eq(users.id, wallets.userId)).where(eq(wallets.studioId, studioId));
    let membersUnspent = 0, ownersHeld = 0;
    for (const r of rows) {
      if (r.role === 'owner') ownersHeld += r.held;
      else membersUnspent += r.tokens + r.held;
    }
    return { membersUnspent, ownersHeld };
  }

  /** What the owner can spend or send: RunPod balance − members' unspent tokens − owners' holds (USD). Null when unknown. */
  async ownerAvailable(studioId: string): Promise<{ usd: number | null; rp: RunpodBalance; membersUnspentUsd: number; ownersHeldUsd: number }> {
    const rp = await this.runpodBalance(studioId);
    const p = await this.pools(studioId);
    const membersUnspentUsd = this.toUsd(p.membersUnspent), ownersHeldUsd = this.toUsd(p.ownersHeld);
    const usd = rp.balance == null ? null : Math.round((rp.balance - membersUnspentUsd - ownersHeldUsd) * 1e8) / 1e8;
    return { usd, rp, membersUnspentUsd, ownersHeldUsd };
  }

  async spend(studioId: string, since: number, userId?: string) {
    const conds = [eq(ledger.studioId, studioId), gte(ledger.createdAt, since), inArray(ledger.kind, SPEND_KINDS)];
    if (userId) conds.push(eq(ledger.userId, userId));
    const [r] = await this.ctx.db.select({ s: sql<number>`coalesce(sum(${ledger.amountUsd}), 0)` }).from(ledger).where(and(...conds));
    return Number(r?.s ?? 0);
  }
  private async heldUsd(studioId: string, userId?: string) {
    const conds = [eq(wallets.studioId, studioId)];
    if (userId) conds.push(eq(wallets.userId, userId));
    const [r] = await this.ctx.db.select({ s: sql<number>`coalesce(sum(${wallets.held}), 0)` }).from(wallets).where(and(...conds));
    return this.toUsd(Number(r?.s ?? 0));
  }

  async caps(u: { id: string; studioId: string }) {
    const c = this.ctx.config, s = await this.settings(u.studioId);
    const [row] = await this.ctx.db.select({ capPerJob: users.capPerJob, capPerDay: users.capPerDay }).from(users).where(eq(users.id, u.id));
    return {
      perJob: row?.capPerJob ?? s.capPerJob ?? c.CAP_PER_JOB_USD,
      perUserDay: row?.capPerDay ?? s.capPerUserDay ?? c.CAP_PER_USER_DAY_USD,
      perDay: s.capPerDay ?? c.CAP_PER_DAY_USD,
    };
  }

  /** Refuses work that would go over a cap. Today's spend counts running holds too. */
  async checkCaps(u: Who, costUsd: number, opts: { perJob: boolean }) {
    const caps = await this.caps(u), since = dayStart();
    if (opts.perJob && costUsd > caps.perJob + EPS) throw new ApiError(402, 'over_job_limit', `Over your $${caps.perJob.toFixed(2)} per-job limit`);
    const mine = (await this.spend(u.studioId, since, u.id)) + (await this.heldUsd(u.studioId, u.id));
    if (mine + costUsd > caps.perUserDay + EPS) throw new ApiError(402, 'over_user_day_limit', `Over your $${caps.perUserDay.toFixed(2)} daily limit · $${Math.max(0, caps.perUserDay - mine).toFixed(2)} left today`);
    const studio = (await this.spend(u.studioId, since)) + (await this.heldUsd(u.studioId));
    if (studio + costUsd > caps.perDay + EPS) throw new ApiError(402, 'over_day_limit', `Over the studio's $${caps.perDay.toFixed(2)} daily limit`);
  }

  private async ensureCovered(u: Who, tokens: number) {
    if (u.role === 'owner') {
      const a = await this.ownerAvailable(u.studioId);
      // Unknown RunPod balance: caps still apply, but the balance can't be checked.
      if (a.usd != null && this.toUsd(tokens) > a.usd + EPS) throw new ApiError(402, 'insufficient_balance', 'Not enough balance · top up in Credits');
      return;
    }
    const w = await this.wallet(u.id, u.studioId);
    if (tokens > w.tokens) throw new ApiError(402, 'insufficient_tokens', `Not enough tokens · ask the studio owner for more (you have ${w.tokens})`);
  }

  /** Holds the estimate for a job. Throws insufficient_* or a cap error before anything starts. */
  hold(u: Who, jobId: string, costUsd: number, opts: { perJob: boolean }) {
    return this.lock.run(u.studioId, async () => {
      const tokens = this.toTokens(costUsd);
      await this.checkCaps(u, costUsd, opts);
      await this.ensureCovered(u, tokens);
      await this.wallet(u.id, u.studioId);
      await this.ctx.db.update(wallets).set({
        tokens: u.role === 'owner' ? wallets.tokens : sql`${wallets.tokens} - ${tokens}`,
        held: sql`${wallets.held} + ${tokens}`, updatedAt: Date.now(),
      }).where(eq(wallets.userId, u.id));
      await this.row({ studioId: u.studioId, userId: u.id, actorId: u.id, jobId, kind: 'hold', tokens: -tokens, note: `hold $${costUsd.toFixed(4)}` });
      return tokens;
    }).finally(() => this.notify(u.studioId, [u.id]));
  }

  /** Failure or cancel: the whole hold goes back. */
  release(studioId: string, userId: string, jobId: string, tokens: number, note = 'job failed') {
    if (!tokens) return Promise.resolve();
    return this.lock.run(studioId, async () => {
      const role = await this.roleOf(userId);
      await this.ctx.db.update(wallets).set({
        tokens: role === 'owner' ? wallets.tokens : sql`${wallets.tokens} + ${tokens}`,
        held: sql`greatest(${wallets.held} - ${tokens}, 0)`, updatedAt: Date.now(),
      }).where(eq(wallets.userId, userId));
      await this.row({ studioId, userId, actorId: userId, jobId, kind: 'release', tokens, note });
    }).finally(() => this.notify(studioId, [userId]));
  }

  /**
   * Done: the hold becomes spend at the actual cost. A member pays at most the hold plus what's in the wallet;
   * anything beyond is recorded as studio overhead (the owner's real money).
   */
  settle(studioId: string, userId: string, jobId: string, holdTokens: number, actualUsd: number, note = 'job done') {
    return this.lock.run(studioId, async () => {
      const role = await this.roleOf(userId);
      let want = this.toTokens(actualUsd), overheadUsd = 0;
      if (role !== 'owner') {
        const w = await this.wallet(userId, studioId);
        const max = holdTokens + Math.max(0, w.tokens);
        if (want > max) { overheadUsd = actualUsd - this.toUsd(max); want = max; }
      }
      const back = holdTokens - want; // > 0: the estimate was high; < 0: it ran over
      await this.ctx.db.update(wallets).set({
        tokens: role === 'owner' ? wallets.tokens : sql`${wallets.tokens} + ${back}`,
        held: sql`greatest(${wallets.held} - ${holdTokens}, 0)`, updatedAt: Date.now(),
      }).where(eq(wallets.userId, userId));
      await this.row({ studioId, userId, actorId: userId, jobId, kind: 'settle', tokens: back, amountUsd: actualUsd - overheadUsd, note });
      if (overheadUsd > EPS) await this.row({ studioId, userId: null, actorId: userId, jobId, kind: 'overhead', amountUsd: overheadUsd, note: 'over the member wallet' });
      await this.simSpend(studioId, actualUsd);
    }).finally(() => this.notify(studioId, [userId]));
  }

  /** Fixed-price work: checked against caps and wallet, then spent at once. */
  charge(u: Who, costUsd: number, note: string, refId?: string) {
    if (costUsd <= 0) return Promise.resolve();
    return this.lock.run(u.studioId, async () => {
      const tokens = this.toTokens(costUsd);
      await this.checkCaps(u, costUsd, { perJob: false });
      await this.ensureCovered(u, tokens);
      await this.wallet(u.id, u.studioId);
      if (u.role !== 'owner') await this.ctx.db.update(wallets).set({ tokens: sql`${wallets.tokens} - ${tokens}`, updatedAt: Date.now() }).where(eq(wallets.userId, u.id));
      await this.row({ studioId: u.studioId, userId: u.id, actorId: u.id, jobId: refId ?? null, kind: 'charge', tokens: -tokens, amountUsd: costUsd, note });
      await this.simSpend(u.studioId, costUsd);
    }).finally(() => this.notify(u.studioId, [u.id]));
  }

  /** Undo a fixed-price charge (the image engine failed). */
  refundCharge(u: Who, costUsd: number, note: string, refId?: string) {
    if (costUsd <= 0) return Promise.resolve();
    return this.lock.run(u.studioId, async () => {
      const tokens = this.toTokens(costUsd);
      if (u.role !== 'owner') await this.ctx.db.update(wallets).set({ tokens: sql`${wallets.tokens} + ${tokens}`, updatedAt: Date.now() }).where(eq(wallets.userId, u.id));
      await this.row({ studioId: u.studioId, userId: u.id, actorId: u.id, jobId: refId ?? null, kind: 'charge', tokens, amountUsd: -costUsd, note: `refund: ${note}` });
      await this.simSpend(u.studioId, -costUsd);
    }).finally(() => this.notify(u.studioId, [u.id]));
  }

  /** Pod idle and start-up time that no job paid for. */
  async overhead(studioId: string, usd: number, note: string) {
    if (usd <= EPS) return;
    await this.row({ studioId, userId: null, actorId: null, jobId: null, kind: 'overhead', amountUsd: usd, note });
    await this.simSpend(studioId, usd);
  }

  /**
   * GPU warm-up and idle time on a user's own pod ("GPU warm-up" line). A member pays from their tokens, as far as they
   * go (the rest is studio overhead); an owner's is their own spend.
   */
  gpuOverhead(studioId: string, userId: string, usd: number, jobId: string | null, note: string) {
    return this.lock.run(studioId, async () => {
      const role = await this.roleOf(userId);
      let paid = usd, rest = 0, tokens = 0;
      if (role !== 'owner') {
        const w = await this.wallet(userId, studioId);
        tokens = Math.min(this.toTokens(usd), Math.max(0, w.tokens));
        paid = Math.min(usd, this.toUsd(tokens)); rest = usd - paid;
        if (tokens) await this.ctx.db.update(wallets).set({ tokens: sql`${wallets.tokens} - ${tokens}`, updatedAt: Date.now() }).where(eq(wallets.userId, userId));
      }
      await this.row({ studioId, userId, actorId: userId, jobId, kind: 'warmup', tokens: -tokens, amountUsd: paid, note });
      if (rest > EPS) await this.row({ studioId, userId: null, actorId: userId, jobId, kind: 'overhead', amountUsd: rest, note: `${note}: over the member wallet` });
      await this.simSpend(studioId, usd);
    }).finally(() => this.notify(studioId, [userId]));
  }

  async clearFailNext(studioId: string) {
    await this.ctx.db.update(studioSettings).set({ failNext: false }).where(eq(studioSettings.studioId, studioId));
  }

  /** In simulated mode the stand-in RunPod credit goes down by what was really spent, like RunPod's own balance. */
  private async simSpend(studioId: string, usd: number) {
    if (this.ctx.config.balanceMode !== 'simulated') return;
    await this.settings(studioId);
    await this.ctx.db.update(studioSettings).set({ simBalance: sql`greatest(${studioSettings.simBalance} - ${usd}, 0)` }).where(eq(studioSettings.studioId, studioId));
  }
  /** Dev only: add simulated RunPod credit. */
  async simTopUp(u: Who, usd: number) {
    await this.settings(u.studioId);
    await this.ctx.db.update(studioSettings).set({ simBalance: sql`${studioSettings.simBalance} + ${usd}` }).where(eq(studioSettings.studioId, u.studioId));
    await this.row({ studioId: u.studioId, userId: u.id, actorId: u.id, jobId: null, kind: 'topup', amountUsd: 0, tokens: 0, note: `simulated RunPod top-up $${usd.toFixed(2)}` });
    await this.notify(u.studioId, [u.id]);
  }

  // ------------------------------------------------------------------ owner: send and take back tokens
  transfer(owner: Who, toUserId: string, tokens: number, note?: string) {
    return this.lock.run(owner.studioId, async () => {
      const member = await this.memberOf(owner.studioId, toUserId);
      const a = await this.ownerAvailable(owner.studioId);
      if (a.usd == null) throw new ApiError(503, 'balance_unavailable', "Can't read the RunPod balance right now, so tokens can't be sent");
      const availTokens = Math.floor(Math.round(a.usd / this.rate * 1e6) / 1e6 + EPS);
      if (tokens > availTokens) throw new ApiError(402, 'over_allocation', `You can send at most ${availTokens} tokens ($${this.toUsd(availTokens).toFixed(2)}): the rest of the RunPod balance is already with members or on hold`);
      await this.wallet(member.id, owner.studioId);
      await this.ctx.db.update(wallets).set({ tokens: sql`${wallets.tokens} + ${tokens}`, updatedAt: Date.now() }).where(eq(wallets.userId, member.id));
      await this.row({ studioId: owner.studioId, userId: member.id, actorId: owner.id, jobId: null, kind: 'transfer', tokens, note: note ?? null });
    }).finally(() => this.notify(owner.studioId, [toUserId, owner.id]));
  }

  reclaim(owner: Who, fromUserId: string, tokens: number, note?: string) {
    return this.lock.run(owner.studioId, async () => {
      const member = await this.memberOf(owner.studioId, fromUserId);
      const w = await this.wallet(member.id, owner.studioId);
      if (tokens > w.tokens) throw new ApiError(400, 'bad_request', `They have ${w.tokens} unused tokens${w.held ? ` (${w.held} more are on hold for running jobs)` : ''}`);
      await this.ctx.db.update(wallets).set({ tokens: sql`${wallets.tokens} - ${tokens}`, updatedAt: Date.now() }).where(eq(wallets.userId, member.id));
      await this.row({ studioId: owner.studioId, userId: member.id, actorId: owner.id, jobId: null, kind: 'reclaim', tokens: -tokens, note: note ?? null });
    }).finally(() => this.notify(owner.studioId, [fromUserId, owner.id]));
  }

  private async memberOf(studioId: string, userId: string) {
    const [m] = await this.ctx.db.select().from(users).where(and(eq(users.id, userId), eq(users.studioId, studioId)));
    if (!m) throw new ApiError(404, 'not_found', 'Member not found');
    if (m.role === 'owner') throw new ApiError(400, 'bad_request', "The owner's wallet is the RunPod balance; send tokens to members only");
    return m;
  }
  private async roleOf(userId: string) {
    const [u] = await this.ctx.db.select({ role: users.role }).from(users).where(eq(users.id, userId));
    return u?.role ?? 'member';
  }
  private async row(r: { studioId: string; userId: string | null; actorId: string | null; jobId: string | null; kind: string; tokens?: number; amountUsd?: number; note?: string | null }) {
    await this.ctx.db.insert(ledger).values({ ...r, tokens: r.tokens ?? 0, amountUsd: r.amountUsd ?? 0, createdAt: Date.now() });
  }

  // ------------------------------------------------------------------ views
  /** GET /v1/wallet */
  async walletView(u: Who) {
    const w = await this.wallet(u.id, u.studioId);
    const now = Date.now();
    const owner = u.role === 'owner';
    const today = owner ? await this.spend(u.studioId, dayStart(now), u.id) : await this.spend(u.studioId, dayStart(now), u.id);
    const month = await this.spend(u.studioId, monthStart(now), u.id);
    const base = { userId: u.id, role: u.role, tokenUsd: this.rate, heldTokens: w.held, heldUsd: this.toUsd(w.held), todayUsd: today, monthUsd: month };
    if (!owner) return { ...base, tokens: w.tokens, usd: this.toUsd(w.tokens), balanceSource: 'wallet' as const };
    const a = await this.ownerAvailable(u.studioId);
    const tokens = a.usd == null ? 0 : Math.max(0, Math.floor(Math.round(a.usd / this.rate * 1e6) / 1e6 + EPS));
    return { ...base, tokens, usd: a.usd ?? 0, availableToSend: a.usd, runpodBalance: a.rp.balance, balanceSource: a.rp.source, membersUnspentUsd: a.membersUnspentUsd };
  }

  /**
   * GET /v1/balance (the app's Credits card). Members: `balance` is their wallet in USD. The owner: `balance` is what they
   * can spend or send (RunPod balance − members' unspent tokens − holds), with `runpodBalance` and `availableToSend`.
   */
  async balanceView(u: Who) {
    const w = await this.walletView(u);
    const caps = await this.caps(u);
    const now = Date.now();
    const today = u.role === 'owner' ? await this.spend(u.studioId, dayStart(now)) : w.todayUsd;
    const month = u.role === 'owner' ? await this.spend(u.studioId, monthStart(now)) : w.monthUsd;
    const balance = Math.max(0, Math.round(w.usd * 1e8) / 1e8);
    return {
      balance, month, today, perJobLimit: caps.perJob, perDayLimit: u.role === 'owner' ? caps.perDay : caps.perUserDay,
      perUserDayLimit: caps.perUserDay, videos: videosLeft(balance), tokens: w.tokens, tokenUsd: this.rate, role: u.role,
      heldUsd: w.heldUsd, balanceSource: w.balanceSource,
      ...(u.role === 'owner' ? { runpodBalance: (w as any).runpodBalance, availableToSend: (w as any).availableToSend } : {}),
    };
  }

  /** Sends `balance` and `wallet` events to the affected users and to every owner (whose pool moved too). */
  async notify(studioId: string, userIds: string[]) {
    try {
      const connected = this.ctx.hub.connectedUsers(studioId);
      if (!connected.size) return;
      const owners = await this.ctx.db.select({ id: users.id }).from(users).where(and(eq(users.studioId, studioId), eq(users.role, 'owner')));
      const targets = new Set([...userIds, ...owners.map(o => o.id)].filter(id => connected.has(id)));
      for (const id of targets) {
        const [row] = await this.ctx.db.select({ id: users.id, studioId: users.studioId, role: users.role }).from(users).where(eq(users.id, id));
        if (!row) continue;
        const who = row as Who;
        this.ctx.hub.emitTo(id, { type: 'balance', balance: await this.balanceView(who) });
        if (userIds.includes(id)) this.ctx.hub.emitTo(id, { type: 'wallet', wallet: await this.walletView(who) });
      }
    } catch (e) {
      this.ctx.log.warn({ err: (e as Error).message }, 'money notify failed');
    }
  }
}

export type { Who };
export const whoOf = (u: AuthUser): Who => ({ id: u.id, studioId: u.studioId, role: u.role });
