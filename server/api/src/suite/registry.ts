// AI suite · video model registry (plans/ai-suite.md "Model registry"). One entry per hosted (or self-hosted) video model:
// what it can take (text, start/middle/end frames, reference images/videos/audio), its limits, how it is priced, its
// licence flags, and the provider that runs it. Input schemas and prices were read from each model's public page on
// 2026-11-05 (replicate.com/<owner>/<name>/api, fal.ai/models/<id>/llms.txt). Member-facing data never names any of this;
// only owner views (Settings → Engines / the suite settings) do.

export type ProviderId = 'replicate' | 'fal' | 'runpod' | 'mock';
export type ShotMode = 'text' | 'image' | 'reference' | 'swap';
export type Tier = 'draft' | 'standard' | 'hd' | 'cinema';
export const TIERS: Tier[] = ['draft', 'standard', 'hd', 'cinema'];
export const TIER_INFO: Record<Tier, { label: string; detail: string }> = {
  draft: { label: 'Draft', detail: 'Quick preview' },
  standard: { label: 'Standard', detail: 'Everyday quality' },
  hd: { label: 'HD', detail: 'Sharper, for posting' },
  cinema: { label: 'Cinema', detail: 'Best camera work and detail' },
};

/** How a model wants its inputs named in the prompt. */
export type RefStyle = 'angle' /* <Image 1>, <Video 1> */ | 'at' /* @image_1, @video_1 */ | 'triple' /* <<<image_1>>> */ | 'bracket' /* [Image1] */ | 'none';
/** Which camera wording template the compiler uses (prompt library keys suite.camera.format.*). */
export type CameraVocab = 'kling' | 'seedance' | 'h3' | 'veo' | 'wan' | 'ltx' | 'generic';
/** Which input mapper builds the provider input (suite/inputs.ts). */
export type Adapter = 'minimax-h3' | 'kling-v4' | 'kling-v3-omni' | 'seedance' | 'veo' | 'wan-2.7' | 'ltx-2.3' | 'fal-h3-3d' | 'mock';

export type Resolution = { id: string; label: string; shortSide: number; perSec: number; perSecWithVideo?: number; audioPerSec?: number };

export type ModelSpec = {
  id: string;
  name: string;
  provider: ProviderId;
  /** Provider model ref; per mode where a family has separate endpoints (Wan 2.7 t2v/i2v/r2v). */
  ref: string | Partial<Record<'t2v' | 'i2v' | 'ref2v' | 'guide', string>>;
  adapter: Adapter;
  modes: { text: boolean; image: boolean; reference: boolean; guide?: boolean };
  frames: { start: boolean; end: boolean; middle: number; /** frames and references can be combined */ withRefs: boolean };
  refs: { images: number; videos: number; audios: number; /** all images (frames + refs) together */ totalImages?: number; videoSecondsMax?: number; videoSecondsMin?: number };
  duration: { min: number; max: number; allowed?: number[]; /** billed at least this many seconds */ minBilled?: number };
  resolutions: Resolution[];
  aspectRatios: string[];
  fps?: number[];
  /** Native audio: 'always' (comes with it), 'flag' (generate_audio switch), 'none'. */
  audio: 'always' | 'flag' | 'none';
  negativePrompt: boolean;
  seed: boolean;
  camera: { vocab: CameraVocab; refStyle: RefStyle; /** a camera enum field and its values */ enumField?: string; enumValues?: string[]; referenceVideo: boolean };
  lora: boolean;
  promptMax?: number;
  licence: { kind: 'hosted' | 'open-weights'; name: string; notice?: string; territoryExcluded?: string[]; /** never offered for new features */ blockNewFeatures?: boolean;
    /** hidden until the owner acknowledges it in suite settings */ requiresAck?: boolean; notes?: string };
  status: 'active' | 'preview' | 'removed';
  notes?: string;
};

const R = (id: string, label: string, shortSide: number, perSec: number, extra: Partial<Resolution> = {}): Resolution => ({ id, label, shortSide, perSec, ...extra });
const hosted = (name: string, extra: Partial<ModelSpec['licence']> = {}): ModelSpec['licence'] => ({ kind: 'hosted', name, ...extra });
const AR_FULL = ['9:16', '16:9', '1:1', '4:3', '3:4', '21:9'];

