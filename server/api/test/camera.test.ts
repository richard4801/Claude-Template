// Camera sessions, presigned guide uploads, Shot drafts (no spend), live events, the Blender relay and the
// Direct with Claude chat with a fake Claude client (no API calls).
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { ledger } from '../src/db/schema.js';
import { cameraOf } from '../src/routes/camera.js';
import type { DirectorClient } from '../src/camera/director.js';
import { demoModel, makeApp, people, sse, until, type Client } from './helpers.js';

type App = Awaited<ReturnType<typeof makeApp>>;
let a: App, owner: Client, member: Client, base: string, modelId: string;

beforeAll(async () => {
  a = await makeApp({ BLENDER_CALL_TIMEOUT_SEC: '5' });
  await a.app.listen({ port: 0, host: '127.0.0.1' });
  base = `http://127.0.0.1:${(a.app.server.address() as { port: number }).port}`;
  ({ owner, members: [member] } = await people(a, 1) as { owner: Client; members: Client[] });
  modelId = (await demoModel(owner)).id;
});
afterAll(async () => { await a.close(); });

/** PUT bytes to a presigned (local storage) URL. */
const put = (url: string, body: string | Buffer, type: string) => fetch(url, { method: 'PUT', body: typeof body === 'string' ? body : new Uint8Array(body), headers: { 'content-type': type } });

