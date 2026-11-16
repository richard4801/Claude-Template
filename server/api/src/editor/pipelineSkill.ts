// The Edit pipeline skill (owner idea, 2026-11-16): a self-improving how-to for editing that MUSE's Claude reads at the
// start of an edit (core always, technique pages on demand), logs against while it works, and improves after each edit.
// - Versioned: every change is a new immutable version with a changelog line (what, why, source edit); any version can
//   be rolled back to (a rollback is itself a new version, so nothing is ever lost).
// - Small changes apply at once; big ones (changing or removing a core rule, deleting or retiring a technique page,
//   touching an existing house-style entry, editing a proven page, or contradicting one) wait for the owner's OK.
// - Technique pages are scored from evidence, one vote per edit: trial → proven after PROVEN_AFTER edits it worked in;
//   failing in RETIRE_AFTER edits in a row proposes retiring it (a big change). Proven + repeatable → "make this a
//   template" hint (edit_template_save); never created automatically.
// - House style: the owner's reactions (pipeline_taste), folded in by the proposal step.
// Not a third memory: the person's memory (claude/memory.ts, playbook_rules: facts and preferences, enforced on edits)
// stays the one memory; this is the procedure. House style never copies a rule already in memory. Owner only, free,
// credentials redacted from every text.
import type { FastifyInstance } from 'fastify';
import { and, asc, desc, eq, inArray, isNull } from 'drizzle-orm';
import type { AuthUser, Ctx } from '../ctx.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { compact, uid } from '../lib/util.js';
import { editCorrections, playbookRules } from './learnSchema.js';
import { editSessions } from './schema.js';
import { pipelineLogs, pipelineProposals, pipelineReactions, pipelineSkillVersions } from './pipelineSchema.js';
import { redactCredentials } from './templatePacks.js';
import type { EditTool } from './mcpTools.js';
import { uiLine, ownChat } from '../claude/chatTools.js';

export const PIPELINE_LIMITS = {
  coreChars: 6000, pageChars: 4000, titleChars: 80, pages: 80, styleEntries: 100, styleChars: 300, whyChars: 300,
  changesPerProposal: 20, logEntriesPerEdit: 200, logEntryChars: 1000, reactionChars: 300, evidencePerPage: 50,
} as const;
/** A technique page becomes proven after working in this many different edits. */
export const PROVEN_AFTER = 3;
/** Failing in this many different edits in a row proposes retiring a page. */
export const RETIRE_AFTER = 2;
/** Two texts at least this alike (content words) are the same lesson. */
export const DUPLICATE_AT = 0.8;

export const PLACEHOLDER_CORE = `# MUSE Edit Pipeline

The owner's pipeline is still being written. Until it is:
- Start from get_edit; change the edit in small undoable steps and say what each one does.
- Watch and listen before you judge timing, pacing or sound.
- Log each attempt with pipeline_log: what you tried, whether it worked, why, the settings.

## Learned
`;

// ------------------------------------------------------------------ the snapshot

export type Evidence = { editId: string; revision?: number; result: 'worked' | 'failed'; note: string; at: number };
export type Page = { name: string; title: string; body: string; evidence: Evidence[]; score: number; status: 'trial' | 'proven' | 'retired';
  repeatable?: boolean; createdAt: number; updatedAt: number };
export type StyleEntry = { id: string; text: string; sentiment: Sentiment; evidence: { editId: string; reaction: string; at: number }[] };
export type Snapshot = { core: string; pages: Page[]; houseStyle: StyleEntry[] };
export type Sentiment = 'like' | 'dislike' | 'neutral';
export type ChangeOp = 'core_add' | 'core_edit' | 'core_remove' | 'page_add' | 'page_edit' | 'page_evidence' | 'page_retire' | 'page_delete'
  | 'style_add' | 'style_edit' | 'style_remove';
export const CHANGE_OPS: readonly ChangeOp[] = ['core_add', 'core_edit', 'core_remove', 'page_add', 'page_edit', 'page_evidence', 'page_retire', 'page_delete',
  'style_add', 'style_edit', 'style_remove'];
/** One proposed change. `line` names a core rule (its words), `name` a page, `id` a house-style entry. */
export type Change = { op: ChangeOp; why: string; text?: string; line?: string; name?: string; title?: string; body?: string;
  result?: 'worked' | 'failed'; note?: string; revision?: number; repeatable?: boolean; id?: string; sentiment?: Sentiment;
  reactionIds?: number[]; contradicts?: string; editId?: string };
export type ChangelogLine = { what: string; why: string; editId?: string; kind: 'small' | 'big' | 'owner' | 'rollback' | 'seed' };

export const seedSnapshot = (): Snapshot => ({ core: PLACEHOLDER_CORE, pages: [], houseStyle: [] });
const clone = (s: Snapshot): Snapshot => JSON.parse(JSON.stringify(s)) as Snapshot;

// ------------------------------------------------------------------ words: duplicates and contradictions

const STOP = new Set(['a', 'an', 'the', 'and', 'or', 'to', 'of', 'in', 'on', 'at', 'for', 'with', 'is', 'are', 'be', 'it', 'its', 'this', 'that', 'by', 'as',
  'when', 'then', 'than', 'so', 'if', 'from', 'into', 'each', 'every', 'all', 'any', 'use', 'make', 'keep', 'up', 'do', 'does', 'should', 'must', 'we', 'you']);
const NEGATIONS = new Set(['not', 'never', 'no', 'dont', "don't", 'avoid', 'without', 'stop', 'nothing', 'none', 'cannot', 'cant', "can't", 'neither', 'nor']);
const OPPOSITES: [string, string][] = [['fast', 'slow'], ['faster', 'slower'], ['more', 'less'], ['longer', 'shorter'], ['long', 'short'], ['before', 'after'],
  ['add', 'remove'], ['always', 'never'], ['increase', 'decrease'], ['warm', 'cool'], ['warmer', 'cooler'], ['high', 'low'], ['higher', 'lower'],
  ['big', 'small'], ['bigger', 'smaller'], ['loud', 'quiet'], ['louder', 'quieter'], ['early', 'late'], ['earlier', 'later'], ['top', 'bottom'],
  ['above', 'below'], ['on', 'off'], ['in', 'out'], ['bright', 'dark'], ['brighter', 'darker'], ['hard', 'soft'], ['tight', 'loose']];
const OPP = new Map<string, string>(OPPOSITES.flatMap(([a, b]) => [[a, b], [b, a]] as [string, string][]));

