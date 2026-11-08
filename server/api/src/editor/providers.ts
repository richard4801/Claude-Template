// Editor v2 AI providers (plans/api.md "Editor v2"): a deterministic MOCK (dev, tests, no money) and Replicate.
// Member-facing data never names these; the job only records model ids for owner views.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import type { Ctx } from '../ctx.js';
import { ReplicateError, outputUrl, type Prediction } from '../replicate/client.js';
import { uid } from '../lib/util.js';
import type { Word } from './cuts.js';

export type Hooks = {
  cancelled: () => boolean;
  onPrediction?: (id: string) => void | Promise<void>;
  onProgress?: (p: number, phase: string) => void | Promise<void>;
};
export type Stem = 'vocals' | 'no_vocals';
export type TrackPoint = { x: number; y: number; frame: number; keep: boolean };
export type Transcript = { words: Word[]; language: string; gpuSec: number | null };
/** A produced file on local disk (deleted by the caller), and the GPU seconds the provider billed (null = unknown). */
export type Produced = { file: string | null; contentType: string; gpuSec: number | null };

export interface EditorProvider {
  readonly name: 'mock' | 'replicate';
  /** Model ids per kind (owner views). `track`: tap-to-keep (workstream 1). */
  models: { transcribe: string; matte: string; separate: string; track: string };
  /** $/GPU-second per kind, for estimates and settling. */
  rates: { transcribe: number; matte: number; separate: number; track: number };
  transcribe(mediaUrl: string, durationSec: number, language: string | null, h: Hooks): Promise<Transcript>;
  /**
   * The alpha matte of the person (workstream 1, "fix 1"): a grey video the same length as the source, white = keep.
   * The apps apply it to the original clip (`alphaMatte`), so green clothes and hair edges survive (no chroma key).
   */
  matte(mediaUrl: string, durationSec: number, h: Hooks): Promise<Produced>;
  /**
   * Tap to keep (workstream 1, "option 2"): the subject under the owner's points, tracked through the clip, as the same
   * kind of alpha matte. Points are in pixels on the given frames; `keep: false` points mark what to leave out.
   */
  track(mediaUrl: string, durationSec: number, points: TrackPoint[], h: Hooks): Promise<Produced>;
  /** The voice alone (music and noise removed), or with `stem: "no_vocals"` everything but the voice (beat-only audio). */
  separate(mediaUrl: string, durationSec: number, h: Hooks, stem?: Stem): Promise<Produced>;
}

const env = (k: string, d: string) => process.env[k]?.trim() || d;
const envNum = (k: string, d: number) => { const v = Number(process.env[k]); return Number.isFinite(v) && v > 0 ? v : d; };

/** Replicate's per-second GPU prices (replicate.com/pricing, 2026-11): A100 80 GB $0.0014, L40S $0.000975. */
export const DEFAULT_RATES = { transcribe: 0.0014, matte: 0.000975, separate: 0.0014, track: 0.0014 };
export const DEFAULT_MODELS = { transcribe: 'victor-upmeet/whisperx', matte: 'arielreplicate/robust_video_matting', separate: 'ryan5453/demucs', track: 'meta/sam-2-video' };

// ------------------------------------------------------------------ mock
const SCRIPT = 'Okay so um this is the one product I keep coming back to. Honestly uh it changed my whole routine. You put a little on like this and you just wait. Look at that glow! I I use it every single day. Um anyway link is in my bio.';

/** Deterministic words for a clip: the script spoken at ~2.6 words/s with a pause after each sentence, cut to the duration. */
export function mockWords(durationSec: number): Word[] {
  const out: Word[] = [];
  let t = 0.3;
  for (const raw of SCRIPT.split(' ')) {
    const len = Math.min(0.6, 0.18 + raw.length * 0.035);
    if (t + len > durationSec - 0.2) break;
    out.push({ text: raw, startSec: Math.round(t * 1000) / 1000, endSec: Math.round((t + len) * 1000) / 1000, score: /^(um|uh)$/i.test(raw) ? 0.55 : 0.93 });
    t += len + (/[.!?]$/.test(raw) ? 0.9 : 0.08);
  }
  return out;
}

