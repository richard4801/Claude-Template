// Blender tools for the in-app chat. They run on the owner's Mac (relay.ts → the MUSE Mac app → the Blender add-on's
// localhost socket) as fixed MUSE scripts; Claude passes data, never code. The Mac validates the same rules again.
import { z } from 'zod';
import { ASPECTS, CamKey, CharKey, Vec3 } from './validate.js';

const finite = z.number().finite();
const id = z.string().regex(/^[A-Za-z0-9_-]{1,64}$/);
const vec3 = (d: string) => ({ type: 'array', items: { type: 'number' }, minItems: 3, maxItems: 3, description: d });
const obj = (properties: Record<string, unknown>, required: string[] = []) => ({ type: 'object', properties, required, additionalProperties: false });
const ascending = (ks: { t: number }[]) => ks.every((k, i) => i === 0 || k.t >= ks[i - 1]!.t);

export type BlenderTool = { name: string; description: string; inputSchema: Record<string, unknown>; args: z.ZodType<Record<string, unknown>> };

const camKeySchema = obj({ t: { type: 'number' }, position: vec3('metres'), target: vec3('look-at point'), focalMm: { type: 'number' }, rollDeg: { type: 'number' },
  ease: { type: 'string', enum: ['linear', 'in', 'out', 'in_out'] } }, ['t', 'position']);
const charKeySchema = obj({ t: { type: 'number' }, position: vec3('metres on the floor'), facingDeg: { type: 'number' }, action: { type: 'string', maxLength: 80 } }, ['t', 'position']);

export const BLENDER_TOOLS: BlenderTool[] = [
  { name: 'blender_status', description: 'Is Blender reachable on the owner\'s Mac? Returns {connected, addonVersion, scene}.', inputSchema: obj({}), args: z.object({}).strict() },
  { name: 'blender_scene_info', description: 'Objects in the open Blender scene (names, types, locations).', inputSchema: obj({}), args: z.object({}).strict() },
  { name: 'blender_screenshot', description: 'A screenshot of the Blender viewport, returned to you as an image. Use it to check your blocking.',
    inputSchema: obj({ maxSize: { type: 'integer', minimum: 256, maximum: 1600 } }), args: z.object({ maxSize: z.number().int().min(256).max(1600).optional() }).strict() },
  { name: 'blender_setup_scene', description: 'Sets fps, frame range (from durationSec), resolution for the aspect, and a flat grey floor. clear=true first deletes every MUSE_* object (nothing else).',
    inputSchema: obj({ fps: { type: 'integer', minimum: 12, maximum: 60 }, durationSec: { type: 'number', minimum: 1, maximum: 30 }, aspect: { type: 'string', enum: [...ASPECTS] },
      resolutionShort: { type: 'integer', minimum: 480, maximum: 1080 }, clear: { type: 'boolean' } }, ['fps', 'durationSec', 'aspect']),
    args: z.object({ fps: z.number().int().min(12).max(60), durationSec: finite.min(1).max(30), aspect: z.enum(ASPECTS), resolutionShort: z.number().int().min(480).max(1080).optional(),
      clear: z.boolean().optional() }).strict() },
  { name: 'blender_place_character', description: 'Places a neutral grey proxy for a cast member (MUSE_char_<modelId>), scaled to her height, at a floor position, facing facingDeg (0 = facing -Y, toward a camera placed on -Y).',
    inputSchema: obj({ modelId: { type: 'string' }, label: { type: 'string', maxLength: 60 }, heightM: { type: 'number', minimum: 1.2, maximum: 2.2 }, position: vec3('metres'), facingDeg: { type: 'number' } },
      ['modelId', 'label', 'heightM', 'position']),
    args: z.object({ modelId: id, label: z.string().max(60), heightM: finite.min(1.2).max(2.2), position: Vec3, facingDeg: finite.min(-720).max(720).optional() }).strict() },
  { name: 'blender_animate_character', description: 'Keyframes a placed proxy\'s floor position and facing over time (seconds).',
    inputSchema: obj({ modelId: { type: 'string' }, keyframes: { type: 'array', minItems: 1, maxItems: 64, items: charKeySchema } }, ['modelId', 'keyframes']),
    args: z.object({ modelId: id, keyframes: z.array(CharKey).min(1).max(64).refine(ascending, 'keyframes must be in time order') }).strict() },
  { name: 'blender_add_prop', description: 'Adds a simple grey prop (MUSE_prop_<id>): box, cylinder, sphere or plane, size in metres.',
    inputSchema: obj({ id: { type: 'string' }, shape: { type: 'string', enum: ['box', 'cylinder', 'sphere', 'plane'] }, size: vec3('metres'), position: vec3('metres'), rotationDeg: vec3('degrees') },
      ['id', 'shape', 'size', 'position']),
    args: z.object({ id, shape: z.enum(['box', 'cylinder', 'sphere', 'plane']), size: z.tuple([finite.min(0.01).max(100), finite.min(0.01).max(100), finite.min(0.01).max(100)]),
      position: Vec3, rotationDeg: Vec3.optional() }).strict() },
  { name: 'blender_set_camera', description: 'Creates/updates the scene camera MUSE_camera with keyframes (position, look-at target, focal length, roll) and makes it the active camera.',
    inputSchema: obj({ keyframes: { type: 'array', minItems: 1, maxItems: 64, items: camKeySchema }, cuts: { type: 'array', maxItems: 32, items: { type: 'number' }, description: 'Hard cut times (s)' },
      sensorMm: { type: 'number', minimum: 4, maximum: 70 } }, ['keyframes']),
    args: z.object({ keyframes: z.array(CamKey).min(1).max(64).refine(ascending, 'keyframes must be in time order'), cuts: z.array(finite.min(0).max(60)).max(32).optional(),
      sensorMm: finite.min(4).max(70).optional() }).strict() },
  { name: 'blender_render_guides', description: 'Renders the guides on the Mac and uploads them to this session: greybox (flat-grey playblast video), keyframes (start/mid/end stills), camera_json (per-frame camera), characters_json (per-frame character positions and screen boxes). Takes up to a few minutes.',
    inputSchema: obj({ passes: { type: 'array', minItems: 1, items: { type: 'string', enum: ['greybox', 'keyframes', 'camera_json', 'characters_json'] } },
      resolutionShort: { type: 'integer', minimum: 480, maximum: 1080 } }, ['passes']),
    args: z.object({ passes: z.array(z.enum(['greybox', 'keyframes', 'camera_json', 'characters_json'])).min(1).max(4), resolutionShort: z.number().int().min(480).max(1080).optional() }).strict() },
];

export const blenderToolByName = new Map(BLENDER_TOOLS.map(t => [t.name, t]));
