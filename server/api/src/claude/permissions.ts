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
type Pending = { ask: PermissionAsk; userId: string; resolve: (text: string) => void; timer: NodeJS.Timeout; upload?: boolean; acked?: boolean };
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

/** Said only when the person's Mac really runs an app without file cards (it talks to the server without X-Muse-Caps: files). */
export const NEEDS_NEW_APP = 'This needs the newer MUSE app on your Mac (update MUSE, then ask again).';
/** No MUSE app with file cards has been in touch (closed, asleep, offline, or the server just restarted and it hasn't reconnected). */
export const MAC_NOT_CONNECTED = 'MUSE on your Mac isn\'t connected right now (open MUSE on the Mac and check it is signed in, then ask again). Nothing was done.';
/** How long a Mac's "I can answer file questions" (X-Muse-Caps: files) counts after its last request. */
export const CAPS_TTL_MS = 5 * 60 * 1000;
/** A call made while no Mac has checked in waits this long for one (the Mac's heartbeat is every 20 s; after a server
 * restart its event stream reconnects within seconds), then says plainly that the Mac isn't connected. */
export const APP_WAIT_MS = 25_000;
/**
 * Claude Code cuts an MCP tool call it hasn't had an answer to (Claude Code 2.1: 60 s unless MCP_TOOL_TIMEOUT is set, at
 * most 5 min with MUSE's idle setting) with "The operation timed out.". upload_local_file and upload_status therefore
 * answer within this long, with the upload's state, and Claude asks again with upload_status.
 */
export const UPLOAD_ANSWER_MS = 40_000;
/** A Mac that says it acks (X-Muse-Caps: acks) shows a card or starts an upload within this long, or the call ends with why. */
export const ACK_WAIT_MS = 20_000;
/** A finished upload's state is kept this long for upload_status. */
export const UPLOAD_KEEP_MS = 60 * 60 * 1000;

/** Where an upload_local_file stands, as Claude reads it. */
export type UploadPhase = 'sent' | 'asking' | 'uploading' | 'confirming' | 'done' | 'failed';
export type UploadState = {
  ticket: string; userId: string; path: string; purpose: string; phase: UploadPhase; createdAt: number; updatedAt: number;
  sentBytes?: number; totalBytes?: number; attempt?: number; result?: UploadResult; error?: string;
};
const MB = (n: number) => Math.round(n / 1024 / 1024 * 10) / 10;

/** The tool's answer: the upload (status done, its uploadId at the top as before), a failure with why, or where it stands. */
export function uploadView(st: UploadState, macReportsProgress: boolean): Record<string, unknown> {
  const name = st.path.split('/').pop() || st.path;
  if (st.phase === 'done' && st.result) return { status: 'done', ...st.result };
  if (st.phase === 'failed') return { status: 'failed', error: st.error ?? 'The upload failed.' };
  const base = { status: st.phase === 'sent' || st.phase === 'asking' ? 'waiting_for_approval' : st.phase, uploadTicket: st.ticket,
    next: `Call upload_status {"uploadTicket":"${st.ticket}"} to wait for it (each call waits up to ${UPLOAD_ANSWER_MS / 1000} s).` };
  switch (st.phase) {
    case 'sent': return { ...base, message: macReportsProgress
      ? `Sent to MUSE on the Mac; it hasn't shown the "Upload ${name} to MUSE?" card yet.`
      : `Waiting: the person approves "Upload ${name} to MUSE?" on their Mac, then the Mac uploads it (this Mac app doesn't report progress, so this covers both).` };
    case 'asking': return { ...base, message: `Waiting for the person to approve the "Upload ${name} to MUSE?" card on their Mac.` };
    case 'uploading': {
      const pct = st.totalBytes ? Math.min(99, Math.floor((st.sentBytes ?? 0) / st.totalBytes * 100)) : undefined;
      return { ...base, ...(pct !== undefined ? { percent: pct, sentMB: MB(st.sentBytes ?? 0), totalMB: MB(st.totalBytes!) } : {}), ...(st.attempt && st.attempt > 1 ? { attempt: st.attempt } : {}),
        message: `Approved; uploading ${name}${pct !== undefined ? `: ${pct}% (${MB(st.sentBytes ?? 0)} of ${MB(st.totalBytes!)} MB)` : ''}${st.attempt && st.attempt > 1 ? ` (try ${st.attempt})` : ''}.` };
    }
    case 'confirming': return { ...base, message: `${name} is up; MUSE is checking the file.` };
    default: return base;
  }
}

