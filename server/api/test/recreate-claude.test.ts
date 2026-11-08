// Claude in the Recreate and Edit screens (workstream 1, Release 1 #4): "recreate" chat threads, the brief Claude on the
// owner's Mac starts from, and the API-key fallback running MUSE's own editor loop. A fake Claude client: no API calls.
import fs from 'node:fs';
import path from 'node:path';
import { eq } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { users } from '../src/db/schema.js';
import { assistantOf } from '../src/recreate/assistant.js';
import { recreateReferences } from '../src/recreate/schema.js';
import { makeApp, people, type Client } from './helpers.js';

const FIX = path.join(path.dirname(new URL(import.meta.url).pathname), 'fixtures');

/** A scripted Claude: each call to stream() gives the next reply; the params of every call are kept. */
function fakeClaude(replies: { text?: string; tools?: { name: string; input: Record<string, unknown> }[] }[]) {
  const calls: any[] = [];
  let i = 0;
  return {
    calls,
    client: { beta: { messages: { stream: (params: any) => {
      calls.push(structuredClone(params));
      const r = replies[Math.min(i++, replies.length - 1)]!;
      const content = [...(r.text ? [{ type: 'text', text: r.text }] : []), ...(r.tools ?? []).map((t, k) => ({ type: 'tool_use', id: `tu_${i}_${k}`, name: t.name, input: t.input }))];
      return {
        on(_e: 'text', cb: (d: string) => void) { if (r.text) cb(r.text); return this; },
        finalMessage: async () => ({ content, stop_reason: r.tools?.length ? 'tool_use' : 'end_turn', usage: {} }) as any,
      };
    } } } },
  };
}

