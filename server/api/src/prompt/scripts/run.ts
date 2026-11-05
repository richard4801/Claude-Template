// The script runner (plans/prompt-scripts.md §2): inputs → rules → blocks → the assembled prompt. Pure and deterministic.
import { fill } from '../library.js';
import { COND_OPS, type Cond, type InputDef, type InputValue, type Inputs, type Item, type Rule, type Script, type ScriptPart, type ScriptResult } from './types.js';

export type RunOptions = {
  inputs: Inputs;
  /** Placeholder values supplied by the code (her name, look, image ranges …). Never the user's words. */
  vars?: Record<string, string | number | null | undefined>;
  /** The user's own words. Only `user` sections see them, as {direction}; system blocks never do. */
  user?: { direction?: string | null };
  /** Block texts by library key (the studio's resolved prompt library). */
  texts: Record<string, string>;
  /** The studio's rules for this script (default: the script's own). */
  rules?: Rule[];
};

/** The user's text as it goes into the prompt: one line (it can't start a fake section), trimmed, no stray braces. */
export const userText = (s: string | null | undefined) => (s ?? '').replace(/[\r\n\t]+/g, ' ').replace(/\s{2,}/g, ' ').trim();

const itemValue = (item: Item | null, name: string) => (item ? item[name] : undefined);
function valueOf(c: Cond, inputs: Inputs, item: Item | null): InputValue | undefined {
  return c.input.startsWith('item.') ? itemValue(item, c.input.slice(5)) : inputs[c.input];
}

export function condHolds(c: Cond, inputs: Inputs, item: Item | null = null): boolean {
  const v = valueOf(c, inputs, item);
  const list = Array.isArray(v) ? (v as unknown[]) : null;
  switch (c.op) {
    case 'is': return v === c.value || (v == null && c.value === false);
    case 'isNot': return !(v === c.value || (v == null && c.value === false));
    case 'in': return Array.isArray(c.value) && c.value.includes(String(v));
    case 'notIn': return Array.isArray(c.value) && !c.value.includes(String(v));
    case 'atLeast': return typeof v === 'number' && typeof c.value === 'number' && v >= c.value;
    case 'atMost': return typeof v === 'number' && typeof c.value === 'number' && v <= c.value;
    case 'has': return !!list && list.includes(c.value as never);
    case 'hasNot': return !list || !list.includes(c.value as never);
    case 'empty': return v == null || (typeof v === 'string' ? !v.trim() : list ? list.length === 0 : false);
    case 'notEmpty': return !(v == null || (typeof v === 'string' ? !v.trim() : list ? list.length === 0 : false));
  }
  return false;
}

const ruleOn = (r: Rule, inputs: Inputs, item: Item | null) =>
  r.enabled !== false && !(r.optional && inputs.presets === false) && r.when.every(c => condHolds(c, inputs, item));

const itemVars = (item: Item | null) => item
  ? Object.fromEntries(Object.entries(item).map(([k, v]) => [k, Array.isArray(v) ? v.join(', ') : v == null ? '' : String(v)])) : {};

