// Template pack intake (plans/edit-templates.md §1; report ci_d4cc38758998). MUSE Claude built 27 effect and transition
// templates outside the editor (a local pack on the owner's Mac: README, templates.json, scripts, finals, previews) and
// logged gaps with report_gap, but nothing let it hand the pack over or let the team read the gaps in full. These
// owner-only tools close that: gaps_list reads every gap, template_pack_send stores the manifest, the scripts and notes
// (as text) and the preview/final uploads (made first with upload_local_file), template_pack_read reads it back.
// Free, nothing renders, nothing reaches a member. The library itself (save/apply templates in Edit) comes later.
import { and, eq, inArray } from 'drizzle-orm';
import type { AuthUser, Ctx } from '../ctx.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { uid } from '../lib/util.js';
import { uploads } from '../db/schema.js';
import { learningOf } from './learn.js';
import { editTemplatePacks } from './learnSchema.js';
import type { EditTool } from './mcpTools.js';

export const PACK_LIMITS = { manifestBytes: 256_000, fileChars: 200_000, filesPerCall: 40, files: 300, totalChars: 3_000_000, media: 300 };
const MEDIA_ROLES = ['preview', 'final', 'source', 'overlay'] as const;

const owner = (u: AuthUser) => { if (u.role !== 'owner') throw new ApiError(403, 'owner_only', 'Template packs are for the studio owner'); };

/** Credentials never stored: provider key shapes, bearer tokens, JWTs and `secret = "…"` style literals in scripts.
 * Narrower than issues.ts scrub() (code keeps its hashes, ids and URLs). Returns the text and how many were redacted. */