const words = (s: string) => s.toLowerCase().replace(/[’']/g, '').match(/[a-z0-9]+(?:\.[0-9]+)?/g) ?? [];
const content = (s: string) => new Set(words(s).filter(w => !STOP.has(w) && !NEGATIONS.has(w)));
/** 0..1: how alike two texts are (content words, Jaccard; negations count). */
export function similarity(a: string, b: string): number {
  const na = a.trim().toLowerCase().replace(/\s+/g, ' '), nb = b.trim().toLowerCase().replace(/\s+/g, ' ');
  if (na === nb) return 1;
  const A = new Set(words(a).filter(w => !STOP.has(w))), B = new Set(words(b).filter(w => !STOP.has(w)));
  if (!A.size || !B.size) return 0;
  const inter = [...A].filter(w => B.has(w)).length;
  return inter / new Set([...A, ...B]).size;
}
const negated = (s: string) => words(s).filter(w => NEGATIONS.has(w)).length % 2 === 1;
/** Two texts about the same thing that say opposite things: one negated and the other not, or an opposite word. */
export function contradicts(a: string, b: string): boolean {
  const A = content(a), B = content(b);
  const shared = [...A].filter(w => B.has(w));
  // the same topic: at least two words in common, and most of the shorter text's words
  if (shared.length < 2 || shared.length / Math.min(A.size, B.size) < 0.5) return false;
  if (negated(a) !== negated(b)) return true;
  for (const w of A) { const o = OPP.get(w); if (o && B.has(o) && !A.has(o) && !B.has(w)) return true; }
  return false;
}

/** The rules of the core: its bullet and numbered lines (without the marker). */
export const coreRules = (core: string) => core.split('\n').map(l => l.trim()).filter(l => /^([-*]|\d+[.)])\s+/.test(l)).map(l => l.replace(/^([-*]|\d+[.)])\s+/, ''));
const findCoreLine = (core: string, line: string): string | null => {
  const rules = coreRules(core);
  const exact = rules.find(r => r.trim() === line.trim());
  if (exact) return exact;
  const scored = rules.map(r => ({ r, s: similarity(r, line) })).filter(x => x.s >= 0.6).sort((a, b) => b.s - a.s);
  return scored[0] && (scored.length === 1 || scored[0].s > scored[1]!.s) ? scored[0].r : null;
};
const replaceCoreLine = (core: string, rule: string, next: string | null) => {
  const lines = core.split('\n');
  const i = lines.findIndex(l => l.trim().replace(/^([-*]|\d+[.)])\s+/, '') === rule && /^\s*([-*]|\d+[.)])\s+/.test(l));
  if (i < 0) return core;
  if (next === null) lines.splice(i, 1); else lines[i] = lines[i]!.replace(/^(\s*([-*]|\d+[.)])\s+).*$/, `$1${next}`);
  return lines.join('\n');
};
const addCoreLine = (core: string, text: string) => {
  const base = core.replace(/\s+$/, '');
  return /(^|\n)## Learned\s*$/m.test(base) || /\n## Learned\n/.test(base + '\n') ? `${base}\n- ${text}\n` : `${base}\n\n## Learned\n- ${text}\n`;
};
export const slug = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 48);

// ------------------------------------------------------------------ scoring

/** Score and status from evidence: one vote per edit (its latest), proven after PROVEN_AFTER edits it worked in. */
export function rescore(p: Page): Page {
  const byEdit = new Map<string, Evidence>();
  for (const e of p.evidence) byEdit.set(e.editId, e);
  const votes = [...byEdit.values()];
  const wins = votes.filter(e => e.result === 'worked').length, losses = votes.length - wins;
  const status = p.status === 'retired' ? 'retired' : p.status === 'proven' || (wins >= PROVEN_AFTER && wins > losses) ? 'proven' : 'trial';
  return { ...p, score: wins - losses, status };
}
/** The page failed in the last RETIRE_AFTER different edits. */
export function failingRun(p: Page): boolean {
  const order: string[] = [], last = new Map<string, Evidence>();
  for (const e of p.evidence) { if (!last.has(e.editId)) order.push(e.editId); else { order.splice(order.indexOf(e.editId), 1); order.push(e.editId); } last.set(e.editId, e); }
  const tail = order.slice(-RETIRE_AFTER).map(id => last.get(id)!);
  return tail.length >= RETIRE_AFTER && tail.every(e => e.result === 'failed');
}

// ------------------------------------------------------------------ classify and apply

export type Classified = { kind: 'small' | 'big'; reason: string } | { kind: 'skip'; reason: string } | { kind: 'convert'; to: Change; reason: string };

/** Small or big, a duplicate to skip, or a change to turn into another (a page name that exists, a core at its budget). */
export function classify(s: Snapshot, c: Change): Classified {
  const page = c.name ? s.pages.find(p => p.name === c.name) : undefined;
  const proven = s.pages.filter(p => p.status === 'proven');
  const against = (text: string) => {
    if (c.contradicts) return `it contradicts ${c.contradicts}`;
    const rule = coreRules(s.core).find(r => contradicts(text, r));
    if (rule) return `it contradicts the core rule “${rule.slice(0, 80)}”`;
    const p = proven.find(p => p.name !== c.name && [p.title, ...p.body.split('\n')].some(l => l.trim() && contradicts(text, l)));
    if (p) return `it contradicts the proven technique “${p.title}”`;
    const st = s.houseStyle.find(e => contradicts(text, e.text));
    if (st) return `it contradicts the house style “${st.text.slice(0, 80)}”`;
    return null;
  };
  switch (c.op) {
    case 'core_edit': case 'core_remove': return { kind: 'big', reason: 'changes a core rule' };
    case 'page_delete': return { kind: 'big', reason: 'deletes a technique page' };
    case 'page_retire': return { kind: 'big', reason: 'retires a technique page' };
    case 'style_edit': case 'style_remove': return { kind: 'big', reason: 'changes an existing house-style entry' };
    case 'page_evidence': return { kind: 'small', reason: 'records how a technique did' };
    case 'core_add': {
      const dup = coreRules(s.core).find(r => similarity(r, c.text!) >= DUPLICATE_AT);
      if (dup) return { kind: 'skip', reason: `already in the core: “${dup.slice(0, 80)}”` };
      const why = against(c.text!);
      if (why) return { kind: 'big', reason: why };
      if (addCoreLine(s.core, c.text!).length > PIPELINE_LIMITS.coreChars) {
        return { kind: 'convert', reason: `the core is at its ${PIPELINE_LIMITS.coreChars}-character budget, so it goes to a page`,
          to: { ...c, op: 'page_add', name: uniqueName(s, slug(c.text!.split(/\s+/).slice(0, 6).join(' ')) || 'note'), title: c.text!.slice(0, PIPELINE_LIMITS.titleChars), body: c.text! } };
      }
      return { kind: 'small', reason: 'adds a core rule' };
    }
    case 'page_add': {
      if (page) return { kind: 'convert', reason: `page ${c.name} exists, so this edits it`, to: { ...c, op: 'page_edit' } };
      const dup = s.pages.find(p => p.status !== 'retired' && (similarity(p.body, c.body!) >= DUPLICATE_AT || similarity(p.title, c.title ?? '') >= 0.95));
      if (dup) return { kind: 'skip', reason: `the same as the page “${dup.title}” (${dup.name})` };
      const why = against(`${c.title ?? ''}\n${c.body}`) ?? c.body!.split('\n').map(l => l.trim() && against(l)).find(Boolean);
      if (why) return { kind: 'big', reason: why };
      return { kind: 'small', reason: 'adds a trial technique page' };
    }
    case 'page_edit': {
      if (!page) return { kind: 'skip', reason: `no page named ${c.name}` };
      if (page.status === 'proven') return { kind: 'big', reason: 'changes a proven technique' };
      if (page.status === 'retired') return { kind: 'big', reason: 'brings back a retired technique' };
      const why = c.body ? c.body.split('\n').map(l => l.trim() && against(l)).find(Boolean) : null;
      if (why) return { kind: 'big', reason: why };
      return { kind: 'small', reason: 'refines a trial technique' };
    }
    case 'style_add': {
      const dup = s.houseStyle.find(e => similarity(e.text, c.text!) >= DUPLICATE_AT);
      if (dup) return { kind: 'skip', reason: `already in house style: “${dup.text.slice(0, 80)}”` };
      // A folded reaction's "Avoid:" says it was disliked; its own words are what may go against a rule.
      const why = against(c.text!.replace(STYLE_PREFIX, ''));
      if (why) return { kind: 'big', reason: why };
      return { kind: 'small', reason: 'adds to house style' };
    }
  }
}
const uniqueName = (s: Snapshot, base: string) => { let n = base, i = 2; while (s.pages.some(p => p.name === n)) n = `${base}-${i++}`; return n; };