describe('camera sessions', () => {
  it('are owner-only', async () => {
    expect((await member.req('GET', '/v1/camera-sessions')).body.code).toBe('owner_only');
    expect((await member.req('POST', '/v1/camera-sessions', {})).status).toBe(403);
  });

  it('create, read, list, update with revisions', async () => {
    const c = await owner.req('POST', '/v1/camera-sessions', { title: 'Walk and talk', brief: 'Mia walks to the counter', characters: [{ modelId, role: 'lead' }], durationSec: 6 });
    expect(c.status).toBe(200);
    const s = c.body;
    expect(s.id).toMatch(/^cs_[0-9a-f]{24}$/);
    expect(s).toMatchObject({ status: 'drafting', aspect: '9:16', fps: 24, revision: 1, relay: { online: false, blender: false } });
    expect(s.characters[0]).toMatchObject({ modelId, name: 'Demo model', role: 'lead', heightM: 1.68 });
    expect(s.camera).toMatchObject({ mode: 'directed', directed: { cameraSessionId: s.id, guideAssets: {}, keyframes: [] } });
    expect((await owner.req('GET', `/v1/camera-sessions/${s.id}`)).body.messages).toEqual([]);
    expect((await owner.req('GET', '/v1/camera-sessions')).body.map((x: any) => x.id)).toContain(s.id);

    const p = await owner.req('PATCH', `/v1/camera-sessions/${s.id}`, { brief: 'New brief', revision: 1 });
    expect(p.body).toMatchObject({ brief: 'New brief', revision: 2 });
    expect((await owner.req('PATCH', `/v1/camera-sessions/${s.id}`, { brief: 'x', revision: 1 })).body.code).toBe('stale_revision');
    expect((await owner.req('PATCH', `/v1/camera-sessions/${s.id}`, { fps: 500 })).status).toBe(400);
    expect((await owner.req('POST', '/v1/camera-sessions', { characters: [{ modelId: 'm_nope' }] })).status).toBe(400);
    expect((await owner.req('GET', '/v1/camera-sessions/cs_000000000000000000000000')).status).toBe(404);
  });

  it('camera path and blocking are validated and move the session to blocking', async () => {
    const s = (await owner.req('POST', '/v1/camera-sessions', { characters: [{ modelId }], durationSec: 5 })).body;
    const camera = { keyframes: [{ t: 0, position: [0, -3, 1.5], target: [0, 0, 1.5], focalMm: 35 }, { t: 5, position: [0, -2, 1.5], target: [0, 0, 1.5] }] };
    expect((await owner.req('PUT', `/v1/camera-sessions/${s.id}/path`, { camera: { keyframes: [{ t: 6, position: [0, 0, 0] }] } })).body.error).toMatch(/after the clip/);
    expect((await owner.req('PUT', `/v1/camera-sessions/${s.id}/path`, { camera: { keyframes: [{ t: 2, position: [0, 0, 0] }, { t: 1, position: [0, 0, 0] }] } })).status).toBe(400);
    expect((await owner.req('PUT', `/v1/camera-sessions/${s.id}/path`, { characters: [{ modelId: 'm_other', keyframes: [{ t: 0, position: [0, 0, 0] }] }] })).body.error).toMatch(/not in the cast/);
    const r = await owner.req('PUT', `/v1/camera-sessions/${s.id}/path`, { camera, characters: [{ modelId, keyframes: [{ t: 0, position: [-1, 0, 0], facingDeg: 90 }, { t: 4, position: [1, 0, 0], action: 'stops at the counter' }] }] });
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({ status: 'blocking', cameraPath: camera, blocking: { characters: [{ modelId }] } });
    expect(r.body.camera.directed.keyframes).toHaveLength(2);
  });

  it('guide media: presigned upload straight to storage, confirm, CameraSpec points at the newest greybox', async () => {
    const s = (await owner.req('POST', '/v1/camera-sessions', {})).body;
    expect((await owner.req('POST', `/v1/camera-sessions/${s.id}/assets`, { kind: 'greybox', contentType: 'image/png' })).status).toBe(400);
    const n = await owner.req('POST', `/v1/camera-sessions/${s.id}/assets`, { kind: 'greybox', contentType: 'video/mp4', bytes: 9 });
    expect(n.body.upload).toMatchObject({ method: 'PUT', headers: { 'content-type': 'video/mp4' } });
    expect(n.body.asset).toMatchObject({ kind: 'greybox', state: 'pending', source: 'app' });
    expect(n.body.upload.url).not.toContain('muse_'); // no MUSE credential in the URL
    expect((await owner.req('POST', `/v1/camera-sessions/${s.id}/assets/${n.body.asset.id}/confirm`)).body.code).toBe('upload_missing');
    expect((await put(n.body.upload.url, 'fake-mp4!', 'video/mp4')).status).toBe(200);
    const c = await owner.req('POST', `/v1/camera-sessions/${s.id}/assets/${n.body.asset.id}/confirm`);
    expect(c.body).toMatchObject({ id: n.body.asset.id, state: 'ready', bytes: 9 });
    expect(await (await fetch(c.body.url)).text()).toBe('fake-mp4!');
    const g = (await owner.req('GET', `/v1/camera-sessions/${s.id}`)).body;
    expect(g.status).toBe('ready');
    expect(g.camera.directed.guideAssets.greybox).toBe(n.body.asset.id);

    // JSON trajectories must parse.
    const j = (await owner.req('POST', `/v1/camera-sessions/${s.id}/assets`, { kind: 'camera_json', contentType: 'application/json' })).body;
    // (Dev storage's PUT route would reject bad JSON itself, so send it as raw bytes; R2 stores whatever arrives.)
    await put(j.upload.url, '{not json', 'application/octet-stream');
    expect((await owner.req('POST', `/v1/camera-sessions/${s.id}/assets/${j.asset.id}/confirm`)).status).toBe(400);
    await put(j.upload.url, '{"frames":[]}', 'application/json');
    expect((await owner.req('POST', `/v1/camera-sessions/${s.id}/assets/${j.asset.id}/confirm`)).body.state).toBe('ready');
    expect((await owner.req('GET', `/v1/camera-sessions/${s.id}`)).body.camera.directed.trajectories.camera).toBe(j.asset.id);
    // The set blocks for the app's 3D preview (the Mac writes set.json with every greybox render).
    const sj = (await owner.req('POST', `/v1/camera-sessions/${s.id}/assets`, { kind: 'set_json', contentType: 'application/json' })).body;
    await put(sj.upload.url, '{"version":1,"objects":[]}', 'application/json');
    expect((await owner.req('POST', `/v1/camera-sessions/${s.id}/assets/${sj.asset.id}/confirm`)).body).toMatchObject({ kind: 'set_json', state: 'ready' });

    expect((await owner.req('DELETE', `/v1/camera-sessions/${s.id}/assets/${j.asset.id}`)).status).toBe(204);
    expect((await owner.req('DELETE', `/v1/camera-sessions/${s.id}`)).status).toBe(204);
    expect((await fetch(c.body.url)).status).toBe(404);
  });

  it('a Shot draft is an estimate only: no hold, no ledger row', async () => {
    const s = (await owner.req('POST', '/v1/camera-sessions', { durationSec: 5, brief: 'cosy kitchen, morning light' })).body;
    const before = (await a.ctx.db.select().from(ledger)).length;
    const d = await owner.req('POST', `/v1/camera-sessions/${s.id}/shot-draft`, {});
    // With the AI suite merged (mock mode in tests) the draft is the suite's own estimate.
    expect(d.body).toMatchObject({ state: 'draft', source: 'suite', targetModel: 'kling-v4.0', durationSec: 5, prompt: 'cosy kitchen, morning light' });
    expect(d.body.estimate.usd).toBe(1.18); // the target's price: Kling 4.0 1080p, 5 s × $0.235 (no guide video yet)
    expect(d.body.estimate.tokens).toBe(Math.ceil(d.body.estimate.usd / a.ctx.config.TOKEN_USD - 1e-9));
    expect(d.body.camera.directed.cameraSessionId).toBe(s.id);
    expect((await a.ctx.db.select().from(ledger)).length).toBe(before);
    expect((await owner.req('GET', `/v1/camera-sessions/${s.id}`)).body.shotDraft.id).toBe(d.body.id);

    // The owner pressed Generate in the app: the render job is linked back and the session follows it.
    expect((await owner.req('POST', `/v1/camera-sessions/${s.id}/shot-draft/job`, { jobId: 'j_nope' })).status).toBe(400);
    const jobId = 'j_cam_test';
    await a.ctx.db.execute((await import('drizzle-orm')).sql`insert into jobs (id, studio_id, kind, title, model_id, model_name, request, state, cost, seed, created_at) select ${jobId}, studio_id, 'h3', 'Shot', ${modelId}, 'Demo model', '{}'::jsonb, 'running', 0, 1, 0 from users where id = ${owner.id}`);
    const l = await owner.req('POST', `/v1/camera-sessions/${s.id}/shot-draft/job`, { jobId });
    expect(l.body).toMatchObject({ status: 'generating', shotDraft: { jobId } });
    await a.ctx.db.execute((await import('drizzle-orm')).sql`update jobs set state = 'done' where id = ${jobId}`);
    expect((await owner.req('GET', `/v1/camera-sessions/${s.id}`)).body.status).toBe('done');
    const empty = (await owner.req('POST', '/v1/camera-sessions', {})).body;
    expect((await owner.req('POST', `/v1/camera-sessions/${empty.id}/shot-draft/job`, { jobId })).body.code).toBe('no_draft');
  });

  it('without the AI suite the draft is priced from the target model\'s $/s (no hold either)', async () => {
    const suite = a.ctx.suite;
    (a.ctx as any).suite = undefined;
    try {
      const s = (await owner.req('POST', '/v1/camera-sessions', { durationSec: 5, brief: 'cosy kitchen, morning light' })).body;
      const before = (await a.ctx.db.select().from(ledger)).length;
      const d = await owner.req('POST', `/v1/camera-sessions/${s.id}/shot-draft`, {});
      expect(d.body).toMatchObject({ state: 'draft', source: 'camera', targetModel: 'kling-v4.0', durationSec: 5, prompt: 'cosy kitchen, morning light', estimate: { usd: 0.71, tokens: 71 } });
      expect((await a.ctx.db.select().from(ledger)).length).toBe(before);
    } finally { a.ctx.suite = suite; }
  });

  it('with the AI suite merged, the draft is the suite\'s estimate of a directed ShotRequest using the greybox', async () => {
    const s = (await owner.req('POST', '/v1/camera-sessions', { characters: [{ modelId }], durationSec: 6, brief: 'walk' })).body;
    const n = (await owner.req('POST', `/v1/camera-sessions/${s.id}/assets`, { kind: 'greybox', contentType: 'video/mp4' })).body;
    await put(n.upload.url, 'mp4', 'video/mp4');
    await owner.req('POST', `/v1/camera-sessions/${s.id}/assets/${n.asset.id}/confirm`);
    const seen: any[] = [];
    const suite = a.ctx.suite; // the real suite (restored below: app.close() waits on its runner)
    (a.ctx as any).suite = { estimate: async (_u: unknown, body: any) => { seen.push(body); return { estimate: 0.78, warnings: ['length set to 6 s'] }; } };
    try {
      const before = (await a.ctx.db.select().from(ledger)).length;
      const d = (await owner.req('POST', `/v1/camera-sessions/${s.id}/shot-draft`, {})).body;
      expect(d).toMatchObject({ source: 'suite', estimate: { usd: 0.78, tokens: 78 }, warnings: ['length set to 6 s'] });
      // Priced on its target model (workstream 1): Kling 4.0 at 1080p for the default target.
      expect(seen[0]).toMatchObject({ quality: 'cinema', engineModel: 'kling-v4', resolution: '1080p' });
      expect(seen[0]).toMatchObject({ prompt: 'walk', duration: 6, aspectRatio: '9:16', modelId, camera: { mode: 'directed', guide: { use: 'blocking', cameraSessionId: s.id } } });
      const key = seen[0].camera.guide.video.key;
      expect(key).toMatch(new RegExp(`^cam/${s.id}/${n.asset.id}\\.mp4$`));
      expect(d.request).toEqual(seen[0]);
      expect(seen[0].camera.guide.keyframes).toBeUndefined(); // no stills in this session
      // The suite only takes references it knows: the guide is a studio upload.
      const ups = await a.ctx.db.execute((await import('drizzle-orm')).sql`select state from uploads where storage_key = ${key}`).then((r: any) => r.rows ?? r);
      expect(ups).toEqual([{ state: 'ready' }]);
      expect((await a.ctx.db.select().from(ledger)).length).toBe(before);
    } finally { a.ctx.suite = suite; }
  });

  it('live events reach the owner only; notes join the transcript', async () => {
    const o = await sse(base, owner.token), m = await sse(base, member.token);
    const s = (await owner.req('POST', '/v1/camera-sessions', { title: 'Live' })).body;
    const note = await owner.req('POST', `/v1/camera-sessions/${s.id}/messages`, { text: 'Keep her face to camera at 3 s' });
    expect(note.body).toMatchObject({ role: 'user', source: 'app', text: 'Keep her face to camera at 3 s' });
    await until(() => o.events.some(e => e.type === 'camera' && e.op === 'message' && e.sessionId === s.id));
    expect(o.events.find(e => e.type === 'camera' && e.op === 'upsert')!.session.messages).toBeUndefined();
    expect(m.events.filter(e => e.type === 'camera')).toEqual([]);
    expect((await owner.req('GET', `/v1/camera-sessions/${s.id}/messages`)).body.map((x: any) => x.text)).toEqual(['Keep her face to camera at 3 s']);
    await o.stop(); await m.stop();
  });
});