export function redactCredentials(s: string): { text: string; redacted: number } {
  let n = 0;
  const hit = () => { n++; return '[redacted]'; };
  const text = s
    .replace(/\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{16,}/gi, (_m, w) => `${w} ${hit()}`)
    .replace(/\b(?:sk|pk|rk|r8|fal|ghp|gho|github_pat|xox[abp]|AKIA|hf)[-_][A-Za-z0-9_-]{12,}/g, hit)
    .replace(/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/g, hit)
    .replace(/\b([A-Za-z_]*(?:api[_-]?key|secret|password|passwd|token|credential)[A-Za-z_]*)(["']?\s*[:=]\s*)(["'])([^"'\s$[]{8,})\3/gi,
      (_m, k, sep, q) => `${k}${sep}${q}${hit()}${q}`);
  return { text, redacted: n };
}

const cleanPath = (p: unknown) => {
  const s = typeof p === 'string' ? p.trim().replace(/\\/g, '/').replace(/^\.?\/+/, '') : '';
  if (!s || s.length > 200 || s.split('/').some(x => x === '..' || x === '') || !/^[\w .()+@,-]+(\/[\w .()+@,-]+)*$/.test(s)) {
    throw badRequest(`files: path "${String(p).slice(0, 80)}" must be relative inside the pack, like "scripts/glitch.py"`);
  }
  return s;
};
const packName = (v: unknown) => {
  const s = typeof v === 'string' ? v.trim() : '';
  if (!/^[\w][\w .-]{0,79}$/.test(s)) throw badRequest('pack: a short name, like "icon-storyboard"');
  return s;
};
const templateIds = (m: unknown): string[] => {
  const list = Array.isArray(m) ? m : (m && typeof m === 'object' ? (m as { templates?: unknown }).templates : undefined);
  return Array.isArray(list) ? list.map(t => (t && typeof t === 'object' ? String((t as { id?: unknown }).id ?? '') : '')).filter(Boolean) : [];
};

type Row = typeof editTemplatePacks.$inferSelect;
const view = (r: Row) => {
  const ids = templateIds(r.manifest);
  const withPreview = new Set(r.media.filter(m => m.role === 'preview' || m.role === 'final').map(m => m.templateId));
  return { packId: r.id, pack: r.name, status: r.status, templates: ids.length, files: Object.keys(r.files).length,
    chars: Object.values(r.files).reduce((n, f) => n + f.text.length, 0), media: r.media.length,
    missingPreviews: ids.filter(id => !withPreview.has(id)), updatedAt: r.updatedAt };
};

/** Stores or merges one submit. Files merge by path (sent again = replaced), media by (templateId, uploadId). */
export async function sendPack(ctx: Ctx, u: AuthUser, a: Record<string, unknown>) {
  owner(u);
  const name = packName(a.pack);
  const now = Date.now();
  const [cur] = await ctx.db.select().from(editTemplatePacks).where(and(eq(editTemplatePacks.studioId, u.studioId), eq(editTemplatePacks.name, name)));
  let manifest = cur?.manifest ?? null;
  if (a.manifest !== undefined) {
    let m = a.manifest;
    if (typeof m === 'string') { try { m = JSON.parse(m); } catch { throw badRequest('manifest: the templates.json content (JSON)'); } }
    if (!m || typeof m !== 'object') throw badRequest('manifest: the templates.json content (an object or a list)');
    if (Buffer.byteLength(JSON.stringify(m)) > PACK_LIMITS.manifestBytes) throw badRequest(`manifest: at most ${PACK_LIMITS.manifestBytes / 1000} KB; send long notes as files`);
    manifest = redactJson(m) as Row['manifest'];
  }
  const files = { ...(cur?.files ?? {}) };
  let redacted = 0;
  const sent = Array.isArray(a.files) ? a.files : a.files === undefined ? [] : null;
  if (!sent) throw badRequest('files: [{path, text}]');
  if (sent.length > PACK_LIMITS.filesPerCall) throw badRequest(`files: at most ${PACK_LIMITS.filesPerCall} per call; send the rest in more calls (they merge)`);
  for (const f of sent as { path?: unknown; text?: unknown }[]) {
    const path = cleanPath(f?.path);
    if (typeof f.text !== 'string') throw badRequest(`files: "${path}" needs text (scripts and notes only; send media with upload_local_file and list it in media)`);
    if (f.text.length > PACK_LIMITS.fileChars) throw badRequest(`files: "${path}" is over ${PACK_LIMITS.fileChars / 1000}k characters; split it`);
    if (/[\u0000-\u0008\u000e-\u001f]/.test(f.text)) throw badRequest(`files: "${path}" looks binary; send it with upload_local_file and list it in media`);
    const r = redactCredentials(f.text);
    redacted += r.redacted;
    files[path] = { text: r.text, bytes: Buffer.byteLength(r.text), at: now };
  }
  for (const p of Array.isArray(a.removeFiles) ? a.removeFiles : []) delete files[cleanPath(p)];
  if (Object.keys(files).length > PACK_LIMITS.files) throw badRequest(`files: a pack holds at most ${PACK_LIMITS.files} files`);
  if (Object.values(files).reduce((n, f) => n + f.text.length, 0) > PACK_LIMITS.totalChars) throw badRequest(`files: a pack holds at most ${PACK_LIMITS.totalChars / 1e6}M characters of text`);

  let media = [...(cur?.media ?? [])];
  const addMedia = Array.isArray(a.media) ? a.media as { templateId?: unknown; uploadId?: unknown; role?: unknown; note?: unknown }[] : a.media === undefined ? [] : null;
  if (!addMedia) throw badRequest('media: [{templateId, uploadId, role}]');
  if (addMedia.length) {
    const ids = [...new Set(addMedia.map(m => String(m?.uploadId ?? '')))];
    const found = new Set((await ctx.db.select({ id: uploads.id }).from(uploads)
      .where(and(eq(uploads.studioId, u.studioId), inArray(uploads.id, ids), eq(uploads.state, 'ready')))).map(r => r.id));
    for (const m of addMedia) {
      const templateId = typeof m.templateId === 'string' ? m.templateId.trim().slice(0, 80) : '';
      const uploadId = String(m.uploadId ?? '');
      if (!templateId) throw badRequest('media: templateId (the id in templates.json)');
      if (!found.has(uploadId)) throw badRequest(`media: upload "${uploadId.slice(0, 40)}" isn't a finished upload in this studio (upload_local_file, then upload_status until done)`);
      const role = typeof m.role === 'string' && (MEDIA_ROLES as readonly string[]).includes(m.role) ? m.role : 'preview';
      media = media.filter(x => !(x.templateId === templateId && x.uploadId === uploadId));
      media.push({ templateId, uploadId, role, ...(typeof m.note === 'string' && m.note ? { note: redactCredentials(m.note.slice(0, 300)).text } : {}) });
    }
    if (media.length > PACK_LIMITS.media) throw badRequest(`media: a pack holds at most ${PACK_LIMITS.media} uploads`);
  }

  const vals = { manifest, files, media, updatedAt: now };
  const [row] = cur
    ? await ctx.db.update(editTemplatePacks).set(vals).where(eq(editTemplatePacks.id, cur.id)).returning()
    : await ctx.db.insert(editTemplatePacks).values({ id: uid('tp'), studioId: u.studioId, name, createdBy: u.id, createdAt: now, ...vals }).returning();
  return { ...view(row!), ...(redacted ? { redacted, note: `${redacted} credential-looking value(s) were replaced with [redacted]` } : {}),
    next: 'Send the rest (files merge by path), then the previews: upload_local_file each, then media [{templateId, uploadId, role}]. Tell the owner when the pack is complete.' };
}

function redactJson(v: unknown): unknown {
  if (typeof v === 'string') return redactCredentials(v).text;
  if (Array.isArray(v)) return v.map(redactJson);
  if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, redactJson(x)]));
  return v;
}

