// Claude operates MUSE's own window (owner, 2026-11-11: "Claude cursor control: MUSE window only"). A fallback for
// anything no dedicated tool covers. Never the whole Mac: the MUSE app describes its own visible controls (SwiftUI
// accessibility ids and labels) and acts on them itself, so it needs no macOS Accessibility or Screen Recording
// permission. Fulfilled by the person's own Mac like upload_local_file: the call goes out as a live event
// ({type:'claude', op:'uiCall', call}), one of their Macs claims it, does it and posts the result back. Only their own app:
// events go to that person's devices only. Settings keys/providers/prices, sign-out, account deletion, payment and
// delete confirmations are never pressed by Claude (refused here and again on the Mac): those stay the person's, through
// the go-ahead cards. In memory, like the permission relay (one API instance).
import type { AuthUser, Ctx } from '../ctx.js';
import { ApiError, badRequest } from '../errors.js';
import { uid } from '../lib/util.js';
import type { EditTool } from '../editor/mcpTools.js';

export type UiKind = 'snapshot' | 'act' | 'wait';
export type UiCall = { id: string; kind: UiKind; args: Record<string, unknown>; createdAt: number; expiresAt: number };
type Pending = { call: UiCall; userId: string; claimedBy?: string; resolve: (r: UiOutcome) => void; timer: NodeJS.Timeout };
/** The Mac's reason codes: stopped (the person pressed Esc), off (their Settings toggle), protected, not_found, failed. */
export const UI_ERROR_CODES = ['stopped', 'off', 'protected', 'not_found', 'failed'] as const;
export type UiErrorCode = typeof UI_ERROR_CODES[number];
export type UiOutcome = { error: string; code?: UiErrorCode } | { result: Record<string, unknown>; image?: string };
/** The person's own choices (Esc, their toggle) and the refusal list are not MUSE problems: never auto-reported as issues. */
export const UI_QUIET_CODES = new Set(['ui_stopped', 'ui_off', 'ui_protected']);

/** Older Mac apps (no X-Muse-Caps: ui): the tools say so at once. */
export const NEEDS_NEW_APP_UI = 'This needs the newer MUSE app (update MUSE on your Mac, then ask again).';
export const UI_CAPS_TTL_MS = 5 * 60 * 1000;
/** A Mac that doesn't answer in this long (asleep, app closed) ends the call. ui_wait adds its own timeout. */
export const UI_ANSWER_MS = 20_000;
export const UI_WAIT_MAX_S = 30;

export const UI_ACTIONS = ['press', 'set_text', 'set_value', 'select', 'toggle', 'scroll', 'menu', 'focus', 'key'] as const;
export type UiAction = typeof UI_ACTIONS[number];
/** Keys Claude may press in the MUSE window (nothing that quits, closes or switches apps). */
export const UI_KEYS = ['return', 'escape', 'tab', 'shift+tab', 'space', 'up', 'down', 'left', 'right', 'delete', 'cmd+z', 'cmd+shift+z', 'cmd+a', 'cmd+c', 'cmd+v', 'cmd+f'] as const;
export const UI_WAIT_FOR = ['appears', 'disappears', 'enabled', 'idle'] as const;

/**
 * Controls Claude never touches, by id or label (the Mac app marks the same controls `protected` in the snapshot and
 * refuses them too; MuseCore UiRefusal keeps the same list). Claude may open these screens; the person presses.
 */
const PROTECTED: { re: RegExp; why: string }[] = [
  { re: /\b(api[\s_-]?key|secret|token|password|passcode|credential)s?\b/i, why: 'keys, tokens and passwords' },
  { re: /\bprovider(s)?\b|\bproviders?[._-]/i, why: 'provider settings' },
  { re: /\b(price|prices|pricing|markup|margin|per[\s_-]?second rate)\b/i, why: 'prices' },
  { re: /\b(sign|log)[\s_-]?out\b|\bsignout\b|\blogout\b/i, why: 'signing out' },
  { re: /\b(delete|close|remove)[\s_-]?(my[\s_-]?)?account\b|\baccount[._\s-]?delet/i, why: 'deleting the account' },
  { re: /\b(top[\s_-]?up|topup|payment|pay now|checkout|buy credits|add credits|add funds|billing|card number|transfer credits)\b/i, why: 'payments and top-ups' },
  { re: /(^|[._\s-])(confirm[\s_-]?)?(delete|discard|erase)\b/i, why: 'deleting' },
];

/** Why Claude may not touch this control, or null. */
export function protectedReason(target: string): string | null {
  const t = target.trim();
  for (const p of PROTECTED) if (p.re.test(t)) return p.why;
  return null;
}
export const refusalText = (why: string) =>
  `That control is for the person, not Claude (${why}). Use the dedicated tool, which asks them with a go-ahead card, or open the screen and tell them what to press.`;

