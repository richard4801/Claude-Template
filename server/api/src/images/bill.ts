// One photo action's money (plans/api.md "App clean-up" §3): hold an estimate at start, settle to the exact sum of what
// the engine charged, or release it all when the action fails (anything already billed for photos that were thrown
// away goes on a studio overhead row, so the studio balance stays true to real spending).
import type { Ctx } from '../ctx.js';
import type { Who } from '../money/money.js';

export class PhotoBill {
  /** Exact cost of the photos that were kept. */
  spent = 0;
  /** Billed by the engine for photos that were thrown away. */
  wasted = 0;
  private holdTokens = 0;
  private done = false;
  constructor(private ctx: Ctx, private who: Who, readonly refId: string, readonly estimate: number, readonly note: string) {}

  /** Holds the estimate (caps and wallet checked first). */
  async start() {
    if (this.estimate > 0) this.holdTokens = await this.ctx.money.hold(this.who, this.refId, this.estimate, { perJob: false, note: `${this.note} · hold` });
    return this;
  }
  add(usd: number) { this.spent += Math.max(0, usd); }
  waste(usd: number) { this.wasted += Math.max(0, usd); }

  /** The action finished: settle to what the kept photos cost. */
  async finish() {
    if (this.done) return;
    this.done = true;
    if (this.holdTokens || this.spent > 0) await this.ctx.money.settle(this.who.studioId, this.who.id, this.refId, this.holdTokens, this.spent, this.note);
    if (this.wasted > 1e-9) await this.ctx.money.overhead(this.who.studioId, this.wasted, `Photos that didn't finish · ${this.note}`);
  }

  /** The action failed: the member isn't charged. */
  async fail() {
    if (this.done) return;
    this.done = true;
    if (this.holdTokens) await this.ctx.money.release(this.who.studioId, this.who.id, this.refId, this.holdTokens, `${this.note} · failed`);
    const lost = this.spent + this.wasted;
    if (lost > 1e-9) await this.ctx.money.overhead(this.who.studioId, lost, `Photos that didn't finish · ${this.note}`);
  }
}
