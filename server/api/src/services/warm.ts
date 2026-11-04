// "Keep GPU warm" (plans/backend.md, plans/api.md): a user holds a dedicated pod so renders start at once.
//
// - On: take the user's own pod, else an idle ready pod nobody is waiting for, else start one (MAX_GPUS applies).
//   The pod is marked with the session id: the pool then never idles it out or hands it to someone else, and charges
//   no warm-up or idle lines for it (pool.ts).
// - Billing: the pod's wall time from the session start is the "Warm GPU" ledger line (kind "warm"), settled every
//   whole minute and pro rata at the end. Jobs claimed on it carry the session id, and their settle covers only the
//   part that ran after the session ended (JobService.complete → uncoveredCost).
// - Auto-off: idle (no render for idleMinutes once ready), cap (maxMinutes from the start, extended once by "Keep
//   warm"), the user's credit can't cover WARM_MIN_CREDIT_MINUTES more, or the RunPod balance < RUNPOD_MIN_BALANCE_USD.
//   A warning goes out WARM_WARNING_MINUTES before an idle or cap auto-off.
// - Off: terminate the pod, or hand it back to the normal pool when a render is still running on it or the user has
//   renders waiting (it then stops IDLE_SHUTDOWN_SECONDS after its last job, charged like any pod).
// Runs on the dispatcher's pass (JobService.pass → tick), so tests drive it with a fake `now`.
import { and, desc, eq, inArray } from 'drizzle-orm';
import type { AuthUser, Ctx } from '../ctx.js';
import { jobs, pods, users, warmSessions } from '../db/schema.js';
import { ApiError } from '../errors.js';
import { uid } from '../lib/util.js';
import type { Who } from '../money/money.js';
import { gpuCanRun, workKindOf, type JobRow, type PodRow } from '../gpu/controller.js';
import type { PodPool } from '../gpu/pool.js';

export type WarmSession = typeof warmSessions.$inferSelect;
export type WarmOffReason = 'user' | 'idle' | 'cap' | 'credit' | 'owner_balance' | 'gpu_lost';
const ACTIVE = ['starting', 'warm', 'stopping'] as const;
const MIN = 60_000;
const CHECK_EVERY_MS = 10_000;
const LAST_OFF_MS = 60 * MIN;
const r4 = (x: number) => Math.round(x * 1e4) / 1e4;

export class WarmService {
  /** Per-user lock so two quick taps can't start two pods. */
  private locks = new Map<string, Promise<unknown>>();
  /** When credit and balance were last checked, per session. */
  private checkedAt = new Map<string, number>();
  constructor(private ctx: Ctx) {}

  private get pool() { return this.ctx.gpu as unknown as PodPool; }

  private serial<T>(key: string, fn: () => Promise<T>): Promise<T> {
    const prev = this.locks.get(key) ?? Promise.resolve();
    const next = prev.catch(() => {}).then(fn);
    this.locks.set(key, next);
    next.finally(() => { if (this.locks.get(key) === next) this.locks.delete(key); }).catch(() => {});
    return next;
  }

  /** Studio rules: who may switch it on, idle minutes and the cap. */
  async limits(studioId: string) {
    const s = await this.ctx.money.settings(studioId), c = this.ctx.config;
    return { allowed: s.warmGpuAllowed ?? 'everyone', idleMinutes: s.warmIdleMinutes ?? c.WARM_IDLE_MINUTES, maxMinutes: s.warmMaxMinutes ?? c.WARM_MAX_MINUTES };
  }
  private mayUse(allowed: string, role: string) { return allowed !== 'owner' || role === 'owner'; }

  async active(userId: string) {
    const [s] = await this.ctx.db.select().from(warmSessions).where(and(eq(warmSessions.userId, userId), inArray(warmSessions.state, [...ACTIVE])))
      .orderBy(desc(warmSessions.startedAt)).limit(1);
    return s ?? null;
  }
  private async podOf(s: WarmSession) {
    if (!s.podId) return null;
    return (await this.ctx.db.select().from(pods).where(eq(pods.id, s.podId)))[0] ?? null;
  }

