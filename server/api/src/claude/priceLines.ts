// Price lines for Approve cards (claude/cards.ts, suite/breakdown.ts). A leaf module: no imports.
export type PriceLine = { label: string; usd: number };

const r2 = (v: number) => Math.round(v * 100) / 100;
/** Price lines that add up to the total exactly (the rounding difference goes on the biggest line). */
export function balance(lines: PriceLine[], total: number): PriceLine[] {
  const kept = lines.filter(l => l.usd > 0.004).map(l => ({ label: l.label, usd: r2(l.usd) }));
  if (!kept.length) return [];
  const diff = r2(r2(total) - kept.reduce((a, l) => a + l.usd, 0));
  if (diff !== 0) { const big = kept.reduce((m, l) => (l.usd > m.usd ? l : m)); big.usd = r2(big.usd + diff); }
  return kept;
}
