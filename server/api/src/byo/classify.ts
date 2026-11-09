// Bring your own provider · reading a model's input schema (OpenAPI / JSON Schema, as Replicate and fal publish them).
// Each input field is matched to a role MUSE knows how to fill (prompt, negative prompt, start/end frame, reference
// images, duration, aspect ratio, resolution, seed, sound, width/height). The model is classed as image or video from the
// provider's category, its output and its inputs. A required field with no role and no default makes it "needs setup":
// the owner gives that field a fixed value before the model can be switched on.

export type Kind = 'image' | 'video';
export type Role = 'prompt' | 'negativePrompt' | 'startImage' | 'endImage' | 'referenceImages' | 'duration' | 'aspectRatio' | 'resolution' | 'seed' | 'audio' | 'width' | 'height';
export type FieldMap = Partial<Record<Role, string>>;

/** What MUSE can send this model (member-safe numbers, no field names). */
export type Inputs = {
  prompt: boolean; negativePrompt: boolean; startImage: boolean; endImage: boolean;
  /** How many reference images it takes (0 = none). */
  referenceImages: number;
  duration: { min: number; max: number; allowed?: number[] } | null;
  aspectRatios: string[]; resolutions: string[]; seed: boolean;
};

export type Analysis = {
  kind: Kind | null;
  inputs: Inputs;
  /** Role → the provider's field name (server only). */
  map: FieldMap;
  /** How each mapped field wants its value: a single URL or a list; a number or a string. */
  shapes: { referenceImages?: 'array' | 'single'; duration?: 'integer' | 'number' | 'string' };
  /** Required fields MUSE can't fill and the model gives no default for. */
  missing: string[];
  /** Every input field name (for the owner's needs-setup view). */
  fields: string[];
  /** The start frame is required: the model can't make a shot from text alone. */
  startRequired: boolean;
};

type Json = Record<string, any>;

