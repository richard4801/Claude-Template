// Saving editor v2 projects with an edited version (plans/api.md "Editor v2" → versions). routes/versions.ts calls
// checkProject for `edits.version: 2`; v1 lists keep their own rules there.
import { and, eq, inArray } from 'drizzle-orm';
import type { Ctx } from '../ctx.js';
import { takes, uploads } from '../db/schema.js';
import { badRequest, notFound } from '../errors.js';
import { EditProblem, LIMITS, validate, type EditProject } from './model.js';
import { FILTERS } from './presets.js';
import { CubeError, parseCube, type Lut } from './look.js';
import { LOOK_IDS } from './lookpack.js';
import { fontOfUpload } from './font.js';
import { contentItem } from './content.js';
import { paletteIds } from './photo.js';
import { ApiError } from '../errors.js';

const lutCache = new Map<string, Lut>();
/** An uploaded .cube of the studio, parsed (cached by storage key). bad_request with the line when it is not usable. */
export async function lutOfUpload(ctx: Ctx, studioId: string, uploadId: string): Promise<Lut> {
  const [up] = await ctx.db.select().from(uploads).where(and(eq(uploads.id, uploadId), eq(uploads.studioId, studioId)));
  if (!up) throw notFound('Upload');
  if (!up.storageKey.endsWith('.cube')) throw badRequest('uploadId: not a .cube upload');
  const hit = lutCache.get(up.storageKey);
  if (hit) return hit;
  const obj = await ctx.storage.get(up.storageKey);
  if (!obj) throw new ApiError(409, 'upload_missing', 'The file has not arrived yet · upload it to the URL first');
  const chunks: Buffer[] = [];
  let n = 0;
  for await (const c of obj.body as AsyncIterable<Buffer>) { n += c.length; if (n > 12 * 1024 * 1024) throw badRequest('the .cube is over 12 MB'); chunks.push(Buffer.from(c)); }
  let l: Lut;
  try { l = parseCube(Buffer.concat(chunks).toString('utf8')); } catch (e) { if (e instanceof CubeError) throw badRequest(`.cube: ${e.message}`); throw e; }
  if (up.state !== 'ready') await ctx.db.update(uploads).set({ state: 'ready', bytes: n }).where(eq(uploads.id, up.id));
  if (lutCache.size > 50) lutCache.clear();
  lutCache.set(up.storageKey, l);
  return l;
}

/** The rules of plans/video-editor.md "Editor v2" → Rules, plus: every take/upload asset is this studio's. */
export async function checkProject(ctx: Ctx, studioId: string, project: unknown, urlTakeId: string | null): Promise<{ durationSec: number }> {
  if (JSON.stringify(project ?? null).length > LIMITS.maxJsonBytes) throw badRequest(`edits: at most ${LIMITS.maxJsonBytes / 1024} KB`);
  if (!project || typeof project !== 'object' || Array.isArray(project)) throw badRequest('edits: must be an object');
  let r: { durationSec: number };
  try { r = validate(project as EditProject, FILTERS, LOOK_IDS, paletteIds()); } catch (e) {
    if (e instanceof EditProblem) throw badRequest(e.message);
    throw badRequest(`edits: ${(e as Error).message}`); // a missing nested object
  }
  const p = project as EditProject;
  if (urlTakeId !== null && p.sourceTakeId !== urlTakeId) throw badRequest('edits.sourceTakeId: must be the take in the URL');
  const takeIds = [...new Set(p.assets.filter(a => a.take).map(a => a.take!))];
  const uploadIds = [...new Set(p.assets.filter(a => a.upload).map(a => a.upload!))];
  if (takeIds.length) {
    const found = await ctx.db.select({ id: takes.id, kind: takes.kind, mediaKey: takes.mediaKey, thumb: takes.thumb }).from(takes).where(and(eq(takes.studioId, studioId), inArray(takes.id, takeIds)));
    for (const id of takeIds) if (!found.some(f => f.id === id)) throw notFound(`Take ${id}`);
    p.assets.forEach((a, i) => {
      if (!a.take) return;
      const t = found.find(f => f.id === a.take)!;
      const isVideo = !!t.mediaKey && (t.kind === 'take' || (t.kind as string) === 'edit');
      if (a.kind === 'video' && !isVideo) throw badRequest(`edits.assets.${i}: that take is not a video`);
      if (a.kind === 'image' && t.kind !== 'shot') throw badRequest(`edits.assets.${i}: that take is not a photo`);
      if (a.kind === 'audio' && !isVideo) throw badRequest(`edits.assets.${i}: that take has no sound`);
    });
  }
  // Content library items must be in the catalog, as the right kind (stickers are images, sound effects audio).
  p.assets.forEach((a, i) => {
    if (!a.library?.startsWith('content:')) return;
    const hit = contentItem(a.library);
    if (!hit || (a.kind === 'image' ? hit.pack.kind !== 'stickers' : hit.pack.kind !== 'sfx')) throw badRequest(`edits.assets.${i}: unknown content`);
  });
  if (uploadIds.length) {
    const found = await ctx.db.select({ id: uploads.id, contentType: uploads.contentType }).from(uploads).where(and(eq(uploads.studioId, studioId), inArray(uploads.id, uploadIds)));
    for (const id of uploadIds) if (!found.some(f => f.id === id)) throw notFound(`Upload ${id}`);
    p.assets.forEach((a, i) => {
      if (!a.upload) return;
      const ct = found.find(f => f.id === a.upload)!.contentType;
      if (a.kind === 'lut') return; // checked below (parsed)
      if (a.kind === 'font') return; // checked below (parsed)
      const ok = a.kind === 'image' ? ct.startsWith('image/') : a.kind === 'video' ? ct.startsWith('video/') : /^(audio|video)\//.test(ct);
      if (!ok) throw badRequest(`edits.assets.${i}: the upload is not ${a.kind === 'image' ? 'an image' : `a${a.kind === 'audio' ? 'n audio' : ' video'} file`}`);
    });
  }
  for (const [i, a] of p.assets.entries()) {
    if (a.kind !== 'font') continue;
    try { await fontOfUpload(ctx, studioId, a.upload!); } catch (e) {
      if (e instanceof ApiError && e.status === 400) throw badRequest(`edits.assets.${i}: ${e.message === 'uploadId: not a font upload' ? 'the upload is not a font' : e.message}`);
      throw e;
    }
  }
  for (const [i, a] of p.assets.entries()) {
    if (a.kind !== 'lut') continue;
    try { await lutOfUpload(ctx, studioId, a.upload!); } catch (e) {
      if (e instanceof ApiError && e.status === 400) throw badRequest(`edits.assets.${i}: ${e.message}`);
      throw e;
    }
  }
  return r;
}
