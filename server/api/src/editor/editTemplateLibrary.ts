// Edit's template library (plans/edit-templates.md §2–§3): storage (edit_templates, migration 0038), the 27 seeds, the
// four tools Claude uses and the routes the apps use. Effects and transitions only: photo presets are templates_manage
// (src/templates), caption styles are caption_style. Owner only, like the rest of Edit with Claude.
//
// Applying a template expands its spec (editTemplates.ts) against the session's current project and commits the result
// as ONE undoable change. dryRun returns the change without saving it (the apps preview it on the real selection). A
// template with a paid subject matte is priced first; on confirm, its live part lands with the cut-out copy hidden and
// the owner is asked in the app (the existing Approve flow, never more than the price shown); declining takes the copy
// back out. Nothing renders at apply time and pack scripts are never run.
import type { FastifyInstance } from 'fastify';
import { and, eq, inArray } from 'drizzle-orm';
import type { AuthUser, Ctx } from '../ctx.js';
import { uploads } from '../db/schema.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { uid } from '../lib/util.js';
import { diff } from './jsonpatch.js';
import * as M from './model.js';
import { CAPTION_STYLE_LABELS, CAPTION_STYLES } from './presets.js';
import { clipWindow } from './range.js';
import { editorAi } from './service.js';
import { editSessionsOf, type TemplateMatte } from './sessions.js';
import { editTemplatePacks, editTemplates } from './learnSchema.js';
import { checkSpec, expandTemplate, paramValues, primitiveLive, readiness, specFromSelection, type EditTemplateSpec, type ExpandOptions, type Target } from './editTemplates.js';
import { SEED_PACK, SEED_TEMPLATES, SEED_VERSION } from './editTemplateSeeds.js';
import type { EditTool, ToolEnv } from './mcpTools.js';

type Row = typeof editTemplates.$inferSelect;
export const LIBRARY_LIMITS = { templates: 300 } as const;
const NAMING = 'Edit effects and transitions (photo presets are templates_manage; caption styles are caption_style).';

const owner = (u: AuthUser) => { if (u.role !== 'owner') throw new ApiError(403, 'owner_only', 'Edit templates are for the studio owner'); };

/** The library's card for a template (what the apps draw and Claude reads). */
export function templateView(r: Row) {
  const spec = r.spec as unknown as EditTemplateSpec;
  const rd = readiness(spec);
  return {
    id: r.templateId, name: r.name, description: spec.description, kind: r.kind, target: r.target, level: r.level,
    state: rd.ready ? 'ready' : rd.state, ...(rd.ready ? {} : { reason: rd.reason }),
    requires: spec.requires ?? [], timing: spec.timing ?? null, each: spec.each ?? null,
    // Settings the person can change now (one waiting for a primitive stays hidden, its default used).
    params: (spec.params ?? []).filter(q => !q.needs || primitiveLive(q.needs)).map(({ needs: _n, ...q }) => q),
    paid: r.level === 'matte',
    preview: r.previewUpload ? { uploadId: r.previewUpload } : null,
    reference: r.referenceUpload ? { uploadId: r.referenceUpload } : null,
    by: r.by, source: r.source, version: r.version, updatedAt: r.updatedAt,
  };
}

class EditTemplateLibrary {
  constructor(private ctx: Ctx) {}