/** What a change does, as before → after text (for the owner's review). */
export function describe(s: Snapshot, c: Change): { target: string; before: string; after: string } {
  const page = c.name ? s.pages.find(p => p.name === c.name) : undefined;
  const style = c.id ? s.houseStyle.find(e => e.id === c.id) : undefined;
  switch (c.op) {
    case 'core_add': return { target: 'core', before: '', after: c.text! };
    case 'core_edit': return { target: 'core', before: (c.line && findCoreLine(s.core, c.line)) ?? c.line ?? '', after: c.text ?? '' };
    case 'core_remove': return { target: 'core', before: (c.line && findCoreLine(s.core, c.line)) ?? c.line ?? '', after: '' };
    case 'page_add': return { target: `page ${c.name}`, before: '', after: `${c.title}\n${c.body}` };
    case 'page_edit': return { target: `page ${c.name}`, before: page ? `${page.title}\n${page.body}` : '', after: `${c.title ?? page?.title ?? ''}\n${c.body ?? page?.body ?? ''}` };
    case 'page_evidence': return { target: `page ${c.name}`, before: page ? `${page.status}, score ${page.score}` : '', after: `${c.result}: ${c.note ?? ''}` };
    case 'page_retire': return { target: `page ${c.name}`, before: page ? `${page.status}, score ${page.score}` : '', after: 'retired' };
    case 'page_delete': return { target: `page ${c.name}`, before: page ? `${page.title}\n${page.body}` : '', after: '' };
    case 'style_add': return { target: 'house style', before: '', after: c.text! };
    case 'style_edit': return { target: 'house style', before: style?.text ?? '', after: c.text ?? '' };
    case 'style_remove': return { target: 'house style', before: style?.text ?? '', after: '' };
  }
}

const stale = (msg: string) => new ApiError(409, 'pipeline_stale', msg);

/** Applies one change to a snapshot (already classified and allowed). Throws when its target is gone or a limit is hit. */
export function applyChange(s: Snapshot, c: Change, now = Date.now()): { snapshot: Snapshot; what: string } {
  const n = clone(s);
  const page = c.name ? n.pages.find(p => p.name === c.name) : undefined;
  const needPage = () => { if (!page) throw stale(`No technique page named ${c.name} any more`); return page; };
  switch (c.op) {
    case 'core_add': {
      n.core = addCoreLine(n.core, c.text!);
      if (n.core.length > PIPELINE_LIMITS.coreChars) throw badRequest(`The core is at its ${PIPELINE_LIMITS.coreChars}-character budget · move detail into a page`);
      return { snapshot: n, what: `Core: added “${c.text}”` };
    }
    case 'core_edit': case 'core_remove': {
      const rule = c.line ? findCoreLine(n.core, c.line) : null;
      if (!rule) throw stale(`The core rule “${(c.line ?? '').slice(0, 80)}” isn't in the core any more`);
      n.core = replaceCoreLine(n.core, rule, c.op === 'core_remove' ? null : c.text!);
      if (n.core.length > PIPELINE_LIMITS.coreChars) throw badRequest(`The core is at its ${PIPELINE_LIMITS.coreChars}-character budget · move detail into a page`);
      return { snapshot: n, what: c.op === 'core_remove' ? `Core: removed “${rule}”` : `Core: “${rule}” → “${c.text}”` };
    }
    case 'page_add': {
      if (page) throw stale(`A page named ${c.name} exists`);
      if (n.pages.filter(p => p.status !== 'retired').length >= PIPELINE_LIMITS.pages) throw badRequest(`The skill holds up to ${PIPELINE_LIMITS.pages} technique pages · retire some first`);
      n.pages.push({ name: c.name!, title: c.title!, body: c.body!, evidence: [], score: 0, status: 'trial', createdAt: now, updatedAt: now });
      return { snapshot: n, what: `New trial technique “${c.title}” (${c.name})` };
    }
    case 'page_edit': {
      const p = needPage();
      if (c.title) p.title = c.title;
      if (c.body) p.body = c.body;
      if (typeof c.repeatable === 'boolean') p.repeatable = c.repeatable;
      if (p.status === 'retired') p.status = 'trial';
      p.updatedAt = now;
      return { snapshot: n, what: `Technique “${p.title}” (${p.name}) updated` };
    }
    case 'page_evidence': {
      const p = needPage();
      const before = p.status;
      p.evidence = [...p.evidence.filter(e => e.editId !== c.editId), compact({ editId: c.editId ?? 'unknown', revision: c.revision, result: c.result!, note: c.note ?? '', at: now }) as Evidence]
        .slice(-PIPELINE_LIMITS.evidencePerPage);
      if (typeof c.repeatable === 'boolean') p.repeatable = c.repeatable;
      Object.assign(p, rescore(p), { updatedAt: now });
      return { snapshot: n, what: `“${p.title}” ${c.result} in ${c.editId}${p.status !== before ? ` · now ${p.status}` : ''} (score ${p.score})` };
    }
    case 'page_retire': { const p = needPage(); p.status = 'retired'; p.updatedAt = now; return { snapshot: n, what: `Technique “${p.title}” retired` }; }
    case 'page_delete': { const p = needPage(); n.pages = n.pages.filter(x => x !== p); return { snapshot: n, what: `Technique “${p.title}” deleted` }; }
    case 'style_add': {
      if (n.houseStyle.length >= PIPELINE_LIMITS.styleEntries) throw badRequest(`House style holds up to ${PIPELINE_LIMITS.styleEntries} entries`);
      n.houseStyle.push({ id: uid('hs'), text: c.text!, sentiment: c.sentiment ?? 'neutral', evidence: [] });
      return { snapshot: n, what: `House style: “${c.text}”` };
    }
    case 'style_edit': case 'style_remove': {
      const e = n.houseStyle.find(x => x.id === c.id);
      if (!e) throw stale('That house-style entry isn\'t there any more');
      if (c.op === 'style_remove') { n.houseStyle = n.houseStyle.filter(x => x !== e); return { snapshot: n, what: `House style: removed “${e.text}”` }; }
      const was = e.text; e.text = c.text!;
      return { snapshot: n, what: `House style: “${was}” → “${c.text}”` };
    }
  }
}

// ------------------------------------------------------------------ checking what Claude sends