describe('Blender relay', () => {
  it('heartbeat, claim once, result; offline means an immediate error result', async () => {
    const { relay } = cameraOf(a.ctx);
    const u = { id: owner.id, studioId: '', role: 'owner' as const, email: '', studioName: '', sessionId: null };
    expect(await relay.call(u, 'cs_x', 'blender_status', {})).toMatchObject({ ok: false, error: expect.stringMatching(/Mac app is not connected/) });
    const hb = await owner.req('POST', '/v1/blender/relay', { online: true, blender: { connected: true, addonVersion: '1.8' } });
    expect(hb.body).toEqual({ ok: true, pending: [] });
    expect(relay.status(owner.id)).toMatchObject({ online: true, blender: true });
    const p = relay.call(u, 'cs_x', 'blender_status', {});
    const [call] = (await owner.req('GET', '/v1/blender/calls')).body;
    expect(call).toMatchObject({ sessionId: 'cs_x', tool: 'blender_status', outDir: 'CameraSessions/cs_x' });
    const claimed = (await owner.req('POST', `/v1/blender/calls/${call.id}/claim`)).body;
    expect(claimed.id).toBe(call.id);
    expect(claimed.expiresAt).toBeGreaterThanOrEqual(call.expiresAt); // a claimed call gets a fresh deadline
    expect((await owner.req('POST', `/v1/blender/calls/${call.id}/claim`)).body.code).toBe('already_claimed');
    expect((await member.req('POST', `/v1/blender/calls/${call.id}/result`, { ok: true })).status).toBe(403);
    expect((await owner.req('POST', `/v1/blender/calls/${call.id}/result`, { ok: true, result: { connected: true } })).status).toBe(204);
    expect(await p).toEqual({ ok: true, result: { connected: true } });
    expect((await owner.req('POST', `/v1/blender/calls/${call.id}/result`, { ok: true })).body.code).toBe('call_expired');
    await owner.req('POST', '/v1/blender/relay', { online: false });
    expect(relay.status(owner.id).online).toBe(false);
  });
});