  /** The next idle or cap auto-off. Idle only counts once the pod is ready and while no render runs on it. */
  autoOff(s: WarmSession, busy: boolean) {
    const capAt = s.startedAt + s.maxMinutes * MIN;
    const idleAt = s.state === 'warm' && !busy && s.lastActiveAt != null ? s.lastActiveAt + s.idleMinutes * MIN : null;
    return idleAt != null && idleAt < capAt ? { at: idleAt, reason: 'idle' as const } : { at: capAt, reason: 'cap' as const };
  }

  // ------------------------------------------------------------------ view
  async view(u: Who, now = Date.now()) {
    const lim = await this.limits(u.studioId);
    const allowed = this.mayUse(lim.allowed, u.role);
    const s = await this.active(u.id);
    if (s) return this.viewOf(s, await this.podOf(s), allowed, now);
    const [last] = await this.ctx.db.select().from(warmSessions).where(and(eq(warmSessions.userId, u.id), eq(warmSessions.state, 'off')))
      .orderBy(desc(warmSessions.startedAt)).limit(1);
    return {
      state: 'off' as const, startedAt: null, readyAt: null, minutes: 0, costUsd: 0, ratePerHour: this.ctx.config.GPU_HOURLY_USD, busy: false,
      autoOffAt: null, idleMinutes: lim.idleMinutes, maxMinutes: lim.maxMinutes, canExtend: false, allowed,
      ...(last?.endedAt && now - last.endedAt < LAST_OFF_MS
        ? { lastOff: { reason: last.endReason as WarmOffReason, at: last.endedAt, minutes: Math.floor((last.endedAt - last.startedAt) / MIN), costUsd: r4(last.costUsd) } } : {}),
    };
  }

  viewOf(s: WarmSession, pod: PodRow | null, allowed: boolean, now = Date.now()) {
    const busy = !!pod?.currentJobId;
    const off = this.autoOff(s, busy);
    return {
      state: s.state, startedAt: s.startedAt, readyAt: s.readyAt ?? null, minutes: Math.max(0, Math.floor((now - s.startedAt) / MIN)), costUsd: r4(s.costUsd),
      ratePerHour: s.ratePerHr, busy, autoOffAt: off.at, autoOffReason: off.reason, warningAt: off.at - this.ctx.config.WARM_WARNING_MINUTES * MIN,
      idleMinutes: s.idleMinutes, maxMinutes: s.maxMinutes, canExtend: !s.extended, allowed,
    };
  }

  private async emit(s: WarmSession, event: 'state' | 'tick' | 'warning', now: number, extra: Record<string, unknown> = {}) {
    const [u] = await this.ctx.db.select({ id: users.id, studioId: users.studioId, role: users.role }).from(users).where(eq(users.id, s.userId));
    if (!u) return;
    this.ctx.hub.emitTo(s.userId, { type: 'gpu', event, gpu: await this.view(u as Who, now), ...extra });
  }

  // ------------------------------------------------------------------ on / off / keep warm
  turnOn(user: AuthUser) {
    return this.serial(user.id, async () => {
      const now = Date.now();
      const who: Who = { id: user.id, studioId: user.studioId, role: user.role };
      const existing = await this.active(user.id);
      if (existing) return this.view(who, now);
      const lim = await this.limits(user.studioId);
      if (!this.mayUse(lim.allowed, user.role)) throw new ApiError(403, 'warm_not_allowed', 'Only the studio owner can keep a GPU warm');
      const c = this.ctx.config;
      const rp = await this.ctx.money.runpodBalance(user.studioId);
      if (rp.balance != null && rp.balance < c.RUNPOD_MIN_BALANCE_USD) throw new ApiError(402, 'owner_balance_low', "The studio's GPU credit is low · the owner needs to top up RunPod");
      const need = c.GPU_HOURLY_USD * c.WARM_MIN_CREDIT_MINUTES / 60;
      const can = await this.ctx.money.spendableUsd(who);
      if (can != null && can < need) {
        throw new ApiError(402, user.role === 'owner' ? 'insufficient_balance' : 'insufficient_tokens',
          `Not enough credit to keep a GPU warm · it needs at least $${need.toFixed(2)} (${c.WARM_MIN_CREDIT_MINUTES} min)`);
      }

      const id = uid('warm');
      const pod = await this.attachPod(user, id, now);
      const ready = pod.state === 'running';
      const [s] = await this.ctx.db.insert(warmSessions).values({
        id, studioId: user.studioId, userId: user.id, podId: pod.id, state: ready ? 'warm' : 'starting', startedAt: now,
        readyAt: ready ? now : null, lastActiveAt: ready ? now : null, settledUntil: now, costUsd: 0,
        ratePerHr: pod.costPerHr || c.GPU_HOURLY_USD, idleMinutes: lim.idleMinutes, maxMinutes: lim.maxMinutes,
      }).returning();
      this.ctx.log.info({ user: user.id, pod: pod.id, session: id, ready }, 'warm GPU on');
      await this.emit(s!, 'state', now);
      this.ctx.jobs.kick();
      return this.view(who, now);
    });
  }