  /** The pack's media per template: previews, reference clips, overlays and sounds (uploads, with their kind). */
  private async packMedia(studioId: string, pack = SEED_PACK) {
    const [r] = await this.ctx.db.select({ media: editTemplatePacks.media }).from(editTemplatePacks).where(and(eq(editTemplatePacks.studioId, studioId), eq(editTemplatePacks.name, pack)));
    const media = r?.media ?? [];
    if (!media.length) return new Map<string, NonNullable<ExpandOptions['media']>>();
    const ids = [...new Set(media.map(m => m.uploadId))];
    const types = new Map((await this.ctx.db.select({ id: uploads.id, contentType: uploads.contentType }).from(uploads)
      .where(and(eq(uploads.studioId, studioId), inArray(uploads.id, ids), eq(uploads.state, 'ready')))).map(x => [x.id, x.contentType]));
    const out = new Map<string, NonNullable<ExpandOptions['media']>>();
    for (const m of media) {
      const ct = types.get(m.uploadId);
      if (!ct) continue;
      const kind = ct.startsWith('image/') ? 'image' : ct.startsWith('audio/') ? 'audio' : 'video';
      out.set(m.templateId, [...(out.get(m.templateId) ?? []), { uploadId: m.uploadId, role: m.role, kind }]);
    }
    return out;
  }

  /**
   * The 27 seeds for a studio: inserted once each (a delete sticks: the row stays with deletedAt), brought up to the
   * current seed version while the owner hasn't changed them, and given the pack's preview and reference clip when the
   * pack has them (the previews may arrive after the seeds).
   */
  async seed(studioId: string, by?: string) {
    const rows = await this.ctx.db.select().from(editTemplates).where(eq(editTemplates.studioId, studioId));
    const have = new Map(rows.map(r => [r.templateId, r]));
    const media = await this.packMedia(studioId);
    const now = Date.now();
    const pick = (id: string, role: string) => media.get(id)?.find(m => m.role === role && m.kind !== 'audio')?.uploadId ?? null;
    for (const spec of SEED_TEMPLATES) {
      const r = have.get(spec.id);
      const preview = pick(spec.id, 'preview'), reference = pick(spec.id, 'final');
      if (!r) {
        await this.ctx.db.insert(editTemplates).values({ id: uid('etp'), studioId, templateId: spec.id, name: spec.name, kind: spec.kind, target: spec.target, level: spec.level,
          spec: spec as unknown as Record<string, unknown>, previewUpload: preview, referenceUpload: reference, source: spec.source ?? null, by: 'seed', version: 1, seedVersion: SEED_VERSION,
          createdBy: by ?? null, createdAt: now, updatedAt: now }).onConflictDoNothing();
        continue;
      }
      if (r.deletedAt) continue;
      const set: Partial<Row> = {};
      if (r.by === 'seed' && (r.seedVersion ?? 0) < SEED_VERSION) Object.assign(set, { spec: spec as unknown as Record<string, unknown>, name: spec.name, kind: spec.kind, target: spec.target, level: spec.level, seedVersion: SEED_VERSION });
      if (!r.previewUpload && preview) set.previewUpload = preview;
      if (!r.referenceUpload && reference) set.referenceUpload = reference;
      if (Object.keys(set).length) await this.ctx.db.update(editTemplates).set({ ...set, updatedAt: now }).where(eq(editTemplates.id, r.id));
    }
  }

  async list(u: AuthUser, q: { query?: unknown; kind?: unknown; target?: unknown } = {}) {
    owner(u);
    await this.seed(u.studioId, u.id);
    const rows = (await this.ctx.db.select().from(editTemplates).where(eq(editTemplates.studioId, u.studioId))).filter(r => !r.deletedAt);
    const words = typeof q.query === 'string' ? q.query.toLowerCase().trim() : '';
    const list = rows.filter(r => (!q.kind || r.kind === q.kind) && (!q.target || r.target === q.target)
      && (!words || `${r.templateId} ${r.name} ${(r.spec as { description?: string }).description ?? ''}`.toLowerCase().includes(words)));
    // Ready first, then by who made them (yours, Claude's, the pack's), then by name.
    const order = (r: Row) => (readiness(r.spec as unknown as EditTemplateSpec).ready ? 0 : 1);
    list.sort((a, b) => order(a) - order(b) || (a.by === 'seed' ? 1 : 0) - (b.by === 'seed' ? 1 : 0) || a.name.localeCompare(b.name));
    return {
      templates: list.map(templateView),
      // Caption styles stay a section of the library in the apps (owner decision 1); they are applied with caption_style.
      captionStyles: CAPTION_STYLE_LABELS.filter(([id]) => id in CAPTION_STYLES).map(([id, name]) => ({ id, name })),
      note: NAMING,
    };
  }

