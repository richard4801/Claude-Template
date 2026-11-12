// Edit helpers on Higgsfield and fal (Genjutsu restyle / object swap, slow motion): poll a saved request until the
// provider ends it, the same rules as the AI Suite and Character swap lines (services/paidLost.ts):
// - a status check that doesn't get through counts as still running (never a failure, never a new paid start);
// - our timeout asks the provider to cancel and keeps polling; a render it finishes anyway is kept; no answer → PaidLost
//   'unconfirmed' (it may still charge);
// - once the provider has made the result it is paid: `onMade` runs first (the caller records it), the download is
//   retried with a fresh status, and if it still can't be fetched → PaidLost 'unsaved' (recoverable by the owner).
import fs from 'node:fs';
import { ReplicateError } from '../replicate/client.js';
import type { ProviderStatus } from '../suite/providers.js';
import { PaidLost, sleep } from '../services/paidLost.js';

/** The server is shutting down: the job stays running with its request id saved (not failed, not cancelled). */
export class StepBack extends Error { constructor() { super('server stopping'); } }

export type PollProvider = { get(id: string): Promise<ProviderStatus>; cancel(id: string): Promise<void>; download(url: string, file: string): Promise<void> };
export type PollHooks = {
  cancelled: () => boolean; pollMs: number; timeoutMs: number;
  /** A deploy or restart: step back without cancelling at the provider (the next instance polls the saved id). */
  leaving?: () => boolean;
  onProgress?: (f: number) => Promise<void> | void;
  /** The provider finished (and billed): called with the result URL before anything else can fail. */
  onMade?: (url: string, computeSec: number | null) => Promise<void> | void;
};

export async function pollPaid(p: PollProvider, id: string, file: string, label: string, o: PollHooks): Promise<{ computeSec: number | null }> {
  const t0 = Date.now();
  let cancelAsked = 0;
  for (;;) {
    if (o.leaving?.()) throw new StepBack();
    if (o.cancelled()) { await p.cancel(id); throw new ReplicateError('Cancelled', 'cancelled'); }
    const s = await p.get(id).catch(() => ({ status: 'running' }) as ProviderStatus);
    if (s.status === 'failed') throw s.error ?? new ReplicateError(`${label} failed`, 'failed');
    if (s.status === 'canceled') throw new ReplicateError(cancelAsked ? `${label} took too long and was stopped` : `${label} cancelled the request`, cancelAsked ? 'timeout' : 'failed');
    if (s.status === 'succeeded') {
      if (!s.url) throw new PaidLost('unsaved', 1, `${label} finished without a result`);
      const computeSec = s.computeSec ?? null;
      await o.onMade?.(s.url, computeSec);
      let url = s.url, last = '';
      for (let a = 0; a < 3; a++) {
        try {
          await p.download(url, file);
          if (fs.existsSync(file) && fs.statSync(file).size) return { computeSec };
          last = 'the result came back empty';
        } catch (e) { last = (e as Error).message; }
        await sleep(Math.min(10_000, o.pollMs * (a + 1)));
        const again = await p.get(id).catch(() => null);
        if (again?.status === 'succeeded' && again.url) url = again.url;
      }
      throw new PaidLost('unsaved', 1, `${label}: ${last}`);
    }
    const elapsed = Date.now() - t0;
    if (!cancelAsked && elapsed > o.timeoutMs) { await p.cancel(id); cancelAsked = Date.now(); }
    if (cancelAsked && Date.now() - cancelAsked > o.timeoutMs / 2) throw new PaidLost('unconfirmed', 1, `${label} neither finished nor cancelled`);
    await o.onProgress?.(Math.min(0.9, elapsed / 1000 / 240));
    await sleep(o.pollMs);
  }
}