const red = (s: string) => redactCredentials(s).text;
const text = (v: unknown, field: string, max: number, required = true): string | undefined => {
  if (v === undefined || v === null || v === '') { if (required) throw badRequest(`${field}: required`); return undefined; }
  if (typeof v !== 'string' || !v.trim()) throw badRequest(`${field}: text`);
  if (v.length > max) throw badRequest(`${field}: at most ${max} characters`);
  return red(v.trim());
};
export function checkChange(raw: unknown, editId?: string): Change {
  if (!raw || typeof raw !== 'object') throw badRequest('changes: [{op, why, …}]');
  const r = raw as Record<string, unknown>;
  if (!CHANGE_OPS.includes(r.op as ChangeOp)) throw badRequest(`op: one of ${CHANGE_OPS.join(', ')}`);
  const op = r.op as ChangeOp;
  const c: Change = { op, why: text(r.why, 'why', PIPELINE_LIMITS.whyChars)!, ...(editId ? { editId } : {}) };
  const name = () => { const nm = text(r.name, 'name', 48)!; if (!/^[a-z0-9][a-z0-9-]{0,47}$/.test(nm)) throw badRequest('name: a page name (lower case, digits, dashes)'); return nm; };
  if (op === 'core_add' || op === 'style_add') c.text = text(r.text, 'text', op === 'core_add' ? 400 : PIPELINE_LIMITS.styleChars);
  if (op === 'core_edit') { c.line = text(r.line, 'line', 400); c.text = text(r.text, 'text', 400); }
  if (op === 'core_remove') c.line = text(r.line, 'line', 400);
  if (op === 'page_add') { c.name = typeof r.name === 'string' && r.name ? name() : slug(String(r.title ?? '')) || 'technique'; c.title = text(r.title, 'title', PIPELINE_LIMITS.titleChars); c.body = text(r.body, 'body', PIPELINE_LIMITS.pageChars); }
  if (op === 'page_edit') { c.name = name(); c.title = text(r.title, 'title', PIPELINE_LIMITS.titleChars, false); c.body = text(r.body, 'body', PIPELINE_LIMITS.pageChars, false);
    if (!c.title && !c.body && typeof r.repeatable !== 'boolean') throw badRequest('page_edit: title, body or repeatable'); }
  if (op === 'page_evidence') { c.name = name(); if (r.result !== 'worked' && r.result !== 'failed') throw badRequest('result: worked or failed'); c.result = r.result; c.note = text(r.note, 'note', 300, false) ?? '';
    if (typeof r.revision === 'number') c.revision = r.revision; }
  if (op === 'page_retire' || op === 'page_delete') c.name = name();
  if (op === 'style_edit') { c.id = text(r.id, 'id', 40); c.text = text(r.text, 'text', PIPELINE_LIMITS.styleChars); }
  if (op === 'style_remove') c.id = text(r.id, 'id', 40);
  if (typeof r.repeatable === 'boolean') c.repeatable = r.repeatable;
  if (r.sentiment === 'like' || r.sentiment === 'dislike' || r.sentiment === 'neutral') c.sentiment = r.sentiment;
  if (Array.isArray(r.reactionIds)) c.reactionIds = r.reactionIds.filter((x): x is number => Number.isInteger(x)).slice(0, 20);
  if (r.contradicts !== undefined) c.contradicts = text(r.contradicts, 'contradicts', 120, false);
  return c;
}

