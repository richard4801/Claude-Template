// Movement → Directed for Claude's Suite draft (suite_set_draft directed): the camera and blocking guides of one of the
// owner's camera sessions, the same request create_shot_draft builds (camera/shots.ts shotRequest): the greybox as the
// guide video (use blocking) and the start/middle/end stills as keyframes. The suite signs /uploads/<key> when it runs.
import { and, desc, eq } from 'drizzle-orm';
import type { AuthUser, Ctx } from '../ctx.js';
import { ApiError, notFound } from '../errors.js';
import { cameraAssets, cameraSessions } from '../camera/schema.js';
import type { CameraSpecInput } from './camera.js';

export type DraftDirected = { cameraSessionId: string; title: string; camera: CameraSpecInput };

export async function directedOf(ctx: Ctx, u: AuthUser, cameraSessionId: string): Promise<DraftDirected> {
  const [s] = await ctx.db.select().from(cameraSessions).where(and(eq(cameraSessions.id, cameraSessionId), eq(cameraSessions.studioId, u.studioId)));
  if (!s || s.ownerId !== u.id) throw notFound('Camera session');
  const assets = await ctx.db.select().from(cameraAssets).where(and(eq(cameraAssets.sessionId, s.id), eq(cameraAssets.state, 'ready'))).orderBy(desc(cameraAssets.createdAt));
  const newest = (kind: string) => assets.find(a => a.kind === kind);
  const grey = newest('greybox');
  if (!grey) throw new ApiError(409, 'no_guides', `“${s.title}” has no rendered guides yet: render them first (render_camera_guides), then set Directed again`);
  const still = (kind: string) => { const a = newest(kind); return a ? `/uploads/${a.storageKey}` : undefined; };
  const start = still('keyframe_start'), middle = still('keyframe_mid'), end = still('keyframe_end');
  const keyframes = start || middle || end ? { ...(start ? { start } : {}), ...(middle ? { middle: [middle] } : {}), ...(end ? { end } : {}) } : undefined;
  return { cameraSessionId: s.id, title: s.title,
    camera: { mode: 'directed', guide: { video: { key: grey.storageKey, ...(s.durationSec ? { seconds: s.durationSec } : {}) }, use: 'blocking', cameraSessionId: s.id, ...(keyframes ? { keyframes } : {}) } } };
}
