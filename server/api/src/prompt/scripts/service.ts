// Settings → Prompts → Scripts (owner only, plans/api.md "Prompt scripts"): each script's inputs, rules and blocks;
// rule edits in a structured form (never code), saved per studio in prompt_script_rules; preview with sample inputs.
import { and, eq } from 'drizzle-orm';
import type { FastifyInstance } from 'fastify';
import type { AuthUser, Ctx } from '../../ctx.js';
import { users } from '../../db/schema.js';
import { ApiError, notFound } from '../../errors.js';
import { PROMPT_GROUPS } from '../library.js';
import { SCRIPTS, scriptDef } from './defs.js';
import { cleanRules, resolveRules, runScript, ruleTargets, same, scriptBlocks, validateRules, type SavedRules } from './run.js';
import { promptScriptRules } from './schema.js';
import { COND_OPS, type Inputs, type Rule, type Script } from './types.js';

type Row = typeof promptScriptRules.$inferSelect;

/** The studio's rules for every script it has edited (resolved: stale lists fall back to the defaults). */
export async function loadRules(ctx: Pick<Ctx, 'db'>, studioId: string): Promise<Record<string, Rule[]>> {
  const rows = await ctx.db.select().from(promptScriptRules).where(eq(promptScriptRules.studioId, studioId));
  const out: Record<string, Rule[]> = {};
  for (const r of rows) { const s = scriptDef(r.scriptId); if (s) out[r.scriptId] = resolveRules(s, r as SavedRules).rules; }
  return out;
}

const sampleInputs = (s: Script): Inputs => Object.fromEntries(s.inputs.map(i => [i.name, i.sample]));
const sampleVars = (s: Script) => Object.fromEntries((s.vars ?? []).map(v => [v.name, v.sample]));

export class PromptScripts {
  constructor(private ctx: Ctx) {}

  private async view(s: Script, row: Row | undefined, emails?: Map<string, string>) {
    const res = resolveRules(s, row ? (row as SavedRules) : null);
    const targets = ruleTargets(s).map(id => ({ id, label: id.startsWith('@') ? (s.values ?? []).find(v => `@${v.name}` === id)!.label : s.sections.find(x => x.id === id)!.label }));
    return {
      id: s.id, group: s.group, title: s.title, description: s.description, format: s.format,
      inputs: s.inputs, sections: s.sections.map(x => ({ id: x.id, label: x.label, kind: x.kind, pick: x.pick, ...(x.join != null ? { join: x.join } : {}), ...(x.each ? { each: x.each } : {}), ...(x.heading ? { heading: x.heading } : {}), ...(x.alias ? { alias: x.alias } : {}) })),
      values: s.values ?? [], targets, vars: s.vars ?? [], blocks: scriptBlocks(s),
      rules: res.rules, defaultRules: s.rules, overridden: res.overridden, stale: res.stale,
      updatedAt: res.overridden ? row!.updatedAt : null, updatedBy: res.overridden && row?.updatedBy ? emails?.get(row.updatedBy) ?? null : null,
    };
  }
  private async emails(studioId: string) {
    return new Map((await this.ctx.db.select({ id: users.id, email: users.email }).from(users).where(eq(users.studioId, studioId))).map(u => [u.id, u.email]));
  }
  private def(id: string) { const s = scriptDef(id); if (!s) throw notFound('Prompt script'); return s; }
  private async row(studioId: string, id: string) {
    return (await this.ctx.db.select().from(promptScriptRules).where(and(eq(promptScriptRules.studioId, studioId), eq(promptScriptRules.scriptId, id))))[0];
  }

  async list(studioId: string) {
    const rows = new Map((await this.ctx.db.select().from(promptScriptRules).where(eq(promptScriptRules.studioId, studioId))).map(r => [r.scriptId, r]));
    const emails = await this.emails(studioId);
    return { groups: PROMPT_GROUPS.map(g => ({ ...g })), ops: COND_OPS, scripts: await Promise.all(SCRIPTS.map(s => this.view(s, rows.get(s.id), emails))) };
  }
  async one(studioId: string, id: string) { const s = this.def(id); return this.view(s, await this.row(studioId, id), await this.emails(studioId)); }