const LIKE = /\b(love|loved|great|perfect|yes|nice|good|like|likes|liked|beautiful|amazing|keep|exactly|better)\b/i;
const DISLIKE = /\b(too|don'?t|hate|no|ugly|bad|wrong|less|worse|boring|annoying|cheesy|stop|not)\b/i;
export const sentimentOf = (s: string): Sentiment => (DISLIKE.test(s) ? 'dislike' : LIKE.test(s) ? 'like' : 'neutral');
/** A reaction as a house-style line when Claude gave none: the owner's words, with what they were about. */
const STYLE_PREFIX = /^(Avoid|Owner likes|Owner noted):\s*/;
export const styleLine = (reaction: string, context: string, sentiment: Sentiment) =>
  `${sentiment === 'dislike' ? 'Avoid' : sentiment === 'like' ? 'Owner likes' : 'Owner noted'}: “${reaction}”${context ? ` (${context})` : ''}`.slice(0, PIPELINE_LIMITS.styleChars);

// ------------------------------------------------------------------ the service

const owner = (u: AuthUser) => { if (u.role !== 'owner') throw new ApiError(403, 'owner_only', 'The edit pipeline skill is the studio owner\'s'); };
type VersionRow = typeof pipelineSkillVersions.$inferSelect;
const isConflict = (e: unknown) => /23505|duplicate key|unique/i.test(`${(e as { code?: string }).code ?? ''} ${(e as Error).message ?? ''}`);

export type ProposeResult = {
  version: number; applied: { op: ChangeOp; target: string; what: string; why: string }[];
  pending: { id: string; op: ChangeOp; target: string; reason: string; before: string; after: string }[];
  skipped: { op: ChangeOp; reason: string }[]; folded: number; templateHints: { name: string; title: string; score: number }[]; summary: string;
};

export class PipelineSkill {
  constructor(private ctx: Ctx) {}
  private get db() { return this.ctx.db; }

  /** The newest version (the seed placeholder, made on first use). */
  async current(studioId: string): Promise<VersionRow> {
    const [row] = await this.db.select().from(pipelineSkillVersions).where(eq(pipelineSkillVersions.studioId, studioId)).orderBy(desc(pipelineSkillVersions.version)).limit(1);
    if (row) return row;
    try {
      const [r] = await this.db.insert(pipelineSkillVersions).values({ studioId, version: 1, snapshot: seedSnapshot() as unknown as Record<string, unknown>,
        changelog: [{ what: 'Started the edit pipeline skill (placeholder core)', why: 'first use', kind: 'seed' }], by: 'seed', createdAt: Date.now() }).returning();
      return r!;
    } catch (e) { if (!isConflict(e)) throw e; return this.current(studioId); }
  }
  /** Makes the next version from the newest one; retries when another change landed first. */
  private async commit(studioId: string, by: VersionRow['by'], fn: (s: Snapshot, version: number) => { snapshot: Snapshot; changelog: ChangelogLine[] } | null) {
    for (let i = 0; i < 4; i++) {
      const cur = await this.current(studioId);
      const out = fn(cur.snapshot as unknown as Snapshot, cur.version);
      if (!out || !out.changelog.length) return { row: cur, changed: false };
      if (out.snapshot.core.length > PIPELINE_LIMITS.coreChars) throw badRequest(`The core is at its ${PIPELINE_LIMITS.coreChars}-character budget · move detail into a page`);
      try {
        const [row] = await this.db.insert(pipelineSkillVersions).values({ studioId, version: cur.version + 1, snapshot: out.snapshot as unknown as Record<string, unknown>,
          changelog: out.changelog as unknown as Record<string, unknown>[], by, createdAt: Date.now() }).returning();
        void this.ctx.hub.emit(studioId, v => (v.role === 'owner' ? { type: 'claude', op: 'pipeline_skill', version: row!.version } : null));
        return { row: row!, changed: true };
      } catch (e) { if (!isConflict(e)) throw e; }
    }
    throw new ApiError(409, 'pipeline_busy', 'The skill changed several times at once · try again');
  }

  private async ownEdit(u: AuthUser, editId: unknown): Promise<string> {
    if (typeof editId !== 'string' || !/^[A-Za-z0-9_-]{1,80}$/.test(editId)) throw badRequest('editId: the edit session id (es_…)');
    const [s] = await this.db.select({ id: editSessions.id }).from(editSessions).where(and(eq(editSessions.id, editId), eq(editSessions.studioId, u.studioId)));
    if (!s) throw notFound('Edit session');
    return editId;
  }

  // ---------------------------------------------------------------- reading (progressive disclosure)
  async read(u: AuthUser, o: { page?: unknown; pages?: unknown } = {}) {
    owner(u);
    const cur = await this.current(u.studioId);
    const s = cur.snapshot as unknown as Snapshot;
    if (typeof o.page === 'string' && o.page) {
      const p = s.pages.find(x => x.name === o.page);
      if (!p) throw notFound('Technique page');
      return { version: cur.version, page: { name: p.name, title: p.title, status: p.status, score: p.score, repeatable: !!p.repeatable, body: p.body,
        evidence: p.evidence.slice(-10).map(e => compact({ editId: e.editId, result: e.result, note: e.note, at: e.at })) } };
    }
    const index = s.pages.filter(p => p.status !== 'retired' || o.pages === 'all').map(p => ({ name: p.name, title: p.title, status: p.status, score: p.score }));
    if (o.pages === true || o.pages === 'all') return { version: cur.version, pages: index };
    return { version: cur.version, core: s.core, houseStyle: s.houseStyle.map(e => ({ id: e.id, text: e.text })), pages: index,
      note: 'The core is the procedure: follow it. Open a technique page (page: name) only when the edit needs it. Proven pages worked in several edits; trial ones are still being tested.' };
  }

  // ---------------------------------------------------------------- logging and reactions
  async log(u: AuthUser, editId: unknown, entry: unknown) {
    owner(u);
    const id = await this.ownEdit(u, editId);
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) throw badRequest('entry: {tried, result, why?, settings?, ms?, technique?}');
    const e = entry as Record<string, unknown>;
    const result = ['worked', 'failed', 'partial', 'note'].includes(e.result as string) ? e.result as string : undefined;
    if (!result) throw badRequest('entry.result: worked, failed, partial or note');
    const clean = compact({ tried: text(e.tried, 'entry.tried', 400)!, result, why: text(e.why, 'entry.why', 400, false),
      settings: e.settings !== undefined ? red(JSON.stringify(e.settings)).slice(0, 600) : undefined,
      ms: typeof e.ms === 'number' && e.ms >= 0 ? Math.round(e.ms) : undefined,
      technique: typeof e.technique === 'string' && /^[a-z0-9][a-z0-9-]{0,47}$/.test(e.technique) ? e.technique : undefined,
      revision: typeof e.revision === 'number' ? e.revision : undefined });
    if (JSON.stringify(clean).length > PIPELINE_LIMITS.logEntryChars) throw badRequest(`entry: at most ${PIPELINE_LIMITS.logEntryChars} characters in all`);
    const n = (await this.db.select({ id: pipelineLogs.id }).from(pipelineLogs).where(and(eq(pipelineLogs.studioId, u.studioId), eq(pipelineLogs.editId, id)))).length;
    if (n >= PIPELINE_LIMITS.logEntriesPerEdit) throw badRequest(`An edit's log holds up to ${PIPELINE_LIMITS.logEntriesPerEdit} entries`);
    const [row] = await this.db.insert(pipelineLogs).values({ studioId: u.studioId, editId: id, entry: clean, createdAt: Date.now() }).returning();
    return { logged: row!.id, entries: n + 1 };
  }
  async logOf(u: AuthUser, editId: string) {
    return (await this.db.select().from(pipelineLogs).where(and(eq(pipelineLogs.studioId, u.studioId), eq(pipelineLogs.editId, editId))).orderBy(asc(pipelineLogs.id)))
      .map(r => ({ id: r.id, ...r.entry, at: r.createdAt }));
  }
  async taste(u: AuthUser, editId: unknown, reaction: unknown, context?: unknown, sentiment?: unknown) {
    owner(u);
    const id = await this.ownEdit(u, editId);
    const r = text(reaction, 'reaction', PIPELINE_LIMITS.reactionChars)!;
    const cx = text(context, 'context', 300, false) ?? '';
    const s: Sentiment = sentiment === 'like' || sentiment === 'dislike' || sentiment === 'neutral' ? sentiment : sentimentOf(r);
    const [row] = await this.db.insert(pipelineReactions).values({ studioId: u.studioId, editId: id, reaction: r, context: cx, sentiment: s, createdAt: Date.now() }).returning();
    return { recorded: row!.id, sentiment: s, note: 'It is folded into house style when you call pipeline_propose for this edit.' };
  }

  // ---------------------------------------------------------------- the proposal step
  /** Without changes: the material (log, reactions, corrections, the skill now). With changes: small ones apply as one new
   *  version, big ones wait for the owner; logged techniques get their evidence and reactions fold into house style. */
  async propose(u: AuthUser, editId: unknown, changes?: unknown): Promise<ProposeResult | Record<string, unknown>> {
    owner(u);
    const id = await this.ownEdit(u, editId);
    const log = await this.logOf(u, id);
    const reactions = await this.db.select().from(pipelineReactions).where(and(eq(pipelineReactions.studioId, u.studioId), eq(pipelineReactions.editId, id), isNull(pipelineReactions.foldedVersion)));
    if (changes === undefined) {
      const cur = await this.current(u.studioId);
      const s = cur.snapshot as unknown as Snapshot;
      const corrections = await this.db.select().from(editCorrections).where(and(eq(editCorrections.studioId, u.studioId), eq(editCorrections.sessionId, id))).orderBy(desc(editCorrections.createdAt)).limit(20);
      return { editId: id, version: cur.version, log, reactions: reactions.map(r => ({ id: r.id, reaction: r.reaction, context: r.context, sentiment: r.sentiment })),
        corrections: corrections.map(c => ({ area: c.area, what: c.what, kind: c.kind })),
        skill: { coreChars: s.core.length, coreBudget: PIPELINE_LIMITS.coreChars, core: s.core, pages: s.pages.map(p => ({ name: p.name, title: p.title, status: p.status, score: p.score })),
          houseStyle: s.houseStyle.map(e => ({ id: e.id, text: e.text })) },
        next: `Call pipeline_propose again with changes: [{op, why, …}] (ops: ${CHANGE_OPS.join(', ')}). page_evidence for each technique you used (worked/failed, one per edit); page_add for a new technique that worked (it starts as trial); core_add only for a short rule; style_add to phrase a reaction as house style (reactionIds). Logged techniques get their evidence and leftover reactions are folded in by themselves. Changing or removing core rules, retiring/deleting pages, changing house-style entries, editing proven pages and anything that contradicts them wait for the owner.` };
    }
    if (!Array.isArray(changes)) throw badRequest('changes: an array of {op, why, …}');
    if (changes.length > PIPELINE_LIMITS.changesPerProposal) throw badRequest(`changes: at most ${PIPELINE_LIMITS.changesPerProposal}`);
    const asked = changes.map(c => checkChange(c, id));
    // Logged techniques: one vote per page for this edit (its last outcome), unless Claude already sent page_evidence.
    const voted = new Set(asked.filter(c => c.op === 'page_evidence').map(c => c.name));
    const lastByPage = new Map<string, { result: 'worked' | 'failed'; why?: string; revision?: number }>();
    for (const e of log as Record<string, unknown>[]) if (typeof e.technique === 'string' && (e.result === 'worked' || e.result === 'failed'))
      lastByPage.set(e.technique, { result: e.result, why: e.why as string | undefined, revision: e.revision as number | undefined });
    const auto: Change[] = [...lastByPage].filter(([name]) => !voted.has(name)).map(([name, v]) => compact({ op: 'page_evidence' as const, name, result: v.result, note: v.why ?? 'from the edit log',
      revision: v.revision, why: 'logged during the edit', editId: id }));
    const memory = (await this.db.select({ text: playbookRules.text }).from(playbookRules).where(and(eq(playbookRules.studioId, u.studioId), isNull(playbookRules.userId)))).map(r => r.text);

    const result: ProposeResult = { version: 0, applied: [], pending: [], skipped: [], folded: 0, templateHints: [], summary: '' };
    const bigs: { change: Change; reason: string; d: ReturnType<typeof describe>; auto?: boolean }[] = [];
    const foldIds: number[] = [];
    const committed = await this.commit(u.studioId, 'claude', (start, version) => {
      let s = start;
      const log: ChangelogLine[] = [];
      result.applied = []; result.skipped = []; bigs.length = 0; foldIds.length = 0;
      const run = (c0: Change) => {
        let c = c0, k = classify(s, c);
        if (k.kind === 'convert') { c = k.to; const k2 = classify(s, c); k = k2.kind === 'convert' ? { kind: 'small', reason: k.reason } : k2; }
        if (k.kind === 'skip') { result.skipped.push({ op: c.op, reason: k.reason }); return; }
        if (k.kind === 'big') { bigs.push({ change: c, reason: k.reason, d: describe(s, c) }); return; }
        try {
          const out = applyChange(s, c);
          s = out.snapshot;
          log.push({ what: out.what, why: c.why, editId: id, kind: 'small' });
          result.applied.push({ op: c.op, target: describe(start, c).target, what: out.what, why: c.why });
        } catch (e) { if (!(e instanceof ApiError)) throw e; result.skipped.push({ op: c.op, reason: e.message }); }
      };
      for (const c of asked) {
        if (c.op === 'style_add' && memory.some(m => similarity(m, c.text!) >= DUPLICATE_AT)) { result.skipped.push({ op: c.op, reason: 'already in the owner\'s memory' }); for (const r of c.reactionIds ?? []) foldIds.push(r); continue; }
        run(c);
        if (c.op === 'style_add') for (const r of c.reactionIds ?? []) foldIds.push(r);
      }
      for (const c of auto) if (s.pages.some(p => p.name === c.name)) run(c);
      // Reactions Claude didn't phrase: fold them in as they were said (or add their evidence to the entry they repeat).
      for (const r of reactions) {
        if (foldIds.includes(r.id)) continue;
        foldIds.push(r.id);
        const line = styleLine(r.reaction, r.context, r.sentiment as Sentiment);
        if (memory.some(m => similarity(m, r.reaction) >= DUPLICATE_AT)) continue;
        const same = s.houseStyle.find(e => similarity(e.text, line) >= DUPLICATE_AT || similarity(e.text, r.reaction) >= DUPLICATE_AT);
        if (same) {
          // More evidence for an entry the owner already has: its words stay as they are, so this is small.
          s = clone(s);
          s.houseStyle.find(e => e.id === same.id)!.evidence.push({ editId: id, reaction: r.reaction, at: Date.now() });
          log.push({ what: `House style “${same.text.slice(0, 60)}”: the owner said it again`, why: 'owner reaction', editId: id, kind: 'small' });
          continue;
        }
        run({ op: 'style_add', text: line, sentiment: r.sentiment as Sentiment, why: 'owner reaction', editId: id });
        const e = s.houseStyle.find(x => x.text === line);
        if (e && !e.evidence.length) e.evidence.push({ editId: id, reaction: r.reaction, at: Date.now() });
      }
      // Reactions Claude phrased as style_add: their evidence goes on that entry.
      for (const c of asked) if (c.op === 'style_add') { const e = s.houseStyle.find(x => x.text === c.text); if (e && !e.evidence.length)
        for (const r of reactions.filter(x => c.reactionIds?.includes(x.id))) e.evidence.push({ editId: id, reaction: r.reaction, at: Date.now() }); }
      // Pages failing again and again: propose retiring them (big).
      for (const p of s.pages) if (p.status !== 'retired' && failingRun(p) && !bigs.some(b => b.change.op === 'page_retire' && b.change.name === p.name))
        bigs.push({ change: { op: 'page_retire', name: p.name, why: `failed in the last ${RETIRE_AFTER} edits it was used in`, editId: id }, reason: 'retires a technique page', d: describe(s, { op: 'page_retire', name: p.name, why: '' }), auto: true });
      result.folded = foldIds.length;
      result.templateHints = s.pages.filter(p => p.status === 'proven' && p.repeatable).map(p => ({ name: p.name, title: p.title, score: p.score }));
      result.version = version;
      return { snapshot: s, changelog: log };
    });
    result.version = committed.row.version;
    if (foldIds.length) await this.db.update(pipelineReactions).set({ foldedVersion: committed.row.version })
      .where(and(eq(pipelineReactions.studioId, u.studioId), inArray(pipelineReactions.id, foldIds)));
    // Big changes wait for the owner; the same change already waiting isn't asked twice.
    const waiting = await this.pendingRows(u.studioId);
    for (const b of bigs) {
      const twin = waiting.find(w => sameChange(stripMeta(w.change as Change), b.change));
      if (twin && b.auto) continue; // MUSE's own retire suggestion already waits: not news
      if (twin) { result.pending.push({ id: twin.id, op: b.change.op, target: b.d.target, reason: twin.reason, before: b.d.before, after: b.d.after }); continue; }
      const pid = uid('pp');
      await this.db.insert(pipelineProposals).values({ id: pid, studioId: u.studioId, editId: id, change: { ...b.change, describe: b.d } as unknown as Record<string, unknown>,
        reason: b.reason, status: 'pending', baseVersion: committed.row.version, createdAt: Date.now() });
      result.pending.push({ id: pid, op: b.change.op, target: b.d.target, reason: b.reason, before: b.d.before, after: b.d.after });
    }
    const small = result.applied.length, big = result.pending.length;
    result.summary = small || big ? `Updated the edit pipeline: ${small} small change${small === 1 ? '' : 's'}${big ? `, ${big} waiting for you` : ''}` : 'The edit pipeline is unchanged';
    if (result.templateHints.length) result.summary += ` · ${result.templateHints.length} proven technique${result.templateHints.length === 1 ? ' could be a template' : 's could be templates'}`;
    return result;
  }

  private pendingRows(studioId: string) {
    return this.db.select().from(pipelineProposals).where(and(eq(pipelineProposals.studioId, studioId), eq(pipelineProposals.status, 'pending'))).orderBy(asc(pipelineProposals.createdAt));
  }
  async pending(u: AuthUser) {
    owner(u);
    return (await this.pendingRows(u.studioId)).map(proposalView);
  }
  async decide(u: AuthUser, id: string, approve: boolean) {
    owner(u);
    const [p] = await this.db.select().from(pipelineProposals).where(and(eq(pipelineProposals.id, id), eq(pipelineProposals.studioId, u.studioId)));
    if (!p) throw notFound('Proposal');
    if (p.status !== 'pending') throw new ApiError(409, 'already_decided', `This change was already ${p.status}`);
    let version: number | undefined;
    if (approve) {
      const c = stripMeta(p.change as Change);
      const out = await this.commit(u.studioId, 'owner', s => {
        const r = applyChange(s, c);
        return { snapshot: r.snapshot, changelog: [{ what: r.what, why: `${c.why} (approved by the owner)`, ...(p.editId ? { editId: p.editId } : {}), kind: 'big' }] };
      });
      version = out.row.version;
    }
    const [row] = await this.db.update(pipelineProposals).set({ status: approve ? 'approved' : 'declined', decidedAt: Date.now(), ...(version ? { appliedVersion: version } : {}) })
      .where(eq(pipelineProposals.id, id)).returning();
    return { ...proposalView(row!), ...(version ? { version } : {}) };
  }

  // ---------------------------------------------------------------- versions, rollback, the owner's own edits
  async versions(u: AuthUser) {
    owner(u);
    await this.current(u.studioId);
    const rows = await this.db.select({ version: pipelineSkillVersions.version, changelog: pipelineSkillVersions.changelog, by: pipelineSkillVersions.by, createdAt: pipelineSkillVersions.createdAt })
      .from(pipelineSkillVersions).where(eq(pipelineSkillVersions.studioId, u.studioId)).orderBy(desc(pipelineSkillVersions.version)).limit(200);
    return rows;
  }
  private async at(studioId: string, version: number) {
    const [row] = await this.db.select().from(pipelineSkillVersions).where(and(eq(pipelineSkillVersions.studioId, studioId), eq(pipelineSkillVersions.version, version)));
    if (!row) throw notFound('Skill version');
    return row;
  }
  async version(u: AuthUser, version: number) {
    owner(u);
    const row = await this.at(u.studioId, version);
    return { version: row.version, by: row.by, createdAt: row.createdAt, changelog: row.changelog, snapshot: row.snapshot };
  }
  /** What a version changed from the one before it, section by section, before → after. */
  async diff(u: AuthUser, version: number) {
    owner(u);
    const b = await this.at(u.studioId, version);
    const a = version > 1 ? await this.at(u.studioId, version - 1) : null;
    return { version, changelog: b.changelog, changes: diffSnapshots(a ? a.snapshot as unknown as Snapshot : null, b.snapshot as unknown as Snapshot) };
  }
  async rollback(u: AuthUser, to: unknown) {
    owner(u);
    if (typeof to !== 'number' || !Number.isInteger(to) || to < 1) throw badRequest('version: a version number');
    const target = await this.at(u.studioId, to);
    const out = await this.commit(u.studioId, 'owner', (_s, cur) => {
      if (cur === to) return null;
      return { snapshot: target.snapshot as unknown as Snapshot, changelog: [{ what: `Rolled back to version ${to}`, why: 'the owner rolled back', kind: 'rollback' }] };
    });
    return { version: out.row.version, rolledBackTo: to, changed: out.changed };
  }
  /** Undo: back to the version before the newest. */
  async undo(u: AuthUser) {
    owner(u);
    const cur = await this.current(u.studioId);
    if (cur.version <= 1) throw badRequest('Nothing to undo');
    return this.rollback(u, cur.version - 1);
  }
  /** The owner (or the coordinator, as the owner) writes content directly: the core, pages, house style. */
  async setContent(u: AuthUser, b: Record<string, unknown>) {
    owner(u);
    const note = text(b.note, 'note', PIPELINE_LIMITS.whyChars, false) ?? 'written by the owner';
    const core = b.core === undefined ? undefined : text(b.core, 'core', PIPELINE_LIMITS.coreChars);
    const pages = b.pages === undefined ? undefined : (() => {
      if (!Array.isArray(b.pages) || b.pages.length > PIPELINE_LIMITS.pages) throw badRequest(`pages: up to ${PIPELINE_LIMITS.pages} {name, title, body, status?}`);
      return b.pages.map((p: Record<string, unknown>) => {
        const c = checkChange({ op: 'page_add', why: note, name: p?.name, title: p?.title, body: p?.body });
        return { name: c.name!, title: c.title!, body: c.body!, evidence: [], score: 0, status: p?.status === 'proven' ? 'proven' : 'trial', createdAt: Date.now(), updatedAt: Date.now() } as Page;
      });
    })();
    const style = b.houseStyle === undefined ? undefined : (() => {
      if (!Array.isArray(b.houseStyle) || b.houseStyle.length > PIPELINE_LIMITS.styleEntries) throw badRequest(`houseStyle: up to ${PIPELINE_LIMITS.styleEntries} lines`);
      return b.houseStyle.map((t: unknown) => ({ id: uid('hs'), text: text(t, 'houseStyle[]', PIPELINE_LIMITS.styleChars)!, sentiment: 'neutral' as const, evidence: [] }));
    })();
    if (core === undefined && !pages && !style) throw badRequest('core, pages or houseStyle');
    const out = await this.commit(u.studioId, 'owner', s => {
      const n: Snapshot = { core: core ?? s.core, pages: pages ? mergePages(s.pages, pages) : s.pages, houseStyle: style ?? s.houseStyle };
      const what = [core !== undefined && 'core', pages && `${pages.length} page(s)`, style && 'house style'].filter(Boolean).join(', ');
      return { snapshot: n, changelog: [{ what: `The owner wrote: ${what}`, why: note, kind: 'owner' }] };
    });
    return { version: out.row.version };
  }

  /** The whole picture for Settings → Claude → Edit pipeline skill. */
  async state(u: AuthUser) {
    owner(u);
    const cur = await this.current(u.studioId);
    const s = cur.snapshot as unknown as Snapshot;
    return { version: cur.version, updatedAt: cur.createdAt, by: cur.by, core: s.core, coreChars: s.core.length, coreBudget: PIPELINE_LIMITS.coreChars,
      pages: s.pages.map(p => ({ name: p.name, title: p.title, status: p.status, score: p.score, repeatable: !!p.repeatable, uses: new Set(p.evidence.map(e => e.editId)).size })),
      houseStyle: s.houseStyle.map(e => ({ id: e.id, text: e.text, sentiment: e.sentiment, times: e.evidence.length })),
      pending: (await this.pendingRows(u.studioId)).map(proposalView),
      templateHints: s.pages.filter(p => p.status === 'proven' && p.repeatable).map(p => ({ name: p.name, title: p.title, score: p.score })) };
  }

  /** The skill as Claude Code skill files (SKILL.md + reference pages), for the Mac to write into MUSE's own Claude config. */
  async skillFiles(u: AuthUser) {
    owner(u);
    const cur = await this.current(u.studioId);
    return { version: cur.version, files: skillFiles(cur.snapshot as unknown as Snapshot, cur.version) };
  }
}