  async row(u: AuthUser, templateId: unknown): Promise<Row> {
    owner(u);
    if (typeof templateId !== 'string' || !templateId) throw badRequest('templateId: from edit_templates');
    await this.seed(u.studioId, u.id);
    const [r] = await this.ctx.db.select().from(editTemplates).where(and(eq(editTemplates.studioId, u.studioId), eq(editTemplates.templateId, templateId)));
    if (!r || r.deletedAt) throw notFound(`Edit template "${templateId.slice(0, 64)}"`);
    return r;
  }

  async get(u: AuthUser, templateId: unknown) {
    const r = await this.row(u, templateId);
    return { ...templateView(r), spec: r.spec };
  }

  /** Saves from a selection in an edit session or from a spec. The same id again is a new version (by stays theirs). */
  async save(u: AuthUser, a: Record<string, unknown>, by: 'claude' | 'owner') {
    owner(u);
    await this.seed(u.studioId, u.id);
    const name = typeof a.name === 'string' ? a.name.trim() : '';
    let spec: EditTemplateSpec;
    if (a.spec !== undefined) {
      spec = checkSpec(typeof a.spec === 'object' && a.spec ? { ...(a.spec as object), ...(name ? { name } : {}) } : a.spec);
    } else {
      const from = a.from as { sessionId?: unknown; itemIds?: unknown; cutAt?: unknown } | undefined;
      if (!from || typeof from.sessionId !== 'string') throw badRequest('from: {sessionId, itemIds, cutAt?} (what is selected), or spec');
      if (!name) throw badRequest('name: what to call it');
      const kind = a.kind === 'transition' || a.kind === 'effect' ? a.kind : null;
      if (!kind) throw badRequest('kind: transition or effect');
      const s = await editSessionsOf(this.ctx).row(u, from.sessionId);
      const id = typeof a.id === 'string' && a.id ? a.id : slug(name);
      spec = specFromSelection(s.project as M.EditProject, { itemIds: Array.isArray(from.itemIds) ? from.itemIds.map(String) : [], ...(typeof from.cutAt === 'number' ? { cutAt: from.cutAt } : {}) },
        { id, name, kind, ...(a.target === 'clip' || a.target === 'cut' || a.target === 'edit' ? { target: a.target } : {}), ...(typeof a.description === 'string' ? { description: a.description } : {}) });
    }
    spec.source = { ...(spec.source ?? {}), by };
    const preview = a.previewUpload === undefined || a.previewUpload === null ? undefined : String(a.previewUpload);
    if (preview) {
      const [up] = await this.ctx.db.select({ id: uploads.id }).from(uploads).where(and(eq(uploads.id, preview), eq(uploads.studioId, u.studioId), eq(uploads.state, 'ready')));
      if (!up) throw badRequest('previewUpload: a finished upload of this studio (upload_local_file, then upload_status)');
    }
    const now = Date.now();
    const [cur] = await this.ctx.db.select().from(editTemplates).where(and(eq(editTemplates.studioId, u.studioId), eq(editTemplates.templateId, spec.id)));
    const vals = { name: spec.name, kind: spec.kind, target: spec.target, level: spec.level, spec: spec as unknown as Record<string, unknown>, source: spec.source ?? null, by, updatedAt: now };
    let r: Row;
    if (cur) {
      [r] = await this.ctx.db.update(editTemplates).set({ ...vals, version: cur.deletedAt ? cur.version + 1 : cur.version + 1, deletedAt: null, ...(preview ? { previewUpload: preview } : {}) }).where(eq(editTemplates.id, cur.id)).returning() as [Row];
    } else {
      const n = (await this.ctx.db.select({ id: editTemplates.id }).from(editTemplates).where(eq(editTemplates.studioId, u.studioId))).length;
      if (n >= LIBRARY_LIMITS.templates) throw badRequest(`A studio keeps at most ${LIBRARY_LIMITS.templates} Edit templates · delete one first`);
      [r] = await this.ctx.db.insert(editTemplates).values({ id: uid('etp'), studioId: u.studioId, templateId: spec.id, ...vals, previewUpload: preview ?? null, version: 1, createdBy: u.id, createdAt: now }).returning() as [Row];
    }
    return { template: templateView(r), spec: r.spec, saved: cur ? `New version ${r.version} of ${r.name}` : `Saved ${r.name} as a template` };
  }

