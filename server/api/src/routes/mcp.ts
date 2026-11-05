// The MUSE remote MCP endpoint (Streamable HTTP) and its Protected Resource Metadata (RFC 9728).
// Auth: an owner personal access token in the Authorization header (never in the query string).
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import type { Ctx } from '../ctx.js';
import type { CameraService } from '../camera/service.js';
import { authenticatePat } from '../mcp/tokens.js';
import { handleRpc, PROTOCOL_VERSIONS, rpcError } from '../mcp/server.js';

export async function registerMcpRoutes(app: FastifyInstance, ctx: Ctx, camera: CameraService) {
  if (!ctx.config.MCP_ENABLED) return;
  const metadataUrl = () => `${ctx.publicBase()}/.well-known/oauth-protected-resource`;

  app.get('/.well-known/oauth-protected-resource', { config: { public: true } }, async () => ({
    resource: `${ctx.publicBase()}/mcp`,
    // OAuth 2.1 is the follow-up (plans/mcp-bridge.md); today the owner pastes a personal access token.
    authorization_servers: [],
    bearer_methods_supported: ['header'],
    resource_name: 'MUSE',
    resource_documentation: 'https://github.com/richard4801/claude-template/blob/main/plans/mcp-bridge.md',
  }));

  const unauthorized = (reply: FastifyReply, message: string) => reply.status(401)
    .header('www-authenticate', `Bearer resource_metadata="${metadataUrl()}"`)
    .send(rpcError(null, -32001, message));

  const handler = async (req: FastifyRequest, reply: FastifyReply) => {
    // DNS-rebinding protection: browsers send Origin; only our own origin may call.
    const origin = req.headers.origin;
    if (origin && origin !== new URL(ctx.publicBase()).origin) return reply.status(403).send(rpcError(null, -32000, 'Origin not allowed'));
    const pv = req.headers['mcp-protocol-version'];
    if (typeof pv === 'string' && !PROTOCOL_VERSIONS.includes(pv)) return reply.status(400).send(rpcError(null, -32000, `Unsupported MCP-Protocol-Version ${pv}`));
    const h = req.headers.authorization;
    const user = await authenticatePat(ctx, h?.startsWith('Bearer ') ? h.slice(7).trim() : null);
    if (!user) return unauthorized(reply, 'A MUSE owner access token is required (MUSE → Settings → Claude & MCP)');
    const res = await handleRpc(ctx, camera, user, req.body);
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