  private check(s: Script, body: unknown): Rule[] {
    const rules = (body as { rules?: unknown } | null)?.rules;
    const why = validateRules(s, rules);
    if (why) throw new ApiError(400, 'script_invalid', why);
    return cleanRules(rules as Rule[]);
  }
  async set(u: AuthUser, id: string, body: unknown) {
    const s = this.def(id);
    const rules = this.check(s, body);
    if (same(rules, cleanRules(s.rules))) return this.reset(u, id);
    const values = { studioId: u.studioId, scriptId: id, rules, knownDefaults: s.rules.map(r => r.id), updatedBy: u.id, updatedAt: Date.now() };
    await this.ctx.db.insert(promptScriptRules).values(values)
      .onConflictDoUpdate({ target: [promptScriptRules.studioId, promptScriptRules.scriptId], set: { rules, knownDefaults: values.knownDefaults, updatedBy: u.id, updatedAt: values.updatedAt } });
    return this.changed(u.studioId, id);
  }
  async reset(u: AuthUser, id: string) {
    this.def(id);
    await this.ctx.db.delete(promptScriptRules).where(and(eq(promptScriptRules.studioId, u.studioId), eq(promptScriptRules.scriptId, id)));
    return this.changed(u.studioId, id);
  }
  private async changed(studioId: string, id: string) {
    this.ctx.prompts.forget(studioId);
    const v = await this.one(studioId, id);
    this.ctx.hub.emitOwners(studioId, { type: 'promptScript', script: v });
    return v;
  }

  /**
   * The script run on sample values: `inputs` (merged over the samples), `rules` (unsaved edits; default: the saved
   * ones), `texts` (unsaved block edits by key), `direction` (the user's words).
   */
  async preview(u: AuthUser, body: unknown) {
    const b = (body ?? {}) as { id?: unknown; inputs?: unknown; rules?: unknown; texts?: unknown; direction?: unknown };
    if (typeof b.id !== 'string') throw new ApiError(400, 'bad_request', 'id: which script');
    const s = this.def(b.id);
    const saved = await this.ctx.prompts.texts(u.studioId);
    const rules = b.rules === undefined ? resolveRules(s, (await this.row(u.studioId, s.id)) as SavedRules | undefined).rules : this.check(s, b);
    const texts: Record<string, string> = { ...saved };
    if (b.texts && typeof b.texts === 'object') for (const [k, v] of Object.entries(b.texts as Record<string, unknown>)) if (typeof v === 'string' && scriptBlocks(s).includes(k)) texts[k] = v;
    const inputs = { ...sampleInputs(s), ...(b.inputs && typeof b.inputs === 'object' ? (b.inputs as Inputs) : {}) };
    const direction = typeof b.direction === 'string' ? b.direction.slice(0, 500) : 'smiling, glancing at the camera';
    const r = runScript(s, { inputs, vars: sampleVars(s), texts, rules, user: { direction } });
    return { id: s.id, text: r.text, parts: r.parts, fired: r.fired, inputs };
  }
}

export async function registerPromptScriptRoutes(app: FastifyInstance, ctx: Ctx) {
  const svc = new PromptScripts(ctx);
  app.get('/v1/prompt-scripts', { config: { owner: true } }, async req => svc.list(req.user.studioId));
  app.get<{ Params: { id: string } }>('/v1/prompt-scripts/:id', { config: { owner: true } }, async req => svc.one(req.user.studioId, req.params.id));
  app.put<{ Params: { id: string } }>('/v1/prompt-scripts/:id', { config: { owner: true } }, async req => svc.set(req.user, req.params.id, req.body));
  app.delete<{ Params: { id: string } }>('/v1/prompt-scripts/:id', { config: { owner: true } }, async req => svc.reset(req.user, req.params.id));
  app.post('/v1/prompt-scripts/preview', { config: { owner: true } }, async req => svc.preview(req.user, req.body));
}
