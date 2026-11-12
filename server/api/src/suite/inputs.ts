// AI suite · provider inputs per adapter. Field names verified against each model's public schema (2026-11-05).
import type { ShotPlan } from './plan.js';
import type { ModelSpec } from './registry.js';

/** Signed URLs for the plan's media, in plan order. */
export type MediaUrls = { start?: string; middle: string[]; end?: string; refs: string[]; videos: string[]; /** The reference audio (or its instrumental). */ audio?: string };

const set = (o: Record<string, unknown>, k: string, v: unknown) => {
  if (v === undefined || v === null || (Array.isArray(v) && !v.length)) return;
  o[k] = v;
};

export function buildInput(m: ModelSpec, p: ShotPlan, u: MediaUrls): Record<string, unknown> {
  const i: Record<string, unknown> = { prompt: p.prompt };
  const frames = !!(u.start || u.end);
  switch (m.adapter) {
    case 'byo': return byoInput(m, p, u); // WS5: an owner-added model, filled from its own schema
    case 'hf-h3': // Higgsfield (api.higgsfield.ai): text-to-video / reference-to-video; 2K only; no watermark (labels are the user's choice)
      i.duration = p.seconds; i.resolution = '2K'; i.aspect_ratio = p.aspect; i.aigc_watermark = false;
      set(i, 'image_urls', u.refs.slice(0, 9)); set(i, 'video_urls', u.videos.slice(0, 3)); set(i, 'audio_urls', u.audio ? [u.audio] : undefined);
      break;
    case 'minimax-h3':
      i.duration = p.seconds;
      if (m.resolutions.length > 1) i.resolution = p.resolution;
      i.ratio = frames && m.id !== 'h3-lite' ? 'adaptive' : p.aspect;
      set(i, 'first_frame_image', u.start); set(i, 'last_frame_image', u.end);
      set(i, 'reference_image_urls', u.refs); set(i, 'reference_video_urls', u.videos.slice(0, 3)); set(i, 'reference_audio_urls', u.audio ? [u.audio] : undefined);
      break;
    case 'kling-v4':
      if (p.mode === 'recast' || p.mode === 'remix') { // edit the source clip (base_video): length and aspect come from it
        i.base_video = u.videos[0]; i.resolution = p.resolution; set(i, 'reference_images', u.refs.slice(0, 10));
        break;
      }
      i.duration = p.seconds; i.resolution = p.resolution; i.aspect_ratio = p.aspect;
      set(i, 'start_image', u.start); set(i, 'middle_images', u.middle); set(i, 'end_image', u.end);
      set(i, 'reference_images', u.refs); set(i, 'reference_videos', u.videos.slice(0, 5));
      break;
    case 'kling-v3-omni':
      i.duration = p.seconds; i.mode = p.resolution === '720p' ? 'standard' : p.resolution === '4k' ? '4k' : 'pro'; i.aspect_ratio = p.aspect;
      set(i, 'start_image', u.start); if (u.start) set(i, 'end_image', u.end);
      set(i, 'reference_images', u.refs);
      if (u.videos[0]) { i.reference_video = u.videos[0]; i.video_reference_type = 'feature'; i.generate_audio = false; }
      else i.generate_audio = p.audio;
      break;
    case 'seedance':
      if (p.mode === 'remix') { // New Swap: the clip as [Video1], the pictures as references; its own sound is not wanted (MUSE puts the clip's back)
        i.duration = Math.round(p.seconds); i.resolution = p.resolution; i.aspect_ratio = p.aspect; i.generate_audio = false;
        set(i, 'reference_videos', u.videos.slice(0, 1)); set(i, 'reference_images', u.refs); set(i, 'seed', p.seed);
        break;
      }
      i.duration = p.seconds; i.resolution = p.resolution; i.aspect_ratio = frames ? 'adaptive' : p.aspect; i.generate_audio = p.audio;
      if (frames) { set(i, 'image', u.start); if (u.start) set(i, 'last_frame_image', u.end); }
      else { set(i, 'reference_images', u.refs); set(i, 'reference_videos', u.videos); set(i, 'reference_audios', u.audio ? [u.audio] : undefined); }
      set(i, 'seed', p.seed);
      break;
    case 'veo':
      i.duration = p.seconds; i.resolution = p.resolution; i.aspect_ratio = p.aspect;
      set(i, 'image', u.start); set(i, 'last_frame', u.end); set(i, 'seed', p.seed);
      break;
    case 'wan-2.7':
      i.duration = p.kind === 'ref2v' ? Math.min(10, p.seconds) : p.seconds; i.resolution = p.resolution;
      if (p.kind !== 'i2v') i.aspect_ratio = p.aspect;
      set(i, 'negative_prompt', p.negative); set(i, 'seed', p.seed);
      if (p.extend?.method === 'clip') { i.first_clip = u.videos[0]; break; } // Extend: continue the clip (2–10 s)
      if (p.kind === 'i2v') { set(i, 'first_frame', u.start); if (u.start) set(i, 'last_frame', u.end); }
      if (p.kind === 'ref2v') { set(i, 'reference_images', u.refs); set(i, 'reference_videos', u.videos); }
      break;
    case 'ltx-2.3':
      i.task = u.start ? 'image_to_video' : 'text_to_video'; i.duration = p.seconds; i.resolution = p.resolution; i.aspect_ratio = p.aspect; i.generate_audio = p.audio;
      set(i, 'image', u.start); if (u.start) set(i, 'last_frame_image', u.end);
      Object.assign(i, p.params);
      break;
    case 'fal-h3-3d':
      i.video_url = u.videos[0]; i.resolution = p.resolution; set(i, 'reference_image_urls', u.refs.slice(0, 8));
      break;
    // ---- Recast (same take, new cast)
    case 'fal-h3-recast': // one photo per new person, left to right; who-is-who in the prompt; the source sound is kept
      i.video_url = u.videos[0]; i.reference_image_urls = u.refs.slice(0, 4); i.resolution = p.resolution; set(i, 'seed', p.seed);
      break;
    case 'kling-o1': // the source as the base video, references mapped by the prompt
      i.reference_video = u.videos[0]; i.video_reference_type = 'base'; set(i, 'reference_images', u.refs.slice(0, 4));
      i.keep_original_sound = p.recast?.keepAudio ?? p.remix?.keepAudio ?? true; i.mode = p.resolution === '720p' ? 'std' : 'pro';
      if (['9:16', '16:9', '1:1'].includes(p.aspect)) i.aspect_ratio = p.aspect;
      break;
    case 'wan-animate': { // one character per call; no prompt
      const o: Record<string, unknown> = { video: u.videos[0], character_image: u.refs[0], resolution: p.resolution === '480' ? '480' : '720', merge_audio: p.recast?.keepAudio ?? p.remix?.keepAudio ?? true };
      set(o, 'seed', p.seed);
      return o;
    }
    // ---- New Swap (remix, plans/new-swap.md)
    case 'wan-2.7-edit': // replicate.com/wan-video/wan-2.7-videoedit: the clip (2–10 s), the instruction, one reference picture
      i.video = u.videos[0]; i.resolution = p.resolution; i.aspect_ratio = 'auto'; i.audio_setting = 'origin';
      set(i, 'reference_image', u.refs[0]); set(i, 'seed', p.seed);
      break;
    case 'hf-genjutsu': // docs.higgsfield.ai genjutsu motion-transfer: video_url, image_urls 1–8, prompt in plain words ("image 1")
      return { video_url: u.videos[0], image_urls: u.refs.slice(0, 8), resolution: p.resolution,
        ...(p.prompt.trim() ? { prompt: p.prompt.replace(/<Image (\d+)>/g, 'image $1').replace(/<Video 1>/g, 'the source video').slice(0, 10000) } : {}) };
    case 'mock':
      Object.assign(i, { duration: p.seconds, resolution: p.resolution, aspect_ratio: p.aspect, start: u.start, middle: u.middle, end: u.end, refs: u.refs, videos: u.videos, audio: u.audio, ...p.params });
      break;
  }
  return i;
}

