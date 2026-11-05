import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { buildApp, type App, type BuildOptions } from '../src/app.js';
import { loadConfig } from '../src/config.js';
import { openDb } from '../src/db/client.js';
import { createInvite, ensureStudio } from '../src/auth/auth.js';
import { sql } from 'drizzle-orm';

/**
 * A fresh API on an empty database: embedded Postgres (PGlite) by default, or a real Postgres when TEST_DATABASE_URL
 * is set (the schema is dropped and migrated again for each app).
 */
export async function makeApp(env: Record<string, string> = {}, opts: BuildOptions = {}): Promise<App & { dir: string }> {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-vitest-'));
  const url = process.env.TEST_DATABASE_URL;
  let db = opts.db;
  if (!db && url) {
    const pg = await import('pg');
    const c = new pg.default.Client({ connectionString: url });
    await c.connect();
    await c.query('drop schema if exists public cascade; drop schema if exists drizzle cascade; create schema public;');
    await c.end();
    db = await openDb(url);
  }
  const config = loadConfig({ DATABASE_URL: 'pglite://memory', UPLOAD_DIR: dir, LOG_LEVEL: 'silent', SPEED: '2400', GEN_MS: '20', DISPATCH_MS: '50', SCHEDULER_MS: '50',
    BALANCE_CACHE_SEC: '0', AUTH_RATE_PER_MIN: '1000', PUBLIC_URL: '', ...env });
  const app = await buildApp(config, { logger: false, ...opts, db });
  const close = async () => { await app.close(); if (db && !opts.db) await db.close(); fs.rmSync(dir, { recursive: true, force: true }); };
  return { ...app, close, dir };
}

export type Client = { token: string; id: string; role: string; req: (method: string, url: string, body?: unknown) => Promise<{ status: number; body: any }> };

export function client(a: App, token?: string) {
  return async (method: string, url: string, body?: unknown) => {
    const r = await a.app.inject({ method: method as any, url, headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(body !== undefined ? { 'content-type': 'application/json' } : {}) },
      payload: body !== undefined ? JSON.stringify(body) : undefined });
    return { status: r.statusCode, body: r.body ? (() => { try { return JSON.parse(r.body); } catch { return r.body; } })() : null };
  };
}

const ATTEST = { attestAdultRightsOriginal: true, attestLabelAi: true };
/**
 * Owner + members on a fresh studio (via real invites). `topUp` (default $100) is recorded as the owner's first top-up of
 * the studio balance (plans/api.md "App clean-up" §4); pass 0 for a studio with no money loaded.
 */
export async function people(a: App, members = 1, opts: { topUp?: number } = {}): Promise<{ owner: Client; members: Client[] }> {
  const studio = await ensureStudio(a.ctx, 'Test Studio');
  const signUp = async (email: string, role: 'owner' | 'member') => {
    const inv = await createInvite(a.ctx, { studioId: studio.id, role });
    const r = await client(a)('POST', '/v1/auth/signup', { studioName: 'x', email, password: 'correct horse', inviteCode: inv.code, ...ATTEST });
    if (r.status !== 200) throw new Error(`signup failed ${JSON.stringify(r.body)}`);
    return { token: r.body.token, id: r.body.user.id, role: r.body.user.role, req: client(a, r.body.token) };
  };
  const owner = await signUp('owner@test.dev', 'owner');
  const ms: Client[] = [];
  for (let i = 0; i < members; i++) ms.push(await signUp(`member${i + 1}@test.dev`, 'member'));
  const topUp = opts.topUp ?? 100;
  if (topUp > 0) {
    const r = await owner.req('POST', '/v1/studio/topups', { amountUsd: topUp, note: 'test' });
    if (r.status !== 200) throw new Error(`top-up failed ${JSON.stringify(r.body)}`);
  }
  return { owner, members: ms };
}

/** A model with a full character sheet (bundled stills) and an outfit. */
export async function demoModel(c: Client) {
  const m = (await c.req('POST', '/v1/models', { name: 'Demo model', age: 24, niche: 'Fashion' })).body;
  for (const [k, a] of Object.entries({ face: 'face', profile: 'profile', front: 'g_front', tq: 'g_tq', side: 'g_side', back: 'g_back', faceTq: 'c_face' }))
    await c.req('PUT', `/v1/models/${m.id}/slots/${k}`, { image: { asset: a }, source: 'upload' });
  return m as { id: string };
}

export const until = async <T>(fn: () => Promise<T | undefined | null | false> | T | undefined | null | false, ms = 10_000): Promise<T> => {
  const t0 = Date.now();
  for (;;) {
    const v = await fn();
    if (v) return v as T;
    if (Date.now() - t0 > ms) throw new Error('timed out');
    await new Promise(r => setTimeout(r, 25));
  }
};

/**
 * Collects SSE events from a listening app. Resolves once the server has subscribed this stream (its `: connected`
 * line, written in the same tick as the subscription), so events emitted after this returns are never missed, however
 * slow the machine is. Also resolves if the stream ends without connecting (e.g. a 401).
 */
export async function sse(base: string, token: string) {
  const ctrl = new AbortController(), events: any[] = [];
  let connected!: () => void;
  const ready = new Promise<void>(r => { connected = r; });
  const done = fetch(`${base}/v1/events`, { headers: { authorization: `Bearer ${token}` }, signal: ctrl.signal }).then(async res => {
    const dec = new TextDecoder();
    let buf = '';
    for await (const chunk of res.body as any) {
      buf += dec.decode(chunk, { stream: true });
      let i;
      while ((i = buf.indexOf('\n\n')) >= 0) {
        const msg = buf.slice(0, i); buf = buf.slice(i + 2);
        for (const line of msg.split('\n')) {
          if (line === ': connected') connected();
          else if (line.startsWith('data: ')) events.push(JSON.parse(line.slice(6)));
        }
      }
    }
  }).catch(() => {}).finally(() => connected());
  let timer: NodeJS.Timeout | undefined;
  const late = new Promise<never>((_, no) => { timer = setTimeout(() => { ctrl.abort(); no(new Error('SSE stream did not connect')); }, 10_000); });
  await Promise.race([ready, late]).finally(() => clearTimeout(timer));
  return { events, stop: async () => { ctrl.abort(); await done; } };
}

export { sql };

/** Records another studio top-up directly (tests that used to set the simulated RunPod balance). */
export async function topUp(a: App, studioId: string, usd: number) {
  const [o] = await a.ctx.db.execute(sql`select id from users where studio_id = ${studioId} and role = 'owner' limit 1`).then((r: any) => r.rows ?? r);
  await a.ctx.money.recordTopUp({ id: o.id, studioId, role: 'owner' }, { amountUsd: usd, note: 'test' });
}
