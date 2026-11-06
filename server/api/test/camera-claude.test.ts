// Claude chat threads on the owner's plan: Mac presence, phone turns relayed to the Mac (queue / claim / stop /
// timeout), the Mac mirroring its Claude Code stream, live events, the API-key fallback switch. No Claude calls.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { cameraOf } from '../src/routes/camera.js';
import { makeApp, people, sse, until, type Client } from './helpers.js';

type App = Awaited<ReturnType<typeof makeApp>>;
let a: App, owner: Client, member: Client, base: string, sessionId: string;
const READY = { claudeCode: { installed: true, signedIn: true, version: '2.1.300 (Claude Code)', model: 'claude-opus-5-5' } };

beforeAll(async () => {
  a = await makeApp();
  await a.app.listen({ port: 0, host: '127.0.0.1' });
  base = `http://127.0.0.1:${(a.app.server.address() as { port: number }).port}`;
  ({ owner, members: [member] } = await people(a, 1, { topUp: 0 }) as { owner: Client; members: Client[] });
  sessionId = (await owner.req('POST', '/v1/camera-sessions', { title: 'Claude chat' })).body.id;
});
afterAll(async () => { await a.close(); });
const claude = () => cameraOf(a.ctx).claude!;
const thread = async (contextId = sessionId, contextKind = 'camera') => (await owner.req('POST', '/v1/claude/threads', { contextKind, contextId })).body;

describe('status, settings, threads', () => {
  it('owner only; the Mac is offline until it sends a heartbeat; the API fallback is off by default', async () => {
    expect((await member.req('GET', '/v1/claude/status')).status).toBe(403);
    const s = (await owner.req('GET', '/v1/claude/status')).body;
    expect(s).toMatchObject({ mac: { online: false, claudeCode: { installed: false, signedIn: false } }, apiFallback: { available: false, enabled: false },
      openInClaudeUrl: 'https://claude.ai/new' });
    expect(s.connectorUrl).toMatch(/\/mcp$/);
    const hb = (await owner.req('POST', '/v1/claude/mac/heartbeat', READY)).body;
    expect(hb).toEqual({ ok: true, pending: [] });
    expect((await owner.req('GET', '/v1/claude/status')).body.mac).toMatchObject({ online: true, claudeCode: READY.claudeCode });
    expect((await owner.req('PATCH', '/v1/claude/settings', { apiFallback: true })).body.apiFallback).toEqual({ available: false, enabled: true });
    await owner.req('PATCH', '/v1/claude/settings', { apiFallback: false });
  });

  it('one thread per context: camera ids must be the owner\'s sessions, edit ids are free-form', async () => {
    const t1 = await thread(), t2 = await thread();
    expect(t1.id).toMatch(/^ct_/);
    expect(t2.id).toBe(t1.id);
    expect((await owner.req('POST', '/v1/claude/threads', { contextKind: 'camera', contextId: 'cs_nope' })).status).toBe(404);
    expect((await thread('es_123', 'edit')).contextKind).toBe('edit');
    expect((await owner.req('PATCH', `/v1/claude/threads/${t1.id}`, { claudeSessionId: '4f1c-session' })).body.claudeSessionId).toBe('4f1c-session');
    expect((await member.req('POST', '/v1/claude/threads', { contextKind: 'edit', contextId: 'x' })).status).toBe(403);
  });
});

