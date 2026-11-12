// AI suite (workstream 1, plans/ai-suite-design.md build step 2): the composer's full draft stored with each job and
// photo (so "Reuse settings" restores it exactly), saved rigs and a model's default rig. Pure: schemas and helpers.
import { z } from 'zod';
import { badRequest } from '../errors.js';
import { APERTURES, BODIES, ERAS, GENRES, HEIGHTS, LENSES, LIGHTING, LOOKS, MOVES, PALETTES, SHOT_SIZES, TEMPOS, UGC_FORMATS, type Option } from './camera.js';

/** The composer's tools (the clients' ComposerTool ids) plus `upscale`, which only the feed names. */
export const TOOLS = ['shot', 'photo', 'storyboard', 'swap', 'recast', 'extend', 'upscale', 'talking', 'ugc', 'remix' /* New Swap (beta), shown as "Swap" */] as const;
export type Tool = (typeof TOOLS)[number];

const ids = (l: { id: string }[]) => new Set(l.map(x => x.id));
const pick = (what: string, l: Option[] | { id: string }[]) => {
  const ok = ids(l);
  return z.string().max(64).refine(v => ok.has(v), v => ({ message: `unknown ${what} "${v}"` }));
};

/**
 * A rig: the composer's rig rows by catalog id (the same names as the clients' ComposerSettings). Every field is
 * optional: a missing field is "Auto". Ids are checked against the camera catalog (hidden and merged ids included).
 */
export const RigSchema = z.object({
  body: pick('camera body', BODIES).optional(),
  lens: pick('lens', LENSES).optional(),
  focalMm: z.number().min(8).max(200).optional(),
  aperture: pick('aperture', APERTURES).optional(),
  height: pick('angle', HEIGHTS).optional(),
  shotSize: pick('framing', SHOT_SIZES).optional(),
  lighting: pick('lighting', LIGHTING).optional(),
  palette: pick('palette', PALETTES).optional(),
  stock: pick('film stock', LOOKS).optional(),
  /** Grade the take with the Look (false = only describe it in the prompt). */
  gradeLook: z.boolean().optional(),
  genre: pick('genre', GENRES).optional(),
  era: pick('era', ERAS).optional(),
  tempo: pick('tempo', TEMPOS).optional(),
  format: pick('format', UGC_FORMATS).optional(),
  /** Optional moves (at most 2), applied as `#` chips. */
  moves: z.array(z.object({ id: pick('move', MOVES), intensity: z.number().min(0).max(1).optional() }).strict()).max(2).optional(),
}).strict();
export type Rig = z.infer<typeof RigSchema>;

const MAX_DRAFT_BYTES = 64 * 1024;

/**
 * The composer's draft as the client sent it: the tool, the bottom-bar values, the rig, the prompt tokens with their
 * chip keys and the input slots. The server reads `tool` (the feed's filter) and the values for the summary line;
 * everything else is kept as sent (≤ 64 KB) and handed back for "Reuse settings".
 */
export const DraftSchema = z.object({
  v: z.number().int().min(1).max(99).default(1),
  tool: z.enum(TOOLS),
  quality: z.string().max(32).optional(),
  aspect: z.string().max(16).optional(),
  duration: z.number().min(0).max(120).optional(),
  takes: z.number().int().min(1).max(8).optional(),
  count: z.number().int().min(1).max(8).optional(),
  sound: z.boolean().optional(),
  speaking: z.boolean().nullable().optional(),
  rig: z.record(z.string(), z.unknown()).optional(),
  tokens: z.array(z.unknown()).max(400).optional(),
  slots: z.unknown().optional(),
}).passthrough().refine(d => JSON.stringify(d).length <= MAX_DRAFT_BYTES, { message: `a draft is at most ${MAX_DRAFT_BYTES / 1024} KB` });
export type Draft = z.infer<typeof DraftSchema>;

/** A request's optional `draft`, checked; a bad draft is refused rather than dropped (the client would lose it silently). */
export function draftOf(body: unknown): Draft | null {
  const raw = (body as { draft?: unknown } | null)?.draft;
  if (raw == null) return null;
  const r = DraftSchema.safeParse(raw);
  if (!r.success) throw badRequest(`Invalid draft: ${r.error.issues[0]?.path.join('.')} ${r.error.issues[0]?.message}`);
  return r.data;
}

const secs = (n: number) => `${Number.isInteger(n) ? n : Math.round(n * 10) / 10} s`;

/** The feed's one line, in caption style: "9:16, 10 s, 1 take, sound on" (photos: "9:16, 4 photos"). */
export function draftSummary(d: Partial<Draft> | null | undefined, fallback: { aspect?: string; seconds?: number; takes?: number; count?: number; sound?: boolean } = {}): string {
  const aspect = d?.aspect ?? fallback.aspect;
  const tool = d?.tool;
  const parts: string[] = [];
  if (aspect) parts.push(aspect);
  if (tool === 'photo' || (!tool && fallback.count)) {
    const n = d?.count ?? fallback.count;
    if (n) parts.push(`${n} photo${n === 1 ? '' : 's'}`);
    return parts.join(', ');
  }
  const seconds = d?.duration ?? fallback.seconds;
  if (seconds) parts.push(secs(seconds));
  const takes = d?.takes ?? fallback.takes;
  if (takes) parts.push(`${takes} take${takes === 1 ? '' : 's'}`);
  const sound = d?.sound ?? fallback.sound;
  if (sound != null) parts.push(sound ? 'sound on' : 'sound off');
  return parts.join(', ');
}

/** "9:16" from a width and height (the closest of the composer's shapes), or undefined. */
export function aspectOf(w?: unknown, h?: unknown): string | undefined {
  const W = Number(w), H = Number(h);
  if (!(W > 0 && H > 0)) return undefined;
  const shapes: [string, number][] = [['9:16', 9 / 16], ['16:9', 16 / 9], ['1:1', 1], ['4:5', 4 / 5], ['3:4', 3 / 4], ['4:3', 4 / 3], ['21:9', 21 / 9], ['2:3', 2 / 3]];
  const r = W / H;
  return shapes.reduce((a, b) => (Math.abs(Math.log(b[1] / r)) < Math.abs(Math.log(a[1] / r)) ? b : a))[0];
}
