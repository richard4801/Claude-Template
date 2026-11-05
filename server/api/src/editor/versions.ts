// Saving editor v2 projects with an edited version (plans/api.md "Editor v2" → versions). routes/versions.ts calls
// checkProject for `edits.version: 2`; v1 lists keep their own rules there.
import { and, eq, inArray } from 'drizzle-orm';
import type { Ctx } from '../ctx.js';
import { takes, uploads } from '../db/schema.js';
import { badRequest, notFound } from '../errors.js';
import { EditProblem, LIMITS, validate, type EditProject } from './model.js';
import { FILTERS } from './presets.js';

/** The rules of plans/video-editor.md "Editor v2" → Rules, plus: every take/upload asset is this studio's. */
export async function checkProject(ctx: Ctx, studioId: string, project: unknown, urlTakeId: string | null): Promise<{ durationSec: number }> {
  if (JSON.stringify(project ?? null).length > LIMITS.maxJsonBytes) throw badRequest(`edits: at most ${LIMITS.maxJsonBytes / 1024} KB`);
  if (!project || typeof project !== 'object' || Array.isArray(project)) throw badRequest('edits: must be an object');
  let r: { durationSec: number };
  try { r = validate(project as EditProject, FILTERS); } catch (e) {
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
  if (uploadIds.length) {
    const found = await ctx.db.select({ id: uploads.id, contentType: uploads.contentType }).from(uploads).where(and(eq(uploads.studioId, studioId), inArray(uploads.id, uploadIds)));
    for (const id of uploadIds) if (!found.some(f => f.id === id)) throw notFound(`Upload ${id}`);
    p.assets.forEach((a, i) => {
      if (!a.upload) return;
      const ct = found.find(f => f.id === a.upload)!.contentType;
      const ok = a.kind === 'image' ? ct.startsWith('image/') : a.kind === 'video' ? ct.startsWith('video/') : /^(audio|video)\//.test(ct);
      if (!ok) throw badRequest(`edits.assets.${i}: the upload is not ${a.kind === 'image' ? 'an image' : `a${a.kind === 'audio' ? 'n audio' : ' video'} file`}`);
    });
  }
  return r;
}
