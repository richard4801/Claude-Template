import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createInvite, ensureStudio } from '../src/auth/auth.js';
import { sessions, users } from '../src/db/schema.js';
import { client, makeApp, people } from './helpers.js';

const ATTEST = { attestAdultRightsOriginal: true, attestLabelAi: true };

describe('auth and invites', () => {
  let a: Awaited<ReturnType<typeof makeApp>>;
  beforeAll(async () => { a = await makeApp(); });
  afterAll(async () => { await a.close(); });
  const anon = () => client(a);

  it('everything under /v1 needs a session; /health does not', async () => {
    expect((await anon()('GET', '/v1/models')).body).toEqual({ error: 'Sign in to continue', code: 'unauthorized' });
    expect((await anon()('GET', '/v1/models')).status).toBe(401);
    expect((await anon()('GET', '/health')).body.ok).toBe(true);
    expect((await client(a, 'muse_nope')('GET', '/v1/balance')).status).toBe(401);
  });

  it('sign-up needs both attestations (checked first), then an invite', async () => {
    let r = await anon()('POST', '/v1/auth/signup', { email: 'a@b.co', password: 'longenough', attestAdultRightsOriginal: true, attestLabelAi: false });
    expect(r.status).toBe(400); expect(r.body.code).toBe('attestation_required');
    r = await anon()('POST', '/v1/auth/signup', { email: 'a@b.co', password: 'longenough', ...ATTEST });
    expect(r.body.code).toBe('invite_required');
    r = await anon()('POST', '/v1/auth/signup', { email: 'a@b.co', password: 'longenough', inviteCode: 'MUSE-AAAA-BBBB-CCCC', ...ATTEST });
    expect(r.body.code).toBe('invite_invalid');
  });

  it('an invite works once, stores the attestations with a timestamp, and the first one makes the owner', async () => {
    const st = await ensureStudio(a.ctx, 'Studio A');
    const inv = await createInvite(a.ctx, { studioId: st.id });
    expect(inv.role).toBe('owner');
    expect(inv.code).toMatch(/^MUSE-[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$/);
    const t0 = Date.now();
    const r = await anon()('POST', '/v1/auth/signup', { studioName: 'ignored', email: 'Boss@Studio.dev', password: 'longenough', inviteCode: inv.code.toLowerCase(), ...ATTEST });
    expect(r.status).toBe(200);
    expect(r.body.user).toMatchObject({ email: 'boss@studio.dev', studioName: 'Studio A', role: 'owner' });
    expect(r.body.token).toMatch(/^muse_/);
    const [u] = await a.ctx.db.select().from(users);
    expect(u!.attestAdultRightsOriginalAt).toBeGreaterThanOrEqual(t0);
    expect(u!.attestLabelAiAt).toBeGreaterThanOrEqual(t0);
    expect(u!.passwordHash).toMatch(/^\$argon2id\$/);
    const again = await anon()('POST', '/v1/auth/signup', { email: 'other@studio.dev', password: 'longenough', inviteCode: inv.code, ...ATTEST });
    expect(again.body.code).toBe('invite_invalid');
    // Tokens are stored hashed only.
    const rows = await a.ctx.db.select().from(sessions);
    expect(rows.every(s => !s.tokenHash.includes(r.body.token) && s.tokenHash.length === 64)).toBe(true);
  });

  it('owner makes invites (email-locked), members cannot; sign-in, sign-out revokes', async () => {
    const owner = await client(a)('POST', '/v1/auth/signin', { email: 'boss@studio.dev', password: 'longenough' });
    expect(owner.status).toBe(200);
    const o = client(a, owner.body.token);
    const inv = await o('POST', '/v1/invites', { email: 'tess@studio.dev' });
    expect(inv.status).toBe(200); expect(inv.body.role).toBe('member');
    expect((await anon()('POST', '/v1/auth/signup', { email: 'wrong@studio.dev', password: 'longenough', inviteCode: inv.body.code, ...ATTEST })).body.code).toBe('invite_invalid');
    const m = await anon()('POST', '/v1/auth/signup', { email: 'tess@studio.dev', password: 'longenough', inviteCode: inv.body.code, ...ATTEST });
    expect(m.body.user.role).toBe('member');
    const mc = client(a, m.body.token);
    expect((await mc('POST', '/v1/invites', {})).body.code).toBe('owner_only');
    expect((await mc('GET', '/v1/invites')).status).toBe(403);
    expect((await o('GET', '/v1/invites')).body.length).toBe(2);
    expect((await client(a)('POST', '/v1/auth/signin', { email: 'tess@studio.dev', password: 'nope' })).body.code).toBe('bad_credentials');
    expect((await mc('GET', '/v1/auth/me')).body.email).toBe('tess@studio.dev');
    expect((await mc('POST', '/v1/auth/signout')).status).toBe(204);
    expect((await mc('GET', '/v1/auth/me')).status).toBe(401);
    // Short passwords are refused outside dev mode.
    const inv2 = await o('POST', '/v1/invites', {});
    expect((await anon()('POST', '/v1/auth/signup', { email: 'x@studio.dev', password: 'short', inviteCode: inv2.body.code, ...ATTEST })).status).toBe(400);
  });

  it('disabled members are signed out', async () => {
    const owner = client(a, (await client(a)('POST', '/v1/auth/signin', { email: 'boss@studio.dev', password: 'longenough' })).body.token);
    const tess = (await client(a)('POST', '/v1/auth/signin', { email: 'tess@studio.dev', password: 'longenough' })).body;
    expect((await owner('PATCH', `/v1/members/${tess.user.id}`, { disabled: true })).body.disabled).toBe(true);
    expect((await client(a, tess.token)('GET', '/v1/models')).status).toBe(401);
    expect((await client(a)('POST', '/v1/auth/signin', { email: 'tess@studio.dev', password: 'longenough' })).body.code).toBe('account_disabled');
  });
});

describe('auth rate limit', () => {
  it('limits sign-in attempts per IP', async () => {
    const a = await makeApp({ AUTH_RATE_PER_MIN: '3' });
    const codes = [];
    for (let i = 0; i < 5; i++) codes.push((await client(a)('POST', '/v1/auth/signin', { email: 'x@y.zz', password: 'nope' })).body.code);
    expect(codes.slice(0, 3)).toEqual(['bad_credentials', 'bad_credentials', 'bad_credentials']);
    expect(codes[4]).toBe('rate_limited');
    await a.close();
  });
  it('OWNER_INVITE_CODE makes the first owner without a terminal, once', async () => {
    const a = await makeApp({ OWNER_INVITE_CODE: 'my-own-secret-code', STUDIO_NAME: 'Jenne Studio' });
    const r = await client(a)('POST', '/v1/auth/signup', { email: 'jen@x.dev', password: 'longenough', inviteCode: 'my-own-secret-code', ...ATTEST });
    expect(r.body.user).toMatchObject({ role: 'owner', studioName: 'Jenne Studio' });
    expect((await client(a)('POST', '/v1/auth/signup', { email: 'b@x.dev', password: 'longenough', inviteCode: 'my-own-secret-code', ...ATTEST })).body.code).toBe('invite_invalid');
    await a.close();
  });
  it('dev mode lets sign-up skip the invite (contract tests only)', async () => {
    const a = await makeApp({ DEV_MODE: 'true' });
    const r = await client(a)('POST', '/v1/auth/signup', { studioName: 'S', email: 'a@b.c', password: 'x', ...ATTEST });
    expect(r.status).toBe(200);
    await a.close();
  });
  void people;
});
