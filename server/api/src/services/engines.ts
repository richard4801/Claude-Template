// Engine health for owner Settings → Engines (plans/api.md "App clean-up" §4–5): which engines have keys, which one
// refused for lack of credit (until a job on it works again), and the owner notice when that happens. This is the only
// place provider names are sent to an app, and only to owners.
import { and, eq } from 'drizzle-orm';
import type { Ctx } from '../ctx.js';
import { users } from '../db/schema.js';

export type EngineId = 'replicate' | 'runpod';
export const ENGINE_NAMES: Record<EngineId, string> = { replicate: 'Replicate', runpod: 'RunPod' };
export const OWNER_CREDIT_NOTICE = 'An engine is out of credit · see Settings → Engines';

export class EngineHealth {
  /** Engine → when it last refused for lack of credit (cleared when a job on it works). */
  private credit = new Map<EngineId, { at: number; message: string }>();
  constructor(private ctx: Ctx) {}

  /** An engine refused for lack of credit: remember it and tell every owner in the studio (wallet event notice). */
  async outOfCredit(studioId: string, engine: EngineId, detail: string) {
    const first = !this.credit.has(engine);
    this.credit.set(engine, { at: Date.now(), message: `${ENGINE_NAMES[engine]} is out of credit · add credit in your ${ENGINE_NAMES[engine]} account` });
    this.ctx.log.warn({ engine, studioId, detail: detail.slice(0, 300), first }, 'engine out of credit');
    try {
      const owners = await this.ctx.db.select({ id: users.id }).from(users).where(and(eq(users.studioId, studioId), eq(users.role, 'owner')));
      for (const o of owners) {
        const wallet = await this.ctx.money.walletView({ id: o.id, studioId, role: 'owner' });
        this.ctx.hub.emitTo(o.id, { type: 'wallet', wallet, notice: { code: 'provider_out_of_credit', engine, message: OWNER_CREDIT_NOTICE } });
      }
    } catch (e) { this.ctx.log.warn({ err: (e as Error).message }, 'owner notice failed'); }
  }
  worked(engine: EngineId) { this.credit.delete(engine); }

  /** The owner's Engines block. */
  async view(studioId: string) {
    const c = this.ctx.config, gpu = await this.ctx.gpu.status() as { mode?: string; noGpu?: unknown[] } & Record<string, unknown>;
    const s = await this.ctx.money.settings(studioId);
    const rep = this.credit.get('replicate'), rp = this.credit.get('runpod');
    const rpBal = this.ctx.runpod.configured ? await this.ctx.money.runpodBalance(studioId) : null;
    const runpodStatus = rp ? 'out_of_credit' : this.ctx.gpu.mode === 'simulated' ? 'simulated' : !this.ctx.runpod.configured ? 'no_key' : (gpu.noGpu?.length ? 'no_gpu' : 'ready');
    const sel = await this.ctx.images.selection(studioId);
    return {
      list: [
        { id: 'replicate', name: 'Replicate', usedFor: 'Draft, Standard and HD video · photos', keySet: this.ctx.replicate.configured,
          status: rep ? 'out_of_credit' : this.ctx.replicate.configured ? 'ready' : 'no_key', ...(rep ? { message: rep.message, outOfCreditAt: rep.at } : {}) },
        { id: 'runpod', name: 'RunPod', usedFor: 'Edit, Fast · beta, Upscale', keySet: this.ctx.runpod.configured, status: runpodStatus,
          ...(rp ? { message: rp.message, outOfCreditAt: rp.at } : runpodStatus === 'no_gpu' ? { message: 'No add-on GPU free right now · jobs wait and retry' } : {}),
          ...(rpBal && rpBal.balance != null ? { balanceUsd: rpBal.balance } : {}) },
      ],
      imageEngine: { ...sel, label: this.ctx.images.label(sel) },
      addOn: { maxGpus: s.maxGpus ?? c.MAX_GPUS, overheadPayer: s.overheadPayer ?? 'user', gpu },
      keepReady: { idleMinutes: s.warmIdleMinutes ?? c.WARM_IDLE_MINUTES, maxMinutes: s.warmMaxMinutes ?? c.WARM_MAX_MINUTES, ratePerHour: c.GPU_HOURLY_USD },
    };
  }
}
