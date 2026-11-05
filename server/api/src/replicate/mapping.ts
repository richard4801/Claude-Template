// Any Replicate model for an image step (plans/api.md "Model tools" §2): read a model version's OpenAPI input schema,
// find the fields we know how to fill (prompt, image(s), size, seed, strength, scale, format, count), decide whether the
// model can do a step, and build the `input` for one prediction. `disable_safety_checker` (and any safety-checker switch)
// is never sent: it stays at the model's default.

export const IMAGE_STEPS = ['shot', 'edit', 'realism', 'upscale', 'dressA', 'dressB'] as const;
export type ImageStep = (typeof IMAGE_STEPS)[number];
export const STEP_LABELS: Record<ImageStep, string> = {
  shot: 'New shots', edit: 'Edits', realism: 'Enhance · realism', upscale: 'Enhance · upscale', dressA: 'Dress up · Option A', dressB: 'Dress up · Option B',
};

type Json = Record<string, any>;
/** The parts of a Replicate model object we read. */
export type RawModel = {
  owner: string; name: string; description?: string | null; run_count?: number; is_official?: boolean; url?: string; cover_image_url?: string | null;
  visibility?: string; latest_version?: { id: string; openapi_schema?: Json | null } | null;
};

export type MappedRole = 'prompt' | 'image' | 'images' | 'aspectRatio' | 'width' | 'height' | 'resolution' | 'seed' | 'strength' | 'scale' | 'outputFormat' | 'outputQuality' | 'count';
export type Mapping = {
  prompt?: string;
  image?: { field: string; array: boolean; max: number | null };
  extraImageFields?: string[];
  aspectRatio?: string; aspectValues?: string[];
  size?: { width: string; height: string; min?: number; max?: number };
  resolution?: string; resolutionValues?: string[];
  seed?: string;
  strength?: { field: string; min: number; max: number };
  scale?: { field: string; kind: 'number' | 'enum'; values?: string[]; min?: number; max?: number };
  outputFormat?: string; outputFormatValues?: string[];
  outputQuality?: string; outputQualityMax?: number;
  count?: string; countMin?: number;
};
export type InputField = { name: string; type: string; required: boolean; default?: unknown; enum?: unknown[]; minimum?: number; maximum?: number;
  maxItems?: number; description?: string; mappedAs?: MappedRole };
export type MapResult = { mapping: Mapping; compatible: boolean; reasons: string[]; warnings: string[]; inputs: InputField[] };

const PROMPT_NAMES = ['prompt', 'instruction', 'instructions', 'text', 'edit_prompt'];
const ARRAY_IMAGE_NAMES = ['input_images', 'images', 'image_input', 'image', 'reference_images', 'image_urls', 'input_image', 'ref_images', 'image_list'];
const SINGLE_IMAGE_NAMES = ['image', 'input_image', 'init_image', 'img', 'image_url', 'source_image', 'input', 'input_image_1', 'image_1', 'first_image', 'reference_image', 'subject_image'];
const EXTRA_IMAGE_RE = /^(input_)?image_?([2-9])$|^(second|third|fourth)_image$|^image_[b-e]$/;
const STRENGTH_NAMES = ['prompt_strength', 'strength', 'denoising_strength', 'creativity', 'image_strength'];
const SCALE_NAMES = ['scale_factor', 'scale', 'upscale_factor', 'upscale', 'upscale_by', 'outscale'];
const COUNT_NAMES = ['num_outputs', 'num_images', 'max_images', 'number_of_images', 'n'];
/** Never sent by us, and refused in the owner's extra inputs. */
export const isSafetySwitch = (k: string) => /safety_?checker|disable_safety/i.test(k);

/** Resolves a property: enums are `allOf: [{$ref: "#/components/schemas/x"}]`. */
function resolve(prop: Json, schemas: Json): Json {
  const ref = prop.allOf?.[0]?.$ref ?? prop.$ref ?? prop.anyOf?.find((x: Json) => x.$ref)?.$ref;
  if (typeof ref === 'string') {
    const k = ref.split('/').pop()!;
    const target = schemas[k] ?? {};
    return { ...target, ...prop, enum: target.enum ?? prop.enum, type: target.type ?? prop.type, allOf: undefined };
  }
  return prop;
}
const isUri = (p: Json) => p.type === 'string' && (p.format === 'uri' || /url|uri/i.test(p.format ?? ''));
const isUriArray = (p: Json) => p.type === 'array' && p.items && (p.items.format === 'uri' || p.items.type === 'string' && /image/i.test(JSON.stringify(p.items)) );

