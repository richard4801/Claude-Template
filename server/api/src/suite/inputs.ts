// AI suite · provider inputs per adapter. Field names verified against each model's public schema (2026-11-05).
import type { ShotPlan } from './plan.js';
import type { ModelSpec } from './registry.js';

/** Signed URLs for the plan's media, in plan order. */
export type MediaUrls = { start?: string; middle: string[]; end?: string; refs: string[]; videos: string[] };

const set = (o: Record<string, unknown>, k: string, v: unknown) => {
  if (v === undefined || v === null || (Array.isArray(v) && !v.length)) return;
  o[k] = v;
};

export function buildInput(m: ModelSpec, p: ShotPlan, u: MediaUrls): Record<string, unknown> {
  const i: Record<string, unknown> = { prompt: p.prompt };
  const frames = !!(u.start || u.end);
  switch (m.adapter) {
    case 'minimax-h3':
      i.duration = p.seconds;
      if (m.resolutions.length > 1) i.resolution = p.resolution;
      i.ratio = frames && m.id !== 'h3-lite' ? 'adaptive' : p.aspect;
      set(i, 'first_frame_image', u.start); set(i, 'last_frame_image', u.end);
      set(i, 'reference_image_urls', u.refs); set(i, 'reference_video_urls', u.videos.slice(0, 3));
      break;
    case 'kling-v4':
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
      i.duration = p.seconds; i.resolution = p.resolution; i.aspect_ratio = frames ? 'adaptive' : p.aspect; i.generate_audio = p.audio;
      if (frames) { set(i, 'image', u.start); if (u.start) set(i, 'last_frame_image', u.end); }
      else { set(i, 'reference_images', u.refs); set(i, 'reference_videos', u.videos); }
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
    case 'mock':
      Object.assign(i, { duration: p.seconds, resolution: p.resolution, aspect_ratio: p.aspect, start: u.start, middle: u.middle, end: u.end, refs: u.refs, videos: u.videos, ...p.params });
      break;
  }
  return i;
}