export class MockProvider implements EditorProvider {
  readonly name = 'mock' as const;
  models = { transcribe: 'mock/transcribe', matte: 'mock/matte', separate: 'mock/separate', track: 'mock/track' };
  rates = { ...DEFAULT_RATES };
  constructor(private stepMs: number, private sleep: (ms: number) => Promise<void> = ms => new Promise(r => setTimeout(r, ms))) {}
  private async steps(h: Hooks, phase: string) {
    for (let i = 1; i <= 4; i++) {
      if (h.cancelled()) throw new ReplicateError('Cancelled', 'cancelled');
      await this.sleep(this.stepMs);
      await h.onProgress?.(i / 4, phase);
    }
    if (h.cancelled()) throw new ReplicateError('Cancelled', 'cancelled');
  }
  async transcribe(_url: string, durationSec: number, language: string | null, h: Hooks): Promise<Transcript> {
    await h.onPrediction?.(uid('mockpred'));
    await this.steps(h, 'Listening');
    return { words: mockWords(durationSec), language: language ?? 'en', gpuSec: 8 + 0.15 * durationSec };
  }
  /** The mock returns no file: the job then points the result at the source itself. */
  async matte(_url: string, durationSec: number, h: Hooks): Promise<Produced> {
    await this.steps(h, 'Cutting out the background');
    return { file: null, contentType: 'video/mp4', gpuSec: 10 + 4 * durationSec };
  }
  /** The mock's tracked matte: no file either (the job points the result at the source). */
  async track(_url: string, durationSec: number, points: TrackPoint[], h: Hooks): Promise<Produced> {
    if (!points.some(p => p.keep)) throw new ReplicateError('No point to keep', 'failed');
    await this.steps(h, 'Following what you tapped');
    return { file: null, contentType: 'video/mp4', gpuSec: 15 + 3 * durationSec };
  }
  async separate(_url: string, durationSec: number, h: Hooks, _stem: Stem = 'vocals'): Promise<Produced> {
    await this.steps(h, 'Cleaning up the voice');
    return { file: null, contentType: 'audio/mpeg', gpuSec: 5 + 0.3 * durationSec };
  }
}

// ------------------------------------------------------------------ Replicate
/**
 * Words from a WhisperX-style output: `{segments: [{start, end, text, words: [{word, start, end, score}]}]}` (or a top-level
 * `word_segments`). Words without times (numbers, symbols) get times shared out from their neighbours / segment.
 */
export function parseTranscript(output: unknown): { words: Word[]; language: string | null } {
  const o = (typeof output === 'string' ? (() => { try { return JSON.parse(output); } catch { return {}; } })() : output ?? {}) as Record<string, any>;
  const segs: any[] = Array.isArray(o.segments) ? o.segments : [];
  const out: Word[] = [];
  const pushRun = (list: any[], s0: number, s1: number) => {
    const ws = list.map(w => ({ text: String(w.word ?? w.text ?? '').trim(), start: Number(w.start), end: Number(w.end), score: Number(w.score ?? w.probability) }))
      .filter(w => w.text);
    ws.forEach((w, i) => {
      let a = Number.isFinite(w.start) ? w.start : NaN, b = Number.isFinite(w.end) ? w.end : NaN;
      if (!Number.isFinite(a)) { const prev = out[out.length - 1]; a = prev && prev.endSec >= s0 ? prev.endSec : s0; }
      if (!Number.isFinite(b)) { const nx = ws.slice(i + 1).find(x => Number.isFinite(x.start)); b = nx ? nx.start : s1; }
      if (b < a) b = a;
      out.push({ text: w.text.slice(0, 60), startSec: Math.round(a * 1000) / 1000, endSec: Math.round(b * 1000) / 1000, ...(Number.isFinite(w.score) ? { score: Math.round(w.score * 1000) / 1000 } : {}) });
    });
  };
  if (segs.some(s => Array.isArray(s.words))) for (const s of segs) pushRun(Array.isArray(s.words) ? s.words : [], Number(s.start) || 0, Number(s.end) || Number(s.start) || 0);
  else if (Array.isArray(o.word_segments)) pushRun(o.word_segments, 0, Number.MAX_SAFE_INTEGER);
  else for (const s of segs) { // segment-level only: share the segment's time out over its words
    const parts = String(s.text ?? '').trim().split(/\s+/).filter(Boolean), a = Number(s.start) || 0, b = Number(s.end) || a, step = parts.length ? (b - a) / parts.length : 0;
    parts.forEach((p, i) => out.push({ text: p.slice(0, 60), startSec: Math.round((a + i * step) * 1000) / 1000, endSec: Math.round((a + (i + 1) * step) * 1000) / 1000 }));
  }
  out.sort((x, y) => x.startSec - y.startSec);
  return { words: out, language: typeof o.detected_language === 'string' ? o.detected_language : typeof o.language === 'string' ? o.language : null };
}