describe('phone → Mac relay', () => {
  it('queue, claim once, mirrored stream (deltas live, messages stored), done; live events reach the owner', async () => {
    const live = await sse(base, owner.token);
    await owner.req('POST', '/v1/claude/mac/heartbeat', READY);
    const t = await thread();
    const sent = await owner.req('POST', `/v1/claude/threads/${t.id}/messages`, { text: 'Lower the camera, lens 50' });
    expect(sent.status).toBe(202);
    expect(sent.body.turn).toMatchObject({ state: 'queued', from: 'phone', text: 'Lower the camera, lens 50' });
    expect((await owner.req('POST', `/v1/claude/threads/${t.id}/messages`, { text: 'again' })).body.code).toBe('claude_busy');
    const [p] = (await owner.req('GET', '/v1/claude/turns')).body;
    expect(p.id).toBe(sent.body.turn.id);
    expect((await owner.req('POST', `/v1/claude/turns/${p.id}/claim`)).body.state).toBe('running');
    expect((await owner.req('POST', `/v1/claude/turns/${p.id}/claim`)).body.code).toBe('already_claimed');
    expect((await owner.req('GET', '/v1/claude/status')).body.mac.answeringTurn).toBe(p.id);

    const png = Buffer.from('fakepng').toString('base64');
    const ev = await owner.req('POST', `/v1/claude/threads/${t.id}/events`, { turnId: p.id, events: [
      { type: 'user', text: 'Lower the camera, lens 50' },
      { type: 'text', delta: 'Lowering ' }, { type: 'text', delta: 'the camera…' },
      { type: 'tool', id: 'toolu_1', name: 'mcp__muse__set_camera_path', status: 'running' },
      { type: 'tool', id: 'toolu_1', name: 'mcp__muse__set_camera_path', status: 'done', summary: 'Saved camera path' },
      { type: 'image', data: png, mimeType: 'image/png' },
      { type: 'assistant', text: 'Done: camera at 1.2 m, 50 mm.' },
      { type: 'done', ok: true, model: 'claude-opus-5-5' },
    ] });
    expect(ev.body).toEqual({ ok: true });
    const g = (await owner.req('GET', `/v1/claude/threads/${t.id}`)).body;
    expect(g.activeTurn).toBeUndefined();
    expect(g.messages.map((m: any) => [m.role, m.source])).toEqual([['user', 'phone'], ['tool', 'mac'], ['tool', 'mac'], ['assistant', 'mac']]);
    expect(g.messages[1].tool).toEqual({ id: 'toolu_1', name: 'mcp__muse__set_camera_path', ok: true, summary: 'Saved camera path' });
    expect(await (await fetch(g.messages[2].image.url)).text()).toBe('fakepng');
    await until(() => live.events.some(e => e.type === 'claude' && e.op === 'turn' && e.turn.state === 'done'));
    const deltas = live.events.filter(e => e.type === 'claude' && e.op === 'event' && e.event.type === 'text').map(e => e.event.delta).join('');
    expect(deltas).toBe('Lowering the camera…');
    expect(live.events.some(e => e.type === 'claude' && e.op === 'message' && e.message.role === 'assistant')).toBe(true);
    expect((await owner.req('POST', `/v1/claude/threads/${t.id}/events`, { turnId: p.id, events: [{ type: 'text', delta: 'late' }] })).body.code).toBe('turn_expired');
    await live.stop();
  });

  it('the Mac\'s own turns (no turnId) store the user message too', async () => {
    const t = await thread('es_mac_own', 'edit');
    await owner.req('POST', `/v1/claude/threads/${t.id}/events`, { events: [{ type: 'user', text: 'Trim the first second' }, { type: 'assistant', text: 'Trimmed 0:00–0:01.' }] });
    expect((await owner.req('GET', `/v1/claude/threads/${t.id}`)).body.messages.map((m: any) => m.text)).toEqual(['Trim the first second', 'Trimmed 0:00–0:01.']);
  });

  it('stop: a queued turn stops at once; a running one asks the Mac to interrupt', async () => {
    const live = await sse(base, owner.token);
    await owner.req('POST', '/v1/claude/mac/heartbeat', READY);
    const t = await thread('es_stop', 'edit');
    const q = (await owner.req('POST', `/v1/claude/threads/${t.id}/messages`, { text: 'one' })).body.turn;
    expect((await owner.req('POST', `/v1/claude/turns/${q.id}/stop`)).body.state).toBe('stopped');
    const r = (await owner.req('POST', `/v1/claude/threads/${t.id}/messages`, { text: 'two' })).body.turn;
    await owner.req('POST', `/v1/claude/turns/${r.id}/claim`);
    expect((await owner.req('POST', `/v1/claude/turns/${r.id}/stop`)).body.state).toBe('running');
    await until(() => live.events.some(e => e.type === 'claude' && e.op === 'stop' && e.turnId === r.id));
    await owner.req('POST', `/v1/claude/threads/${t.id}/events`, { turnId: r.id, events: [{ type: 'done', ok: false, error: 'Stopped' }] });
    expect((await owner.req('GET', `/v1/claude/threads/${t.id}`)).body.activeTurn).toBeUndefined();
    await live.stop();
  });

  it('timeouts: an unclaimed turn fails; a claimed one that goes silent fails', async () => {
    claude().claimTimeoutMs = 80; claude().silentTurnMs = 120;
    try {
      await owner.req('POST', '/v1/claude/mac/heartbeat', READY);
      const t = await thread('es_timeout', 'edit');
      const q = (await owner.req('POST', `/v1/claude/threads/${t.id}/messages`, { text: 'nobody home' })).body.turn;
      await until(async () => !(await owner.req('GET', `/v1/claude/threads/${t.id}`)).body.activeTurn);
      expect((await owner.req('POST', `/v1/claude/turns/${q.id}/claim`)).body.code).toBe('turn_expired');
      const r = (await owner.req('POST', `/v1/claude/threads/${t.id}/messages`, { text: 'claimed then silent' })).body.turn;
      await owner.req('POST', `/v1/claude/turns/${r.id}/claim`);
      await until(async () => !(await owner.req('GET', `/v1/claude/threads/${t.id}`)).body.activeTurn);
    } finally { claude().claimTimeoutMs = 90_000; claude().silentTurnMs = 600_000; }
  });

  it('Mac offline: mac_offline with the fallback options; api-turn refused while the fallback is off', async () => {
    const t = await thread();
    // Forget the Mac (its heartbeat is older than 45 s).
    (claude() as any).presence.clear();
    const r = await owner.req('POST', `/v1/claude/threads/${t.id}/messages`, { text: 'hello?' });
    expect(r.status).toBe(409);
    expect(r.body).toMatchObject({ code: 'mac_offline', fallback: { openInClaudeUrl: 'https://claude.ai/new', apiFallback: false } });
    expect((await owner.req('POST', `/v1/claude/threads/${t.id}/api-turn`, { text: 'hi' })).body.code).toBe('fallback_off');
    await owner.req('POST', '/v1/claude/mac/heartbeat', { claudeCode: { installed: true, signedIn: false } });
    expect((await owner.req('POST', `/v1/claude/threads/${t.id}/messages`, { text: 'signed out' })).body.code).toBe('mac_offline');
  });

  it('validates events and limits', async () => {
    const t = await thread();
    expect((await owner.req('POST', `/v1/claude/threads/${t.id}/events`, { events: [{ type: 'nope' }] })).status).toBe(400);
    expect((await owner.req('POST', `/v1/claude/threads/${t.id}/events`, { events: [] })).status).toBe(400);
    expect((await member.req('POST', `/v1/claude/threads/${t.id}/events`, { events: [{ type: 'text', delta: 'x' }] })).status).toBe(403);
  });
});

