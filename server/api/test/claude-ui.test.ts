// Claude operates the MUSE window (claude/uiControl.ts): the person's own Mac does it; old apps are refused; protected
// controls (keys, prices, sign-out, payments, deletes) are never touched; one Mac claims each call.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { protectedReason } from '../src/claude/uiControl.js';
import { makeApp, people, type Client } from './helpers.js';

type App = Awaited<ReturnType<typeof makeApp>>;
let a: App, owner: Client, member: Client, token: string, memberToken: string;
beforeAll(async () => {
  a = await makeApp();
  ({ owner, members: [member] } = await people(a, 1) as { owner: Client; members: Client[] });
  token = (await owner.req('POST', '/v1/mcp/session-token')).body.token;
  memberToken = (await member.req('POST', '/v1/mcp/session-token')).body.token;
});
afterAll(async () => { await a.close(); });

let n = 1;
const rpc = async (tok: string, name: string, args: Record<string, unknown>) => {
  const r = await a.app.inject({ method: 'POST', url: '/mcp', headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream', authorization: `Bearer ${tok}` },
    payload: JSON.stringify({ jsonrpc: '2.0', id: n++, method: 'tools/call', params: { name, arguments: args } }) });
  return JSON.parse(r.body).result;
};
const caps = (c: Client, list: string) => a.app.inject({ method: 'GET', url: '/v1/claude/ui', headers: { authorization: `Bearer ${c.token}`, 'x-muse-caps': list } });
const nextCall = async (c: Client) => { let x: any; for (let i = 0; i < 50 && !x; i++) { x = (await c.req('GET', '/v1/claude/ui')).body.calls[0]; if (!x) await new Promise(r => setTimeout(r, 20)); } return x; };

describe('ui_* tools (Claude operates the MUSE window)', () => {
  it('listed for owner and members; old apps get "newer MUSE app"', async () => {
    for (const tok of [token, memberToken]) {
      const r = await a.app.inject({ method: 'POST', url: '/mcp', headers: { 'content-type': 'application/json', accept: 'application/json', authorization: `Bearer ${tok}` },
        payload: JSON.stringify({ jsonrpc: '2.0', id: n++, method: 'tools/list' }) });
      const names = JSON.parse(r.body).result.tools.map((t: any) => t.name);
      expect(names).toEqual(expect.arrayContaining(['ui_snapshot', 'ui_act', 'ui_wait']));
    }
    await caps(owner, 'files,results'); // a Mac that can't operate its window
    const r = await rpc(token, 'ui_snapshot', {});
    expect(r.isError).toBe(true);
    expect(r.content[0].text).toMatch(/newer MUSE app/);
  });

  it('snapshot: the Mac claims, answers with controls and a picture of the MUSE window', async () => {
    await caps(owner, 'files,results,ui');
    const p = rpc(token, 'ui_snapshot', { screenshot: true });
    const c = await nextCall(owner);
    expect(c).toMatchObject({ kind: 'snapshot', args: { screenshot: true } });
    expect((await member.req('POST', `/v1/claude/ui/${c.id}/claim`, { device: 'm' })).status).toBe(410); // not theirs
    expect((await owner.req('POST', `/v1/claude/ui/${c.id}/claim`, { device: 'mac-1' })).status).toBe(200);
    expect((await owner.req('POST', `/v1/claude/ui/${c.id}/claim`, { device: 'mac-2' })).status).toBe(409); // the other Mac does nothing
    expect((await owner.req('GET', '/v1/claude/ui')).body.calls).toEqual([]);
    const result = { page: 'library', controls: [{ id: 'library.search', role: 'textField', label: 'Search', enabled: true }] };
    expect((await owner.req('POST', `/v1/claude/ui/${c.id}`, { result, image: 'AAAA' })).status).toBe(204);
    const r = await p;
    expect(r.content[0]).toEqual({ type: 'image', data: 'AAAA', mimeType: 'image/jpeg' });
    expect(JSON.parse(r.content[1].text)).toEqual(result);
    expect((await owner.req('POST', `/v1/claude/ui/${c.id}`, { result })).status).toBe(410); // ended
  });

  it('act: protected controls refused before the Mac is asked; Esc stop comes back as the person\'s choice', async () => {
    for (const target of ['settings.providers.apiKey', 'Sign out', 'Top up', 'Delete account', 'Confirm delete', 'settings.prices.markup', 'Generate', 'Approve']) {
      const r = await rpc(token, 'ui_act', { action: 'press', target });
      expect(r.isError).toBe(true);
      expect(r.content[0].text).toMatch(/^ui_protected: .*for the person/);
    }
    expect((await rpc(token, 'ui_act', { action: 'key', value: 'cmd+q' })).content[0].text).toMatch(/value: a key/);
    expect((await rpc(token, 'ui_act', { action: 'press' })).content[0].text).toMatch(/target/);
    expect((await owner.req('GET', '/v1/claude/ui')).body.calls).toEqual([]);

    const p = rpc(token, 'ui_act', { action: 'set_text', target: 'library.search', value: 'beach' });
    const c = await nextCall(owner);
    expect(c.args).toEqual({ action: 'set_text', target: 'library.search', value: 'beach' });
    await owner.req('POST', `/v1/claude/ui/${c.id}/claim`, { device: 'mac-1' });
    await owner.req('POST', `/v1/claude/ui/${c.id}`, { error: 'The person pressed Esc: Claude stopped.', code: 'stopped' });
    const r = await p;
    expect(r.isError).toBe(true);
    expect(r.content[0].text).toBe('ui_stopped: The person pressed Esc: Claude stopped.');
    const issues = (await owner.req('GET', '/v1/claude/issues')).body;
    expect(JSON.stringify(issues)).not.toContain('ui_stopped'); // not a MUSE problem

    const p2 = rpc(token, 'ui_act', { action: 'key', value: 'Return' });
    const c2 = await nextCall(owner);
    expect(c2.args).toEqual({ action: 'key', value: 'return' });
    await owner.req('POST', `/v1/claude/ui/${c2.id}`, { result: { done: true } });
    expect(JSON.parse((await p2).content[0].text)).toEqual({ done: true });
  });

  it('a member\'s call goes to the member\'s Mac only', async () => {
    await caps(member, 'ui');
    const p = rpc(memberToken, 'ui_wait', { for: 'idle', timeout: 2 });
    const c = await nextCall(member);
    expect(c).toMatchObject({ kind: 'wait', args: { for: 'idle', timeout: 2 } });
    expect((await owner.req('GET', '/v1/claude/ui')).body.calls).toEqual([]);
    expect((await owner.req('POST', `/v1/claude/ui/${c.id}`, { result: {} })).status).toBe(410);
    await member.req('POST', `/v1/claude/ui/${c.id}`, { result: { met: true, waitedMs: 120 } });
    expect(JSON.parse((await p).content[0].text)).toEqual({ met: true, waitedMs: 120 });
  });

  it('refusal list', () => {
    for (const t of ['API key', 'settings.engines.token', 'Log out', 'Buy credits', 'Payment', 'Discard', 'edit.clip.delete', 'Show provider names', 'Generate', 'Generate · $0.40', 'Run queue', 'Approve', 'Allow once', 'Post now', 'Spend 12 credits'])
      expect(protectedReason(t), t).not.toBeNull();
    for (const t of ['library.search', 'Remove from collection', 'Export', 'suite.prompt', 'Deliver', 'Add to queue', 'Posts', 'Deny']) expect(protectedReason(t), t).toBeNull();
  });
});