export class UiHub {
  private calls = new Map<string, Pending>();
  private caps = new Map<string, number>();
  constructor(private ctx: Ctx) {}

  /** A request from the person's Mac that can operate its own window (it sends X-Muse-Caps: ui). */
  sawApp(userId: string) { this.caps.set(userId, Date.now()); }
  canAsk(userId: string) { const at = this.caps.get(userId); return at !== undefined && Date.now() - at < UI_CAPS_TTL_MS; }

  /** Sends the call to the person's Macs; resolves with the Mac's answer, or an error when none answers in time. */
  request(u: AuthUser, kind: UiKind, args: Record<string, unknown>, waitMs = UI_ANSWER_MS): Promise<UiOutcome> {
    if (!this.canAsk(u.id)) return Promise.resolve({ error: NEEDS_NEW_APP_UI });
    const now = Date.now();
    const call: UiCall = { id: uid('ui'), kind, args, createdAt: now, expiresAt: now + waitMs };
    return new Promise(resolve => {
      const timer = setTimeout(() => this.end(call.id, { error: 'MUSE on your Mac did not answer (is the app open and awake?). Nothing was done.' }), waitMs);
      this.calls.set(call.id, { call, userId: u.id, resolve, timer });
      void this.ctx.hub.emitTo(u.id, { type: 'claude', op: 'uiCall', call });
    });
  }

  pending(u: AuthUser) { return [...this.calls.values()].filter(p => p.userId === u.id && !p.claimedBy).map(p => p.call); }

  /** One Mac does the call: the first to claim it. Others get 409 and do nothing. */
  claim(u: AuthUser, id: string, device: string) {
    const p = this.calls.get(id);
    if (!p || p.userId !== u.id) throw new ApiError(410, 'ui_expired', 'That request has ended');
    if (p.claimedBy && p.claimedBy !== device) throw new ApiError(409, 'ui_claimed', 'Another of your Macs is doing this');
    p.claimedBy = device;
    return { call: p.call };
  }

  answer(u: AuthUser, id: string, b: { result?: Record<string, unknown>; image?: string; error?: string; code?: UiErrorCode }) {
    const p = this.calls.get(id);
    if (!p || p.userId !== u.id) throw new ApiError(410, 'ui_expired', 'That request has ended');
    if (b.error !== undefined) return this.end(id, { error: b.error.trim().slice(0, 500) || 'MUSE could not do that.', ...(b.code ? { code: b.code } : {}) });
    if (!b.result) throw badRequest('result or error');
    this.end(id, { result: b.result, ...(b.image ? { image: b.image } : {}) });
  }

  private end(id: string, out: UiOutcome) {
    const p = this.calls.get(id);
    if (!p) return;
    clearTimeout(p.timer);
    this.calls.delete(id);
    void this.ctx.hub.emitTo(p.userId, { type: 'claude', op: 'uiCallEnd', id });
    p.resolve(out);
  }

  close() {
    for (const p of this.calls.values()) { clearTimeout(p.timer); p.resolve({ error: 'The server is restarting.' }); }
    this.calls.clear();
  }
}

const hubs = new WeakMap<Ctx, UiHub>();
export const uiOf = (ctx: Ctx) => { let h = hubs.get(ctx); if (!h) { h = new UiHub(ctx); hubs.set(ctx, h); } return h; };

const str = (v: unknown, max: number) => (typeof v === 'string' ? v.trim().slice(0, max) : '');

/** What a tool returns: the Mac's error as a tool error (Claude reads it), else the result (+ the window picture). */
function reply(o: UiOutcome) {
  if ('error' in o) {
    const c = o.code ?? 'failed';
    throw new ApiError(c === 'stopped' || c === 'off' || c === 'protected' ? 403 : c === 'not_found' ? 404 : 422, `ui_${c}`, o.error);
  }
  const meta = o.result;
  const blocks: unknown[] = [];
  if (o.image) blocks.push({ type: 'image', data: o.image, mimeType: 'image/jpeg' });
  blocks.push({ type: 'text', text: JSON.stringify(meta) });
  return { mcpContent: blocks, structuredContent: meta };
}

const TARGET_DOC = 'The control: its id from ui_snapshot (best), or its visible label.';