/** The same change, whatever the key order (jsonb reorders keys) and whichever edit asked. */
const sameChange = (x: Change, y: Change) => { const k = (c: Change) => JSON.stringify(Object.entries({ ...c, editId: undefined, why: undefined }).filter(([, v]) => v !== undefined).sort(([a], [b]) => a.localeCompare(b))); return k(x) === k(y); };
const stripMeta = (c: Change): Change => { const { describe: _d, ...rest } = c as Change & { describe?: unknown }; return rest; };
const proposalView = (p: typeof pipelineProposals.$inferSelect) => {
  const c = p.change as Change & { describe?: { target: string; before: string; after: string } };
  return compact({ id: p.id, op: c.op, why: c.why, reason: p.reason, editId: p.editId ?? undefined, status: p.status, target: c.describe?.target, before: c.describe?.before ?? '', after: c.describe?.after ?? '',
    createdAt: p.createdAt, decidedAt: p.decidedAt ?? undefined, appliedVersion: p.appliedVersion ?? undefined });
};
const mergePages = (old: Page[], next: Page[]) => {
  const out = old.filter(p => !next.some(n => n.name === p.name));
  for (const n of next) { const was = old.find(p => p.name === n.name); out.push(was ? { ...was, title: n.title, body: n.body, updatedAt: n.updatedAt } : n); }
  return out;
};

