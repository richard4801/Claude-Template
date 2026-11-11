// Input schemas for camera sessions, shared by REST, the MCP tools and the in-app chat's tools.
import { z } from 'zod';
import { badRequest } from '../errors.js';
import type { CameraAssetKind } from './schema.js';

export const ASPECTS = ['9:16', '16:9', '1:1', '4:5', '21:9'] as const;
export const STATUSES = ['drafting', 'blocking', 'rendering', 'ready', 'generating', 'done', 'failed'] as const;
export const ASSET_KINDS = ['greybox', 'depth', 'pose', 'tracks', 'keyframe_start', 'keyframe_mid', 'keyframe_end', 'still', 'preview',
  'camera_json', 'characters_json', 'set_json', 'blend'] as const satisfies readonly CameraAssetKind[];

const finite = z.number().finite();
const coord = finite.min(-1000).max(1000);
export const Vec3 = z.tuple([coord, coord, coord]);
const t = finite.min(0).max(60);
const id = z.string().regex(/^[A-Za-z0-9_-]{1,64}$/, 'letters, digits, _ and - only');

export const CamKey = z.object({
  t, position: Vec3, target: Vec3.optional(), focalMm: finite.min(8).max(300).optional(), rollDeg: finite.min(-180).max(180).optional(),
  ease: z.enum(['linear', 'in', 'out', 'in_out']).optional(),
}).strict();
export const CharKey = z.object({ t, position: Vec3, facingDeg: finite.min(-720).max(720).optional(), action: z.string().max(80).optional() }).strict();
const ascending = (ks: { t: number }[]) => ks.every((k, i) => i === 0 || k.t >= ks[i - 1]!.t);
export const CameraPath = z.object({
  keyframes: z.array(CamKey).min(1).max(64).refine(ascending, 'keyframes must be in time order'),
  cuts: z.array(t).max(32).optional(),
  sensorMm: finite.min(4).max(70).optional(),
}).strict();
export const CharacterBlocking = z.object({
  modelId: id, keyframes: z.array(CharKey).min(1).max(64).refine(ascending, 'keyframes must be in time order'), note: z.string().max(500).optional(),
}).strict();
export const CastIn = z.object({ modelId: id, role: z.string().max(80).optional(), heightM: finite.min(1.2).max(2.2).optional() }).strict();
export const Presets = z.object({
  rig: z.string().max(64).optional(), move: z.string().max(64).optional(), angle: z.string().max(64).optional(), intensity: finite.min(0).max(1).optional(),
}).strict();

export const CreateSession = z.object({
  title: z.string().trim().max(120).optional(),
  brief: z.string().max(8000).optional(),
  aspect: z.enum(ASPECTS).optional(),
  fps: z.number().int().min(12).max(60).optional(),
  durationSec: finite.min(1).max(30).optional(),
  characters: z.array(CastIn).max(6).optional(),
  presets: Presets.optional(),
  targetModel: z.string().max(100).optional(),
}).strict();
export const PatchSession = CreateSession.extend({
  status: z.enum(STATUSES).optional(),
  revision: z.number().int().positive().optional(),
}).strict();
export const SetPath = z.object({ camera: CameraPath.optional(), characters: z.array(CharacterBlocking).max(6).optional() }).strict();
export const NewAsset = z.object({
  kind: z.enum(ASSET_KINDS), contentType: z.string().max(100), bytes: z.number().int().positive().optional(), label: z.string().max(120).optional(),
}).strict();
export const ShotDraftIn = z.object({
  prompt: z.string().max(4000).optional(), targetModel: z.string().max(100).optional(), durationSec: finite.min(1).max(30).optional(),
}).strict();

/** Allowed content types and size limits per asset kind. */
export const ASSET_RULES: Record<CameraAssetKind, { types: string[]; maxBytes: number }> = (() => {
  const video = { types: ['video/mp4', 'video/quicktime'], maxBytes: 1024 ** 3 };
  const image = { types: ['image/png', 'image/jpeg', 'image/webp'], maxBytes: 50 * 1024 ** 2 };
  const json = { types: ['application/json'], maxBytes: 20 * 1024 ** 2 };
  return {
    greybox: video, depth: video, pose: video, tracks: video, keyframe_start: image, keyframe_mid: image, keyframe_end: image, still: image, preview: image,
    camera_json: json, characters_json: json, set_json: json, blend: { types: ['application/x-blender', 'application/octet-stream'], maxBytes: 500 * 1024 ** 2 },
  };
})();
export const extOf = (contentType: string) => ({
  'video/mp4': 'mp4', 'video/quicktime': 'mov', 'image/png': 'png', 'image/jpeg': 'jpg', 'image/webp': 'webp', 'application/json': 'json',
  'application/x-blender': 'blend', 'application/octet-stream': 'blend',
} as Record<string, string>)[contentType] ?? 'bin';

/** Parses with a contract error that names the field. */
export function parse<T>(schema: z.ZodType<T>, body: unknown): T {
  const r = schema.safeParse(body ?? {});
  if (!r.success) { const i = r.error.issues[0]!; throw badRequest(`${i.path.join('.') || 'body'}: ${i.message}`); }
  return r.data;
}
