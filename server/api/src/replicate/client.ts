// Replicate's HTTP API (plans/backend.md "Replicate"): create a prediction on an official model, poll it, cancel it.
//
// Rate limits: with a small balance Replicate allows a burst of 1 and 6 prediction starts a minute, and answers 429
// with "Your rate limit resets in ~Ns". Every start in this process (video and photos) goes through one gate, and a
// 429 blocks the gate until Replicate's hint has passed, so callers queue up behind each other instead of hammering it.
// The token is only ever sent in the Authorization header; it is never logged.
import fs from 'node:fs';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';

export type PredictionStatus = 'starting' | 'processing' | 'succeeded' | 'failed' | 'canceled';
export type Prediction = {
  id: string; status: PredictionStatus; output?: unknown; error?: unknown;
  metrics?: { predict_time?: number; video_output_duration_seconds?: number; [k: string]: unknown };
};
export type ReplicateErrorKind = 'refused' | 'failed' | 'rate_limited' | 'timeout' | 'unavailable' | 'cancelled' | 'out_of_credit';

export class ReplicateError extends Error {
  constructor(message: string, readonly kind: ReplicateErrorKind, readonly status?: number) { super(message); }
}

/** Replicate's wording for a safety-filter refusal (its own checker or the model provider's). */
export const SAFETY_RE = /\b(sensitive|safety|flagged|nsfw|content[ _-]?(policy|moderation|filter)|moderation|E005|inappropriate)\b/i;

/** Replicate's wording when the account can't pay (HTTP 402, or a prediction error about credit or billing). */
export const CREDIT_RE = /\b(insufficient (credit|funds|balance)|out of credit|payment required|billing (limit|issue|required)|add (a )?payment|monthly spend limit)\b/i;

export const errorText = (e: unknown) => (typeof e === 'string' ? e : e == null ? '' : JSON.stringify(e)).slice(0, 500);

/** "Request was throttled. Your rate limit resets in ~6s." → 6. */
export function rateHintSeconds(body: string, retryAfter: string | null): number | null {
  const m = /resets? in\s*~?\s*(\d+(?:\.\d+)?)\s*s/i.exec(body);
  if (m) return Number(m[1]);
  const ra = retryAfter ? Number(retryAfter) : NaN;
  return Number.isFinite(ra) && ra >= 0 ? ra : null;
}

/** Output URL of a finished prediction: a string, or the first of a list. */
export const outputUrl = (o: unknown): string | null =>
  typeof o === 'string' ? o : Array.isArray(o) && typeof o[0] === 'string' ? o[0] : null;

export type ReplicateOptions = {
  token?: string; base: string; fetchFn?: typeof fetch;
  /** Injected in tests so backoff doesn't really wait. */
  sleep?: (ms: number) => Promise<void>; now?: () => number;
  log?: { warn: (o: object, m: string) => void; info: (o: object, m: string) => void };
};
export type WaitHooks = {
  /** Called before each wait on a rate limit, with the seconds it will wait. */
  onWait?: (seconds: number) => void | Promise<void>;
  /** Return true to give up (the job was cancelled). */
  cancelled?: () => boolean | Promise<boolean>;
};

const BACKOFF = [5, 10, 20, 40, 60];

export class ReplicateClient {
  private fetchFn: typeof fetch;
  private sleepFn: (ms: number) => Promise<void>;
  private now: () => number;
  /** Starts are blocked until then after a 429 (shared by every caller). */
  private blockedUntil = 0;
  private gate: Promise<unknown> = Promise.resolve();
  constructor(private o: ReplicateOptions) {
    this.fetchFn = o.fetchFn ?? fetch;
    this.sleepFn = o.sleep ?? (ms => new Promise(r => setTimeout(r, ms)));
    this.now = o.now ?? Date.now;
  }
  get configured() { return !!this.o.token; }
  private get base() { return this.o.base.replace(/\/$/, ''); }
  private headers() { return { authorization: `Bearer ${this.o.token}`, 'content-type': 'application/json' }; }
  sleep(ms: number) { return this.sleepFn(ms); }
  clock() { return this.now(); }

  /** One HTTP start at a time across the process. */
  private serial<T>(fn: () => Promise<T>): Promise<T> {
    const next = this.gate.catch(() => {}).then(fn);
    this.gate = next.catch(() => {});
    return next;
  }

