// The MUSE remote MCP endpoint (Streamable HTTP) and its Protected Resource Metadata (RFC 9728).
// Auth: an owner personal access token in the Authorization header (never in the query string).
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import type { Ctx } from '../ctx.js';
import type { CameraService } from '../camera/service.js';
import { authenticatePat } from '../mcp/tokens.js';
import { authenticateAccessToken, registerOAuthRoutes, resourceOf, SCOPES } from '../mcp/oauth.js';
import { handleRpc, PROTOCOL_VERSIONS, rpcError } from '../mcp/server.js';

export async function registerMcpRoutes(app: FastifyInstance, ctx: Ctx, camera: CameraService) {
  if (!ctx.config.MCP_ENABLED) return;
  await registerOAuthRoutes(app, ctx);
  const metadataUrl = () => `${ctx.publicBase()}/.well-known/oauth-protected-resource`;

  app.get('/.well-known/oauth-protected-resource', { config: { public: true } }, async () => ({
    resource: resourceOf(ctx),
    authorization_servers: [ctx.publicBase()],
    scopes_supported: [...SCOPES],
    bearer_methods_supported: ['header'],
    resource_name: 'MUSE',
    resource_documentation: 'https://github.com/richard4801/claude-template/blob/main/plans/mcp-bridge.md',
  }));

  const unauthorized = (reply: FastifyReply, message: string) => reply.status(401)
    .header('www-authenticate', `Bearer resource_metadata="${metadataUrl()}", scope="${SCOPES.join(' ')}"`)
    .send(rpcError(null, -32001, message));

  const handler = async (req: FastifyRequest, reply: FastifyReply) => {
    // DNS-rebinding protection: browsers send Origin; only our own origin may call.
    const origin = req.headers.origin;
    if (origin && origin !== new URL(ctx.publicBase()).origin) return reply.status(403).send(rpcError(null, -32000, 'Origin not allowed'));
    const pv = req.headers['mcp-protocol-version'];
    if (typeof pv === 'string' && !PROTOCOL_VERSIONS.includes(pv)) return reply.status(400).send(rpcError(null, -32000, `Unsupported MCP-Protocol-Version ${pv}`));
    const h = req.headers.authorization;
    const token = h?.startsWith('Bearer ') ? h.slice(7).trim() : '';
    // Personal access tokens have every scope; OAuth tokens only theirs, and only for this audience.
    const pat = await authenticatePat(ctx, token);
    const oauth = pat ? null : await authenticateAccessToken(ctx, token, resourceOf(ctx));
    const user = pat ?? oauth?.user;
    if (!user) return unauthorized(reply, 'Connect with your MUSE owner account (OAuth) or a MUSE access token (Settings → Connections)');
    const res = await handleRpc(ctx, camera, user, req.body, oauth?.scopes);
    if (!res) return reply.status(202).send();
    return reply.header('content-type', 'application/json').send(res);
  };

  const limit = { rateLimit: { max: 240, timeWindow: '1 minute' } };
  app.post('/mcp', { config: { public: true, ...limit }, bodyLimit: 2 * 1024 * 1024 }, handler);
  // Stateless server: no server-initiated stream and no session to end.
  const notAllowed = async (_req: FastifyRequest, reply: FastifyReply) => reply.status(405).header('allow', 'POST').send(rpcError(null, -32000, 'Use POST'));
  app.get('/mcp', { config: { public: true } }, notAllowed);
  app.delete('/mcp', { config: { public: true } }, notAllowed);
}
