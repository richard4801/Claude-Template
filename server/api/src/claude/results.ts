// Results arrive in the chat (owner, 2026-11-11): anything the person waits for that was started while a Claude chat was
// open (a shot, photos, an outfit, Enhance, character-sheet angles, an Edit helper job) tells the chat's owner
// when it ends: `{type: 'claude', op: 'result', result}`. Their Mac claims it (one Mac answers) and runs Claude on it.
// The jobs table keeps the chat on the job's request (durable); the other kinds are linked here, in memory (they finish
// in minutes; a restart forgets the link and the result simply shows in the app as usual).
import { and, eq } from 'drizzle-orm';
import type { AuthUser, Ctx } from '../ctx.js';
import { ApiError } from '../errors.js';
import { compact } from '../lib/util.js';
import { claudeThreads } from '../camera/schema.js';

export type ResultInfo = {
  kind: string; status: 'done' | 'failed'; title?: string; error?: string;
  takeIds?: string[]; modelId?: string; outfitId?: string; runId?: string; editorJobId?: string;
};
type Link = { chatId: string; userId: string; studioId: string; at: number };
type Sent = { userId: string; claimed: boolean; at: number };

const LINK_TTL = 6 * 60 * 60 * 1000, SENT_TTL = 30 * 60 * 1000;

class Results {
  private links = new Map<string, Link>();
  private sent = new Map<string, Sent>();
  constructor(private ctx: Ctx) {}

  /** Something the person started while a chat was open (x-muse-chat): remember the chat under this key. */
  link(u: AuthUser, key: string) {
    if (!u.chatId) return;
    this.prune();
    this.links.set(key, { chatId: u.chatId, userId: u.id, studioId: u.studioId, at: Date.now() });
  }

  /** It ended: tell the chat's owner (once per key; never someone else's chat). */
  async report(key: string, info: ResultInfo) {
    const l = this.links.get(key);
    if (!l) return;
    this.links.delete(key);
    await this.send(key, l, info);
  }

  /** A job (jobs table) carries its own chat. */
  async reportFor(key: string, chat: { chatId: string; userId: string; studioId: string }, info: ResultInfo) {
    await this.send(key, { ...chat, at: Date.now() }, info);
  }

  private async send(key: string, l: Link, info: ResultInfo) {
    if (this.sent.has(key)) return;
    this.prune();
    this.sent.set(key, { userId: l.userId, claimed: false, at: Date.now() }); // reserved before the check: once, even when two finish together
    const [t] = await this.ctx.db.select({ id: claudeThreads.id }).from(claudeThreads)
      .where(and(eq(claudeThreads.id, l.chatId), eq(claudeThreads.ownerId, l.userId), eq(claudeThreads.studioId, l.studioId)));
    if (!t) { this.sent.set(key, { userId: '', claimed: true, at: Date.now() }); return; }
    void this.ctx.hub.emitTo(l.userId, { type: 'claude', op: 'result',
      result: compact({ id: key, chatId: l.chatId, jobId: key, ...info, takeIds: info.takeIds?.length ? info.takeIds : undefined, finishedAt: Date.now() }) });
  }

  /** A deleted chat: nothing reports to it any more. */
  forgetChat(chatId: string) { for (const [k, l] of this.links) if (l.chatId === chatId) this.links.delete(k); }

  /** One Mac answers: the first to claim (the Mac where the chat was last active claims at once, others after a pause). */
  claim(u: AuthUser, key: string) {
    const s = this.sent.get(key);
    if (!s || s.userId !== u.id) throw new ApiError(410, 'result_gone', 'That result has ended');
    if (s.claimed) throw new ApiError(409, 'already_claimed', 'Another Mac is answering it');
    s.claimed = true;
    return { ok: true };
  }

  private prune() {
    const now = Date.now();
    for (const [k, l] of this.links) if (now - l.at > LINK_TTL) this.links.delete(k);
    for (const [k, s] of this.sent) if (now - s.at > SENT_TTL) this.sent.delete(k);
  }
}

const all = new WeakMap<Ctx, Results>();
export const resultsOf = (ctx: Ctx) => { let r = all.get(ctx); if (!r) { r = new Results(ctx); all.set(ctx, r); } return r; };