export class PermissionHub {
  private calls = new Map<string, Pending>();
  private caps = new Map<string, number>();
  private acks = new Map<string, number>();
  private oldMac = new Map<string, number>();
  private appWaiters = new Map<string, Set<() => void>>();
  private uploads = new Map<string, UploadState>();
  private uploadWaiters = new Map<string, Set<() => void>>();
  /** Overridable in tests. */
  appWaitMs = APP_WAIT_MS;
  uploadAnswerMs = UPLOAD_ANSWER_MS;
  ackWaitMs = ACK_WAIT_MS;
  constructor(private ctx: Ctx) {}

  /** A request from the person's Mac app that can show file cards (it sends X-Muse-Caps: files; `acks`: it confirms each card). */
  sawApp(userId: string, acks = false) {
    this.caps.set(userId, Date.now());
    if (acks) this.acks.set(userId, Date.now());
    const w = this.appWaiters.get(userId);
    if (w) { this.appWaiters.delete(userId); for (const f of w) f(); }
  }
  /** A request from a Mac app without file cards (a Mac's URL loader, no X-Muse-Caps at all). */
  sawOldMac(userId: string) { this.oldMac.set(userId, Date.now()); }
  canAsk(userId: string) { const at = this.caps.get(userId); return at !== undefined && Date.now() - at < CAPS_TTL_MS; }
  private acking(userId: string) { const at = this.acks.get(userId); return at !== undefined && Date.now() - at < CAPS_TTL_MS; }

  /** Waits (up to appWaitMs) for a Mac that can answer; null when one is there, else the honest reason. */
  private async macReady(userId: string): Promise<string | null> {
    if (this.canAsk(userId)) return null;
    await new Promise<void>(resolve => {
      const set = this.appWaiters.get(userId) ?? new Set<() => void>();
      const done = () => { clearTimeout(t); set.delete(done); resolve(); };
      const t = setTimeout(done, this.appWaitMs);
      set.add(done);
      this.appWaiters.set(userId, set);
    });
    if (this.canAsk(userId)) return null;
    // "Update MUSE" only when a Mac really talked to us without file cards, and no Mac with them has since this server started.
    const old = this.oldMac.get(userId);
    return old !== undefined && Date.now() - old < CAPS_TTL_MS && !this.caps.has(userId) ? NEEDS_NEW_APP : MAC_NOT_CONNECTED;
  }

  /** Claude Code's question → the person's devices; resolves with the text block Claude Code reads. */
  async ask(u: AuthUser, toolName: string, input: Record<string, unknown>, toolUseId?: string): Promise<string> {
    if (secretIn(toolName, input)) return denyText(CREDENTIAL_REFUSAL);
    const notReady = await this.macReady(u.id);
    if (notReady) return denyText(notReady);
    const now = Date.now();
    const ask: PermissionAsk = { id: uid('perm'), toolName, input, ...(toolUseId ? { toolUseId } : {}), createdAt: now, expiresAt: now + PERMISSION_WAIT_MS };
    return new Promise(resolve => {
      const timer = setTimeout(() => this.end(ask.id, denyText('No answer from the person, so this was not done.')), PERMISSION_WAIT_MS);
      this.calls.set(ask.id, { ask, userId: u.id, resolve, timer });
      this.watchAck(ask.id, u.id, denyText('MUSE on your Mac got the question but didn\'t show a card for it (no Claude turn of yours is running on that Mac). Nothing was done; ask again from MUSE on the Mac.'));
      void this.ctx.hub.emitTo(u.id, { type: 'claude', op: 'permission', ask });
    });
  }

