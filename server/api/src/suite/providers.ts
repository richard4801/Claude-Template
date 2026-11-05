// AI suite · providers. One small interface over Replicate (the existing client: rate-limit gate, 429 backoff), fal's
// queue API and an in-process MOCK that renders a test pattern with ffmpeg (no network, no spend). Errors are
// ReplicateError kinds for every provider so the job failure mapping (services/replicateVideo.ts failureOf) applies.
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import { pipeline } from 'node:stream/promises';
import { Readable } from 'node:stream';
import { promisify } from 'node:util';
import type { Ctx } from '../ctx.js';
import { CREDIT_RE, errorText, outputUrl, ReplicateError, SAFETY_RE } from '../replicate/client.js';
import { predictionError } from '../services/replicateVideo.js';
import type { ProviderId } from './registry.js';

const run = promisify(execFile);

export type ProviderStatus = { status: 'running' | 'succeeded' | 'failed' | 'canceled'; url?: string | null; billedSeconds?: number | null; error?: ReplicateError };
export type StartHooks = { cancelled: () => boolean; onWait?: (seconds: number) => void | Promise<void>; /** The planned output length (the mock renders this long when the input has no duration, e.g. recast). */ seconds?: number };
export interface VideoProvider {
  id: ProviderId;
  configured(): boolean;
  start(ref: string, input: Record<string, unknown>, hooks: StartHooks): Promise<string>;
  get(id: string): Promise<ProviderStatus>;
  cancel(id: string): Promise<void>;
  download(url: string, file: string): Promise<void>;
}

export class ReplicateProvider implements VideoProvider {
  id = 'replicate' as const;
  constructor(private ctx: Ctx) {}
  configured() { return this.ctx.replicate.configured; }
  async start(ref: string, input: Record<string, unknown>, hooks: StartHooks) {
    const p = await this.ctx.replicate.create(ref, input, { maxWaitMs: this.ctx.config.REPLICATE_MAX_RATE_WAIT_SEC * 1000, cancelled: hooks.cancelled, onWait: hooks.onWait });
    return p.id;
  }
  async get(id: string): Promise<ProviderStatus> {
    const p = await this.ctx.replicate.get(id);
    if (p.status === 'succeeded') {
      const secs = Number(p.metrics?.video_output_duration_seconds);
      return { status: 'succeeded', url: outputUrl(p.output), billedSeconds: Number.isFinite(secs) && secs > 0 ? secs : null };
    }
    if (p.status === 'failed') return { status: 'failed', error: predictionError(p) };
    if (p.status === 'canceled') return { status: 'canceled' };
    return { status: 'running' };
  }
  cancel(id: string) { return this.ctx.replicate.cancel(id); }
  download(url: string, file: string) { return this.ctx.replicate.download(url, file); }
}

/** fal's queue API (https://queue.fal.run/<app>): submit → status_url → response_url. Ids carry both URLs. */
export class FalProvider implements VideoProvider {
  id = 'fal' as const;
  constructor(private ctx: Ctx, private fetchFn: typeof fetch = fetch) {}
  configured() { return !!this.ctx.config.FAL_KEY; }
  private headers() { return { authorization: `Key ${this.ctx.config.FAL_KEY}`, 'content-type': 'application/json' }; }
  async start(ref: string, input: Record<string, unknown>, hooks: StartHooks) {
    if (!this.configured()) throw new ReplicateError("fal isn't set up on the server", 'unavailable');
    if (hooks.cancelled()) throw new ReplicateError('Cancelled', 'cancelled');
    const res = await this.fetchFn(`${this.ctx.config.FAL_QUEUE_URL.replace(/\/$/, '')}/${ref}`, { method: 'POST', headers: this.headers(), body: JSON.stringify(input), signal: AbortSignal.timeout(60_000) })
      .catch(e => { throw new ReplicateError(`fal unreachable (${(e as Error).name})`, 'failed'); });
    const text = await res.text().catch(() => '');
    if (res.status === 401 || res.status === 403) throw new ReplicateError("fal refused the server's key", 'unavailable', res.status);
    if (res.status === 402 || CREDIT_RE.test(text)) throw new ReplicateError('fal is out of credit', 'out_of_credit', res.status);
    if (res.status === 429) throw new ReplicateError('fal is busy', 'rate_limited', 429);
    if (!res.ok) throw new ReplicateError(`fal rejected the request (${res.status}: ${text.slice(0, 200)})`, SAFETY_RE.test(text) ? 'refused' : 'failed', res.status);
    const j = JSON.parse(text) as { request_id: string; status_url?: string; response_url?: string; cancel_url?: string };
    const base = `${this.ctx.config.FAL_QUEUE_URL.replace(/\/$/, '')}/${ref.split('/').slice(0, 2).join('/')}/requests/${j.request_id}`;
    return JSON.stringify({ id: j.request_id, s: j.status_url ?? `${base}/status`, r: j.response_url ?? base, c: j.cancel_url ?? `${base}/cancel` });
  }
  async get(id: string): Promise<ProviderStatus> {
    const h = JSON.parse(id) as { s: string; r: string };
    const res = await this.fetchFn(h.s, { headers: this.headers(), signal: AbortSignal.timeout(30_000) }).catch(() => null);
    if (!res || !res.ok) return { status: 'running' };
    const st = (await res.json()) as { status?: string; error?: unknown };
    if (st.status === 'COMPLETED') {
      const out = await this.fetchFn(h.r, { headers: this.headers(), signal: AbortSignal.timeout(30_000) });
      const body = (await out.json().catch(() => ({}))) as { video?: { url?: string }; detail?: unknown };
      if (!out.ok || !body.video?.url) {
        const t = errorText(body.detail ?? st.error ?? `status ${out.status}`);
        return { status: 'failed', error: new ReplicateError(t, SAFETY_RE.test(t) ? 'refused' : 'failed') };
      }
      return { status: 'succeeded', url: body.video.url, billedSeconds: null };
    }
    if (st.status === 'FAILED' || st.error) { const t = errorText(st.error); return { status: 'failed', error: new ReplicateError(t, SAFETY_RE.test(t) ? 'refused' : 'failed') }; }
    return { status: 'running' };
  }
  async cancel(id: string) {
    try { await this.fetchFn(JSON.parse(id).c, { method: 'PUT', headers: this.headers(), signal: AbortSignal.timeout(30_000) }); }
    catch (e) { this.ctx.log.warn({ err: (e as Error).message }, 'fal cancel failed'); }
  }
  async download(url: string, file: string) {
    const res = await this.fetchFn(url, { signal: AbortSignal.timeout(10 * 60_000) }).catch(e => { throw new ReplicateError(`Couldn't download fal's output (${(e as Error).name})`, 'failed'); });
    if (!res.ok || !res.body) throw new ReplicateError(`Couldn't download fal's output (${res.status})`, 'failed', res.status);
    await pipeline(Readable.fromWeb(res.body as any), fs.createWriteStream(file));
  }
}

