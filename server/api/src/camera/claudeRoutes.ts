// Routes for Claude chat threads (plans/api.md "Claude on the owner's plan"). Owner only. Registered by routes/camera.ts.
import type { FastifyInstance } from 'fastify';
import type { Ctx } from '../ctx.js';
import { ApiError } from '../errors.js';
import type { ChatEvent, Director } from './director.js';
import { ClaudeService } from './claude.js';
import type { CameraService } from './service.js';

type P = { Params: { id: string } };

export async function registerClaudeRoutes(app: FastifyInstance, ctx: Ctx, camera: CameraService, director: Director) {
  const claude = new ClaudeService(ctx, camera);
  app.addHook('onClose', async () => claude.close());
  const owner = { config: { owner: true } };

  app.get('/v1/claude/status', owner, async req => claude.status(req.user));
  app.patch('/v1/claude/settings', owner, async req => claude.setSettings(req.user, req.body));
  app.post('/v1/claude/mac/heartbeat', owner, async req => claude.heartbeat(req.user, req.body));
  app.post('/v1/claude/threads', owner, async req => claude.openThread(req.user, req.body));
  app.get<P>('/v1/claude/threads/:id', owner, async req => claude.get(req.user, req.params.id));
  app.patch<P>('/v1/claude/threads/:id', owner, async req => claude.patchThread(req.user, req.params.id, req.body));
  app.post<P>('/v1/claude/threads/:id/messages', owner, async (req, reply) => {
    try {
      return reply.status(202).send(await claude.ask(req.user, req.params.id, req.body));
    } catch (e) {
      const extra = (e as { extra?: Record<string, unknown> }).extra;
      if (e instanceof ApiError && extra) return reply.status(e.status).send({ error: e.message, code: e.code, ...extra });
      throw e;
    }
  });
  app.get('/v1/claude/turns', owner, async req => claude.pending(req.user));
  app.post<P>('/v1/claude/turns/:id/claim', owner, async req => claude.claim(req.user, req.params.id));
  app.post<P>('/v1/claude/turns/:id/stop', owner, async req => claude.stop(req.user, req.params.id));
  app.post<P>('/v1/claude/threads/:id/events', { ...owner, bodyLimit: 4 * 1024 * 1024 }, async req => claude.events(req.user, req.params.id, req.body));

  // The opt-in API-key fallback (billed per use): the camera chat's director, mirrored into the thread.
  app.post<P>('/v1/claude/threads/:id/api-turn', owner, async (req, reply) => {
    const t = await claude.thread(req.user, req.params.id);
    if (!(await claude.fallbackAllowed(req.user))) throw new ApiError(409, 'fallback_off', 'The API fallback is off · turn it on in Settings → Connections');
    if (t.contextKind !== 'camera') throw new ApiError(409, 'fallback_off', 'The API fallback works in Camera stage for now');
    const message = (req.body as { text?: unknown } | undefined)?.text;
    await director.precheck(req.user, t.contextId, message);
    reply.hijack();
    const res = reply.raw;
    req.raw.socket?.setNoDelay?.(true);
    res.writeHead(200, { 'content-type': 'text/event-stream; charset=utf-8', 'cache-control': 'no-cache, no-store, no-transform', connection: 'keep-alive', 'x-accel-buffering': 'no' });
    let open = true, text = '';
    req.raw.on('close', () => { open = false; });
    await claude.mirrorFallback(req.user, t.id, 'user', String(message));
    await director.run(req.user, t.contextId, String(message), (e: ChatEvent) => {
      if (e.type === 'text') text += e.delta;
      if (e.type === 'tool') text = ''; // keep only the final answer
      if (open) res.write(`data: ${JSON.stringify(e)}\n\n`);
    });
    await claude.mirrorFallback(req.user, t.id, 'assistant', text);
    if (open) res.end();
  });
  return claude;
}
