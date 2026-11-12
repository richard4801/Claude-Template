// Provider paths where the provider has finished (and billed) and something on our side failed: never "you weren't
// charged" with the cost silently dropped (paid-jobs-2 follow-up, step 3). Fake fetches only, no money.
import { describe, expect, it } from 'vitest';
import { FalAdapter, MuapiAdapter } from '../src/byo/adapters.js';
import { FalEngine, ImageEngineError } from '../src/images/engines.js';
import { failureOf, REFUSED_PAID } from '../src/services/replicateVideo.js';

const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { 'content-type': 'application/json' } });

describe('fal image engine (studio key)', () => {
  const req = { prompt: 'p', referenceImages: [], width: 512, height: 512, count: 2 };
  it('a result fetch that fails after COMPLETED is asked again, and the images are kept', async () => {
    let results = 0;
    const f = (async (url: string) => {
      if (url.endsWith('/m')) return json({ request_id: 'r1', status_url: 'https://q/s', response_url: 'https://q/r' });
      if (url === 'https://q/s') return json({ status: 'COMPLETED' });
      if (url === 'https://q/r') return ++results < 3 ? json({ detail: 'busy' }, 502) : json({ images: [{ url: 'https://fal.media/a.png' }, { url: 'https://fal.media/b.png' }] });
      throw new Error(url);
    }) as typeof fetch;
    const r = await new FalEngine('k', 'https://q', 0.03, 5000, f, 1).generate(req, { provider: 'fal', model: 'm' });
    expect(r.images).toHaveLength(2);
    expect(results).toBe(3);
  });
  it('a result that never comes back, or our timeout, carries what fal billed (studio overhead), and the timeout asks fal to cancel', async () => {
    const calls: string[] = [];
    const lost = (async (url: string, init?: RequestInit) => {
      calls.push(`${init?.method ?? 'GET'} ${url}`);
      if (url.endsWith('/m')) return json({ request_id: 'r1', status_url: 'https://q/s', response_url: 'https://q/r' });
      if (url === 'https://q/s') return json({ status: 'COMPLETED' });
      return json({}, 500);
    }) as typeof fetch;
    const e1 = await new FalEngine('k', 'https://q', 0.03, 5000, lost, 1).generate(req, { provider: 'fal', model: 'm' }).catch(e => e);
    expect(e1).toBeInstanceOf(ImageEngineError);
    expect(e1.wastedUsd).toBeCloseTo(0.06, 9);
    const slow = (async (url: string, init?: RequestInit) => {
      calls.push(`${init?.method ?? 'GET'} ${url}`);
      if (url.endsWith('/m')) return json({ request_id: 'r1', status_url: 'https://q/s', response_url: 'https://q/r' });
      if (url === 'https://q/s') return json({ status: 'IN_PROGRESS' });
      return json({});
    }) as typeof fetch;
    const e2 = await new FalEngine('k', 'https://q', 0.03, 5, slow, 2).generate(req, { provider: 'fal', model: 'm' }).catch(e => e);
    expect(e2.wastedUsd).toBeCloseTo(0.06, 9);
    expect(calls).toContain('PUT https://q/r/cancel');
  });
});

describe('BYO adapters: finished at the provider', () => {
  it('fal: COMPLETED but the result fetch hit a 5xx or the network → still running (asked again), never failed', async () => {
    let n = 0;
    const f = (async (url: string) => {
      if (url.endsWith('/status')) return json({ status: 'COMPLETED' });
      n++;
      if (n === 1) throw new Error('reset');
      if (n === 2) return json({}, 503);
      return json({ video: { url: 'https://fal.media/v.mp4' } });
    }) as unknown as typeof fetch;
    const a = new FalAdapter(() => ({ falPlatform: 'https://api.fal.ai', falQueue: 'https://queue.fal.run' }), f);
    const h = JSON.stringify({ id: 'x', s: 'https://queue.fal.run/a/b/requests/x/status', r: 'https://queue.fal.run/a/b/requests/x', c: 'c' });
    expect((await a.get('k', h)).status).toBe('running');
    expect((await a.get('k', h)).status).toBe('running');
    expect(await a.get('k', h)).toMatchObject({ status: 'succeeded', url: 'https://fal.media/v.mp4' });
  });
  it('Muapi: a finished run whose outputs are all flagged is a refusal the studio paid for (honest message)', async () => {
    const f = (async () => json({ status: 'completed', outputs: ['https://m/x.mp4'], has_nsfw_contents: [true] })) as unknown as typeof fetch;
    const s = await new MuapiAdapter(() => 'https://api.muapi.ai/api/v1', f).get('k', JSON.stringify({ id: 'p1' }));
    expect(s.status).toBe('failed');
    const fail = failureOf(s.error);
    expect(fail).toMatchObject({ code: 'provider_refused', message: REFUSED_PAID, retryable: false });
    expect(fail.message).not.toMatch(/weren't charged/);
  });
});