export const MODELS: ModelSpec[] = [
  // ---------------------------------------------------------------- MiniMax H3 family (Replicate)
  { id: 'h3', name: 'MiniMax H3', provider: 'replicate', ref: 'minimax/h3', adapter: 'minimax-h3',
    modes: { text: true, image: true, reference: true }, frames: { start: true, end: true, middle: 0, withRefs: true },
    refs: { images: 9, videos: 3, audios: 3 }, duration: { min: 4, max: 15 },
    resolutions: [R('768P', '768P', 768, 0.08), R('2K', '2K', 1440, 0.13)], aspectRatios: AR_FULL,
    audio: 'always', negativePrompt: false, seed: false, camera: { vocab: 'h3', refStyle: 'angle', referenceVideo: true }, lora: false,
    licence: hosted('MiniMax H3 (hosted)', { notice: 'MiniMax H3' }), status: 'active' },
  { id: 'h3-lite', name: 'MiniMax H3 Lite', provider: 'replicate', ref: 'minimax/h3-lite', adapter: 'minimax-h3',
    modes: { text: true, image: true, reference: true }, frames: { start: true, end: true, middle: 0, withRefs: true },
    refs: { images: 9, videos: 3, audios: 3 }, duration: { min: 4, max: 15 },
    resolutions: [R('480P', '480P', 480, 0.0125), R('768P', '768P', 768, 0.02)], aspectRatios: AR_FULL,
    audio: 'always', negativePrompt: false, seed: false, camera: { vocab: 'h3', refStyle: 'angle', referenceVideo: true }, lora: false,
    licence: hosted('MiniMax H3 (hosted)', { notice: 'MiniMax H3' }), status: 'active' },
  { id: 'h3-highspeed', name: 'MiniMax H3 Highspeed', provider: 'replicate', ref: 'minimax/h3-highspeed', adapter: 'minimax-h3',
    modes: { text: true, image: true, reference: true }, frames: { start: true, end: true, middle: 0, withRefs: true },
    refs: { images: 9, videos: 3, audios: 3 }, duration: { min: 4, max: 15 },
    resolutions: [R('768P', '768P', 768, 0.03)], aspectRatios: AR_FULL,
    audio: 'always', negativePrompt: false, seed: false, camera: { vocab: 'h3', refStyle: 'angle', referenceVideo: true }, lora: false,
    licence: hosted('MiniMax H3 (hosted)', { notice: 'MiniMax H3' }), status: 'active', notes: 'No resolution field: always 768P.' },
  // The RunPod open-weights H3 ("Edit" path). Listed so the licence flag is explicit; never selected for suite shots.
  { id: 'h3-open', name: 'MiniMax H3 open weights (own GPU)', provider: 'runpod', ref: 'pipeline/runpod/h3_ref2va_run.py', adapter: 'mock',
    modes: { text: false, image: false, reference: true }, frames: { start: false, end: false, middle: 0, withRefs: false },
    refs: { images: 6, videos: 1, audios: 1 }, duration: { min: 1, max: 15 }, resolutions: [R('768x1344', '768×1344', 768, 0)], aspectRatios: ['9:16'],
    audio: 'none', negativePrompt: false, seed: true, camera: { vocab: 'h3', refStyle: 'angle', referenceVideo: true }, lora: true,
    licence: { kind: 'open-weights', name: 'MiniMax H3 Community Licence', notice: 'Powered by MiniMax H3', territoryExcluded: ['US', 'EU', 'UK', 'KR'], blockNewFeatures: true,
      notes: 'Excludes the US, EU, UK and South Korea (outputs included). Not used for new features; the owner decides the existing Edit path.' },
    status: 'active' },
  // ---------------------------------------------------------------- Kling (Replicate)
  { id: 'kling-v4', name: 'Kling 4.0', provider: 'replicate', ref: 'kwaivgi/kling-v4.0', adapter: 'kling-v4',
    modes: { text: true, image: true, reference: true, guide: true }, frames: { start: true, end: true, middle: 8, withRefs: true },
    refs: { images: 10, videos: 5, audios: 0, totalImages: 10, videoSecondsMin: 3, videoSecondsMax: 30 }, duration: { min: 3, max: 30 },
    resolutions: [R('720p', '720p', 720, 0.157, { perSecWithVideo: 0.094 }), R('1080p', '1080p', 1080, 0.235, { perSecWithVideo: 0.141 })],
    aspectRatios: ['9:16', '16:9', '1:1', '21:9'], audio: 'always', negativePrompt: false, seed: false,
    camera: { vocab: 'kling', refStyle: 'at', referenceVideo: true }, lora: false, promptMax: 26000,
    licence: hosted('Kling (hosted)'), status: 'active',
    notes: 'With a video input, billed seconds = output + the longer of the input videos or the output.' },
  { id: 'kling-v3-omni', name: 'Kling 3.0 Omni', provider: 'replicate', ref: 'kwaivgi/kling-v3-omni-video', adapter: 'kling-v3-omni',
    modes: { text: true, image: true, reference: true, guide: true }, frames: { start: true, end: true, middle: 0, withRefs: true },
    refs: { images: 7, videos: 1, audios: 0, videoSecondsMin: 3, videoSecondsMax: 10 }, duration: { min: 3, max: 15 },
    resolutions: [R('720p', '720p · standard', 720, 0.168, { audioPerSec: 0.224 }), R('1080p', '1080p · pro', 1080, 0.224, { audioPerSec: 0.28 }), R('4k', '4K', 2160, 0.42, { audioPerSec: 0.42 })],
    aspectRatios: ['9:16', '16:9', '1:1'], audio: 'flag', negativePrompt: false, seed: false,
    camera: { vocab: 'kling', refStyle: 'triple', referenceVideo: true }, lora: false, promptMax: 2500,
    licence: hosted('Kling (hosted)'), status: 'active', notes: 'At most 4 images with a reference video; no audio with a reference video; 4K takes no video.' },
  // ---------------------------------------------------------------- Seedance (Replicate)
  { id: 'seedance-2.0', name: 'Seedance 2.0', provider: 'replicate', ref: 'bytedance/seedance-2.0', adapter: 'seedance',
    modes: { text: true, image: true, reference: true, guide: true }, frames: { start: true, end: true, middle: 0, withRefs: false },
    refs: { images: 9, videos: 3, audios: 3, videoSecondsMax: 15 }, duration: { min: 4, max: 15 },
    resolutions: [R('480p', '480p', 480, 0.08, { perSecWithVideo: 0.10 }), R('720p', '720p', 720, 0.18, { perSecWithVideo: 0.22 }),
      R('1080p', '1080p', 1080, 0.45, { perSecWithVideo: 0.55 }), R('4k', '4K', 2160, 1.0, { perSecWithVideo: 1.25 })],
    aspectRatios: [...AR_FULL, '9:21'], audio: 'flag', negativePrompt: false, seed: true,
    camera: { vocab: 'seedance', refStyle: 'bracket', referenceVideo: true }, lora: false, promptMax: 4000,
    licence: hosted('Seedance (hosted)', { notes: 'May refuse realistic faces as references.' }), status: 'active' },
  { id: 'seedance-2.5', name: 'Seedance 2.5', provider: 'replicate', ref: 'bytedance/seedance-2.5', adapter: 'seedance',
    modes: { text: true, image: true, reference: true, guide: true }, frames: { start: true, end: true, middle: 0, withRefs: false },
    refs: { images: 30, videos: 10, audios: 10, videoSecondsMax: 30 }, duration: { min: 4, max: 30 },
    resolutions: [R('480p', '480p', 480, 0.1028, { perSecWithVideo: 0.4304 }), R('720p', '720p', 720, 0.2312, { perSecWithVideo: 0.9676 })],
    aspectRatios: AR_FULL, audio: 'flag', negativePrompt: false, seed: true,
    camera: { vocab: 'seedance', refStyle: 'bracket', referenceVideo: true }, lora: false,
    licence: hosted('Seedance (hosted)', { notes: 'May refuse realistic faces as references.' }), status: 'active',
    notes: 'Video references cost about 4× the no-video price.' },
  // ---------------------------------------------------------------- Veo (Replicate)
  { id: 'veo-3.1-lite', name: 'Veo 3.1 Lite', provider: 'replicate', ref: 'google/veo-3.1-lite', adapter: 'veo',
    modes: { text: true, image: true, reference: false }, frames: { start: true, end: true, middle: 0, withRefs: false },
    refs: { images: 0, videos: 0, audios: 0 }, duration: { min: 4, max: 8, allowed: [4, 6, 8] },
    resolutions: [R('720p', '720p', 720, 0.05), R('1080p', '1080p', 1080, 0.08)], aspectRatios: ['9:16', '16:9'],
    audio: 'always', negativePrompt: false, seed: true, camera: { vocab: 'veo', refStyle: 'none', referenceVideo: false }, lora: false,
    licence: hosted('Veo (hosted)', { notes: 'Outputs carry SynthID.' }), status: 'active', notes: '1080p only at 8 s.' },
  // ---------------------------------------------------------------- Wan 2.7 (Replicate; three endpoints)
  { id: 'wan-2.7', name: 'Wan 2.7', provider: 'replicate', ref: { t2v: 'wan-video/wan-2.7-t2v', i2v: 'wan-video/wan-2.7-i2v', ref2v: 'wan-video/wan-2.7-r2v' }, adapter: 'wan-2.7',
    modes: { text: true, image: true, reference: true }, frames: { start: true, end: true, middle: 0, withRefs: false },
    refs: { images: 5, videos: 3, audios: 0 }, duration: { min: 2, max: 15 },
    resolutions: [R('720p', '720p', 720, 0.10), R('1080p', '1080p', 1080, 0.10)], aspectRatios: ['9:16', '16:9', '1:1', '4:3', '3:4'],
    audio: 'always', negativePrompt: true, seed: true, camera: { vocab: 'wan', refStyle: 'none', referenceVideo: false }, lora: false,
    licence: hosted('Wan (hosted)'), status: 'active',
    notes: 'i2v is $0.15/s at 1080p (priced per endpoint in the estimator); r2v max 10 s; r2v reference videos are identity, not camera; i2v has no aspect ratio.' },
  // ---------------------------------------------------------------- LTX-2.3 Pro (Replicate): the only camera enum
  { id: 'ltx-2.3', name: 'LTX-2.3 Pro', provider: 'replicate', ref: 'lightricks/ltx-2.3-pro', adapter: 'ltx-2.3',
    modes: { text: true, image: true, reference: false }, frames: { start: true, end: true, middle: 0, withRefs: false },
    refs: { images: 0, videos: 0, audios: 0 }, duration: { min: 6, max: 10, allowed: [6, 8, 10] },
    resolutions: [R('1080p', '1080p', 1080, 0.08), R('2k', '2K', 1440, 0.16), R('4k', '4K', 2160, 0.32)], aspectRatios: ['9:16', '16:9'],
    fps: [24, 25, 48, 50], audio: 'flag', negativePrompt: false, seed: false,
    camera: { vocab: 'ltx', refStyle: 'none', referenceVideo: false, enumField: 'camera_motion',
      enumValues: ['none', 'dolly_in', 'dolly_out', 'dolly_left', 'dolly_right', 'jib_up', 'jib_down', 'static', 'focus_shift'] }, lora: false,
    licence: hosted('LTX (hosted)', { notes: 'Machine-generated content must be disclosed (LTX AUP).' }), status: 'active' },
  // ---------------------------------------------------------------- fal: Blender greybox → photoreal (Directed mode, workstream 2)
  { id: 'h3-max-3d', name: 'MiniMax H3 Max 3D-to-video', provider: 'fal', ref: 'minimax/h3-max/3d-to-video', adapter: 'fal-h3-3d',
    modes: { text: false, image: false, reference: false, guide: true }, frames: { start: false, end: false, middle: 0, withRefs: true },
    refs: { images: 8, videos: 1, audios: 0, videoSecondsMax: 15 }, duration: { min: 1, max: 15, minBilled: 5 },
    resolutions: [R('480P', '480P', 480, 0.05), R('768P', '768P', 768, 0.08), R('1080P', '1080P', 1080, 0.16)], aspectRatios: AR_FULL,
    audio: 'none', negativePrompt: false, seed: false, camera: { vocab: 'h3', refStyle: 'angle', referenceVideo: true }, lora: false,
    licence: hosted('MiniMax H3 Max (hosted on fal)', { notice: 'MiniMax H3' }), status: 'preview',
    notes: 'Duration comes from the guide clip; plus reference-token usage (estimate ≈ +$0.50 per job).' },
  // ---------------------------------------------------------------- removed
  { id: 'sora-2', name: 'Sora 2', provider: 'replicate', ref: 'openai/sora-2', adapter: 'mock',
    modes: { text: false, image: false, reference: false }, frames: { start: false, end: false, middle: 0, withRefs: false },
    refs: { images: 0, videos: 0, audios: 0 }, duration: { min: 4, max: 12 }, resolutions: [R('720p', '720p', 720, 0.1)], aspectRatios: ['9:16', '16:9'],
    audio: 'always', negativePrompt: false, seed: false, camera: { vocab: 'generic', refStyle: 'none', referenceVideo: false }, lora: false,
    licence: hosted('OpenAI (hosted)'), status: 'removed', notes: 'API shut down 2026-09-24.' },
];