export function schemasOf(raw: RawModel): Json | null {
  return raw.latest_version?.openapi_schema?.components?.schemas ?? null;
}

/** Whether the model returns image(s): a URI or a list of URIs (missing Output = assume yes). */
function outputIsImage(schemas: Json) {
  const o = schemas.Output;
  if (!o) return true;
  if (isUri(o)) return true;
  if (o.type === 'array' && o.items && (o.items.format === 'uri' || o.items.type === 'string')) return true;
  if (o.type === 'object' && o.properties) return Object.values(o.properties as Json).some((p: any) => isUri(p) || p?.type === 'array');
  return false;
}

/** Reads a model's input schema into a mapping and decides whether it can do `step`. */
export function mapModel(raw: RawModel, step: ImageStep): MapResult {
  const schemas = schemasOf(raw);
  if (!schemas?.Input?.properties) return { mapping: {}, compatible: false, reasons: ["its inputs can't be read"], warnings: [], inputs: [] };
  const input = schemas.Input as Json;
  const required: string[] = Array.isArray(input.required) ? input.required : [];
  const props: Record<string, Json> = {};
  for (const [k, v] of Object.entries(input.properties as Json)) props[k] = resolve(v as Json, schemas);
  const names = Object.keys(props);
  const m: Mapping = {};
  const roles = new Map<string, MappedRole>();
  const take = (k: string, role: MappedRole) => { roles.set(k, role); return k; };

  const prompt = PROMPT_NAMES.find(n => props[n] && props[n]!.type === 'string');
  if (prompt) m.prompt = take(prompt, 'prompt');

  // Image input: an array field first (several references), else a single one, plus image_2/image_3… as more images.
  const arr = ARRAY_IMAGE_NAMES.find(n => props[n] && isUriArray(props[n]!)) ?? names.find(n => /image/i.test(n) && !/mask|control/i.test(n) && isUriArray(props[n]!));
  if (arr) m.image = { field: take(arr, 'images'), array: true, max: typeof props[arr]!.maxItems === 'number' ? props[arr]!.maxItems : maxImagesFromText(props[arr]!.description) };
  else {
    const single = SINGLE_IMAGE_NAMES.find(n => props[n] && isUri(props[n]!)) ?? names.find(n => /image|photo|img/i.test(n) && !/mask|control|style|depth|pose|background/i.test(n) && !EXTRA_IMAGE_RE.test(n) && isUri(props[n]!));
    if (single) m.image = { field: take(single, 'image'), array: false, max: 1 };
  }
  if (m.image && !m.image.array) {
    const extra = names.filter(n => n !== m.image!.field && EXTRA_IMAGE_RE.test(n) && isUri(props[n]!)).sort();
    if (extra.length) { m.extraImageFields = extra; extra.forEach(n => take(n, 'image')); }
  }

  const ar = props.aspect_ratio;
  if (ar && (ar.enum || ar.type === 'string')) { m.aspectRatio = take('aspect_ratio', 'aspectRatio'); m.aspectValues = (ar.enum ?? []).map(String); }
  if (props.width && props.height && ['integer', 'number'].includes(props.width.type)) {
    m.size = { width: take('width', 'width'), height: take('height', 'height'), min: props.width.minimum, max: props.width.maximum };
  }
  const res = ['resolution', 'megapixels'].find(n => props[n]?.enum);
  if (res) { m.resolution = take(res, 'resolution'); m.resolutionValues = props[res]!.enum.map(String); }
  if (props.seed && ['integer', 'number'].includes(props.seed.type)) m.seed = take('seed', 'seed');
  const st = STRENGTH_NAMES.find(n => props[n] && ['number', 'integer'].includes(props[n]!.type));
  if (st) m.strength = { field: take(st, 'strength'), min: props[st]!.minimum ?? 0, max: props[st]!.maximum ?? 1 };
  const sc = SCALE_NAMES.find(n => props[n] && (props[n]!.enum || ['number', 'integer'].includes(props[n]!.type)));
  if (sc) {
    const p = props[sc]!;
    m.scale = p.enum ? { field: take(sc, 'scale'), kind: 'enum', values: p.enum.map(String) } : { field: take(sc, 'scale'), kind: 'number', min: p.minimum, max: p.maximum };
  }
  if (props.output_format?.enum) { m.outputFormat = take('output_format', 'outputFormat'); m.outputFormatValues = props.output_format.enum.map(String); }
  if (props.output_quality && ['integer', 'number'].includes(props.output_quality.type)) { m.outputQuality = take('output_quality', 'outputQuality'); m.outputQualityMax = props.output_quality.maximum; }
  const cnt = COUNT_NAMES.find(n => props[n] && ['integer', 'number'].includes(props[n]!.type));
  if (cnt) { m.count = take(cnt, 'count'); m.countMin = props[cnt]!.minimum; }

  const reasons: string[] = [], warnings: string[] = [];
  for (const r of required) if (!roles.has(r) && props[r]?.default === undefined) reasons.push(`needs ${r}`);
  if (!outputIsImage(schemas)) reasons.push("doesn't return an image");
  const imageCount = !m.image ? 0 : m.image.array ? (m.image.max ?? 99) : 1 + (m.extraImageFields?.length ?? 0);
  const needsPrompt = step !== 'upscale';
  if (needsPrompt && !m.prompt) reasons.push('has no prompt');
  if (step !== 'shot' && !m.image) reasons.push('needs an input image');
  if ((step === 'dressA' || step === 'dressB') && m.image && imageCount < 2) reasons.push('takes one photo · Dress up needs the sheet photo and the outfit');
  if (step === 'shot' && !m.image) warnings.push('no reference images · faces may drift');
  if (step === 'shot' && m.image && imageCount < 3) warnings.push(`takes ${imageCount} reference${imageCount === 1 ? '' : 's'} only`);
  if (step === 'realism' && !m.strength) warnings.push('no strength control · presets do nothing');
  if (step === 'upscale' && !m.scale) warnings.push('no scale control · 2× / 4× do nothing');
  const inputs: InputField[] = names.map(n => {
    const p = props[n]!;
    const f: InputField = { name: n, type: p.enum ? 'enum' : p.type ?? 'string', required: required.includes(n) };
    if (p.default !== undefined) f.default = p.default;
    if (p.enum) f.enum = p.enum;
    if (typeof p.minimum === 'number') f.minimum = p.minimum;
    if (typeof p.maximum === 'number') f.maximum = p.maximum;
    if (typeof p.maxItems === 'number') f.maxItems = p.maxItems;
    if (typeof p.description === 'string') f.description = p.description.slice(0, 300);
    const role = roles.get(n);
    if (role) f.mappedAs = role;
    return f;
  }).sort((a, b) => ((input.properties[a.name]?.['x-order'] ?? 99) - (input.properties[b.name]?.['x-order'] ?? 99)));
  return { mapping: m, compatible: reasons.length === 0, reasons, warnings, inputs };
}

