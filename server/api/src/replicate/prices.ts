// What a Replicate model costs (plans/api.md "Model tools" §3). Replicate's HTTP API has no prices, so they are read from
// the model's web page (https://replicate.com/<owner>/<name>): the JSON props that carry `billingConfig` hold the per-unit
// prices of official models (metric + "$x"), `price` ("$0.00115 per second": the hardware price community models are billed
// at), `p50price` (a typical run) and `model.hardware`.

export type PriceUnit = { metric: string; usd: number; label: string };
export type PriceInfo =
  | { kind: 'per-unit'; units: PriceUnit[]; source: 'model page' | 'config' }
  | { kind: 'per-second'; usdPerSecond: number; hardware: string | null; typicalUsd: number | null; source: 'model page' | 'config' }
  | { kind: 'unknown'; source?: string };

const dollars = (s: unknown) => { const m = /\$\s*([0-9]*\.?[0-9]+)/.exec(String(s ?? '')); return m ? Number(m[1]) : null; };

/** Parses a model page. Returns null when no pricing props are found. */
export function parseModelPage(html: string): PriceInfo | null {
  const re = /<script[^>]*type="application\/json"[^>]*>([\s\S]*?)<\/script>/g;
  let m: RegExpExecArray | null;
  let best: any = null;
  while ((m = re.exec(html))) {
    if (!m[1]!.includes('"billingConfig"')) continue;
    try {
      const j = JSON.parse(m[1]!);
      if (!best || (j.price && !best.price)) best = j;
    } catch { /* not JSON */ }
  }
  if (!best) return null;
  const tiers = best.billingConfig?.current_tiers;
  const prices: any[] = Array.isArray(tiers) && tiers[0]?.prices ? tiers[0].prices : [];
  const units: PriceUnit[] = prices.map(p => ({ metric: String(p.metric ?? 'unit'), usd: dollars(p.price) ?? NaN, label: String(p.title ?? `per ${p.metric_display ?? 'unit'}`) }))
    .filter(u => Number.isFinite(u.usd));
  if (units.length) return { kind: 'per-unit', units, source: 'model page' };
  const perSec = /per\s*second/i.test(String(best.price ?? '')) ? dollars(best.price) : null;
  if (perSec != null) return { kind: 'per-second', usdPerSecond: perSec, hardware: best.model?.hardware ?? best.hardware ?? null, typicalUsd: dollars(best.p50price), source: 'model page' };
  return null;
}

const fmt = (v: number) => {
  if (v >= 0.01) return `$${(Math.round(v * 1000) / 1000).toString().replace(/(\.\d\d)0$/, '$1')}`;
  return `$${Number(v.toPrecision(3))}`;
};
const unitWord = (u: PriceUnit) => u.metric === 'image_input_megapixel_count' ? 'per input MP' : u.metric === 'image_output_megapixel_count' ? 'per output MP'
  : u.metric === 'run_count' ? 'per run' : u.metric === 'image_output_count' ? 'per output image' : u.label;
/** "$0.025 per output image", "$0.015 per run + $0.015 per input MP + $0.015 per output MP", "by time · about $0.018 a run ($0.00115/s on A100 (40GB))". */
export function priceLine(p: PriceInfo | null | undefined) {
  if (!p || p.kind === 'unknown') return 'price unknown';
  if (p.kind === 'per-unit') return p.units.map(u => `${fmt(u.usd)} ${unitWord(u)}`).join(' + ');
  const hw = p.hardware ? ` on ${p.hardware}` : '';
  return p.typicalUsd != null ? `by time · about ${fmt(p.typicalUsd)} a run (${fmt(p.usdPerSecond)}/s${hw})` : `by time · ${fmt(p.usdPerSecond)}/s${hw}`;
}

export type CostCtx = { outMp: number; inMp: number; scale?: number };
export type EstOpts = { timeEstSec: number; unknownUsd: number };
/** Estimate of one prediction (doubles, left to right). */
export function estimateOne(p: PriceInfo, c: CostCtx, o: EstOpts) {
  if (p.kind === 'per-unit') return p.units.reduce((a, u) => a + u.usd * unitsFor(u.metric, c), 0);
  if (p.kind === 'per-second') {
    const k = c.scale && c.scale > 2 ? (c.scale / 2) ** 2 : 1;
    return (p.typicalUsd ?? p.usdPerSecond * o.timeEstSec) * k;
  }
  return o.unknownUsd;
}
function unitsFor(metric: string, c: CostCtx) {
  if (metric === 'image_output_megapixel_count') return c.outMp;
  if (metric === 'image_input_megapixel_count') return c.inMp;
  return 1;
}
const num = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) && v >= 0 ? v : typeof v === 'string' && v.trim() && Number.isFinite(Number(v)) && Number(v) >= 0 ? Number(v) : null);
/**
 * The exact cost of one prediction: Replicate's own dollar figure; per unit: its billing counts (else the measured
 * units); by time: predict_time × the price per second. `estimated: true` when it could only settle on the estimate.
 */
export function exactOne(p: PriceInfo, metrics: Record<string, unknown> | null | undefined, measured: CostCtx, o: EstOpts): { usd: number; estimated: boolean } {
  const m = metrics ?? {};
  const usd = num(m.cost_usd) ?? num(m.cost);
  if (usd != null) return { usd, estimated: false };
  if (p.kind === 'per-unit') return { usd: p.units.reduce((a, u) => a + u.usd * (num(m[u.metric]) ?? unitsFor(u.metric, measured)), 0), estimated: false };
  if (p.kind === 'per-second') {
    const t = num(m.predict_time);
    if (t != null) return { usd: t * p.usdPerSecond, estimated: false };
  }
  return { usd: estimateOne(p, measured, o), estimated: true };
}