describe('API-key fallback (opt-in, fake Claude client)', () => {
  it('when on, api-turn streams the camera director and mirrors the turn into the thread', async () => {
    const b = await makeApp({ ANTHROPIC_API_KEY: 'test-not-a-real-key' });
    try {
      const { owner: o } = await people(b, 0, { topUp: 0 }) as { owner: Client };
      const s = (await o.req('POST', '/v1/camera-sessions', {})).body;
      const t = (await o.req('POST', '/v1/claude/threads', { contextKind: 'camera', contextId: s.id })).body;
      expect((await o.req('POST', `/v1/claude/threads/${t.id}/api-turn`, { text: 'hi' })).body.code).toBe('fallback_off');
      expect((await o.req('PATCH', '/v1/claude/settings', { apiFallback: true })).body.apiFallback).toEqual({ available: true, enabled: true });
      cameraOf(b.ctx).director.setClient({ beta: { messages: { stream: () => ({ on(_e: 'text', cb: (d: string) => void) { cb('From the studio key.'); return this; },
        finalMessage: async () => ({ content: [{ type: 'text', text: 'From the studio key.' }], stop_reason: 'end_turn', usage: {} }) as any }) } } });
      const r = await o.req('POST', `/v1/claude/threads/${t.id}/api-turn`, { text: 'hi' });
      expect(r.status).toBe(200);
      expect(String(r.body)).toContain('"type":"done"');
      const msgs = (await o.req('GET', `/v1/claude/threads/${t.id}`)).body.messages;
      expect(msgs.map((m: any) => [m.role, m.source, m.text])).toEqual([['user', 'api', 'hi'], ['assistant', 'api', 'From the studio key.']]);
    } finally { await b.close(); }
  });
});
