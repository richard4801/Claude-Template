// Effort levels for Claude (owner, 2026-11-13: "add effort levels … just as we have here"): per chat, the person's last
// choice, else the model's own default; checked per model; sent to the in-app turn as output_config.effort. Fake Claude.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { assistantOf } from '../src/recreate/assistant.js';
import { checkEffort, CLAUDE_MODELS, EFFORTS, resolveEffort } from '../src/claude/models.js';
import { makeApp, people, type Client } from './helpers.js';

type App = Awaited<ReturnType<typeof makeApp>>;
let a: App, owner: Client, member: Client;

beforeAll(async () => {
  a = await makeApp({ ANTHROPIC_API_KEY: 'test-not-a-real-key' });
  const p = await people(a, 1); owner = p.owner; member = p.members[0]!;
});
afterAll(async () => { await a?.close(); });

describe('effort per model', () => {
  it('every listed model says which levels it takes and its own default', () => {
    for (const m of CLAUDE_MODELS) {
      expect(m.efforts.every(e => (EFFORTS as readonly string[]).includes(e))).toBe(true);
      if (m.efforts.length) expect(m.efforts).toContain(m.defaultEffort);
    }
    expect(CLAUDE_MODELS.find(m => m.id === 'claude-opus-5-5')!.defaultEffort).toBe('medium');
    expect(CLAUDE_MODELS.find(m => m.id === 'claude-sonnet-5-5')!.defaultEffort).toBe('high');
  });
  it('checks a level against the model; resolves chat, then last choice, then the model default', () => {
    expect(checkEffort('xhigh', 'claude-opus-5-5')).toBe('xhigh');
    expect(checkEffort(null)).toBeNull();
    expect(() => checkEffort('turbo')).toThrow(/effort/);
    expect(resolveEffort('claude-opus-5-5', null, null)).toBe('medium');
    expect(resolveEffort('claude-opus-5-5', null, 'max')).toBe('max');
    expect(resolveEffort('claude-opus-5-5', 'low', 'max')).toBe('low');
    expect(resolveEffort('claude-haiku-5-5', 'bogus', null)).toBe('medium');
  });
  it('a model with no effort setting takes none', () => {
    CLAUDE_MODELS.push({ id: 'claude-test-noeffort', name: 'No effort', speed: 'x', cost: 'x', good: 'x', efforts: [] });
    try {
      expect(() => checkEffort('high', 'claude-test-noeffort')).toThrow(/no effort setting/);
      expect(resolveEffort('claude-test-noeffort', 'high', 'high')).toBeUndefined();
    } finally { CLAUDE_MODELS.pop(); }
  });
});

describe('effort on chats', () => {
  it('a pick is kept on the chat, rides in its brief, and becomes the person\'s last choice (theirs only)', async () => {
    const c = (await member.req('POST', '/v1/claude/chats', {})).body;
    expect((await member.req('GET', '/v1/claude/models')).body.defaultEffort).toBeNull();
    expect((await member.req('PATCH', `/v1/claude/chats/${c.id}`, { effort: 'turbo' })).status).toBe(400);
    const set = (await member.req('PATCH', `/v1/claude/chats/${c.id}`, { effort: 'high' })).body;
    expect(set).toMatchObject({ effort: 'high', brief: { effort: 'high', chatId: c.id } });
    expect((await member.req('GET', `/v1/claude/chats/${c.id}`)).body.effort).toBe('high');
    expect((await member.req('GET', '/v1/claude/models')).body.defaultEffort).toBe('high');
    expect((await owner.req('GET', '/v1/claude/models')).body.defaultEffort).toBeNull();
    // Model and level together; clearing the chat's level leaves the last choice.
    expect((await member.req('PATCH', `/v1/claude/chats/${c.id}`, { model: 'claude-haiku-5-5', effort: 'max' })).body).toMatchObject({ model: 'claude-haiku-5-5', effort: 'max' });
    const cleared = (await member.req('PATCH', `/v1/claude/chats/${c.id}`, { effort: null })).body;
    expect(cleared.effort).toBeUndefined();
    expect(cleared.brief.effort).toBeUndefined();
    expect((await member.req('GET', '/v1/claude/models')).body.defaultEffort).toBe('max');
    expect((await member.req('PUT', '/v1/claude/prefs', { defaultEffort: 'low' })).body).toMatchObject({ defaultEffort: 'low' });
    expect((await member.req('PUT', '/v1/claude/prefs', { defaultEffort: 'nope' })).status).toBe(400);
    expect((await member.req('PUT', '/v1/claude/prefs', {})).status).toBe(400);
  });

  it('the in-app turn (studio key) sends the chat\'s level, else the model\'s own default', async () => {
    await owner.req('PATCH', '/v1/claude/settings', { apiFallback: true });
    const calls: any[] = [];
    assistantOf(a.ctx).setClient({ beta: { messages: { stream: (p: any) => {
      calls.push(structuredClone(p));
      return { on(_e: string, cb: (d: string) => void) { cb('ok'); return this; }, finalMessage: async () => ({ content: [{ type: 'text', text: 'ok' }], stop_reason: 'end_turn', usage: {} }) };
    } } } } as any);
    const c = (await owner.req('POST', '/v1/claude/chats', {})).body;
    expect((await owner.req('POST', `/v1/claude/chats/${c.id}/turn`, { text: 'hi' })).status).toBe(200);
    expect(calls.at(-1)).toMatchObject({ model: 'claude-opus-5-5', output_config: { effort: 'medium' } });
    await owner.req('PATCH', `/v1/claude/chats/${c.id}`, { effort: 'high' });
    expect((await owner.req('POST', `/v1/claude/chats/${c.id}/turn`, { text: 'again' })).status).toBe(200);
    expect(calls.at(-1).output_config).toEqual({ effort: 'high' });
    // A new chat starts from the last choice.
    const c2 = (await owner.req('POST', '/v1/claude/chats', {})).body;
    expect((await owner.req('POST', `/v1/claude/chats/${c2.id}/turn`, { text: 'new' })).status).toBe(200);
    expect(calls.at(-1).output_config).toEqual({ effort: 'high' });
  });
});