describe('Claude in Recreate · threads and the API fallback', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, member: Client, refId: string;
  beforeAll(async () => {
    a = await makeApp({ ANTHROPIC_API_KEY: 'test-not-a-real-key' });
    ({ owner, members: [member] } = await people(a, 1, { topUp: 0 }) as any);
    const [u] = await a.ctx.db.select().from(users).where(eq(users.id, owner.id));
    const recipe = (JSON.parse(fs.readFileSync(path.join(FIX, 'recipe-v1.json'), 'utf8')) as { recipe: any }).recipe;
    refId = 'rx_claude1';
    const now = Date.now();
    await a.ctx.db.insert(recreateReferences).values({ id: refId, studioId: u!.studioId, userId: owner.id, name: 'Tuff edit', state: 'ready', recipe: { ...recipe, id: refId }, createdAt: now, expiresAt: now + 86_400_000 });
  });
  afterAll(async () => { await a?.close(); });

  it('a "recreate" thread is about one of the owner\'s references, with the brief Claude on the Mac starts from', async () => {
    const t = (await owner.req('POST', '/v1/claude/threads', { contextKind: 'recreate', contextId: refId })).body;
    expect(t).toMatchObject({ contextKind: 'recreate', contextId: refId, brief: { referenceId: refId, tools: expect.arrayContaining(['get_recipe', 'match_slots', 'fill_slot', 'apply_recipe']) } });
    expect(t.brief.prompt).toMatch(/recreate a reference edit/);
    // The same thread again; a reference that isn't theirs is not found; members can't open threads.
    expect((await owner.req('POST', '/v1/claude/threads', { contextKind: 'recreate', contextId: refId })).body.id).toBe(t.id);
    expect((await owner.req('POST', '/v1/claude/threads', { contextKind: 'recreate', contextId: 'rx_nope' })).status).toBe(404);
    expect((await member.req('POST', '/v1/claude/threads', { contextKind: 'recreate', contextId: refId })).status).toBe(403);
    const e = (await owner.req('POST', '/v1/claude/threads', { contextKind: 'edit', contextId: 'es_x' })).body;
    expect(e.brief).toMatchObject({ sessionId: 'es_x', tools: expect.arrayContaining(['get_edit', 'apply_edit_ops']) });
  });

  it('the API fallback runs MUSE\'s editor loop: the reference filled in, the tools run, the turn mirrored into the thread', async () => {
    const t = (await owner.req('POST', '/v1/claude/threads', { contextKind: 'recreate', contextId: refId })).body;
    await owner.req('PATCH', '/v1/claude/settings', { apiFallback: true });
    const fake = fakeClaude([
      { tools: [{ name: 'get_recipe', input: { contactSheet: false } }] },
      { text: 'Three shots: a pan, a push-in, then a still with a caption.' },
    ]);
    assistantOf(a.ctx).setClient(fake.client);
    const r = await owner.req('POST', `/v1/claude/threads/${t.id}/api-turn`, { text: 'What is in this edit?' });
    expect(r.status).toBe(200);
    const sse = String(r.body);
    expect(sse).toContain('"type":"tool"');
    expect(sse).toContain('"name":"get_recipe","status":"done"');
    expect(sse).toContain('"type":"done"');
    // Claude never sees the reference id in the tool schema; the server fills it.
    const tools = fake.calls[0].tools as { name: string; input_schema: { properties: Record<string, unknown>; required: string[] } }[];
    const gr = tools.find(x => x.name === 'get_recipe')!;
    expect(gr.input_schema.properties.referenceId).toBeUndefined();
    expect(gr.input_schema.required).not.toContain('referenceId');
    expect(tools.find(x => x.name === 'open_edit')).toBeTruthy(); // to build the edit
    // The tool ran on this reference and its result went back to Claude.
    const toolResult = fake.calls[1].messages.at(-1).content[0];
    expect(toolResult).toMatchObject({ type: 'tool_result' });
    expect(String(toolResult.content)).toContain('muse.recipe/1');
    expect(fake.calls[0].messages.at(-1).content[0].text).toMatch(/^\[Reference rx_claude1 “Tuff edit” · ready · 3 shots/);
    const msgs = (await owner.req('GET', `/v1/claude/threads/${t.id}`)).body.messages;
    expect(msgs.map((m: any) => [m.role, m.text])).toEqual([['user', 'What is in this edit?'], ['assistant', 'Three shots: a pan, a push-in, then a still with a caption.']]);

    // The next turn rebuilds the conversation from the thread: the earlier turn once, this line once.
    const fake2 = fakeClaude([{ text: 'Shot 2 is a close-up.' }]);
    assistantOf(a.ctx).setClient(fake2.client);
    await owner.req('POST', `/v1/claude/threads/${t.id}/api-turn`, { text: 'And shot 2?' });
    const m = fake2.calls[0].messages as { role: string; content: { text: string }[] }[];
    expect(m.map(x => x.role)).toEqual(['user', 'assistant', 'user']);
    expect(m[2]!.content.map(c => c.text)).toEqual([expect.stringMatching(/^\[Reference rx_claude1 .*\]\n\nAnd shot 2\?$/)]);
  });

  it('a paid step keeps its approval: fill_slot without confirm only prices; nothing is spent or started', async () => {
    const t = (await owner.req('POST', '/v1/claude/threads', { contextKind: 'recreate', contextId: refId })).body;
    const s = (await a.ctx.db.select().from(recreateReferences).where(eq(recreateReferences.id, refId)))[0]!;
    const fake = fakeClaude([
      { tools: [{ name: 'fill_slot', input: { slotId: 's2', modelId: 'm_none', sessionId: 'es_none' } }] },
      { text: 'Generating s2 needs a model and an open edit first.' },
    ]);
    assistantOf(a.ctx).setClient(fake.client);
    const r = await owner.req('POST', `/v1/claude/threads/${t.id}/api-turn`, { text: 'Generate shot 2' });
    expect(String(r.body)).toContain('"name":"fill_slot","status":"error"'); // no such session: refused before any price or job
    expect((await a.ctx.db.select().from(recreateReferences).where(eq(recreateReferences.id, refId)))[0]!.fill).toEqual(s.fill);
  });

  it('busy and plain errors before streaming; the fallback still needs the owner\'s switch', async () => {
    const t = (await owner.req('POST', '/v1/claude/threads', { contextKind: 'recreate', contextId: refId })).body;
    expect((await owner.req('POST', `/v1/claude/threads/${t.id}/api-turn`, { text: '' })).status).toBe(400);
    await owner.req('PATCH', '/v1/claude/settings', { apiFallback: false });
    expect((await owner.req('POST', `/v1/claude/threads/${t.id}/api-turn`, { text: 'hi' })).body.code).toBe('fallback_off');
  });
});