/** The model used by the mock provider when SUITE_MODE=mock picks nothing better (it can do everything). */
export const MOCK_MODEL: ModelSpec = {
  id: 'mock', name: 'Test renderer (no spend)', provider: 'mock', ref: 'mock/video', adapter: 'mock',
  modes: { text: true, image: true, reference: true, guide: true }, frames: { start: true, end: true, middle: 8, withRefs: true },
  refs: { images: 10, videos: 5, audios: 3 }, duration: { min: 2, max: 30 }, resolutions: [R('720p', '720p', 720, 0)], aspectRatios: AR_FULL,
  audio: 'flag', negativePrompt: true, seed: true, camera: { vocab: 'generic', refStyle: 'angle', referenceVideo: true }, lora: false,
  licence: hosted('Test'), status: 'active',
};

const BY_ID = new Map(MODELS.map(m => [m.id, m]));
export const modelById = (id: string) => BY_ID.get(id) ?? (id === 'mock' ? MOCK_MODEL : undefined);

export type LadderStep = { model: string; resolution: string };
/**
 * The quality ladder: per tier, candidate models best-first. A shot takes the first candidate that is enabled, licensed,
 * set up and can do what the shot asks (mode, frames, references, guide, duration, aspect ratio). Owners can reorder it.
 */