  async remove(u: AuthUser, templateId: unknown) {
    const r = await this.row(u, templateId);
    await this.ctx.db.update(editTemplates).set({ deletedAt: Date.now(), updatedAt: Date.now() }).where(eq(editTemplates.id, r.id));
    return { deleted: r.templateId, note: 'Edits that used it keep their items.' };
  }

  /**
   * Expands a template onto the session's current project. dryRun: the change as a patch (nothing saved), with the price
   * when it needs a cut-out. Else one undoable change; with a cut-out, priced first (needsConfirmation) and, on confirm,
   * the live part lands and the owner is asked in the app for the cut-out.
   */
  async apply(u: AuthUser, a: Record<string, unknown>, by: 'claude' | { device?: unknown }) {
    owner(u);
    const r = await this.row(u, a.templateId);
    const spec = r.spec as unknown as EditTemplateSpec;
    const svc = editSessionsOf(this.ctx);
    if (typeof a.sessionId !== 'string' || !a.sessionId) throw badRequest('sessionId: the edit session (open_edit)');
    const s = await svc.row(u, a.sessionId);
    const p0 = s.project as M.EditProject;
    const target = parseTarget(a.target, spec);
    const media = r.by === 'seed' || (spec.source?.pack === SEED_PACK) ? (await this.packMedia(u.studioId)).get(spec.source?.templateId ?? spec.id) : undefined;
    const notes = Array.isArray(a.notes) ? a.notes.filter((x): x is number => typeof x === 'number' && Number.isFinite(x) && x >= 0) : undefined;
    const params = a.params && typeof a.params === 'object' && !Array.isArray(a.params) ? a.params as Record<string, unknown> : {};
    // A dropped mark: a template whose upload param has no value uses the pack's overlay when it has one.
    for (const q of spec.params ?? []) if (q.type === 'upload' && params[q.key] === undefined) { const m = media?.find(x => x.role === 'overlay' && x.kind === 'image'); if (m) params[q.key] = m.uploadId; }
    paramValues(spec, params);
    const ex = expandTemplate(p0, spec, target, { params, ...(notes ? { notes } : {}), ...(media ? { media } : {}) });
    svc.checkProject(ex.project, s.takeId);
    const label = ex.labels[0]!;
    // The cut-outs it needs: each priced on the seconds it sends (the copy's own source range), like Remove background.
    const ai = editorAi(this.ctx);
    const mattes = [] as { req: typeof ex.mattes[number]; body: Record<string, unknown>; usd: number }[];
    for (const m of ex.mattes) {
      const it = ex.project.tracks.flatMap(t => t.items).find(x => x.id === m.itemId) as M.VideoClip | undefined;
      const asset = it && ex.project.assets.find(x => x.id === it.asset);
      if (!it || !asset) throw badRequest(`${spec.name}: its cut-out copy is missing`);
      const range = clipWindow([{ inSec: it.inSec, outSec: it.outSec }], asset.durationSec);
      const source = asset.take ? { takeId: asset.take, ...(range ? { range } : {}) } : asset.upload ? { uploadId: asset.upload, durationSec: asset.durationSec, ...(range ? { range } : {}) } : null;
      if (!source) throw badRequest(`${spec.name}: ${it.id}'s shot has no stored media to cut out`);
      const body = { kind: 'matte', source, options: {} };
      const est = await ai.estimate(u, body);
      mattes.push({ req: m, body, usd: est.usd });
    }
    const priceUsd = Math.round(mattes.reduce((n, m) => n + m.usd, 0) * 10000) / 10000;
    const summary = { template: r.templateId, name: r.name, targets: ex.targets, changes: ex.labels, added: ex.added, tracksAdded: ex.tracksAdded, ...(ex.notes.length ? { notes: ex.notes } : {}),
      ...(mattes.length ? { cutOuts: mattes.length, priceUsd } : {}) };
    if (a.dryRun === true) {
      // The change as the apps would receive it, nothing saved: they draw it over the real selection.
      return { dryRun: true, revision: s.revision, ...summary, patch: diff(p0, ex.project), durationSec: M.durationSec(ex.project) };
    }
    if (priceUsd > 0 && a.confirm !== true) {
      return { needsConfirmation: true, estimateUsd: priceUsd, ...summary,
        message: `${r.name} needs the subject cut out (Remove background), about $${priceUsd.toFixed(2)}. Call again with confirm: true: the template lands at once and the owner is asked to approve the cut-out in the MUSE app; it shows when that finishes.` };
    }
    const done = await svc.commitProject(u, s.id, { from: s.revision, ...(typeof a.baseRevision === 'number' ? { baseRevision: a.baseRevision } : {}), project: ex.project, label: `Template: ${label}`, author: by,
      meta: { template: { id: r.templateId, version: r.version, targets: ex.targets } } });
    const tracksMade = ex.project.tracks.slice(p0.tracks.length).map(t => t.id);
    const asked: { pendingId: string; estimateUsd: number; itemId: string }[] = [];
    for (const m of mattes) {
      const tm: TemplateMatte = { templateId: r.templateId, name: r.name, reveal: m.req.reveal, ...(m.req.layer ? { layer: m.req.layer } : { remove: [m.req.itemId], tracks: tracksMade }) };
      const pend = await svc.askOwner(done.session, { kind: 'matte', label: `${r.name}: cut out the subject`, estimateUsd: m.usd,
        args: { ...m.body, itemId: m.req.layer ? m.req.layer.clip : m.req.itemId, maxUsd: m.usd, template: tm } });
      asked.push({ pendingId: pend.id, estimateUsd: m.usd, itemId: m.req.itemId });
    }
    return { applied: true, revision: done.revision, entry: done.entry, durationSec: done.durationSec, ...summary,
      ...(done.safeAreaWarnings ? { safeAreaWarnings: done.safeAreaWarnings } : {}),
      ...(asked.length ? { waitingForOwner: asked, message: 'Applied. The cut-out copy stays hidden until the owner approves the cut-out in the MUSE app and it finishes; declining takes it back out.' } : {}),
      undo: 'undo_edit with this entry id reverts the whole template' };
  }
}