export function diffSnapshots(a: Snapshot | null, b: Snapshot) {
  const out: { section: 'core' | 'page' | 'house style'; name: string; before: string; after: string }[] = [];
  if ((a?.core ?? '') !== b.core) out.push({ section: 'core', name: 'core', before: a?.core ?? '', after: b.core });
  const pages = new Set([...(a?.pages ?? []).map(p => p.name), ...b.pages.map(p => p.name)]);
  const show = (p?: Page) => (p ? `${p.title} [${p.status}, score ${p.score}]\n${p.body}` : '');
  for (const n of pages) { const x = a?.pages.find(p => p.name === n), y = b.pages.find(p => p.name === n); if (show(x) !== show(y)) out.push({ section: 'page', name: n, before: show(x), after: show(y) }); }
  const ids = new Set([...(a?.houseStyle ?? []).map(e => e.id), ...b.houseStyle.map(e => e.id)]);
  for (const id of ids) { const x = a?.houseStyle.find(e => e.id === id), y = b.houseStyle.find(e => e.id === id); if ((x?.text ?? '') !== (y?.text ?? '')) out.push({ section: 'house style', name: id, before: x?.text ?? '', after: y?.text ?? '' }); }
  return out;
}

export function skillFiles(s: Snapshot, version: number): { path: string; text: string }[] {
  const live = s.pages.filter(p => p.status !== 'retired');
  const head = `---\nname: muse-edit-pipeline\ndescription: MUSE's edit pipeline (version ${version}). Read at the start of every MUSE edit; open a reference page when the edit needs that technique. Written by MUSE from the server; edits here are overwritten.\n---\n\n`;
  const style = s.houseStyle.length ? `\n\n## House style (the owner's taste)\n${s.houseStyle.map(e => `- ${e.text}`).join('\n')}\n` : '';
  const index = live.length ? `\n\n## Technique pages\n${live.map(p => `- [${p.title}](reference/${p.name}.md) (${p.status}, score ${p.score})`).join('\n')}\n` : '';
  return [{ path: 'SKILL.md', text: `${head}${s.core.trim()}${style}${index}` },
    ...live.map(p => ({ path: `reference/${p.name}.md`, text: `# ${p.title}\n\nStatus: ${p.status} · score ${p.score}\n\n${p.body}\n` }))];
}