export const DEFAULT_LADDER: Record<Tier, LadderStep[]> = {
  draft: [{ model: 'h3-lite', resolution: '768P' }, { model: 'veo-3.1-lite', resolution: '720p' }, { model: 'h3-highspeed', resolution: '768P' },
    { model: 'seedance-2.0', resolution: '480p' }, { model: 'wan-2.7', resolution: '720p' }],
  standard: [{ model: 'h3', resolution: '768P' }, { model: 'kling-v4', resolution: '720p' }, { model: 'seedance-2.0', resolution: '720p' },
    { model: 'wan-2.7', resolution: '1080p' }, { model: 'ltx-2.3', resolution: '1080p' }],
  hd: [{ model: 'h3', resolution: '2K' }, { model: 'kling-v4', resolution: '1080p' }, { model: 'veo-3.1-lite', resolution: '1080p' },
    { model: 'seedance-2.0', resolution: '1080p' }, { model: 'ltx-2.3', resolution: '2k' }],
  cinema: [{ model: 'kling-v4', resolution: '1080p' }, { model: 'seedance-2.5', resolution: '720p' }, { model: 'seedance-2.0', resolution: '1080p' },
    { model: 'h3', resolution: '2K' }, { model: 'kling-v3-omni', resolution: '1080p' }],
};