// ---------------------------------------------------------------- chat with a fake Claude client
type Block = Record<string, unknown>;
function fakeClaude(script: ((params: any) => Block[])[]) {
  const calls: any[] = [];
  const client: DirectorClient = {
    beta: { messages: { stream(params) {
      const snapshot = JSON.parse(JSON.stringify(params));
      calls.push(snapshot);
      const step = script[calls.length - 1];
      let onText: ((d: string) => void) | null = null;
      return {
        on(_e: 'text', cb: (d: string) => void) { onText = cb; return this; },
        async finalMessage() {
          if (!step) throw new Error('script ran out');
          const content = step(snapshot);
          for (const b of content) if (b.type === 'text') onText?.(String(b.text));
          const stop_reason = content.some(b => b.type === 'tool_use') ? 'tool_use' : 'end_turn';
          return { id: `msg_${calls.length}`, type: 'message', role: 'assistant', model: 'fake', content, stop_reason, stop_sequence: null,
            usage: { input_tokens: 100, output_tokens: 20, cache_read_input_tokens: 80, cache_creation_input_tokens: 0 } } as any;
        },
      };
    } } },
  };
  return { client, calls };
}
const chatEvents = (body: string) => body.split('\n\n').filter(l => l.startsWith('data: ')).map(l => JSON.parse(l.slice(6)));