export function runScript(script: Script, o: RunOptions): ScriptResult {
  const rules = o.rules ?? script.rules;
  const inputs = o.inputs;
  // System values: the user's words are never among them, whatever the caller passed.
  const vars: Record<string, string | number | null | undefined> = { ...(o.vars ?? {}) };
  delete vars.direction;
  const fired: string[] = [];
  const render = (key: string, v: Record<string, unknown>) => fill(o.texts[key] ?? '', v as Record<string, string>).trim();

  // 1. Placeholder values chosen by rules ("@name"): the first matching rule wins.
  for (const slot of script.values ?? []) {
    const r = rules.find(x => x.target === `@${slot.name}` && ruleOn(x, inputs, null));
    if (!r) { if (vars[slot.name] == null) vars[slot.name] = ''; continue; }
    fired.push(r.id);
    const t = render(r.block, vars);
    vars[slot.name] = t ? `${slot.prefix ?? ''}${t}` : '';
  }

  // 2. Sections in order; an `each` section repeats per item.
  const parts: ScriptPart[] = [];
  const direction = userText(o.user?.direction);
  for (const s of script.sections) {
    const items: (Item | null)[] = s.each ? ((inputs[s.each] as Item[] | undefined) ?? []) : [null];
    for (const item of items) {
      let matched = rules.filter(r => r.target === s.id && ruleOn(r, inputs, item));
      if (s.kind === 'user' && !direction) matched = [];
      if (s.pick === 'first') matched = matched.slice(0, 1);
      const v = { ...vars, ...itemVars(item), ...Object.fromEntries(Object.entries(s.alias ?? {}).map(([k, from]) => [k, vars[from] ?? ''])), ...(s.kind === 'user' ? { direction } : {}) };
      const texts = matched.map(r => ({ id: r.id, text: render(r.block, v) })).filter(x => x.text);
      if (!texts.length) continue;
      fired.push(...texts.map(x => x.id));
      parts.push({ section: s.id, layer: s.layer ?? s.id, kind: s.kind, text: texts.map(x => x.text).join(s.join ?? ' '), rules: texts.map(x => x.id) });
    }
  }
  return { script: script.id, parts, text: assemble(script, parts), fired, removed: [] };
}

/** The final text: one line per part, or the video models' "heading:\nbody" blocks. */
export function assemble(script: Script, parts: ScriptPart[]): string {
  if (script.format === 'lines') return parts.map(p => p.text).join('\n');
  const chunks: string[] = [];
  for (const p of parts) {
    const s = script.sections.find(x => x.id === p.section)!;
    if (s.heading || !chunks.length) chunks.push(s.heading ? `${s.heading}\n${p.text}` : p.text);
    else chunks[chunks.length - 1] += `\n${p.text}`;
  }
  return chunks.length ? `${chunks.join('\n\n')}\n` : '';
}

// ------------------------------------------------------------------------------------------------ owner rule edits
/** Library keys the owner may use in this script's rules. */
export const scriptBlocks = (s: Script) => s.blocks ?? [...new Set(s.rules.map(r => r.block))];
export const ruleTargets = (s: Script) => [...s.sections.map(x => x.id), ...(s.values ?? []).map(v => `@${v.name}`)];
const MAX_RULES = 60, MAX_CONDS = 8;
const same = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);

function inputFor(s: Script, name: string, target: string): InputDef | undefined {
  if (!name.startsWith('item.')) return s.inputs.find(i => i.name === name);
  const sec = s.sections.find(x => x.id === target);
  if (!sec?.each) return undefined;
  return s.inputs.find(i => i.name === sec.each)?.fields?.find(f => f.name === name.slice(5));
}

/** Why a condition is wrong, or null. Messages are shown as-is in the editor. */
function condError(s: Script, c: Cond, target: string): string | null {
  if (!c || typeof c !== 'object') return 'Each condition needs an input, a test and a value';
  const def = inputFor(s, String(c.input), target);
  if (!def) return `Unknown input "${c.input}"`;
  const op = COND_OPS.find(o => o.id === c.op);
  if (!op || !op.types.includes(def.type)) return `"${def.label}" can't use the test "${c.op}"`;
  const opts = def.options?.map(o => o.id);
  switch (c.op) {
    case 'empty': case 'notEmpty': return null;
    case 'in': case 'notIn':
      if (!Array.isArray(c.value) || !c.value.length || !c.value.every(v => opts?.includes(v))) return `Pick one or more of ${opts?.join(', ')} for "${def.label}"`;
      return null;
    case 'has': case 'hasNot':
      if (typeof c.value !== 'string' || (opts && !opts.includes(c.value))) return `Pick one of ${opts?.join(', ')} for "${def.label}"`;
      return null;
    case 'atLeast': case 'atMost': return typeof c.value === 'number' && Number.isFinite(c.value) ? null : `"${def.label}" needs a number`;
    default:
      if (def.type === 'bool') return typeof c.value === 'boolean' ? null : `"${def.label}" is yes or no`;
      if (def.type === 'number') return typeof c.value === 'number' ? null : `"${def.label}" needs a number`;
      if (def.type === 'enum') return typeof c.value === 'string' && opts?.includes(c.value) ? null : `Pick one of ${opts?.join(', ')} for "${def.label}"`;
      return typeof c.value === 'string' && c.value.length <= 200 ? null : `"${def.label}" needs a short text`;
  }
}