  /** The pod for a new session: the user's own, an idle one nobody waits for, or a new one. Marks it with the session. */
  private async attachPod(user: AuthUser, sessionId: string, now: number): Promise<PodRow> {
    const c = this.ctx.config;
    const active = await this.pool.activePods();
    const waiting = await this.ctx.db.select().from(jobs).where(and(eq(jobs.state, 'running'), eq(jobs.gpuState, 'pending')));
    const h3 = (p: PodRow) => gpuCanRun(c, p.gpuType, 'h3');
    const own = active.find(p => p.assignedUserId === user.id && !p.warmSessionId && h3(p));
    const idle = own ? undefined : active.find(p => p.studioId === user.studioId && p.state === 'running' && !p.currentJobId && !p.warmSessionId && h3(p)
      && !waiting.some(w => w.userId === p.assignedUserId && gpuCanRun(c, p.gpuType, workKindOf(w as JobRow))));
    const take = own ?? idle;
    if (take) {
      // Settle what the pool owes up to now, under its normal rules, before the session takes over.
      if (take.idleSince && take.warmupCharged) await this.pool.chargeIdle(take, now);
      else if (!take.warmupCharged && take.startedForJobId) await this.pool.charge(take, (now - take.startedAt) / 1000, take.startedForJobId, 'GPU warm-up');
      if (take.currentJobId) await this.ctx.db.update(jobs).set({ warmSessionId: sessionId }).where(eq(jobs.id, take.currentJobId));
      const [u] = await this.ctx.db.update(pods).set({ warmSessionId: sessionId, assignedUserId: user.id, warmupCharged: true, idleSince: take.currentJobId ? null : now })
        .where(eq(pods.id, take.id)).returning();
      this.ctx.log.info({ pod: take.id, from: take.assignedUserId, to: user.id }, own ? 'warm GPU: kept the user\'s own pod' : 'warm GPU: took an idle pod');
      return u!;
    }
    const max = await this.pool.maxGpus(user.studioId);
    if (active.length >= max) throw new ApiError(409, 'no_gpu_free', `All ${max} GPUs are in use · try again when a render finishes`);
    const pod = await this.pool.startPod({ studioId: user.studioId, userId: user.id, jobId: null, warmSessionId: sessionId }, 'h3', now);
    if (!pod) throw new ApiError(503, 'no_gpu_available', this.pool.launchFailure('h3')?.message ?? 'No GPU is free on RunPod right now · try again in a minute');
    return pod;
  }

  turnOff(user: AuthUser) {
    return this.serial(user.id, async () => {
      const now = Date.now();
      const s = await this.active(user.id);
      if (s && s.state !== 'stopping') await this.end(s, 'user', now);
      return this.view({ id: user.id, studioId: user.studioId, role: user.role }, now);
    });
  }