const ratioOf = (s: string) => { const r = /^(\d+(?:\.\d+)?)\s*:\s*(\d+(?:\.\d+)?)$/.exec(s); return r ? Number(r[1]) / Number(r[2]) : null; };
/** The enum value nearest to w/h ("9:16", "3:4" …); "match_input_image" when wanted and offered. */
export function nearestAspect(values: string[], w: number, h: number, matchInput = false) {
  if (matchInput && values.includes('match_input_image')) return 'match_input_image';
  const target = w / h;
  let best: string | null = null, bestD = Infinity;
  for (const v of values) {
    const r = ratioOf(v);
    if (r == null) continue;
    const d = Math.abs(Math.log(r / target));
    if (d < bestD) { bestD = d; best = v; }
  }
  return best;
}
const mpOf = (v: string) => { const r = /^(\d+(?:\.\d+)?)\s*(mp)?$/i.exec(v.trim()); return r ? Number(r[1]) : null; };

export type BuildArgs = {
  prompt?: string; images: string[]; width?: number; height?: number; matchInput?: boolean; outMp?: number;
  seed?: number; strength?: number; scale?: number;
};
/** The `input` of one prediction: the mapped fields, then the owner's extra inputs (never a safety-checker switch). */
export function buildInput(m: Mapping, a: BuildArgs, extra: Record<string, unknown> = {}): Record<string, unknown> {
  const input: Record<string, unknown> = {};
  if (m.prompt && a.prompt) input[m.prompt] = a.prompt;
  if (m.image && a.images.length) {
    if (m.image.array) input[m.image.field] = m.image.max ? a.images.slice(0, m.image.max) : a.images;
    else {
      input[m.image.field] = a.images[0];
      (m.extraImageFields ?? []).forEach((f, i) => { if (a.images[i + 1]) input[f] = a.images[i + 1]; });
    }
  }
  if (a.width && a.height) {
    if (m.aspectRatio && m.aspectValues?.length) {
      const v = nearestAspect(m.aspectValues, a.width, a.height, a.matchInput);
      if (v) input[m.aspectRatio] = v;
    } else if (m.size) {
      const clamp = (v: number) => Math.round(Math.min(m.size!.max ?? 2048, Math.max(m.size!.min ?? 256, v)) / 16) * 16;
      input[m.size.width] = clamp(a.width); input[m.size.height] = clamp(a.height);
    }
  }
  if (m.resolution && m.resolutionValues?.length && a.outMp) {
    let best: string | null = null, bestD = Infinity;
    for (const v of m.resolutionValues) { const mp = mpOf(v); if (mp != null && Math.abs(mp - a.outMp) < bestD) { bestD = Math.abs(mp - a.outMp); best = v; } }
    if (best) input[m.resolution] = best;
  }
  if (m.seed && a.seed != null) input[m.seed] = a.seed;
  if (m.strength && a.strength != null) input[m.strength.field] = Math.min(m.strength.max, Math.max(m.strength.min, a.strength));
  if (m.scale && a.scale != null) {
    if (m.scale.kind === 'number') input[m.scale.field] = Math.min(m.scale.max ?? 16, Math.max(m.scale.min ?? 1, a.scale));
    else {
      const want = a.scale;
      const pick = (m.scale.values ?? []).map(v => ({ v, n: Number(/(\d+(?:\.\d+)?)/.exec(v)?.[1] ?? NaN) })).filter(x => Number.isFinite(x.n))
        .sort((x, y) => Math.abs(x.n - want) - Math.abs(y.n - want))[0];
      if (pick) input[m.scale.field] = pick.v;
    }
  }
  if (m.outputFormat && m.outputFormatValues) {
    const f = ['jpg', 'jpeg'].find(x => m.outputFormatValues!.includes(x));
    if (f) input[m.outputFormat] = f;
  }
  if (m.outputQuality && (m.outputQualityMax ?? 100) >= 95) input[m.outputQuality] = 95;
  if (m.count) input[m.count] = Math.max(1, m.countMin ?? 1);
  for (const [k, v] of Object.entries(extra)) if (!isSafetySwitch(k)) input[k] = v;
  for (const k of Object.keys(input)) if (isSafetySwitch(k)) delete input[k];
  return input;
}