/** The first file URL in an output: a string, an array, or an object of named files (prefers `prefer`). */
export function pickFile(output: unknown, prefer: string[] = []): string | null {
  const direct = outputUrl(output);
  if (direct) return direct;
  if (output && typeof output === 'object' && !Array.isArray(output)) {
    const o = output as Record<string, unknown>;
    for (const k of prefer) { const u = outputUrl(o[k]); if (u) return u; }
    for (const v of Object.values(o)) { const u = outputUrl(v); if (u && /^https?:\/\//.test(u)) return u; }
  }
  return null;
}

export class ReplicateProvider implements EditorProvider {
  readonly name = 'replicate' as const;
  models = {
    transcribe: env('EDITOR_TRANSCRIBE_MODEL', DEFAULT_MODELS.transcribe),
    matte: env('EDITOR_MATTE_MODEL', DEFAULT_MODELS.matte),
    separate: env('EDITOR_SEPARATE_MODEL', DEFAULT_MODELS.separate),
    track: env('EDITOR_TRACK_MODEL', DEFAULT_MODELS.track),
  };
  rates = { transcribe: envNum('EDITOR_TRANSCRIBE_USD_PER_SEC', DEFAULT_RATES.transcribe), matte: envNum('EDITOR_MATTE_USD_PER_SEC', DEFAULT_RATES.matte), separate: envNum('EDITOR_SEPARATE_USD_PER_SEC', DEFAULT_RATES.separate),
    track: envNum('EDITOR_TRACK_USD_PER_SEC', DEFAULT_RATES.track) };
  constructor(private ctx: Ctx) {}

  /** Community models run by version: the latest one from the catalog (cached there), and its input names. */
  private async version(model: string): Promise<{ version?: string; inputs: string[] | null }> {
    const raw = await this.ctx.imageModels.catalog.model(model).catch(() => null);
    const props = (raw?.latest_version?.openapi_schema as any)?.components?.schemas?.Input?.properties;
    const inputs = props && typeof props === 'object' ? Object.keys(props) : null;
    if (raw?.is_official) return { inputs };
    const v = raw?.latest_version?.id;
    if (!v) throw new ReplicateError(`No runnable version of ${model}`, 'failed');
    return { version: v, inputs };
  }

  private async run(model: string, wanted: Record<string, unknown>, h: Hooks, timeoutSec: number): Promise<Prediction> {
    const c = this.ctx.config, r = this.ctx.replicate;
    const { version, inputs } = await this.version(model);
    const input = adaptInput(wanted, inputs);
    const created = await r.create(model, input, { maxWaitMs: c.REPLICATE_MAX_RATE_WAIT_SEC * 1000, cancelled: h.cancelled, ...(version ? { version } : {}) });
    await h.onPrediction?.(created.id);
    const done = await r.wait(created.id, { pollMs: c.REPLICATE_POLL_MS, timeoutMs: timeoutSec * 1000, cancelled: h.cancelled,
      onPoll: async (_p, ms) => { await h.onProgress?.(Math.min(0.9, ms / 1000 / Math.max(10, timeoutSec / 6)), ''); } });
    if (done.status !== 'succeeded') throw new ReplicateError(typeof done.error === 'string' ? done.error : 'The helper failed', done.status === 'canceled' ? 'cancelled' : 'failed');
    return done;
  }
  private gpu(p: Prediction) { const t = Number(p.metrics?.predict_time); return Number.isFinite(t) && t > 0 ? t : null; }
  private async fetch(url: string, ext: string): Promise<string> {
    const file = path.join(os.tmpdir(), `${uid('edai')}.${ext}`);
    await this.ctx.replicate.download(url, file);
    return file;
  }

  async transcribe(url: string, durationSec: number, language: string | null, h: Hooks): Promise<Transcript> {
    const p = await this.run(this.models.transcribe, { audio_file: url, align_output: true, batch_size: 32, ...(language ? { language } : {}) }, h, 300 + durationSec * 2);
    const t = parseTranscript(p.output);
    return { words: t.words, language: t.language ?? language ?? 'en', gpuSec: this.gpu(p) };
  }
  async matte(url: string, durationSec: number, h: Hooks): Promise<Produced> {
    // The alpha matte (white = person), not a green composite: the apps apply it, so nothing green is keyed out.
    const p = await this.run(this.models.matte, { input_video: url, output_type: 'alpha-mask' }, h, 600 + durationSec * 20);
    const u = pickFile(p.output);
    if (!u) throw new ReplicateError('The background removal returned no video', 'failed');
    return { file: await this.fetch(u, 'mp4'), contentType: 'video/mp4', gpuSec: this.gpu(p) };
  }
  async track(url: string, durationSec: number, points: TrackPoint[], h: Hooks): Promise<Produced> {
    // One object, the points the owner tapped (1 = keep, 0 = leave out), a black-and-white mask video back.
    const p = await this.run(this.models.track, {
      input_video: url, click_coordinates: points.map(q => `[${Math.round(q.x)},${Math.round(q.y)}]`).join(','),
      click_labels: points.map(q => (q.keep ? 1 : 0)).join(','), click_frames: points.map(q => q.frame).join(','),
      click_object_ids: points.map(() => 'keep').join(','), mask_type: 'binary', output_video: true,
    }, h, 600 + durationSec * 20);
    const u = pickFile(p.output);
    if (!u) throw new ReplicateError('The tracking returned no video', 'failed');
    return { file: await this.fetch(u, 'mp4'), contentType: 'video/mp4', gpuSec: this.gpu(p) };
  }
  async separate(url: string, durationSec: number, h: Hooks, stem: Stem = 'vocals'): Promise<Produced> {
    // Two-stem split on the voice: the output has both `vocals` and `no_vocals`; we keep the one asked for.
    const p = await this.run(this.models.separate, { audio: url, stem: 'vocals', output_format: 'mp3' }, h, 300 + durationSec * 3);
    const u = stem === 'no_vocals' ? (() => { const o = p.output as Record<string, unknown> | null; return o && typeof o === 'object' && !Array.isArray(o) ? pickFile(o['no_vocals'] ?? o['other'] ?? o['accompaniment'] ?? null) : null; })() : pickFile(p.output, ['vocals']);
    if (!u) throw new ReplicateError('The voice clean-up returned no audio', 'failed');
    const ext = /\.(wav|flac|mp3|m4a)(\?|$)/i.exec(u)?.[1]?.toLowerCase() ?? 'mp3';
    return { file: await this.fetch(u, ext), contentType: ext === 'wav' ? 'audio/wav' : ext === 'flac' ? 'audio/flac' : ext === 'm4a' ? 'audio/mp4' : 'audio/mpeg', gpuSec: this.gpu(p) };
  }
}

/** Other names a model may use for our inputs; tried in order when the schema doesn't have ours. */
const ALIASES: Record<string, string[]> = {
  audio_file: ['audio', 'audio_file', 'file', 'input_audio', 'audio_path'],
  audio: ['audio', 'audio_file', 'input_audio', 'file'],
  input_video: ['input_video', 'video', 'video_path', 'input'],
};
/**
 * Our input renamed to the model's own field names when its OpenAPI schema is known: a field it doesn't have is renamed to
 * an alias it does have, or dropped (options like batch_size); file fields are always kept. Unknown schema: as is.
 */
export function adaptInput(wanted: Record<string, unknown>, inputs: string[] | null): Record<string, unknown> {
  if (!inputs) return wanted;
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(wanted)) {
    if (inputs.includes(k)) { out[k] = v; continue; }
    const alt = (ALIASES[k] ?? []).find(a => inputs.includes(a) && !(a in out));
    if (alt) out[alt] = v;
    else if (ALIASES[k]) out[k] = v;
  }
  return out;
}

/**
 * EDITOR_AI_PROVIDER = mock (the default: no provider calls) | auto (Replicate when the server has a token, else the mock)
 * | replicate. The owner turns the real helpers on by setting auto or replicate; until then production runs the mock.
 * In production the mock is also free (rates 0: no hold, no charge), so nobody pays for its stand-in results.
 */
export function makeProvider(ctx: Ctx): EditorProvider {
  const want = env('EDITOR_AI_PROVIDER', 'mock');
  if (want === 'replicate' || (want === 'auto' && ctx.replicate.configured)) return new ReplicateProvider(ctx);
  const mock = new MockProvider(Math.max(5, ctx.config.GEN_MS));
  if (ctx.config.NODE_ENV === 'production' && !ctx.config.DEV_MODE) mock.rates = { transcribe: 0, matte: 0, separate: 0, track: 0 };
  return mock;
}

export const rmQuiet = (f: string | null) => { if (f) fs.promises.rm(f, { force: true }).catch(() => {}); };