  /** A Mac that acks must show the card (or act) soon: otherwise nobody would ever see it, and Claude would wait. */
  private watchAck(id: string, userId: string, text: string) {
    if (!this.acking(userId)) return;
    const t = setTimeout(() => { const p = this.calls.get(id); if (p && !p.acked) this.end(id, text); }, this.ackWaitMs);
    t.unref?.();
  }

  /**
   * upload_local_file: the person's Mac asks them (the same card, "Upload … to MUSE"), then uploads the file the usual way
   * (images: presign, PUT, confirm, so the server strips their metadata; videos as clips) and posts the upload back.
   * Never holds the call longer than uploadAnswerMs: answers with the upload, a failure, or where it stands (upload_status).
   */
  async upload(u: AuthUser, path: string, purpose: string): Promise<Record<string, unknown>> {
    if (isSecretPath(path)) return { status: 'failed', error: CREDENTIAL_REFUSAL };
    const notReady = await this.macReady(u.id);
    if (notReady) return { status: 'failed', error: notReady };
    const now = Date.now();
    const ask: PermissionAsk = { id: uid('perm'), toolName: 'Upload', input: { file_path: path, purpose }, createdAt: now, expiresAt: now + PERMISSION_WAIT_MS };
    const st: UploadState = { ticket: ask.id, userId: u.id, path, purpose, phase: 'sent', createdAt: now, updatedAt: now };
    this.uploads.set(st.ticket, st);
    const timer = setTimeout(() => this.end(ask.id, JSON.stringify({ error: 'No answer from the person, so nothing was uploaded.' })), PERMISSION_WAIT_MS);
    this.calls.set(ask.id, { ask, userId: u.id, resolve: () => undefined, timer, upload: true });
    this.watchAck(ask.id, u.id, JSON.stringify({ error: 'MUSE on your Mac got the upload but didn\'t show its card (no Claude turn of yours is running on that Mac). Nothing was uploaded; ask again from MUSE on the Mac.' }));
    void this.ctx.hub.emitTo(u.id, { type: 'claude', op: 'permission', ask });
    return this.uploadStatus(u, st.ticket);
  }

  /** upload_status: waits until the upload is done or failed, or uploadAnswerMs, and says where it stands. */
  async uploadStatus(u: AuthUser, ticket: string, waitMs = this.uploadAnswerMs): Promise<Record<string, unknown>> {
    const st = this.uploads.get(ticket);
    if (!st || st.userId !== u.id) {
      return { status: 'unknown', error: 'MUSE doesn\'t know that upload: the server restarted since, or it ended over an hour ago. Check whether the file is in the Library; if not, call upload_local_file again.' };
    }
    if (st.phase !== 'done' && st.phase !== 'failed') {
      await new Promise<void>(resolve => {
        const set = this.uploadWaiters.get(ticket) ?? new Set<() => void>();
        const done = () => { clearTimeout(t); set.delete(done); resolve(); };
        const t = setTimeout(done, waitMs);
        set.add(() => { if (st.phase === 'done' || st.phase === 'failed') done(); });
        this.uploadWaiters.set(ticket, set);
      });
    }
    return uploadView(st, this.acking(u.id));
  }

  private touchUpload(ticket: string, patch: Partial<UploadState>) {
    const st = this.uploads.get(ticket);
    if (!st) return;
    Object.assign(st, patch, { updatedAt: Date.now() });
    for (const f of [...(this.uploadWaiters.get(ticket) ?? [])]) f();
    if (st.phase === 'done' || st.phase === 'failed') {
      this.uploadWaiters.delete(ticket);
      setTimeout(() => this.uploads.delete(ticket), UPLOAD_KEEP_MS).unref?.();
    }
  }