describe('Direct with Claude (mocked Claude)', () => {
  it('no key: director_unavailable before streaming', async () => {
    const s = (await owner.req('POST', '/v1/camera-sessions', {})).body;
    cameraOf(a.ctx).director.setClient(null);
    expect((await owner.req('POST', `/v1/camera-sessions/${s.id}/chat`, { message: 'hi' })).body.code).toBe('director_unavailable');
    expect((await member.req('POST', `/v1/camera-sessions/${s.id}/chat`, { message: 'hi' })).status).toBe(403);
  });

  it('runs MUSE tools in-process, relays Blender tools to the Mac and shows screenshots to Claude', async () => {
    const s = (await owner.req('POST', '/v1/camera-sessions', { characters: [{ modelId }], durationSec: 6 })).body;
    const { client, calls } = fakeClaude([
      () => [{ type: 'text', text: 'Blocking it.' }, { type: 'tool_use', id: 'tu_1', name: 'set_camera_path', input: { camera: { keyframes: [{ t: 0, position: [0, -3, 1.5] }] } } },
        { type: 'tool_use', id: 'tu_2', name: 'blender_screenshot', input: { maxSize: 512 } }],
      () => [{ type: 'tool_use', id: 'tu_3', name: 'create_shot_draft', input: { prompt: 'sunlit cafe' } }],
      () => [{ type: 'text', text: 'Done: camera pushes in; draft ready for you to Generate.' }],
    ]);
    cameraOf(a.ctx).director.setClient(client);
    await owner.req('POST', '/v1/blender/relay', { online: true, blender: { connected: true } });

    // The "Mac": waits for the Blender call, uploads a screenshot as a preview asset, posts the result.
    const mac = (async () => {
      const call = await until(async () => (await owner.req('GET', '/v1/blender/calls')).body[0]);
      expect(call).toMatchObject({ tool: 'blender_screenshot', args: { maxSize: 512 }, sessionId: s.id });
      await owner.req('POST', `/v1/blender/calls/${call.id}/claim`);
      const up = (await owner.req('POST', `/v1/camera-sessions/${s.id}/assets?source=relay`, { kind: 'preview', contentType: 'image/png' })).body;
      expect(up.asset.source).toBe('relay');
      await put(up.upload.url, Buffer.from('PNGDATA'), 'image/png');
      await owner.req('POST', `/v1/camera-sessions/${s.id}/assets/${up.asset.id}/confirm`);
      await owner.req('POST', `/v1/blender/calls/${call.id}/result`, { ok: true, result: { width: 512 }, assetIds: [up.asset.id] });
    })();
    const r = await owner.req('POST', `/v1/camera-sessions/${s.id}/chat`, { message: 'Push in slowly on Mia' });
    await mac;
    const ev = chatEvents(r.body);
    expect(ev.filter(e => e.type === 'text').map(e => e.delta).join('')).toContain('Blocking it.');
    expect(ev.filter(e => e.type === 'tool' && e.status === 'done').map(e => e.name)).toEqual(['set_camera_path', 'blender_screenshot', 'create_shot_draft']);
    expect(ev.some(e => e.type === 'waiting')).toBe(true);
    expect(ev.at(-1)).toMatchObject({ type: 'done', stopReason: 'end_turn', usage: { inputTokens: 300, outputTokens: 60, cacheReadTokens: 240 } });

    // Request shape: model, effort, caching, fallbacks, tools without sessionId, frozen system prompt.
    const p0 = calls[0];
    expect(p0).toMatchObject({ model: 'claude-opus-5-5', output_config: { effort: 'high' }, cache_control: { type: 'ephemeral' }, fallbacks: 'default', betas: ['server-side-fallback-2026-07-01'] });
    expect(p0.system[0].cache_control).toEqual({ type: 'ephemeral' });
    expect(p0.tools.map((t: any) => t.name)).toContain('blender_render_guides');
    expect(p0.tools.map((t: any) => t.name)).not.toContain('create_camera_session');
    expect(JSON.stringify(p0.tools.find((t: any) => t.name === 'set_camera_path').input_schema)).not.toContain('sessionId');
    expect(p0.messages[0].content[0].text).toContain('Push in slowly on Mia');
    expect(calls[1].system).toEqual(p0.system);
    // The screenshot came back to Claude as an image; tool results are in one user message after the assistant turn.
    const results = calls[1].messages.at(-1).content;
    expect(results.map((b: any) => b.tool_use_id)).toEqual(['tu_1', 'tu_2']);
    expect(results[1].content.find((b: any) => b.type === 'image').source).toMatchObject({ type: 'base64', media_type: 'image/png', data: Buffer.from('PNGDATA').toString('base64') });

    const g = (await owner.req('GET', `/v1/camera-sessions/${s.id}`)).body;
    expect(g.cameraPath.keyframes).toHaveLength(1);
    expect(g.shotDraft).toMatchObject({ prompt: 'sunlit cafe', state: 'draft' });
    expect(g.messages.map((m: any) => m.role)).toEqual(['user', 'tool', 'tool', 'tool', 'assistant']);
    expect(g.messages.at(-1).text).toBe('Done: camera pushes in; draft ready for you to Generate.');

    // The next turn appends to the same conversation (append-only, for caching).
    const { client: c2, calls: calls2 } = fakeClaude([() => [{ type: 'text', text: 'Sure.' }]]);
    cameraOf(a.ctx).director.setClient(c2);
    await owner.req('POST', `/v1/camera-sessions/${s.id}/chat`, { message: 'Thanks' });
    expect(calls2[0].messages.slice(0, calls[2].messages.length)).toEqual(calls[2].messages);
    await owner.req('POST', '/v1/blender/relay', { online: false });
  });

  it('bad tool arguments and an offline Mac come back to Claude as tool errors', async () => {
    const s = (await owner.req('POST', '/v1/camera-sessions', {})).body;
    const { client, calls } = fakeClaude([
      () => [{ type: 'tool_use', id: 'a', name: 'blender_set_camera', input: { keyframes: [] } },
        { type: 'tool_use', id: 'b', name: 'blender_status', input: {} },
        { type: 'tool_use', id: 'c', name: 'blender_execute_python', input: { code: 'import os' } }],
      () => [{ type: 'text', text: 'Blender is offline.' }],
    ]);
    cameraOf(a.ctx).director.setClient(client);
    const ev = chatEvents((await owner.req('POST', `/v1/camera-sessions/${s.id}/chat`, { message: 'go' })).body);
    expect(ev.filter(e => e.type === 'tool' && e.status === 'error').map(e => e.name)).toEqual(['blender_set_camera', 'blender_status', 'blender_execute_python']);
    const res = calls[1].messages.at(-1).content;
    expect(res.every((r: any) => r.is_error)).toBe(true);
    expect(res[1].content).toMatch(/not connected/);
    expect(res[2].content).toMatch(/Unknown tool/);
  });

  it('a crashed turn is repaired by appending results, and one turn at a time', async () => {
    const s = (await owner.req('POST', '/v1/camera-sessions', {})).body;
    const { client } = fakeClaude([() => [{ type: 'tool_use', id: 'x1', name: 'list_presets', input: {} }]]); // then the script runs out → error
    cameraOf(a.ctx).director.setClient(client);
    const ev = chatEvents((await owner.req('POST', `/v1/camera-sessions/${s.id}/chat`, { message: 'go' })).body);
    expect(ev.at(-1)).toMatchObject({ type: 'error', code: 'director_failed' });
    const { client: c2, calls } = fakeClaude([() => [{ type: 'text', text: 'ok' }]]);
    cameraOf(a.ctx).director.setClient(c2);
    await owner.req('POST', `/v1/camera-sessions/${s.id}/chat`, { message: 'again' });
    const roles = calls[0].messages.map((m: any) => m.role);
    expect(roles).toEqual(['user', 'assistant', 'user', 'user']);
    expect(calls[0].messages[2].content[0]).toMatchObject({ type: 'tool_result', tool_use_id: 'x1' });

    // Busy: a second turn while one runs.
    let release!: () => void;
    const gate = new Promise<void>(r => { release = r; });
    cameraOf(a.ctx).director.setClient({ beta: { messages: { stream: () => ({ on() { return this; }, finalMessage: async () => { await gate; return { content: [{ type: 'text', text: 'slow' }], stop_reason: 'end_turn', usage: {} } as any; } }) } } });
    const first = owner.req('POST', `/v1/camera-sessions/${s.id}/chat`, { message: 'slow one' });
    await new Promise(r => setTimeout(r, 50));
    expect((await owner.req('POST', `/v1/camera-sessions/${s.id}/chat`, { message: 'second' })).body.code).toBe('chat_busy');
    release();
    await first;
  });
});