const slug = (name: string) => {
  const s = name.toLowerCase().normalize('NFKD').replace(/[^\w\s-]/g, '').trim().replace(/[\s_]+/g, '-').replace(/-+/g, '-').slice(0, 60);
  return /^[a-z0-9][a-z0-9-]{1,63}$/.test(s) ? s : `template-${Date.now().toString(36)}`;
};

/** target as sent: {itemId} | {cutAfter} | {itemIds} | {cutsAfter} | {each} | {edit: true}; a template on the whole edit needs none. */
function parseTarget(t: unknown, spec: EditTemplateSpec): Target {
  if (spec.target === 'edit') return { edit: true };
  if (typeof t === 'string') return spec.target === 'cut' ? { cutAfter: t } : { itemId: t };
  if (!t || typeof t !== 'object') throw badRequest(`target: ${spec.target === 'cut' ? '{cutAfter: clipId} (the clip before the cut), {cutsAfter: [...]}, or {each: "cut" | "note-cut"}' : '{itemId}, {itemIds: [...]}, or {each: "clip"}'}`);
  const o = t as Record<string, unknown>;
  if (typeof o.itemId === 'string') return { itemId: o.itemId };
  if (typeof o.cutAfter === 'string') return { cutAfter: o.cutAfter };
  if (Array.isArray(o.itemIds) && o.itemIds.length && o.itemIds.length <= 100) return { itemIds: o.itemIds.map(String) };
  if (Array.isArray(o.cutsAfter) && o.cutsAfter.length && o.cutsAfter.length <= 100) return { cutsAfter: o.cutsAfter.map(String) };
  if (o.each === 'clip' || o.each === 'cut' || o.each === 'note-cut') return { each: o.each };
  if (o.each === 'selected') throw badRequest('target.each "selected": send the selected ids as itemIds (clips) or cutsAfter (cuts)');
  throw badRequest('target: {itemId}, {cutAfter}, {itemIds}, {cutsAfter} or {each: "clip" | "cut" | "note-cut"}');
}

