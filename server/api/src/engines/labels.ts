// One display name per model (owner 2026-11-11: "Make sure each provider has their name on their models so it doesn't
// mix up with each other"). Every model label MUSE shows reads "<Model> · <Provider>" ("MiniMax H3 · Higgsfield",
// "MiniMax H3 · Replicate"), built here and nowhere else: /v1/engines, the Suite catalog, custom (own-key) models, the
// shot plan's notes and refusals, and Claude's tools all call modelLabel / labelList, and the apps show what they get.
// The 4c member rule (engines/members.ts) still decides whether members see the provider: while the studio hides
// provider names, a member gets the bare model name, and models that would then look the same get "· Option 1/2/…".

/** The provider company's name as people see it. */
const PROVIDERS: Record<string, string> = {
  replicate: 'Replicate', fal: 'fal', higgsfield: 'Higgsfield', muapi: 'Muapi', runpod: 'MUSE', byo: 'Custom', assemblyai: 'AssemblyAI', mock: 'Test',
};
export const providerLabel = (p: string) => PROVIDERS[p] ?? (p ? p.charAt(0).toUpperCase() + p.slice(1) : p);

/** Old suffixes that named the provider inside the model's own name: "MiniMax H3 (Higgsfield)", "SeedVR2 (own GPU)". */
const SUFFIX = new RegExp(`\\s*(?:\\((?:${[...Object.values(PROVIDERS), 'own GPU'].join('|')})\\)|·\\s*(?:${Object.values(PROVIDERS).join('|')}))\\s*$`, 'i');

/** A model's name without any provider in it ("MiniMax H3 (Higgsfield)" → "MiniMax H3"). */
export function baseName(name: string): string {
  let n = name.trim(), prev = '';
  while (n !== prev) { prev = n; n = n.replace(SUFFIX, '').trim(); }
  return n || name.trim();
}

/** "<Model> · <Provider>": the one label for a model wherever it is shown. Without a provider: the bare name. */
export function modelLabel(name: string, provider?: string | null): string {
  const base = baseName(name);
  return provider ? `${base} · ${providerLabel(provider)}` : base;
}

export type Labelled = { name: string; provider?: string | null; providerName?: string };
export type LabelFields = { name: string; label: string; providerName?: string };

/**
 * The display fields for a list of models shown together: `name` = the model's own name, `label` = what to show,
 * `providerName` = the provider (only when shown). Labels in one list are always distinct: same model on two providers
 * differs by provider; the rare same name on one provider gets " (2)"; with providers hidden (members, 4c switch off),
 * models that share a name get "· Option 1", "· Option 2" in list order, and `name` carries that too.
 */
export function labelList<T extends Labelled>(list: T[], o: { showProviders: boolean }): (Omit<T, 'providerName' | 'name'> & LabelFields)[] {
  const first = list.map(e => {
    const base = baseName(e.name);
    return o.showProviders && e.provider ? { base, label: modelLabel(base, e.provider), providerName: providerLabel(e.provider) } : { base, label: base };
  });
  const count = new Map<string, number>();
  for (const f of first) count.set(f.label.toLowerCase(), (count.get(f.label.toLowerCase()) ?? 0) + 1);
  const seen = new Map<string, number>();
  return list.map((e, i) => {
    const f = first[i]!, key = f.label.toLowerCase(), n = (seen.get(key) ?? 0) + 1;
    seen.set(key, n);
    const { providerName: _p, name: _n, ...rest } = e;
    if ((count.get(key) ?? 0) < 2) return { ...rest, name: f.base, label: f.label, ...(f.providerName ? { providerName: f.providerName } : {}) } as Omit<T, 'providerName' | 'name'> & LabelFields;
    if (f.providerName) return { ...rest, name: f.base, label: n === 1 ? f.label : `${f.label} (${n})`, providerName: f.providerName } as Omit<T, 'providerName' | 'name'> & LabelFields;
    const label = `${f.base} · Option ${n}`;
    return { ...rest, name: label, label } as Omit<T, 'providerName' | 'name'> & LabelFields;
  });
}

/**
 * Text written for the owner (plan notes, refusals) as a member with provider names hidden should read it: each full
 * "<Model> · <Provider>" label is replaced by what that member is shown for the model.
 */
export function relabelText(text: string, swaps: { from: string; to: string }[]): string {
  let out = text;
  for (const s of [...swaps].sort((a, b) => b.from.length - a.from.length)) if (s.from !== s.to) out = out.split(s.from).join(s.to);
  return out;
}