/** Follows `$ref`, single `allOf` and nullable `anyOf`/`oneOf` wrappers. */
export function resolve(root: Json, s: Json | undefined, depth = 0): Json {
  if (!s || typeof s !== 'object' || depth > 8) return s ?? {};
  if (typeof s.$ref === 'string') {
    const path = s.$ref.replace(/^#\//, '').split('/');
    let t: any = root;
    for (const p of path) t = t?.[decodeURIComponent(p)];
    return resolve(root, { ...(t ?? {}), ...Object.fromEntries(Object.entries(s).filter(([k]) => k !== '$ref')) }, depth + 1);
  }
  for (const k of ['allOf', 'anyOf', 'oneOf'] as const) {
    if (Array.isArray(s[k])) {
      const parts = (s[k] as Json[]).map(x => resolve(root, x, depth + 1)).filter(x => x.type !== 'null');
      if (parts.length === 1) {
        const rest = Object.fromEntries(Object.entries(s).filter(([kk]) => kk !== k));
        return { ...parts[0], ...rest };
      }
    }
  }
  return s;
}

const isUri = (p: Json) => p.type === 'string' && (p.format === 'uri' || p.format === 'binary' || /url|uri/i.test(p.title ?? '') );
const isUriArray = (p: Json, root: Json) => p.type === 'array' && isUri(resolve(root, p.items));

const NAMES: Record<Exclude<Role, 'referenceImages'>, string[]> = {
  prompt: ['prompt', 'text', 'text_prompt', 'caption'],
  negativePrompt: ['negative_prompt', 'negative', 'negative_text'],
  startImage: ['start_image', 'first_frame_image', 'first_frame', 'image', 'image_url', 'input_image', 'start_image_url', 'init_image', 'first_frame_url', 'images_list'],
  endImage: ['end_image', 'last_frame_image', 'last_frame', 'end_image_url', 'tail_image_url', 'last_frame_url', 'end_frame', 'last_image'],
  duration: ['duration', 'seconds', 'duration_seconds', 'video_length', 'length'],
  aspectRatio: ['aspect_ratio', 'ratio'],
  resolution: ['resolution', 'video_resolution'],
  seed: ['seed'],
  audio: ['generate_audio', 'audio', 'with_audio', 'enable_audio', 'sound', 'generate_audio_switch'],
  width: ['width'],
  height: ['height'],
};
const REF_NAMES = ['reference_images', 'reference_image_urls', 'image_urls', 'input_images', 'images', 'image_input', 'ref_images', 'reference_image', 'ref_image', 'subject_reference', 'images_list'];

const numList = (vals: unknown[]) => vals.map(v => Number(v)).filter(v => Number.isFinite(v) && v > 0).sort((a, b) => a - b);

/**
 * Reads an input schema (`components.schemas.Input` on Replicate, the request body schema on fal). `root` is the whole
 * OpenAPI document so `$ref`s resolve. `hint` is what the provider says the model is (fal's category, a Replicate
 * collection, the model's name and description).
 */
export function analyse(root: Json, input: Json | undefined, hint: { category?: string | null; text?: string; output?: Json | null } = {}): Analysis {
  const schema = resolve(root, input);
  const props: Record<string, Json> = Object.fromEntries(Object.entries((schema.properties ?? {}) as Record<string, Json>).map(([k, v]) => [k, resolve(root, v)]));
  const required = new Set<string>(Array.isArray(schema.required) ? schema.required : []);
  const names = Object.keys(props);
  const map: FieldMap = {};
  const shapes: Analysis['shapes'] = {};
  const take = (role: Exclude<Role, 'referenceImages'>, ok: (p: Json) => boolean) => {
    const n = NAMES[role].find(x => props[x] && ok(props[x]!) && !Object.values(map).includes(x));
    if (n) map[role] = n;
  };
  take('prompt', p => p.type === 'string' && !isUri(p));
  take('negativePrompt', p => p.type === 'string');
  // A list of images is references; a single image is a start frame (video) or the image to work from (image models).
  const refArr = REF_NAMES.find(x => props[x] && isUriArray(props[x]!, root));
  if (refArr) { map.referenceImages = refArr; shapes.referenceImages = 'array'; }
  take('startImage', p => isUri(p) || (p.type === 'string' && /image|frame/i.test(p.description ?? '')));
  take('endImage', p => isUri(p) || p.type === 'string');
  take('duration', p => ['integer', 'number', 'string'].includes(p.type) || Array.isArray(p.enum));
  take('aspectRatio', p => p.type === 'string' || Array.isArray(p.enum));
  take('resolution', p => p.type === 'string' || Array.isArray(p.enum));
  take('seed', p => p.type === 'integer' || p.type === 'number');
  take('audio', p => p.type === 'boolean');
  take('width', p => p.type === 'integer' || p.type === 'number');
  take('height', p => p.type === 'integer' || p.type === 'number');

  // ---- kind
  const cat = (hint.category ?? '').toLowerCase();
  const text = `${hint.text ?? ''}`.toLowerCase();
  const out = hint.output ? resolve(root, hint.output) : null;
  const outText = JSON.stringify(out ?? {}).toLowerCase();
  let kind: Kind | null = null;
  if (/video/.test(cat.split('-to-').at(-1) ?? '')) kind = 'video';
  else if (/image/.test(cat.split('-to-').at(-1) ?? '')) kind = 'image';
  else if (/"video"/.test(outText) || /\.mp4/.test(outText)) kind = 'video';
  else if (/"images?"/.test(outText)) kind = 'image';
  else if (map.duration || map.endImage || names.some(n => /^(fps|num_frames|frames|frame_rate)$/.test(n))) kind = 'video';
  else if (/\bvideo\b|text-to-video|image-to-video/.test(text)) kind = 'video';
  else if (map.width || names.some(n => /^(num_outputs|num_images|output_format|guidance_scale)$/.test(n)) || /\b(image|photo|picture)\b/.test(text)) kind = 'image';

  // An image model's single image input is a reference (the image to edit or follow), not a start frame.
  if (kind === 'image' && map.startImage && !map.referenceImages) { map.referenceImages = map.startImage; shapes.referenceImages = 'single'; delete map.startImage; }
  if (kind === 'image') delete map.endImage;
  if (kind === 'image') { delete map.duration; delete map.audio; }

  // ---- values
  const d = map.duration ? props[map.duration]! : null;
  let duration: Inputs['duration'] = null;
  if (d) {
    shapes.duration = d.type === 'string' ? 'string' : d.type === 'integer' ? 'integer' : 'number';
    if (Array.isArray(d.enum) && d.enum.length) {
      const allowed = numList(d.enum);
      if (allowed.length) duration = { min: allowed[0]!, max: allowed.at(-1)!, allowed };
    } else {
      const min = Number(d.minimum ?? d.exclusiveMinimum ?? 1), max = Number(d.maximum ?? d.exclusiveMaximum ?? Math.max(min, Number(d.default) || 10));
      duration = { min: Number.isFinite(min) && min > 0 ? min : 1, max: Number.isFinite(max) && max > 0 ? max : 10 };
    }
  }
  const enumOf = (role: Role) => { const p = map[role] ? props[map[role]!] : null; return Array.isArray(p?.enum) ? (p!.enum as unknown[]).map(String) : []; };
  const aspects = enumOf('aspectRatio').filter(a => /^\d+:\d+$/.test(a));
  const refItems = map.referenceImages && shapes.referenceImages === 'array' ? props[map.referenceImages]! : null;
  const referenceImages = !map.referenceImages ? 0 : shapes.referenceImages === 'single' ? 1 : Math.max(1, Math.min(10, Number(refItems?.maxItems) || 4));

  // ---- missing: required, no default, not filled by MUSE
  const filled = new Set(Object.values(map));
  const missing = names.filter(n => required.has(n) && !filled.has(n) && props[n]!.default === undefined);
  if (!map.prompt) missing.unshift('prompt');

  return {
    kind,
    inputs: { prompt: !!map.prompt, negativePrompt: !!map.negativePrompt, startImage: !!map.startImage, endImage: !!map.endImage, referenceImages,
      duration, aspectRatios: aspects, resolutions: enumOf('resolution'), seed: !!map.seed },
    map, shapes, missing: [...new Set(missing)], fields: names,
    startRequired: !!map.startImage && required.has(map.startImage) && props[map.startImage]!.default === undefined,
  };
}

