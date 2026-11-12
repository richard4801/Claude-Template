// The price lines under an Approve card (Claude panel, 2026-11-12): what a shot's estimate is made of, so the person
// sees "Video, 15 s at $0.066/s · $0.99" and "2 reference images past the 5 included · $0.18" above the Total. Lines are
// computed from the same plan the estimate comes from and always add up to it (cards.balance puts the rounding on the
// biggest line).
import { balance, type PriceLine } from '../claude/priceLines.js';
import * as P from '../pricing.js';
import { paidImages, type ShotPlan } from './plan.js';
import { modelById } from './registry.js';

export type Breakdown = { lines: PriceLine[]; totalUsd: number };
const secs = (v: number) => String(Math.round(v * 10) / 10);
const rate = (v: number) => `$${v < 0.1 ? v.toFixed(3).replace(/0$/, '') : v.toFixed(2)}/s`;

/** A Suite shot (Shot, Recast, Extend, New Swap). */
export function shotBreakdown(plan: Pick<ShotPlan, 'perSec' | 'billedPerTake' | 'extraPerTake' | 'takes' | 'separationUsd' | 'estimate' | 'modelId'> & { images?: { refs?: unknown[] }; remix?: unknown }): Breakdown {
  const n = Math.max(1, plan.takes);
  const each = n > 1 ? `${n} takes × ` : '';
  const lines: PriceLine[] = [{ label: `Video, ${each}${secs(plan.billedPerTake)} s at ${rate(plan.perSec)}`, usd: plan.perSec * plan.billedPerTake * n }];
  if (plan.extraPerTake > 0) {
    const m = modelById(plan.modelId);
    const paid = m && !plan.remix ? paidImages(m, plan.images?.refs?.length ?? 0) : 0;
    const what = m?.adapter === 'fal-h3-3d' ? '3D guide' : paid ? `${paid} reference image${paid > 1 ? 's' : ''} past the ${m!.refs.includedImages ?? 0} included`
      : m?.byo ? 'The model’s price per run' : 'Extra pictures sent';
    lines.push({ label: n > 1 ? `${what}, ${n} takes` : what, usd: plan.extraPerTake * n });
  }
  if (plan.separationUsd > 0) lines.push({ label: 'Taking the voice out of the music', usd: plan.separationUsd });
  return { lines: balance(lines, plan.estimate), totalUsd: Math.round(plan.estimate * 100) / 100 };
}

/** The classic Swap (one hosted or GPU render request). */
export function renderBreakdown(rr: P.RenderReq, seconds: number): Breakdown {
  const total = P.totalCost(rr), n = Math.max(1, rr.takes ?? 1);
  const label = `${P.engineLabel(rr)}, ${n > 1 ? `${n} takes × ` : ''}${secs(seconds)} s`;
  return { lines: balance([{ label, usd: total }], total), totalUsd: Math.round(total * 100) / 100 };
}
