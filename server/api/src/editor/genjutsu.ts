// Edit helpers on Higgsfield Genjutsu (owner 2026-11-11): Object swap (an object in the video becomes the one in 1–8
// pictures) and Restyle (the whole video in a preset look). Both take a video of at least 4 s and use only its first 30 s
// (Higgsfield's own cut); output is a new video. Read from docs.higgsfield.ai/docs/models/genjutsu/{object-swap,restyle}
// on 2026-11-11. Priced per source second rounded up (Higgsfield's billing), × the editor markup; paid, go-ahead gated
// like every helper. The person's motion transfer onto a clip is Character swap (engine "genjutsu"), not a helper.
import fs from 'node:fs';
import { badRequest } from '../errors.js';
import { ReplicateError } from '../replicate/client.js';
import type { VideoProvider } from '../suite/providers.js';

export const GENJUTSU_HELPERS = {
  objectswap: { ref: 'higgsfield/genjutsu/object-swap/v1.0', maxImages: 8, minImages: 1,
    // No rate on the object-swap page itself; the model table lists it with motion transfer's $0.154–$0.8346/s.
    perSec: { '480p': 0.154, '720p': 0.3446, '1080p': 0.8346 } as Record<string, number> },
  restyle: { ref: 'higgsfield/genjutsu/restyle/v1.0', maxImages: 5, minImages: 0,
    perSec: { '480p': 0.318, '720p': 0.681, '1080p': 1.632 } as Record<string, number> },
} as const;
export type GenjutsuHelper = keyof typeof GENJUTSU_HELPERS;
export const isGenjutsuHelper = (k: string): k is GenjutsuHelper => k === 'objectswap' || k === 'restyle';
export const GENJUTSU_LIMITS = { minSec: 4, maxSec: 30, resolutions: ['480p', '720p', '1080p'] as const, promptMax: 2000 };
export type GenjutsuImage = { url?: string; asset?: string; uploadId?: string };
export type GenjutsuOptions = { images?: GenjutsuImage[]; prompt?: string; resolution?: string; presetId?: string };

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The helper's options, checked: images (object swap 1–8 required, restyle ≤ 5), prompt, resolution, restyle preset. */
export function parseGenjutsuOptions(kind: GenjutsuHelper, o: any): GenjutsuOptions {
  const h = GENJUTSU_HELPERS[kind], out: GenjutsuOptions = {};
  const imgs = o.images ?? [];
  if (!Array.isArray(imgs)) throw badRequest('options.images: a list of pictures ({uploadId} or {url})');
  if (imgs.length < h.minImages) throw badRequest('options.images: at least one picture of the new object');
  if (imgs.length > h.maxImages) throw badRequest(`options.images: at most ${h.maxImages} pictures`);
  out.images = imgs.map((x: any, i: number) => {
    if (!x || typeof x !== 'object') throw badRequest(`options.images[${i}]: {uploadId} or {url}`);
    if (typeof x.uploadId === 'string' && x.uploadId) return { uploadId: x.uploadId };
    if (typeof x.url === 'string' && x.url) return { url: x.url };
    if (typeof x.asset === 'string' && x.asset) return { asset: x.asset };
    throw badRequest(`options.images[${i}]: {uploadId} or {url}`);
  });
  if (o.prompt !== undefined) {
    if (typeof o.prompt !== 'string' || o.prompt.length > GENJUTSU_LIMITS.promptMax) throw badRequest(`options.prompt: text, at most ${GENJUTSU_LIMITS.promptMax} characters`);
    if (o.prompt.trim()) out.prompt = o.prompt.trim();
  }
  const res = o.resolution ?? '720p';
  if (!(GENJUTSU_LIMITS.resolutions as readonly string[]).includes(res)) throw badRequest('options.resolution: "480p", "720p" or "1080p"');
  out.resolution = res;
  if (kind === 'restyle') {
    if (typeof o.presetId !== 'string' || !UUID_RE.test(o.presetId)) throw badRequest('options.presetId: a restyle preset id (edit_jobs features: restyle.presets)');
    out.presetId = o.presetId.toLowerCase();
  }
  return out;
}

/** Seconds Higgsfield bills: the source rounded up, first 30 s only. Shorter than 4 s is refused (said plainly). */
export function genjutsuSeconds(durationSec: number) {
  if (!(durationSec >= GENJUTSU_LIMITS.minSec - 0.05)) throw badRequest(`source: Genjutsu needs a video of at least ${GENJUTSU_LIMITS.minSec} s`);
  return Math.max(GENJUTSU_LIMITS.minSec, Math.ceil(Math.min(durationSec, GENJUTSU_LIMITS.maxSec) - 0.001));
}
/** The price shown and held: Higgsfield's per-second rate × billed seconds × the editor markup. */
export function genjutsuUsd(kind: GenjutsuHelper, resolution: string, durationSec: number, markup: number) {
  const rate = GENJUTSU_HELPERS[kind].perSec[resolution] ?? GENJUTSU_HELPERS[kind].perSec['720p']!;
  return Math.round(rate * genjutsuSeconds(durationSec) * markup * 10000) / 10000;
}

/** The provider input (docs field names). */
export function genjutsuHelperInput(kind: GenjutsuHelper, videoUrl: string, imageUrls: string[], o: GenjutsuOptions) {
  return {
    video_url: videoUrl,
    ...(kind === 'restyle' ? { preset_id: o.presetId, image_urls: imageUrls } : { image_urls: imageUrls }),
    ...(o.prompt ? { prompt: o.prompt } : {}),
    resolution: o.resolution ?? '720p',
  };
}

/** Runs one helper on Higgsfield: start → poll → download to `file`. Cancel stops the request there too. */
export async function runGenjutsu(hf: VideoProvider, kind: GenjutsuHelper, input: Record<string, unknown>, file: string,
  o: { cancelled: () => boolean; pollMs: number; timeoutMs: number; onProgress: (f: number) => Promise<void> }) {
  const id = await hf.start(GENJUTSU_HELPERS[kind].ref, input, { cancelled: o.cancelled });
  const t0 = Date.now();
  for (;;) {
    if (o.cancelled()) { await hf.cancel(id); throw new ReplicateError('Cancelled', 'cancelled'); }
    const s = await hf.get(id);
    if (s.status === 'failed') throw s.error ?? new ReplicateError('Higgsfield failed', 'failed');
    if (s.status === 'canceled') throw new ReplicateError('Higgsfield cancelled the request', 'failed');
    if (s.status === 'succeeded') {
      if (!s.url) throw new ReplicateError('Higgsfield finished without a video', 'failed');
      await hf.download(s.url, file);
      if (!fs.existsSync(file) || !fs.statSync(file).size) throw new ReplicateError('Higgsfield’s video came back empty', 'failed');
      return;
    }
    if (Date.now() - t0 > o.timeoutMs) { await hf.cancel(id); throw new ReplicateError('Higgsfield took too long', 'timeout'); }
    await o.onProgress(Math.min(0.9, (Date.now() - t0) / 1000 / 240));
    await new Promise(r => setTimeout(r, o.pollMs));
  }
}