const one = new WeakMap<Ctx, PipelineSkill>();
export const pipelineOf = (ctx: Ctx) => { let p = one.get(ctx); if (!p) { p = new PipelineSkill(ctx); one.set(ctx, p); } return p; };

// ------------------------------------------------------------------ Claude's tools

const str = (d: string, max?: number) => ({ type: 'string', description: d, ...(max ? { maxLength: max } : {}) });
const EDIT_ID = { editId: str('The edit session (es_…)', 80), sessionId: str('The same as editId (filled in from the open edit)', 80) };
const editOf = (a: Record<string, unknown>) => a.editId ?? a.sessionId;
const CHANGE = { type: 'object', description: 'A change', properties: {
  op: { type: 'string', enum: [...CHANGE_OPS] }, why: str('What the edit showed (evidence)', 300), text: str('core_add / style_add / core_edit / style_edit: the words', 400),
  line: str('core_edit / core_remove: the core rule, as written', 400), name: str('A page name (lower-case-dashes)', 48), title: str('page_add / page_edit', 80),
  body: str('page_add / page_edit: the technique, step by step, with settings', 4000), result: { type: 'string', enum: ['worked', 'failed'] }, note: str('page_evidence: what happened', 300),
  revision: { type: 'number' }, repeatable: { type: 'boolean', description: 'This technique is a repeatable effect (a template candidate)' },
  id: str('style_edit / style_remove: the entry id', 40), sentiment: { type: 'string', enum: ['like', 'dislike', 'neutral'] },
  reactionIds: { type: 'array', items: { type: 'integer' }, description: 'style_add: the reactions it phrases' }, contradicts: str('Name the rule or page this goes against, if any', 120) },
  required: ['op', 'why'] };

export const PIPELINE_TOOLS: EditTool[] = [
  { name: 'pipeline_skill_read', title: 'Read the edit pipeline skill', scope: 'edit:read', readOnly: true, idempotent: true,
    description: 'The studio\'s edit pipeline skill: read its core (the procedure, with the owner\'s house style and the list of technique pages) at the start of every edit and follow it. page: one technique page in full (steps, settings, its evidence); pages: true lists them. Owner only, free.',
    inputSchema: { type: 'object', additionalProperties: false, properties: { page: str('A technique page name', 48), pages: { type: 'boolean', description: 'List the pages only' } } },
    run: (env, a) => pipelineOf(env.ctx).read(env.user, { page: a.page, pages: a.pages }) },
  { name: 'pipeline_log', title: 'Log an edit attempt', scope: 'edit:write',
    description: 'Logs what you just tried in this edit, as you work: tried (what), result (worked | failed | partial | note), why, settings (the values used), ms (how long), technique (the page name, when it was one: its score comes from these). Free; nothing changes in the edit.',
    inputSchema: { type: 'object', additionalProperties: false, properties: { ...EDIT_ID, entry: { type: 'object', properties: { tried: str('What you tried', 400), result: { type: 'string', enum: ['worked', 'failed', 'partial', 'note'] },
      why: str('Why it worked or not', 400), settings: { type: 'object' }, ms: { type: 'number' }, technique: str('A technique page name', 48), revision: { type: 'number' } }, required: ['tried', 'result'] } }, required: ['entry'] },
    run: (env, a) => pipelineOf(env.ctx).log(env.user, editOf(a), a.entry) },
  { name: 'pipeline_taste', title: 'Record the owner\'s reaction', scope: 'edit:write',
    description: 'Records how the owner reacted to the edit ("too fast", "love this transition") with what it was about (context: the part, the setting). It becomes house style when you call pipeline_propose. Free.',
    inputSchema: { type: 'object', additionalProperties: false, properties: { ...EDIT_ID, reaction: str('Their words', 300), context: str('What it was about', 300), sentiment: { type: 'string', enum: ['like', 'dislike', 'neutral'] } }, required: ['reaction'] },
    run: (env, a) => pipelineOf(env.ctx).taste(env.user, editOf(a), a.reaction, a.context, a.sentiment) },
  { name: 'pipeline_propose', title: 'Improve the edit pipeline from this edit', scope: 'edit:write',
    description: 'When the owner says the edit is done or it is exported. First call without changes: you get this edit\'s log, the owner\'s reactions and corrections, and the skill now. Then call with changes [{op, why, …}]: small ones apply at once as a new version (new trial pages, a short core rule, house style, how each technique did), big ones wait for the owner\'s OK in the app (changing or removing a core rule, retiring or deleting a page, changing house style, editing a proven page, or anything that contradicts one). Duplicates are skipped; a full core sends detail to a page. Proven repeatable techniques come back as template hints: tell the owner, never create one yourself. Free.',
    inputSchema: { type: 'object', additionalProperties: false, properties: { ...EDIT_ID, chatId: str('This chat (filled in for you in the app)'), changes: { type: 'array', maxItems: 20, items: CHANGE } } },
    run: async (env, a) => {
      const r = await pipelineOf(env.ctx).propose(env.user, editOf(a), a.changes);
      if ('summary' in r && typeof a.chatId === 'string' && a.chatId) {
        try {
          const t = await ownChat(env.ctx, env.user, a.chatId);
          const p = r as ProposeResult;
          await uiLine(env.ctx, env.user, t.id, 'pipeline_update', p.summary, { summary: p.summary, version: p.version, small: p.applied.length, big: p.pending.length, pendingIds: p.pending.map(x => x.id),
            templateHints: p.templateHints.map(h => h.name) });
        } catch { /* the card is a courtesy: the change itself is saved */ }
      }
      return r;
    } },
];

// ------------------------------------------------------------------ the apps' routes (owner)
export function registerPipelineRoutes(app: FastifyInstance, ctx: Ctx) {
  const P = pipelineOf(ctx);
  type V = { Params: { v: string } };
  app.get('/v1/pipeline-skill', async req => P.state(req.user));
  app.put('/v1/pipeline-skill', async req => P.setContent(req.user, (req.body ?? {}) as Record<string, unknown>));
  app.get('/v1/pipeline-skill/versions', async req => P.versions(req.user));
  app.get<V>('/v1/pipeline-skill/versions/:v', async req => P.version(req.user, Number(req.params.v)));
  app.get<V>('/v1/pipeline-skill/versions/:v/diff', async req => P.diff(req.user, Number(req.params.v)));
  app.post('/v1/pipeline-skill/rollback', async req => P.rollback(req.user, ((req.body ?? {}) as { version?: unknown }).version));
  app.post('/v1/pipeline-skill/undo', async req => P.undo(req.user));
  app.get('/v1/pipeline-skill/pending', async req => P.pending(req.user));
  app.post<{ Params: { id: string } }>('/v1/pipeline-skill/pending/:id/approve', async req => P.decide(req.user, req.params.id, true));
  app.post<{ Params: { id: string } }>('/v1/pipeline-skill/pending/:id/decline', async req => P.decide(req.user, req.params.id, false));
  app.get('/v1/pipeline-skill/skill-files', async req => P.skillFiles(req.user));
}