/**
 * The mock provider: every call is recorded; a prediction finishes on its second poll with a test-pattern mp4 of the
 * requested length and shape (made with ffmpeg on download). `failNext` / `refuseNext` make the next one fail.
 */
export class MockProvider implements VideoProvider {
  id = 'mock' as const;
  calls: { id: string; ref: string; input: Record<string, unknown>; polls: number; cancelled?: boolean }[] = [];
  failNext = 0;
  refuseNext = 0;
  /** Polls before a prediction succeeds. */
  pollsToFinish = 1;
  constructor(private ctx: Ctx) {}
  configured() { return true; }
  async start(ref: string, input: Record<string, unknown>, hooks: StartHooks) {
    if (hooks.cancelled()) throw new ReplicateError('Cancelled', 'cancelled');
    const id = `mock_${this.calls.length + 1}_${Date.now().toString(36)}`;
    const c = { id, ref, input, polls: 0, seconds: hooks.seconds } as MockProvider['calls'][number] & { fail?: 'failed' | 'refused'; seconds?: number };
    if (this.refuseNext > 0) { this.refuseNext--; c.fail = 'refused'; } else if (this.failNext > 0) { this.failNext--; c.fail = 'failed'; }
    this.calls.push(c);
    return id;
  }
  async get(id: string): Promise<ProviderStatus> {
    const c = this.calls.find(x => x.id === id) as (MockProvider['calls'][number] & { fail?: 'failed' | 'refused' }) | undefined;
    if (!c) throw new ReplicateError('no such mock prediction', 'failed', 404);
    if (c.cancelled) return { status: 'canceled' };
    if (++c.polls <= this.pollsToFinish - 1) return { status: 'running' };
    if (c.fail) return { status: 'failed', error: new ReplicateError(c.fail === 'refused' ? 'flagged by the safety filter (mock)' : 'mock failure', c.fail) };
    return { status: 'succeeded', url: `mock://${id}`, billedSeconds: Number(c.input.duration) || (c as { seconds?: number }).seconds || 5 };
  }
  async cancel(id: string) { const c = this.calls.find(x => x.id === id); if (c) c.cancelled = true; }
  async download(url: string, file: string) {
    const c = this.calls.find(x => `mock://${x.id}` === url);
    const secs = Math.max(1, Math.min(30, Number(c?.input.duration) || (c as { seconds?: number } | undefined)?.seconds || 5));
    const ar = String(c?.input.aspect_ratio ?? c?.input.ratio ?? '9:16');
    const [w, h] = ar === '16:9' ? [320, 180] : ar === '1:1' ? [240, 240] : ar === '4:3' ? [320, 240] : ar === '3:4' ? [240, 320] : ar === '21:9' ? [336, 144] : [180, 320];
    await run(this.ctx.config.FFMPEG_PATH, ['-y', '-v', 'error', '-f', 'lavfi', '-i', `testsrc=size=${w}x${h}:rate=24`, '-f', 'lavfi', '-i', 'sine=frequency=440',
      '-t', String(secs), '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', file]);
  }
}