  /** "Keep warm": restart the idle clock; when the cap is the next auto-off, extend it once. */
  extend(user: AuthUser) {
    return this.serial(user.id, async () => {
      const now = Date.now();
      const s = await this.active(user.id);
      if (!s || s.state === 'stopping') throw new ApiError(409, 'not_warm', 'The GPU is not warm');
      const pod = await this.podOf(s);
      const next = this.autoOff(s, !!pod?.currentJobId);
      const extendCap = next.reason === 'cap' && !s.extended;
      const [u] = await this.ctx.db.update(warmSessions).set({
        lastActiveAt: s.state === 'warm' ? now : s.lastActiveAt, warnedFor: null,
        ...(extendCap ? { extended: true, maxMinutes: s.maxMinutes + (await this.limits(s.studioId)).maxMinutes } : {}),
      }).where(eq(warmSessions.id, s.id)).returning();
      await this.emit(u!, 'state', now);
      return this.view({ id: user.id, studioId: user.studioId, role: user.role }, now);
    });
  }

  // ------------------------------------------------------------------ billing
  /** Charges wall time up to `upTo`: whole minutes only, or everything (`final`). Returns the session as updated. */
  private async settle(s: WarmSession, upTo: number, final: boolean) {
    const ms = upTo - s.settledUntil;
    const chargeMs = final ? ms : Math.floor(ms / MIN) * MIN;
    if (chargeMs <= 0) return { s, charged: false };
    const usd = chargeMs / 3_600_000 * s.ratePerHr;
    const mins = chargeMs / MIN;
    // Tokens for the running total, rounded up once: the per-minute lines add up to the session's cost, not 1 token more each.
    const tokens = this.ctx.money.toTokens(s.costUsd + usd) - this.ctx.money.toTokens(s.costUsd);
    await this.ctx.money.gpuOverhead(s.studioId, s.userId, usd, null,
      `Warm GPU · ${Number.isInteger(mins) ? mins : mins.toFixed(2)} min (${s.id}, pod ${s.podId})`, 'warm', tokens);
    const [u] = await this.ctx.db.update(warmSessions).set({ settledUntil: s.settledUntil + chargeMs, costUsd: s.costUsd + usd })
      .where(eq(warmSessions.id, s.id)).returning();
    return { s: u!, charged: true };
  }

  /** Settle, then terminate the pod or hand it back to the pool. */
  private async end(s: WarmSession, reason: WarmOffReason, now: number, upTo = now) {
    const [st] = await this.ctx.db.update(warmSessions).set({ state: 'stopping' }).where(and(eq(warmSessions.id, s.id), inArray(warmSessions.state, ['starting', 'warm']))).returning();
    if (!st) return;
    await this.emit(st, 'state', now);
    const { s: settled } = await this.settle(st, Math.max(st.settledUntil, upTo), true);
    const pod = await this.podOf(settled);
    if (pod && pod.warmSessionId === s.id && ['starting', 'running'].includes(pod.state)) {
      const waiting = await this.ctx.db.select({ id: jobs.id }).from(jobs)
        .where(and(eq(jobs.userId, s.userId), eq(jobs.state, 'running'), eq(jobs.gpuState, 'pending'))).limit(1);
      if (pod.currentJobId || waiting.length) {
        await this.ctx.db.update(pods).set({ warmSessionId: null, warmupCharged: true, idleSince: pod.currentJobId ? null : now }).where(eq(pods.id, pod.id));
        this.ctx.log.info({ pod: pod.id }, 'warm GPU off: pod back to the pool (a render is running or waiting)');
      } else {
        await this.pool.stopPod(pod, now, `warm GPU off: ${reason}`);
      }
    }
    const [off] = await this.ctx.db.update(warmSessions).set({ state: 'off', endedAt: Math.min(now, Math.max(upTo, st.startedAt)), endReason: reason }).where(eq(warmSessions.id, s.id)).returning();
    this.checkedAt.delete(s.id);
    this.ctx.log.info({ user: s.userId, session: s.id, reason, costUsd: r4(off!.costUsd) }, 'warm GPU off');
    await this.emit(off!, 'state', now);
    this.ctx.jobs.kick();
  }

