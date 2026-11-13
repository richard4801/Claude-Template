// Files on the person's own Mac (owner, 2026-11-11): Claude Code in the one-Claude panel may read, write and run commands
// on the Mac, but every call asks the person first. Claude Code is started with
// `--permission-prompt-tool mcp__muse__permission_prompt`: each file or command call it would make arrives here, the person's
// Mac shows an approval card (it also applies their "always allowed" folders), and the answer goes back to Claude Code as
// one text block `{"behavior":"allow"}` or `{"behavior":"deny","message":…}`. Nothing is approved here: the server only
// refuses credential files outright and passes the question on. In memory, like the Blender relay (one API instance).
import type { AuthUser, Ctx } from '../ctx.js';
import { ApiError, badRequest } from '../errors.js';
import { uid } from '../lib/util.js';

export type PermissionAsk = { id: string; toolName: string; input: Record<string, unknown>; toolUseId?: string; createdAt: number; expiresAt: number };
type Pending = { ask: PermissionAsk; userId: string; resolve: (text: string) => void; timer: NodeJS.Timeout; upload?: boolean };
export type UploadResult = { uploadId: string; kind: 'image' | 'clip' | 'audio'; url?: string; name?: string; durationSec?: number };

/** An unanswered card ends the call after this long (Claude Code's own wait is raised past it on the Mac). */
export const PERMISSION_WAIT_MS = 60 * 60 * 1000;