const libraries = new WeakMap<Ctx, EditTemplateLibrary>();
export const editTemplatesOf = (ctx: Ctx) => { let l = libraries.get(ctx); if (!l) { l = new EditTemplateLibrary(ctx); libraries.set(ctx, l); } return l; };

// ------------------------------------------------------------------ Claude's tools
const str = (d: string, max?: number) => ({ type: 'string', description: d, ...(max ? { maxLength: max } : {}) });
const TARGET = { type: ['object', 'string'], description: 'A clip template: {itemId} | {itemIds: [...]} | {each: "clip"}. A cut template: {cutAfter: clipId} (the main clip before the cut) | {cutsAfter: [...]} | {each: "cut" | "note-cut"}. Whole-edit templates need none.' };

export const EDIT_TEMPLATE_TOOLS: EditTool[] = [
  { name: 'edit_templates', title: 'Edit templates', scope: 'edit:read', readOnly: true, idempotent: true,
    description: `The Edit template library: ${NAMING} Each: id, name, what it does, kind (transition | effect), target (clip | cut | edit), level (live: any video; matte: needs a paid subject cut-out, priced on apply; primitive / reference: not ready yet, with the reason), its params and defaults, timing, preview upload. Not-ready ones built from the icon-storyboard pack can be made per video: read the pack's script with template_pack_read, adapt it, and add the result as an overlay. With templateId: that template's full spec.`,
    inputSchema: { type: 'object', additionalProperties: false, properties: { query: str('Words to match', 80), kind: { type: 'string', enum: ['transition', 'effect'] }, target: { type: 'string', enum: ['clip', 'cut', 'edit'] }, templateId: str('One template\'s full spec', 64) } },
    run: async (env, a) => (a.templateId ? editTemplatesOf(env.ctx).get(env.user, a.templateId) : editTemplatesOf(env.ctx).list(env.user, a)) },
  { name: 'edit_template_apply', title: 'Apply an Edit template', scope: 'edit:write',
    description: `Applies an Edit template (${NAMING}) to a clip, a cut, several, or the whole edit as ONE undoable change (undo_edit reverts it all). dryRun: true returns the change (patch, what it adds, notes, price) without saving. Templates at level "matte" need a paid subject cut-out: without confirm you get the price; with confirm: true the template lands and the owner approves the cut-out in the MUSE app (never more than that price); the cut-out copy shows once it finishes, and declining takes it back out. Not-ready templates are refused with the reason. notes: note times in timeline seconds (from song_notes) for templates timed to the song; without them the music's detected beats are used, else even steps. When the result has notes, tell the person the ones that matter in a plain line.`,
    inputSchema: { type: 'object', additionalProperties: false, required: ['sessionId', 'templateId'], properties: {
      sessionId: str('Edit session id (es_…), from open_edit'), templateId: str('From edit_templates', 64), target: TARGET,
      params: { type: 'object', description: 'Settings by key (edit_templates lists them with defaults)' },
      notes: { type: 'array', maxItems: 400, items: { type: 'number' }, description: 'Note times, timeline seconds (song_notes)' },
      baseRevision: { type: 'number', description: 'The revision you last read (refused if the edit moved on)' },
      dryRun: { type: 'boolean', description: 'Return the change without saving it' }, confirm: { type: 'boolean', description: 'For a paid cut-out: ask the owner to approve the price' } } },
    run: (env: ToolEnv, a) => editTemplatesOf(env.ctx).apply(env.user, a, 'claude') },
  { name: 'edit_template_save', title: 'Save an Edit template', scope: 'edit:write',
    description: `Saves an Edit template (${NAMING}). from {sessionId, itemIds, cutAt?}: what is selected becomes a template: the clip's effect, look, colour, blend, mask and keyframes (normalised to its length), and the overlays, adjustment layers, text and sounds over it; copies of a neighbouring shot become $next / $prev so it works on any video. Or spec: a full EditTemplate v1 spec (edit_templates with templateId shows one: params, steps of split | freeze | set | transition | add | wash | jitter | matte, shapes, values as numbers or expressions like "$cut - $lead"). The answer has the spec, so you can add params and save it again. The same id again saves a new version. Pack scripts stay text: name them in spec.source.scripts; they never run.`,
    inputSchema: { type: 'object', additionalProperties: false, properties: {
      name: str('What to call it', 60), kind: { type: 'string', enum: ['transition', 'effect'] }, target: { type: 'string', enum: ['clip', 'cut', 'edit'] }, description: str('What it does, one line', 600),
      id: str('A slug; default from the name', 64),
      from: { type: 'object', additionalProperties: false, properties: { sessionId: str('Edit session id'), itemIds: { type: 'array', items: { type: 'string' }, maxItems: 40 }, cutAt: { type: 'number', description: 'A cut (timeline seconds) for a cut template' } } },
      spec: { type: 'object', description: 'A full EditTemplate v1 spec' }, previewUpload: str('A finished upload showing it (upload_local_file)', 80) } },
    run: (env: ToolEnv, a) => editTemplatesOf(env.ctx).save(env.user, a, 'claude') },
  { name: 'edit_template_delete', title: 'Delete an Edit template', scope: 'edit:write',
    description: `Removes an Edit template from the library (${NAMING}). Edits that used it keep their items. A deleted pack template doesn't come back.`,
    inputSchema: { type: 'object', additionalProperties: false, required: ['templateId'], properties: { templateId: str('From edit_templates', 64) } },
    run: (env: ToolEnv, a) => editTemplatesOf(env.ctx).remove(env.user, a.templateId) },
];

// ------------------------------------------------------------------ the apps' routes
export function registerEditTemplateRoutes(app: FastifyInstance, ctx: Ctx) {
  const lib = editTemplatesOf(ctx);
  type Q = { Querystring: { query?: string; kind?: string; target?: string } };
  app.get<Q>('/v1/editor/templates', async req => lib.list(req.user, req.query ?? {}));
  app.get<{ Params: { id: string } }>('/v1/editor/templates/:id', async req => lib.get(req.user, req.params.id));
  app.post('/v1/editor/templates', async req => lib.save(req.user, (req.body ?? {}) as Record<string, unknown>, 'owner'));
  app.post<{ Params: { id: string } }>('/v1/editor/templates/:id/apply', async req => {
    const b = (req.body ?? {}) as Record<string, unknown>;
    return lib.apply(req.user, { ...b, templateId: req.params.id }, { device: b.device });
  });
  app.delete<{ Params: { id: string } }>('/v1/editor/templates/:id', async req => lib.remove(req.user, req.params.id));
}