/** No pack: every pack's summary. A pack: its manifest, file list and media. With path: that file's text. */
export async function readPack(ctx: Ctx, u: AuthUser, a: Record<string, unknown>) {
  owner(u);
  if (a.pack === undefined) {
    const rows = await ctx.db.select().from(editTemplatePacks).where(eq(editTemplatePacks.studioId, u.studioId));
    return { packs: rows.sort((x, y) => y.updatedAt - x.updatedAt).map(view) };
  }
  const name = packName(a.pack);
  const [r] = await ctx.db.select().from(editTemplatePacks).where(and(eq(editTemplatePacks.studioId, u.studioId), eq(editTemplatePacks.name, name)));
  if (!r) throw notFound('Template pack');
  if (a.path !== undefined) {
    const path = cleanPath(a.path), f = r.files[path];
    if (!f) throw notFound(`File "${path}" in the pack`);
    return { pack: r.name, path, text: f.text, bytes: f.bytes, at: f.at };
  }
  return { ...view(r), manifest: r.manifest, fileList: Object.entries(r.files).map(([path, f]) => ({ path, bytes: f.bytes, at: f.at })), mediaList: r.media };
}

const s = (d: string, max?: number) => ({ type: 'string', description: d, ...(max ? { maxLength: max } : {}) });

export const TEMPLATE_PACK_TOOLS: EditTool[] = [
  { name: 'gaps_list', title: 'List what Edit can\'t do yet (owner)', scope: 'edit:read', readOnly: true, idempotent: true,
    description: 'Owner only, free: every gap logged with report_gap or found in references (most requested first), with its examples. kind and query narrow it (query matches key, what and notes).',
    inputSchema: { type: 'object', additionalProperties: false, properties: {
      kind: { type: 'string', enum: ['transition', 'effect', 'text', 'font', 'motion', 'other'] }, query: s('Words to match', 80),
      limit: { type: 'integer', minimum: 1, maximum: 200 } } },
    run: async (env, a) => {
      owner(env.user);
      const q = typeof a.query === 'string' ? a.query.toLowerCase() : '';
      const all = await learningOf(env.ctx).gaps(env.user, 200);
      const gaps = all.filter(g => (!a.kind || g.kind === a.kind) && (!q || `${g.key} ${g.what} ${g.examples.map(e => e.note).join(' ')}`.toLowerCase().includes(q)));
      return { gaps: gaps.slice(0, typeof a.limit === 'number' ? a.limit : 200), total: gaps.length };
    } },
  { name: 'template_pack_send', title: 'Send a template pack to the MUSE team (owner)', scope: 'edit:write',
    description: 'Owner only, free: hands a pack of effect/transition templates you made outside Edit to the MUSE team, who build each into Edit\'s template library. Send in parts; they merge under the same pack name: manifest (templates.json, each template with an id), files [{path, text}] for the README, scripts and notes (text only, ≤ 40 per call; credentials are redacted), and media [{templateId, uploadId, role: preview|final|source|overlay}] for clips you uploaded first with upload_local_file. The answer lists templates still missing a preview.',
    inputSchema: { type: 'object', additionalProperties: false, required: ['pack'], properties: {
      pack: s('The pack name (e.g. "icon-storyboard")', 80),
      manifest: { description: 'templates.json: {templates: [{id, name, kind, …}]} or a list (or the JSON text)' },
      files: { type: 'array', maxItems: PACK_LIMITS.filesPerCall, items: { type: 'object', additionalProperties: false, required: ['path', 'text'], properties: { path: s('Path inside the pack', 200), text: { type: 'string' } } } },
      removeFiles: { type: 'array', items: { type: 'string', maxLength: 200 } },
      media: { type: 'array', items: { type: 'object', additionalProperties: false, required: ['templateId', 'uploadId'], properties: {
        templateId: s('The template id in the manifest', 80), uploadId: s('From upload_local_file', 80), role: { type: 'string', enum: [...MEDIA_ROLES] }, note: s('What it shows', 300) } } },
    } },
    run: (env, a) => sendPack(env.ctx, env.user, a) },
  { name: 'template_pack_read', title: 'Read a template pack (owner)', scope: 'edit:read', readOnly: true, idempotent: true,
    description: 'Owner only, free: without pack, every pack sent (templates, files, previews, what is missing); with pack, its manifest, file list and media; with pack and path, that file\'s text.',
    inputSchema: { type: 'object', additionalProperties: false, properties: { pack: s('The pack name', 80), path: s('A file path in the pack', 200) } },
    run: (env, a) => readPack(env.ctx, env.user, a) },
];