  /**
   * Starts a prediction on an official model ("owner/name"). Waits out 429s (and brief 5xx) for up to `maxWaitMs`,
   * then throws `rate_limited`. Other errors throw `failed` (bad input, out of credit) or `unavailable` (token).
   */
  async create(model: string, input: Record<string, unknown>, opts: WaitHooks & { maxWaitMs: number }): Promise<Prediction> {
    if (!this.o.token) throw new ReplicateError("Replicate isn't set up on the server", 'unavailable');
    const t0 = this.now();
    let tries = 0, serverErrors = 0;
    for (;;) {
      if (await opts.cancelled?.()) throw new ReplicateError('Cancelled', 'cancelled');
      const blocked = this.blockedUntil - this.now();
      if (blocked > 0) {
        if (this.now() - t0 + blocked > opts.maxWaitMs) throw new ReplicateError('Replicate is busy (rate limit) · try again in a minute', 'rate_limited', 429);
        await opts.onWait?.(Math.ceil(blocked / 1000));
        await this.sleepFn(blocked);
        continue;
      }
      const res = await this.serial(() => this.fetchFn(`${this.base}/models/${model}/predictions`, {
        method: 'POST', headers: this.headers(), body: JSON.stringify({ input }), signal: AbortSignal.timeout(60_000),
      })).catch(e => { throw new ReplicateError(`Replicate unreachable (${(e as Error).name})`, 'failed'); });
      if (res.status === 429) {
        const body = await res.text().catch(() => '');
        const hint = rateHintSeconds(body, res.headers.get('retry-after'));
        const wait = hint != null ? hint + 1 : BACKOFF[Math.min(tries, BACKOFF.length - 1)]!;
        tries++;
        this.blockedUntil = Math.max(this.blockedUntil, this.now() + wait * 1000);
        this.o.log?.info({ model, wait }, 'Replicate rate limit: waiting');
        continue;
      }
      if (res.status >= 500 && serverErrors < 3) {
        serverErrors++;
        await this.sleepFn(BACKOFF[serverErrors - 1]! * 1000);
        continue;
      }
      const text = await res.text().catch(() => '');
      if (res.status === 401 || res.status === 403) throw new ReplicateError("Replicate refused the server's token", 'unavailable', res.status);
      if (res.status === 402) throw new ReplicateError("The studio's Replicate account is out of credit", 'out_of_credit', 402);
      if (!res.ok) {
        const detail = (() => { try { return errorText(JSON.parse(text).detail ?? text); } catch { return text.slice(0, 300); } })();
        if (SAFETY_RE.test(detail)) throw new ReplicateError(detail, 'refused', res.status);
        if (CREDIT_RE.test(detail)) throw new ReplicateError(`Replicate is out of credit (${detail})`, 'out_of_credit', res.status);
        throw new ReplicateError(`Replicate rejected the request (${res.status}${detail ? `: ${detail}` : ''})`, 'failed', res.status);
      }
      return JSON.parse(text) as Prediction;
    }
  }

  /** One read of a prediction. Rate limits and brief server errors are retried. */
  async get(id: string): Promise<Prediction> {
    for (let i = 0; ; i++) {
      const res = await this.fetchFn(`${this.base}/predictions/${encodeURIComponent(id)}`, { headers: this.headers(), signal: AbortSignal.timeout(30_000) })
        .catch(e => { if (i < 4) return null; throw new ReplicateError(`Replicate unreachable (${(e as Error).name})`, 'failed'); });
      if (res && res.ok) return (await res.json()) as Prediction;
      if (res && res.status === 404) throw new ReplicateError('Replicate has no such prediction', 'failed', 404);
      if (res && (res.status === 401 || res.status === 403)) throw new ReplicateError("Replicate refused the server's token", 'unavailable', res.status);
      if (i >= 6) throw new ReplicateError(`Replicate status check failed (${res?.status ?? 'network'})`, 'failed', res?.status);
      const hint = res?.status === 429 ? rateHintSeconds(await res.text().catch(() => ''), res.headers.get('retry-after')) : null;
      await this.sleepFn(((hint ?? BACKOFF[Math.min(i, BACKOFF.length - 1)]!) + (hint != null ? 1 : 0)) * 1000);
    }
  }

  async cancel(id: string) {
    try { await this.fetchFn(`${this.base}/predictions/${encodeURIComponent(id)}/cancel`, { method: 'POST', headers: this.headers(), signal: AbortSignal.timeout(30_000) }); }
    catch (e) { this.o.log?.warn({ id, err: (e as Error).message }, 'Replicate cancel failed'); }
  }

  /** Polls until the prediction ends, the timeout passes (it is then cancelled) or `cancelled()` says stop. */
  async wait(id: string, opts: { pollMs: number; timeoutMs: number; cancelled?: () => boolean | Promise<boolean>; onPoll?: (p: Prediction, elapsedMs: number) => void | Promise<void> }): Promise<Prediction> {
    const t0 = this.now();
    for (;;) {
      const p = await this.get(id);
      if (p.status === 'succeeded' || p.status === 'failed' || p.status === 'canceled') return p;
      if (await opts.cancelled?.()) { await this.cancel(id); throw new ReplicateError('Cancelled', 'cancelled'); }
      const elapsed = this.now() - t0;
      if (elapsed > opts.timeoutMs) { await this.cancel(id); throw new ReplicateError('Replicate took too long and the render was stopped', 'timeout'); }
      await opts.onPoll?.(p, elapsed);
      await this.sleepFn(opts.pollMs);
    }
  }

  /** Downloads an output file (Replicate deletes outputs after a while, so this happens at once). */
  async download(url: string, file: string) {
    const res = await this.fetchFn(url, { signal: AbortSignal.timeout(10 * 60_000) })
      .catch(e => { throw new ReplicateError(`Couldn't download Replicate's output (${(e as Error).name})`, 'failed'); });
    if (!res.ok || !res.body) throw new ReplicateError(`Couldn't download Replicate's output (${res.status})`, 'failed', res.status);
    await pipeline(Readable.fromWeb(res.body as any), fs.createWriteStream(file));
  }
}