  /**
   * A job that ran on a warm GPU: what's left to charge after the session's cover. Only the part of [claimedAt, now]
   * outside [session start, session end] is charged.
   */
  async uncoveredCost(j: JobRow, actual: number, now: number) {
    if (!j.warmSessionId) return actual;
    const [s] = await this.ctx.db.select().from(warmSessions).where(eq(warmSessions.id, j.warmSessionId));
    if (!s) return actual;
    const start = j.claimedAt ?? now;
    const dur = now - start;
    const end = s.endedAt ?? now;
    if (dur <= 0) return end > start ? 0 : actual;
    const covered = Math.max(0, Math.min(now, end) - Math.max(start, s.startedAt));
    return actual * Math.max(0, 1 - covered / dur);
  }

  // ------------------------------------------------------------------ the dispatcher's pass
  async tick(now: number) {
    const live = await this.ctx.db.select().from(warmSessions).where(inArray(warmSessions.state, ['starting', 'warm']));
    for (const s0 of live) {
      try { await this.tickOne(s0, now); } catch (e) { this.ctx.log.error({ session: s0.id, err: (e as Error).message }, 'warm GPU tick failed'); }
    }
  }

  private async tickOne(s0: WarmSession, now: number) {
    let s = s0;
    const pod = await this.podOf(s);
    if (!pod || pod.warmSessionId !== s.id || !['starting', 'running'].includes(pod.state)) {
      this.ctx.log.warn({ session: s.id, pod: s.podId, podState: pod?.state }, 'warm GPU lost its pod');
      return this.end(s, 'gpu_lost', now, Math.min(now, pod?.stoppedAt ?? now));
    }
    if (s.state === 'starting' && pod.state === 'running') {
      [s] = await this.ctx.db.update(warmSessions).set({ state: 'warm', readyAt: now, lastActiveAt: now, ratePerHr: pod.costPerHr || s.ratePerHr })
        .where(eq(warmSessions.id, s.id)).returning() as [WarmSession];
      await this.emit(s, 'state', now);
    }
    const busy = !!pod.currentJobId;
    if (busy && s.state === 'warm' && (s.lastActiveAt == null || now - s.lastActiveAt >= 1000)) {
      [s] = await this.ctx.db.update(warmSessions).set({ lastActiveAt: now }).where(eq(warmSessions.id, s.id)).returning() as [WarmSession];
    }
    const off = this.autoOff(s, busy);
    if (now >= off.at) return this.end(s, off.reason, now, off.at);
    const { s: s2, charged } = await this.settle(s, now, false);
    s = s2;
    if (charged) await this.emit(s, 'tick', now);

    // Credit and the RunPod balance (every minute's settle, else at most every CHECK_EVERY_MS).
    const last = this.checkedAt.get(s.id) ?? 0;
    if (charged || now - last >= CHECK_EVERY_MS || now < last) {
      this.checkedAt.set(s.id, now);
      const c = this.ctx.config;
      const rp = await this.ctx.money.runpodBalance(s.studioId);
      if (rp.balance != null && rp.balance < c.RUNPOD_MIN_BALANCE_USD) return this.end(s, 'owner_balance', now);
      const [u] = await this.ctx.db.select({ id: users.id, studioId: users.studioId, role: users.role }).from(users).where(eq(users.id, s.userId));
      const can = u ? await this.ctx.money.spendableUsd(u as Who) : null;
      if (can != null && can < s.ratePerHr * c.WARM_MIN_CREDIT_MINUTES / 60) return this.end(s, 'credit', now);
    }

    const key = `${off.reason}:${off.at}`;
    if (now >= off.at - this.ctx.config.WARM_WARNING_MINUTES * MIN && s.warnedFor !== key) {
      [s] = await this.ctx.db.update(warmSessions).set({ warnedFor: key }).where(eq(warmSessions.id, s.id)).returning() as [WarmSession];
      const left = Math.max(1, Math.round((off.at - now) / MIN));
      const message = off.reason === 'idle' ? `Warm GPU turns off in ${left} min (no renders)` : `Warm GPU reaches its ${Math.round(s.maxMinutes / 60 * 10) / 10} h limit in ${left} min`;
      await this.emit(s, 'warning', now, { warning: { reason: off.reason, autoOffAt: off.at, message } });
    }
  }
}