/** Keys, passwords and tokens: never readable, even when the person would approve (the Mac checks the same list). */
const SECRET_DIRS = /(^|\/)(\.ssh|\.aws|\.gnupg|\.kube|\.docker|\.claude|\.password-store|\.config\/gh|Library\/Keychains|Keychains)(\/|$)/i;
const SECRET_FILES = /(^|\/)(\.env(\.[^/]*)?|\.netrc|\.npmrc|\.pypirc|\.git-credentials|credentials(\.json)?|id_(rsa|dsa|ecdsa|ed25519)[^/]*|[^/]*\.(pem|key|p12|pfx|keychain|keychain-db)|\.mcp-[^/]*\.json)$/i;
export const isSecretPath = (p: string) => SECRET_DIRS.test(p) || SECRET_FILES.test(p.replace(/\/+$/, ''));
/** Any path-like word in a command that names a secret. */
export const mentionsSecret = (s: string) => s.split(/[\s"'`=;|&<>()]+/).some(w => w.length > 0 && isSecretPath(w));

export const CREDENTIAL_REFUSAL = 'MUSE never lets Claude read or change keys, passwords or tokens (.env, SSH keys, keychains, credential files), even with your approval.';

/** The credential check on a call's input: the paths it names and, for a command, any secret it mentions. */
export function secretIn(toolName: string, input: Record<string, unknown>): boolean {
  for (const k of ['file_path', 'path', 'notebook_path']) if (typeof input[k] === 'string' && isSecretPath(input[k] as string)) return true;
  if (typeof input.pattern === 'string' && /\.env\b|id_rsa|id_ed25519|\.pem\b|\.ssh|keychain/i.test(input.pattern) && toolName === 'Glob') return true;
  if (toolName === 'Bash' && typeof input.command === 'string' && mentionsSecret(input.command)) return true;
  return false;
}

export const allowText = () => JSON.stringify({ behavior: 'allow' });
export const denyText = (message: string) => JSON.stringify({ behavior: 'deny', message });

/** Old Mac apps can't answer: the tools say so at once instead of waiting. */
export const NEEDS_NEW_APP = 'This needs the newer MUSE app on your Mac (update MUSE, then ask again).';
/** How long a Mac's "I can answer file questions" (X-Muse-Caps: files) counts after its last request. */
export const CAPS_TTL_MS = 5 * 60 * 1000;

export class PermissionHub {
  private calls = new Map<string, Pending>();
  private caps = new Map<string, number>();
  constructor(private ctx: Ctx) {}

  /** A request from the person's Mac app that can show file cards (it sends X-Muse-Caps: files). */
  sawApp(userId: string) { this.caps.set(userId, Date.now()); }
  canAsk(userId: string) { const at = this.caps.get(userId); return at !== undefined && Date.now() - at < CAPS_TTL_MS; }

  /** Claude Code's question → the person's devices; resolves with the text block Claude Code reads. */
  ask(u: AuthUser, toolName: string, input: Record<string, unknown>, toolUseId?: string): Promise<string> {
    if (secretIn(toolName, input)) return Promise.resolve(denyText(CREDENTIAL_REFUSAL));
    if (!this.canAsk(u.id)) return Promise.resolve(denyText(NEEDS_NEW_APP));
    const now = Date.now();
    const ask: PermissionAsk = { id: uid('perm'), toolName, input, ...(toolUseId ? { toolUseId } : {}), createdAt: now, expiresAt: now + PERMISSION_WAIT_MS };
    return new Promise(resolve => {
      const timer = setTimeout(() => this.end(ask.id, denyText('No answer from the person, so this was not done.')), PERMISSION_WAIT_MS);
      this.calls.set(ask.id, { ask, userId: u.id, resolve, timer });
      void this.ctx.hub.emitTo(u.id, { type: 'claude', op: 'permission', ask });
    });
  }

  /**
   * upload_local_file: the person's Mac asks them (the same card, "Upload to MUSE"), then uploads the file the usual way
   * (images: presign, PUT, confirm, so the server strips their metadata; videos as clips) and posts the upload back.
   * Resolves with `{uploadId, kind, url}` or `{error}`.
   */
  upload(u: AuthUser, path: string, purpose: string): Promise<string> {
    if (isSecretPath(path)) return Promise.resolve(JSON.stringify({ error: CREDENTIAL_REFUSAL }));
    if (!this.canAsk(u.id)) return Promise.resolve(JSON.stringify({ error: NEEDS_NEW_APP }));
    const now = Date.now();
    const ask: PermissionAsk = { id: uid('perm'), toolName: 'Upload', input: { file_path: path, purpose }, createdAt: now, expiresAt: now + PERMISSION_WAIT_MS };
    return new Promise(resolve => {
      const timer = setTimeout(() => this.end(ask.id, JSON.stringify({ error: 'No answer from the person, so nothing was uploaded.' })), PERMISSION_WAIT_MS);
      this.calls.set(ask.id, { ask, userId: u.id, resolve, timer, upload: true });
      void this.ctx.hub.emitTo(u.id, { type: 'claude', op: 'permission', ask });
    });
  }

  pending(u: AuthUser) { return [...this.calls.values()].filter(p => p.userId === u.id).map(p => p.ask); }

  answer(u: AuthUser, id: string, b: { allow: boolean; message?: string; result?: UploadResult }) {
    const p = this.calls.get(id);
    if (!p || p.userId !== u.id) throw new ApiError(410, 'permission_expired', 'That question has ended');
    if (b.allow && secretIn(p.ask.toolName, p.ask.input)) throw badRequest(CREDENTIAL_REFUSAL);
    if (p.upload) {
      if (b.allow && !b.result) throw badRequest('result: the upload (uploadId, kind)');
      this.end(id, JSON.stringify(b.allow ? b.result : { error: b.message?.trim() || 'The person said no, so nothing was uploaded.' }));
      return;
    }
    this.end(id, b.allow ? allowText() : denyText(b.message?.trim() || 'The person said no.'));
  }

  private end(id: string, text: string) {
    const p = this.calls.get(id);
    if (!p) return;
    clearTimeout(p.timer);
    this.calls.delete(id);
    void this.ctx.hub.emitTo(p.userId, { type: 'claude', op: 'permission_end', id });
    p.resolve(text);
  }

  close() {
    for (const p of this.calls.values()) { clearTimeout(p.timer); p.resolve(denyText('The server is restarting.')); }
    this.calls.clear();
  }
}

const hubs = new WeakMap<Ctx, PermissionHub>();
export const permissionsOf = (ctx: Ctx) => { let h = hubs.get(ctx); if (!h) { h = new PermissionHub(ctx); hubs.set(ctx, h); } return h; };

/** The tool Claude Code calls (`--permission-prompt-tool mcp__muse__permission_prompt`), for the owner and members alike. */
export const PERMISSION_TOOL = {
  name: 'permission_prompt', scope: 'edit:read', title: 'Ask the person before a file or command call',
  description: 'Used by Claude Code in the MUSE app (its --permission-prompt-tool): asks the person on their Mac before Claude reads or writes a file or runs a command. Do not call it yourself.',
  inputSchema: { type: 'object', properties: { tool_name: { type: 'string' }, input: { type: 'object' }, tool_use_id: { type: 'string' } }, required: ['tool_name'], additionalProperties: true },
  run: async (env: { ctx: Ctx; user: AuthUser }, a: Record<string, unknown>) => {
    const toolName = typeof a.tool_name === 'string' ? a.tool_name.slice(0, 80) : '';
    if (!toolName) return { mcpContent: [{ type: 'text', text: denyText('tool_name missing') }] };
    const input = a.input && typeof a.input === 'object' && !Array.isArray(a.input) ? a.input as Record<string, unknown> : {};
    const text = await permissionsOf(env.ctx).ask(env.user, toolName, input, typeof a.tool_use_id === 'string' ? a.tool_use_id.slice(0, 120) : undefined);
    // Exactly one text block (no structuredContent): Claude Code reads the JSON in it.
    return { mcpContent: [{ type: 'text', text }] };
  },
};

/** upload_local_file (owner and members): a file on the person's Mac, uploaded after they say yes. */
export const UPLOAD_TOOL = {
  name: 'upload_local_file', scope: 'assets:write', title: 'Upload a file from this Mac (asks first)',
  description: 'Uploads a file from the person\'s Mac to MUSE after they approve it on a card ("Upload … to MUSE?"). Images (JPEG, PNG, WebP, HEIC, up to 10 MB), videos (MP4, MOV, up to 500 MB) and sound (MP3, M4A, AAC, WAV, or an MP4 with sound only, up to 200 MB; the Mac reads the file to tell). Returns {uploadId, kind: "image" | "clip" | "audio", url, durationSec?} or {error}. Then use the uploadId: suite_add_reference for an image in the shot, watch for a video; for a sound, apply_edit_ops {"op":"add_music","asset":{"upload":uploadId,"durationSec":durationSec}}, then auto_captions with that item\'s itemId to caption a song. Keys, passwords and tokens are never uploaded. Use it when the person names a file on their Mac; the path must be absolute or start with ~/.',
  inputSchema: { type: 'object', properties: { path: { type: 'string', maxLength: 1024, description: 'The file on the Mac (absolute, or ~/…)' },
    purpose: { type: 'string', enum: ['reference', 'clip', 'audio', 'chat'], description: 'What it is for (default chat)' } }, required: ['path'], additionalProperties: false },
  run: async (env: { ctx: Ctx; user: AuthUser }, a: Record<string, unknown>) => {
    const path = typeof a.path === 'string' ? a.path.trim() : '';
    if (!path || !(path.startsWith('/') || path.startsWith('~/')) || path.length > 1024) throw badRequest('path: an absolute path on the Mac, or ~/…');
    const purpose = a.purpose === 'reference' || a.purpose === 'clip' || a.purpose === 'audio' ? a.purpose : 'chat';
    const text = await permissionsOf(env.ctx).upload(env.user, path, purpose);
    return { mcpContent: [{ type: 'text', text }] };
  },
};