/** The provider ref to call for a mode. */
export function refFor(m: ModelSpec, kind: 't2v' | 'i2v' | 'ref2v' | 'guide'): string {
  if (typeof m.ref === 'string') return m.ref;
  return m.ref[kind] ?? m.ref.ref2v ?? m.ref.i2v ?? m.ref.t2v ?? '';
}

/** Owner view of a model (Settings → AI suite). */
export function modelView(m: ModelSpec, s?: { enabled?: boolean; acknowledgedAt?: number | null; priceScale?: number }, configured = true) {
  const blocked = m.status === 'removed' || !!m.licence.blockNewFeatures;
  return {
    id: m.id, name: m.name, provider: m.provider, ref: m.ref, status: m.status, modes: m.modes, frames: m.frames, refs: m.refs, duration: m.duration,
    resolutions: m.resolutions, aspectRatios: m.aspectRatios, fps: m.fps ?? null, audio: m.audio, camera: m.camera, lora: m.lora, licence: m.licence, notes: m.notes ?? null,
    enabled: !blocked && (s?.enabled ?? true), blocked, blockedReason: m.status === 'removed' ? 'Removed by the provider' : m.licence.blockNewFeatures ? 'Licence: not for new features' : null,
    needsAck: !!m.licence.requiresAck && !s?.acknowledgedAt, configured, priceScale: s?.priceScale ?? 1,
  };
}