/**
 * Bring your own provider (WS5): fills an owner-added model's inputs from the roles its schema analysis found, on top of
 * the owner's fixed values for fields MUSE can't fill. Nothing outside the schema is sent.
 */
export function byoInput(m: ModelSpec, p: Pick<ShotPlan, 'prompt' | 'negative' | 'seconds' | 'aspect' | 'resolution' | 'seed' | 'audio'>, u: MediaUrls): Record<string, unknown> {
  const b = m.byo!, map = b.analysis.map, sh = b.analysis.shapes;
  const i: Record<string, unknown> = { ...b.fixed };
  if (map.prompt) i[map.prompt] = p.prompt;
  if (map.negativePrompt && p.negative) i[map.negativePrompt] = p.negative;
  if (map.startImage && u.start) i[map.startImage] = u.start;
  if (map.endImage && u.end && (u.start || !map.startImage)) i[map.endImage] = u.end;
  if (map.referenceImages) {
    const refs = u.refs.length ? u.refs : [];
    if (sh.referenceImages === 'single') { if (refs[0]) i[map.referenceImages] = refs[0]; }
    else if (refs.length) i[map.referenceImages] = refs.slice(0, Math.max(1, b.analysis.inputs.referenceImages));
  }
  const d = b.analysis.inputs.duration;
  if (map.duration && d) {
    let v = Math.max(d.min, Math.min(d.max, p.seconds));
    if (d.allowed?.length) v = d.allowed.reduce((a, c) => (Math.abs(c - p.seconds) < Math.abs(a - p.seconds) ? c : a));
    i[map.duration] = sh.duration === 'string' ? String(v) : sh.duration === 'integer' ? Math.round(v) : v;
  }
  if (map.aspectRatio && (!b.analysis.inputs.aspectRatios.length || b.analysis.inputs.aspectRatios.includes(p.aspect))) i[map.aspectRatio] = p.aspect;
  if (map.resolution && p.resolution && p.resolution !== 'auto') i[map.resolution] = p.resolution;
  if (map.seed && p.seed != null) i[map.seed] = p.seed;
  if (map.audio) i[map.audio] = p.audio;
  return i;
}