/** Models whose `safety_tolerance` we set (FLUX.2 and FLUX Kontext); every other model keeps its own default. */
export const SAFETY_MODEL_RE = /^black-forest-labs\/flux-(2|kontext)/;
/**
 * The `safety_tolerance` to send (owner decision 2026-11-05: as permissive as the model allows, REPLICATE_IMAGE_SAFETY = 5),
 * clamped to the field's schema range and to a lower limit its description states for requests with input images
 * ("2 is currently the maximum allowed when input images are used", FLUX Kontext). Null: don't send it.
 */
export function safetyTolerance(model: string, inputs: InputField[], want: number, hasImages: boolean): number | null {
  const f = inputs.find(i => i.name === 'safety_tolerance');
  if (!f || !SAFETY_MODEL_RE.test(model)) return null;
  let v = Math.round(want);
  if (typeof f.maximum === 'number') v = Math.min(v, f.maximum);
  const withImages = /(\d+)\s+is\s+(?:currently\s+)?the\s+maximum\s+allowed\s+when\s+input\s+images?\s+are\s+used/i.exec(f.description ?? '');
  if (hasImages && withImages) v = Math.min(v, Number(withImages[1]));
  if (typeof f.minimum === 'number') v = Math.max(v, f.minimum);
  return v;
}

/** How many images the mapping can take in one prediction. */
export const imageCapacity = (m: Mapping) => !m.image ? 0 : m.image.array ? (m.image.max ?? 16) : 1 + (m.extraImageFields?.length ?? 0);

/**
 * Many models state their image limit only in the field description ("Maximum 5 images", "supports up to 14 images",
 * "List of 1-10 images"), not as JSON-schema maxItems. Returns that number, or null when the text doesn't say.
 */
export function maxImagesFromText(desc: unknown): number | null {
  if (typeof desc !== 'string') return null;
  const pats = [
    /\bmax(?:imum)?(?:\s+of)?\s+(\d{1,2})\s+(?:input\s+|reference\s+)?images?\b/i,
    /\bup\s+to\s+(\d{1,2})\s+(?:input\s+|reference\s+)?images?\b/i,
    /\b\d{1,2}\s*[-\u2013]\s*(\d{1,2})\s+(?:input\s+|reference\s+)?images?\b/i,
    /\bat\s+most\s+(\d{1,2})\s+(?:input\s+|reference\s+)?images?\b/i,
  ];
  for (const re of pats) { const m = re.exec(desc); if (m) { const n = Number(m[1]); if (n >= 1 && n <= 64) return n; } }
  return null;
}