/** Why a rule list can't be saved for `script`, or null. */
export function validateRules(s: Script, rules: unknown): string | null {
  if (!Array.isArray(rules)) return 'Send the rules as a list';
  if (rules.length > MAX_RULES) return `At most ${MAX_RULES} rules`;
  const ids = new Set<string>(), targets = ruleTargets(s), blocks = scriptBlocks(s);
  for (const r of rules as Rule[]) {
    if (!r || typeof r !== 'object' || typeof r.id !== 'string' || !/^[A-Za-z0-9._-]{1,60}$/.test(r.id)) return 'Each rule needs an id';
    if (ids.has(r.id)) return `Two rules are called "${r.id}"`;
    ids.add(r.id);
    if (typeof r.label !== 'string' || !r.label.trim() || r.label.length > 120) return `Give rule "${r.id}" a short name`;
    if (!targets.includes(r.target)) return `Rule "${r.label}": unknown place "${r.target}"`;
    if (!blocks.includes(r.block)) return `Rule "${r.label}": this script can't use the block "${r.block}"`;
    if (!Array.isArray(r.when) || r.when.length > MAX_CONDS) return `Rule "${r.label}": at most ${MAX_CONDS} conditions`;
    for (const c of r.when) { const e = condError(s, c, r.target); if (e) return `Rule "${r.label}": ${e}`; }
    if (r.enabled != null && typeof r.enabled !== 'boolean') return `Rule "${r.label}": on is yes or no`;
  }
  for (const d of s.rules.filter(x => x.locked)) {
    const r = (rules as Rule[]).find(x => x.id === d.id);
    if (!r) return `"${d.label}" is required and can't be removed`;
    if (r.enabled === false || r.target !== d.target || r.block !== d.block || !same(r.when, d.when) || !!r.optional !== !!d.optional || !r.locked)
      return `"${d.label}" is locked: only its text can be changed (Settings → Prompts → its block)`;
  }
  return null;
}

/** A saved rule list, cleaned: only the fields the runner reads. */
export const cleanRules = (rules: Rule[]): Rule[] => rules.map(r => ({
  id: r.id, label: r.label.trim(), target: r.target, when: r.when.map(c => ({ input: c.input, op: c.op, ...(c.value !== undefined ? { value: c.value } : {}) })),
  block: r.block, ...(r.optional ? { optional: true } : {}), ...(r.locked ? { locked: true } : {}), ...(r.enabled === false ? { enabled: false } : {}),
}));

export type SavedRules = { rules: Rule[]; knownDefaults: string[] };
/**
 * The studio's rules: its saved list, plus any default rule added to the script after it was saved (placed after the
 * default rule before it). A saved list that no longer validates (the script changed) falls back to the defaults.
 */
export function resolveRules(s: Script, saved: SavedRules | null | undefined): { rules: Rule[]; overridden: boolean; stale: boolean } {
  if (!saved) return { rules: s.rules, overridden: false, stale: false };
  if (validateRules(s, saved.rules) != null) return { rules: s.rules, overridden: false, stale: true };
  const out = [...saved.rules];
  const known = new Set(saved.knownDefaults);
  s.rules.forEach((d, i) => {
    if (known.has(d.id) || out.some(r => r.id === d.id)) return;
    const prev = s.rules.slice(0, i).reverse().find(p => out.some(r => r.id === p.id));
    const at = prev ? out.findIndex(r => r.id === prev.id) + 1 : 0;
    out.splice(at, 0, d);
  });
  return { rules: out, overridden: true, stale: false };
}
