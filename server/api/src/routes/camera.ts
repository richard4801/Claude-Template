// Camera sessions, the Direct with Claude chat, MCP tokens and the Blender relay (plans/api.md "MCP & camera sessions").
// Everything here is owner-only. app.ts registers this with one line; it also registers the MCP server (routes/mcp.ts).
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { Ctx } from '../ctx.js';
import { ApiError } from '../errors.js';
import { Director, type ChatEvent } from '../camera/director.js';
import { BlenderRelayHub } from '../camera/relay.js';
import { CameraService } from '../camera/service.js';
import { parse } from '../camera/validate.js';
import { createToken, listTokens, revokeToken } from '../mcp/tokens.js';
import { listGrants, resourceOf, revokeGrantOf, sessionToken } from '../mcp/oauth.js';
import { registerMcpRoutes } from './mcp.js';

export type CameraModule = { service: CameraService; relay: BlenderRelayHub; director: Director };
const modules = new WeakMap<Ctx, CameraModule>();
/** The camera services of an app (tests use it to inject a fake Claude client). */
export const cameraOf = (ctx: Ctx) => modules.get(ctx)!;

type P = { Params: { id: string } };
type PA = { Params: { id: string; assetId: string } };

export async function registerCameraRoutes(app: FastifyInstance, ctx: Ctx) {
  const relay = new BlenderRelayHub(ctx);
  const service = new CameraService(ctx, relay);
  const director = new Director(ctx, service, relay);
  modules.set(ctx, { service, relay, director });
  service.chatBusy = id => director.isBusy(id);
  app.addHook('onClose', async () => relay.close());
  const owner = { config: { owner: true } };

  // ------------------------------------------------------------------ camera sessions
  app.post('/v1/camera-sessions', owner, async req => service.create(req.user, req.body));
  app.get('/v1/camera-sessions', owner, async req => {
    const q = (req.query ?? {}) as { status?: string; limit?: string };
    return service.list(req.user, { status: q.status || undefined, limit: Number(q.limit) || undefined });
  });
  app.get<P>('/v1/camera-sessions/:id', owner, async req => service.get(req.user, req.params.id));
  app.patch<P>('/v1/camera-sessions/:id', owner, async req => service.patch(req.user, req.params.id, req.body));
  app.delete<P>('/v1/camera-sessions/:id', owner, async (req, reply) => { await service.remove(req.user, req.params.id); return reply.status(204).send(); });
  app.get<P>('/v1/camera-sessions/:id/messages', owner, async req => {
    const q = (req.query ?? {}) as { before?: string; limit?: string };
    return service.messages(req.user, req.params.id, { before: Number(q.before) || undefined, limit: Number(q.limit) || undefined });
  });
  app.post<P>('/v1/camera-sessions/:id/messages', owner, async req => service.note(req.user, req.params.id, req.body, 'app'));
  // The Mac's Blender relay marks its uploads with ?source=relay.
  app.post<P>('/v1/camera-sessions/:id/assets', owner, async req =>
    service.newAsset(req.user, req.params.id, req.body, (req.query as { source?: string })?.source === 'relay' ? 'relay' : 'app'));
  app.post<PA>('/v1/camera-sessions/:id/assets/:assetId/confirm', owner, async req => service.confirmAsset(req.user, req.params.id, req.params.assetId));
  app.delete<PA>('/v1/camera-sessions/:id/assets/:assetId', owner, async (req, reply) => {
    await service.removeAsset(req.user, req.params.id, req.params.assetId);
    return reply.status(204).send();
  });
  app.put<P>('/v1/camera-sessions/:id/path', { ...owner, bodyLimit: 2 * 1024 * 1024 }, async req => service.setPath(req.user, req.params.id, req.body));
  app.post<P>('/v1/camera-sessions/:id/shot-draft', owner, async req => service.shotDraft(req.user, req.params.id, req.body));
  app.post<P>('/v1/camera-sessions/:id/shot-draft/job', owner, async req => service.linkJob(req.user, req.params.id, req.body));

  // ------------------------------------------------------------------ Direct with Claude (streams ChatEvents as SSE)
  app.post<P>('/v1/camera-sessions/:id/chat', owner, async (req, reply) => {
    const message = (req.body as { message?: unknown } | undefined)?.message;
    await director.precheck(req.user, req.params.id, message);
    reply.hijack();
    const res = reply.raw;
    req.raw.socket?.setNoDelay?.(true);
    res.writeHead(200, { 'content-type': 'text/event-stream; charset=utf-8', 'cache-control': 'no-cache, no-store, no-transform', connection: 'keep-alive', 'x-accel-buffering': 'no' });
    let open = true;
    req.raw.on('close', () => { open = false; });
    const send = (e: ChatEvent) => { if (open) res.write(`data: ${JSON.stringify(e)}\n\n`); };
    const ka = setInterval(() => { if (open) res.write(': keep-alive\n\n'); }, 10_000);
    // The turn finishes even if the app goes away; the transcript and camera events carry the result.
    await director.run(req.user, req.params.id, String(message), send);
    clearInterval(ka);
    if (open) res.end();
  });

  // ------------------------------------------------------------------ MCP personal access tokens
  app.get('/v1/mcp/tokens', owner, async req => listTokens(ctx, req.user));
  app.post('/v1/mcp/tokens', owner, async req => createToken(ctx, req.user, req.body));
  app.delete<P>('/v1/mcp/tokens/:id', owner, async (req, reply) => { await revokeToken(ctx, req.user, req.params.id); return reply.status(204).send(); });
  // OAuth connections (claude.ai connector, Claude Code) and the Mac app's own short-lived token for its local Claude Code.
  app.get('/v1/mcp/grants', owner, async req => listGrants(ctx, req.user));
  app.delete<P>('/v1/mcp/grants/:id', owner, async (req, reply) => { await revokeGrantOf(ctx, req.user, req.params.id); return reply.status(204).send(); });
  app.post('/v1/mcp/session-token', owner, async req => {
    const b = parse(z.object({ ttlMinutes: z.number().int().min(5).max(720).optional() }).strict(), req.body ?? {});
    const t = await sessionToken(ctx, req.user, b.ttlMinutes ?? 240);
    return { token: t.access_token, expiresAt: t.expiresAt, mcpUrl: resourceOf(ctx) };
  });

  // ------------------------------------------------------------------ Blender relay (the owner's Mac app)
  app.post('/v1/blender/relay', owner, async req => relay.heartbeat(req.user, parse(z.object({
    online: z.boolean(), blender: z.object({ connected: z.boolean(), addonVersion: z.string().max(40).optional(), protocol: z.union([z.string().max(20), z.number()]).optional() }).optional(),
  }), req.body)));
  app.get('/v1/blender/calls', owner, async req => relay.pending(req.user));

  // ------------------------------------------------------------------ Settings → Connections (owner)
  app.get('/v1/connections', owner, async req => ({
    relay: relay.status(req.user.id),
    claudeApp: { lastSeenAt: (await service.claudeAppSeenAt(req.user.id)) ?? undefined, tokens: (await listTokens(ctx, req.user)).length },
    mcpUrl: `${ctx.publicBase()}/mcp`,
    inAppChat: !!ctx.config.ANTHROPIC_API_KEY,
    docsUrl: 'https://github.com/richard4801/claude-template/blob/main/plans/mcp-bridge.md',
  }));
  app.post<P>('/v1/blender/calls/:id/claim', owner, async req => relay.claim(req.user, req.params.id));
  app.post<P>('/v1/blender/calls/:id/result', { ...owner, bodyLimit: 512 * 1024 }, async (req, reply) => {
    const b = parse(z.object({ ok: z.boolean(), result: z.unknown().optional(), error: z.string().max(2000).optional(), assetIds: z.array(z.string().max(40)).max(20).optional() }), req.body);
    if (b.result !== undefined && JSON.stringify(b.result).length > 256 * 1024) throw new ApiError(400, 'bad_request', 'result: at most 256 KB');
    relay.result(req.user, req.params.id, b);
    return reply.status(204).send();
  });

  await registerMcpRoutes(app, ctx, service);
}
