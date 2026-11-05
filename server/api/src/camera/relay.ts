// Relay of Blender tool calls to the owner's Mac (plans/mcp-bridge.md). The server never talks to Blender: it sends a
// `blender` live event to the owner's devices, one Mac claims the call, runs it against the local Blender add-on and
// posts the result. In memory, like the event hub (one API instance).
import type { AuthUser, Ctx } from '../ctx.js';
import { ApiError } from '../errors.js';
import { uid } from '../lib/util.js';

export type BlenderCall = { id: string; sessionId: string; tool: string; args: Record<string, unknown>; outDir: string; createdAt: number; expiresAt: number };
export type BlenderResult = { ok: boolean; result?: unknown; error?: string; assetIds?: string[] };
export type RelayPresence = { online: boolean; blender: boolean; addonVersion?: string };

type Pending = { call: BlenderCall; userId: string; state: 'pending' | 'claimed'; resolve: (r: BlenderResult) => void; timer: NodeJS.Timeout };

export const OFFLINE_AFTER_MS = 45_000;

export class BlenderRelayHub {
  private presence = new Map<string, { at: number; blender: boolean; addonVersion?: string }>();
  private calls = new Map<string, Pending>();
  constructor(private ctx: Ctx) {}

  status(userId: string): RelayPresence {
    const p = this.presence.get(userId);
    const online = !!p && Date.now() - p.at < OFFLINE_AFTER_MS;
    return { online, blender: online && !!p?.blender, ...(online && p?.addonVersion ? { addonVersion: p.addonVersion } : {}) };
  }

  heartbeat(u: AuthUser, b: { online: boolean; blender?: { connected?: boolean; addonVersion?: string } }) {
    const before = this.status(u.id);
    if (b.online) this.presence.set(u.id, { at: Date.now(), blender: !!b.blender?.connected, addonVersion: b.blender?.addonVersion?.slice(0, 40) });
    else this.presence.delete(u.id);
    const after = this.status(u.id);
    if (before.online !== after.online || before.blender !== after.blender) void this.ctx.hub.emitTo(u.id, { type: 'blender', op: 'relay', ...after });
    return { ok: true, pending: this.pending(u) };
  }

  pending(u: AuthUser) {
    return [...this.calls.values()].filter(p => p.userId === u.id && p.state === 'pending' && p.call.expiresAt > Date.now()).map(p => p.call);
  }

  /** Sends a call to the owner's Mac and waits for its result (or the timeout). */
  call(u: AuthUser, sessionId: string, tool: string, args: Record<string, unknown>): Promise<BlenderResult> {
    if (!this.status(u.id).online) {
      return Promise.resolve({ ok: false, error: 'The MUSE Mac app is not connected, so Blender can\'t be reached. Ask the owner to open MUSE on their Mac and switch on the Blender relay.' });
    }
    const now = Date.now(), ttl = this.ctx.config.BLENDER_CALL_TIMEOUT_SEC * 1000;
    const call: BlenderCall = { id: uid('bc'), sessionId, tool, args, outDir: `CameraSessions/${sessionId}`, createdAt: now, expiresAt: now + ttl };
    return new Promise(resolve => {
      const timer = setTimeout(() => {
        if (!this.calls.delete(call.id)) return;
        void this.ctx.hub.emitTo(u.id, { type: 'blender', op: 'cancel', id: call.id });
        resolve({ ok: false, error: 'Blender did not answer in time (the Mac app may be busy or asleep).' });
      }, ttl);
      this.calls.set(call.id, { call, userId: u.id, state: 'pending', resolve, timer });
      void this.ctx.hub.emitTo(u.id, { type: 'blender', op: 'call', call });
    });
  }

  claim(u: AuthUser, id: string): BlenderCall {
    const p = this.calls.get(id);
    if (!p || p.userId !== u.id) throw new ApiError(410, 'call_expired', 'That Blender call has ended');
    if (p.state !== 'pending') throw new ApiError(409, 'already_claimed', 'Another Mac is running that Blender call');
    p.state = 'claimed';
    return p.call;
  }

  result(u: AuthUser, id: string, r: BlenderResult) {
    const p = this.calls.get(id);
    if (!p || p.userId !== u.id) throw new ApiError(410, 'call_expired', 'That Blender call has ended');
    clearTimeout(p.timer);
    this.calls.delete(id);
    p.resolve(r);
  }

  /** Shutdown: every waiting call ends. */
  close() {
    for (const p of this.calls.values()) { clearTimeout(p.timer); p.resolve({ ok: false, error: 'The server is restarting.' }); }
    this.calls.clear();
  }
}