export const UI_TOOLS: EditTool[] = [
  {
    name: 'ui_snapshot', scope: 'edit:read', readOnly: true, idempotent: true, title: 'See the MUSE window (its controls)',
    description: 'FALLBACK ONLY: prefer MUSE\'s dedicated tools; use ui_* only when no tool covers what the person asked, and then call report_issue so a tool gets added. '
      + 'Describes what the MUSE window on the person\'s Mac shows right now: the page, and its visible controls as {id, role, label, value, enabled, selected?, protected?}. '
      + 'screenshot: true also returns a small picture of the MUSE window only (never the rest of the screen). Controls marked protected are the person\'s (keys, prices, sign-out, payments, deletes): never try to operate them.',
    inputSchema: { type: 'object', properties: { screenshot: { type: 'boolean', description: 'Also return a small JPEG of the MUSE window' },
      within: { type: 'string', maxLength: 200, description: 'Only the controls inside this container id (optional)' } }, additionalProperties: false },
    run: async (env, a) => reply(await uiOf(env.ctx).request(env.user, 'snapshot', { screenshot: a.screenshot === true, ...(str(a.within, 200) ? { within: str(a.within, 200) } : {}) })),
  },
  {
    name: 'ui_act', scope: 'edit:write', title: 'Operate a control in the MUSE window',
    description: 'FALLBACK ONLY (see ui_snapshot). Operates one control in the MUSE window, the way the person would: '
      + 'press (a button or link), set_text (replace a text field\'s text with value), set_value (a slider/stepper to the number in value), select (a picker/tab/list row: value is the option\'s label, or omit to select the row itself), '
      + 'toggle (value "on"/"off", or omit to flip), scroll (value "up"/"down"/"top"/"bottom"), menu (a menu-bar item: target like "File > Export"), focus, key (value: one of '
      + UI_KEYS.join(', ') + '; no target needed). The person sees a soft ring on the control and can press Esc to stop you; if they stopped you, do not try again this turn. '
      + 'Never for keys, providers, prices, sign-out, account deletion, payments or delete confirmations: those always go through the dedicated tools\' go-ahead cards (you can open the screen; the person presses). '
      + 'Returns what changed and the control\'s new state; take a fresh ui_snapshot before acting on a changed screen.',
    inputSchema: { type: 'object', properties: {
      action: { type: 'string', enum: [...UI_ACTIONS] },
      target: { type: 'string', maxLength: 300, description: TARGET_DOC },
      value: { type: 'string', maxLength: 4000, description: 'The text, number, option, on/off, scroll direction or key' },
    }, required: ['action'], additionalProperties: false },
    run: async (env, a) => {
      const action = str(a.action, 20) as UiAction;
      if (!(UI_ACTIONS as readonly string[]).includes(action)) throw badRequest(`action: one of ${UI_ACTIONS.join(', ')}`);
      const target = str(a.target, 300), value = typeof a.value === 'string' ? a.value.slice(0, 4000) : undefined;
      if (action === 'key') {
        const k = (value ?? '').trim().toLowerCase();
        if (!(UI_KEYS as readonly string[]).includes(k)) throw badRequest(`value: a key, one of ${UI_KEYS.join(', ')}`);
      } else if (!target) throw badRequest(`target: ${TARGET_DOC}`);
      const why = target ? protectedReason(target) : null;
      if (why) throw new ApiError(403, 'ui_protected', refusalText(why));
      return reply(await uiOf(env.ctx).request(env.user, 'act', { action, ...(target ? { target } : {}), ...(value !== undefined ? { value: action === 'key' ? value.trim().toLowerCase() : value } : {}) }));
    },
  },
  {
    name: 'ui_wait', scope: 'edit:read', readOnly: true, title: 'Wait for something in the MUSE window',
    description: 'FALLBACK ONLY (see ui_snapshot). Waits until a control appears, disappears or becomes enabled, or (for: "idle") until the window stops changing; at most timeout seconds (1–30, default 10). '
      + 'Returns {met: true|false, waitedMs} and, when met, the control.',
    inputSchema: { type: 'object', properties: {
      for: { type: 'string', enum: [...UI_WAIT_FOR] },
      target: { type: 'string', maxLength: 300, description: `${TARGET_DOC} Not needed for idle.` },
      timeout: { type: 'number', minimum: 1, maximum: UI_WAIT_MAX_S },
    }, required: ['for'], additionalProperties: false },
    run: async (env, a) => {
      const kind = str(a.for, 20);
      if (!(UI_WAIT_FOR as readonly string[]).includes(kind)) throw badRequest(`for: one of ${UI_WAIT_FOR.join(', ')}`);
      const target = str(a.target, 300);
      if (kind !== 'idle' && !target) throw badRequest(`target: ${TARGET_DOC}`);
      const t = typeof a.timeout === 'number' && Number.isFinite(a.timeout) ? Math.min(UI_WAIT_MAX_S, Math.max(1, a.timeout)) : 10;
      return reply(await uiOf(env.ctx).request(env.user, 'wait', { for: kind, ...(target ? { target } : {}), timeout: t }, UI_ANSWER_MS + t * 1000));
    },
  },
];