  /** The Mac says what it is doing with a question: showing its card, uploading (bytes so far), checking the file. */
  progress(u: AuthUser, id: string, b: { phase: 'asking' | 'uploading' | 'confirming'; sentBytes?: number; totalBytes?: number; attempt?: number }) {
    const p = this.calls.get(id);
    if (!p || p.userId !== u.id) throw new ApiError(410, 'permission_expired', 'That question has ended');
    p.acked = true;
    if (p.upload) this.touchUpload(id, { phase: b.phase, ...(b.sentBytes !== undefined ? { sentBytes: b.sentBytes } : {}), ...(b.totalBytes !== undefined ? { totalBytes: b.totalBytes } : {}), ...(b.attempt !== undefined ? { attempt: b.attempt } : {}) });
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
    if (p.upload) {
      const r = JSON.parse(text) as UploadResult & { error?: string };
      this.touchUpload(id, r.error ? { phase: 'failed', error: r.error } : { phase: 'done', result: r });
    }
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
  description: 'Uploads a file from the person\'s Mac to MUSE after they approve it on a card ("Upload … to MUSE?"). Images (JPEG, PNG, WebP, HEIC, up to 10 MB), videos (MP4, MOV, up to 500 MB) and sound (MP3, M4A, AAC, WAV, or an MP4 with sound only, up to 200 MB; the Mac reads the file to tell). Answers within 40 s: {status: "done", uploadId, kind: "image" | "clip" | "audio", url, durationSec?}, {status: "failed", error}, or, while the person hasn\'t approved yet or a big file is still going up, {status: "waiting_for_approval" | "uploading" | "confirming", uploadTicket, percent?, message}: then call upload_status {uploadTicket} (each call waits up to 40 s) until it is done or failed, and tell the person what the message says. Then use the uploadId: suite_add_reference for an image in the shot, watch for a video; for a sound, apply_edit_ops {"op":"add_music","asset":{"upload":uploadId,"durationSec":durationSec}}, then auto_captions with that item\'s itemId to caption a song. Keys, passwords and tokens are never uploaded. Use it when the person names a file on their Mac; the path must be absolute or start with ~/.',
  inputSchema: { type: 'object', properties: { path: { type: 'string', maxLength: 1024, description: 'The file on the Mac (absolute, or ~/…)' },
    purpose: { type: 'string', enum: ['reference', 'clip', 'audio', 'chat'], description: 'What it is for (default chat)' } }, required: ['path'], additionalProperties: false },
  run: async (env: { ctx: Ctx; user: AuthUser }, a: Record<string, unknown>) => {
    const path = typeof a.path === 'string' ? a.path.trim() : '';
    if (!path || !(path.startsWith('/') || path.startsWith('~/')) || path.length > 1024) throw badRequest('path: an absolute path on the Mac, or ~/…');
    const purpose = a.purpose === 'reference' || a.purpose === 'clip' || a.purpose === 'audio' ? a.purpose : 'chat';
    const out = await permissionsOf(env.ctx).upload(env.user, path, purpose);
    return { mcpContent: [{ type: 'text', text: JSON.stringify(out) }] };
  },
};

/** upload_status: where an upload_local_file stands (waits up to 40 s for it to finish). */
export const UPLOAD_STATUS_TOOL = {
  name: 'upload_status', scope: 'assets:write', title: 'Check an upload from this Mac', readOnly: true,
  description: 'For an upload_local_file that answered with an uploadTicket: waits up to 40 s and says where it stands: {status: "waiting_for_approval" (the person hasn\'t approved the card yet) | "uploading" (percent, sentMB, totalMB) | "confirming" | "done" (uploadId, kind, url, durationSec?) | "failed" (error) | "unknown"}. Call it again while it is still going; tell the person what the message says rather than retrying the upload.',
  inputSchema: { type: 'object', properties: { uploadTicket: { type: 'string', maxLength: 120 } }, required: ['uploadTicket'], additionalProperties: false },
  run: async (env: { ctx: Ctx; user: AuthUser }, a: Record<string, unknown>) => {
    const ticket = typeof a.uploadTicket === 'string' ? a.uploadTicket.trim() : '';
    if (!ticket) throw badRequest('uploadTicket: from upload_local_file');
    const out = await permissionsOf(env.ctx).uploadStatus(env.user, ticket);
    return { mcpContent: [{ type: 'text', text: JSON.stringify(out) }] };
  },
};
