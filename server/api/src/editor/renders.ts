// Server renders of edit sessions (workstream 1, Release 1): the preview "Your edit" plays in Recreate's Compare on
// both apps, and Recreate's export. One render at a time (CPU); each render is a file in private storage under
// renders/ (served only by the authenticated routes), named by the session's revision, so a preview is made once per
// revision and an edit after it makes a new one. A live `edit` event (op "render") says when it is ready.
import fs from 'node:fs';
import { cleanVideoFile } from '../storage/clean.js';
import os from 'node:os';
import path from 'node:path';
import { pipeline } from 'node:stream/promises';
import { and, eq } from 'drizzle-orm';
import type { AuthUser, Ctx } from '../ctx.js';
import { takes, uploads } from '../db/schema.js';
import { uid } from '../lib/util.js';
import { contentFile } from './content.js';
import type * as M from './model.js';
import { renderProject, type RenderOptions } from './render.js';
import { editSessionsOf } from './sessions.js';

export type RenderState = { key: string; state: 'rendering' | 'ready' | 'failed'; revision: number; durationSec?: number; width?: number; height?: number;
  unsupported?: string[]; error?: string; at: number };
/** A preview is at most this long on its longest side, at most 30 fps. */
export const PREVIEW_MAX_SIDE = 720;

export class EditRenders {
  private states = new Map<string, RenderState>();
  private chain: Promise<unknown> = Promise.resolve();
  private running = 0;
  constructor(private ctx: Ctx) {}

  /** Local files (or signed URLs on S3) for every asset the project uses; the temp dir is the caller's to delete. */
  async files(studioId: string, p: M.EditProject, dir: string): Promise<Record<string, string>> {
    const out: Record<string, string> = {};
    for (const a of p.assets) {
      let key: string | null = null;
      if (a.take) key = (await this.ctx.db.select({ k: takes.mediaKey }).from(takes).where(and(eq(takes.id, a.take), eq(takes.studioId, studioId))))[0]?.k ?? null;
      else if (a.upload) key = (await this.ctx.db.select({ k: uploads.storageKey }).from(uploads).where(and(eq(uploads.id, a.upload), eq(uploads.studioId, studioId))))[0]?.k ?? null;
      // Content library stickers and sound effects (content:<pack>/<item>) are bundled files.
      if (!key) { const f = a.library ? contentFile(a.library) : null; if (f && fs.existsSync(f)) out[a.id] = f; continue; }
      out[a.id] = await this.local(key, dir, a.kind === 'font' || a.kind === 'lut'); // read by the server itself
    }
    return out;
  }
  /** A local copy of `key` (on S3 a signed URL, unless [download]: fonts and LUTs are read by the server, not ffmpeg). */
  async local(key: string, dir: string, download = false): Promise<string> {
    if (this.ctx.storage.kind === 's3' && !download) return this.ctx.storage.presignGet(key, 3600);
    const obj = await this.ctx.storage.get(key);
    if (!obj) throw new Error(`media missing: ${key}`);
    const file = path.join(dir, `${uid('in')}${path.extname(key) || '.bin'}`);
    await pipeline(obj.body as NodeJS.ReadableStream, fs.createWriteStream(file));
    return file;
  }

  /**
   * Renders `project` into storage at `key` (once: a key already stored or rendering is not redone). `onDone` runs after
   * it is stored. One render at a time across the server.
   */
  start(studioId: string, key: string, revision: number, project: M.EditProject, o: RenderOptions & { guideKey?: string }, onDone?: (s: RenderState) => void | Promise<void>): RenderState {
    const have = this.states.get(key);
    if (have && have.state !== 'failed') return have;
    const st: RenderState = { key, state: 'rendering', revision, at: Date.now() };
    this.states.set(key, st);
    const go = async () => {
      this.running++;
      const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-render-'));
      try {
        const files = await this.files(studioId, project, dir);
        const audio = o.guideKey ? { file: await this.local(o.guideKey, dir) } : o.audio;
        const out = path.join(dir, 'out.mp4');
        const r = await renderProject({ ffmpeg: this.ctx.config.FFMPEG_PATH, ffprobe: this.ctx.config.FFPROBE_PATH }, project, files, out, { ...o, ...(audio !== undefined ? { audio } : {}) });
        // No metadata leaves MUSE (storage/clean.ts); the original render is kept if the remux can't read it.
        const clean = (await cleanVideoFile(this.ctx.config.FFMPEG_PATH, out, 'video/mp4')) ?? out;
        if (clean !== out) fs.renameSync(clean, out);
        await this.ctx.storage.putStream(key, fs.createReadStream(out), 'video/mp4', fs.statSync(out).size);
        Object.assign(st, { state: 'ready', durationSec: r.durationSec, width: r.width, height: r.height, unsupported: r.unsupported, at: Date.now() });
        await this.ctx.storage.put(`${key}.json`, Buffer.from(JSON.stringify(st)), 'application/json');
      } catch (e) {
        Object.assign(st, { state: 'failed', error: 'The render didn’t finish · try again', at: Date.now() });
        this.ctx.log.warn({ err: (e as Error).message.slice(0, 300), key }, 'edit render failed');
      } finally {
        this.running--;
        fs.rmSync(dir, { recursive: true, force: true });
      }
      await onDone?.(st);
    };
    const p = this.chain.then(go, go);
    this.chain = p.catch(() => undefined);
    return st;
  }
  /** What is known about a render: in memory, else its stored sidecar (after a restart). */
  async state(key: string): Promise<RenderState | null> {
    const m = this.states.get(key);
    if (m) return m;
    const obj = await this.ctx.storage.get(`${key}.json`).catch(() => null);
    if (!obj) return null;
    const chunks: Buffer[] = []; for await (const c of obj.body as AsyncIterable<Buffer>) chunks.push(Buffer.from(c));
    try { const s = JSON.parse(Buffer.concat(chunks).toString('utf8')) as RenderState; this.states.set(key, s); return s; } catch { return null; }
  }
  /** Removes a stored render and its sidecar. */
  async remove(key: string) {
    this.states.delete(key);
    await this.ctx.storage.delete(key).catch(() => undefined);
    await this.ctx.storage.delete(`${key}.json`).catch(() => undefined);
  }
  /** Waits for every queued render (tests, shutdown). */
  async idle() { await this.chain; }

  // ------------------------------------------------------------------ previews of edit sessions
  private previewKey = (studioId: string, sessionId: string, revision: number) => `renders/${studioId}/${sessionId}/preview-r${revision}.mp4`;
  private lastPreview = new Map<string, string>();
  private view(sessionId: string, s: RenderState) {
    return { sessionId, revision: s.revision, state: s.state, ...(s.state === 'ready' ? { url: `${this.ctx.config.PUBLIC_URL ?? ''}/v1/edit-sessions/${sessionId}/preview.mp4?revision=${s.revision}`,
      durationSec: s.durationSec, width: s.width, height: s.height, unsupported: s.unsupported ?? [] } : {}), ...(s.error ? { error: s.error } : {}) };
  }
  /** The preview of the session's current revision: ready, rendering, or started now. Older previews of it are removed once it is ready. */
  async preview(u: AuthUser, sessionId: string) {
    const s = await editSessionsOf(this.ctx).row(u, sessionId);
    const key = this.previewKey(s.studioId, s.id, s.revision);
    const have = await this.state(key);
    if (have && have.state !== 'failed') return this.view(s.id, have);
    const st = this.start(s.studioId, key, s.revision, s.project as unknown as M.EditProject, { maxSide: PREVIEW_MAX_SIDE, fps: 30, quality: 'preview', audio: 'project' }, async done => {
      if (done.state === 'ready') {
        const prev = this.lastPreview.get(s.id);
        if (prev && prev !== key) await this.remove(prev);
        this.lastPreview.set(s.id, key);
      }
      void this.ctx.hub.emit(s.studioId, v => (v.role === 'owner' ? { type: 'edit', sessionId: s.id, op: 'render', render: this.view(s.id, done) } : null));
    });
    return this.view(s.id, st);
  }
  /** The status of a revision's preview (no render started). */
  async previewState(u: AuthUser, sessionId: string, revision?: number) {
    const s = await editSessionsOf(this.ctx).row(u, sessionId);
    const rev = revision ?? s.revision;
    const st = await this.state(this.previewKey(s.studioId, s.id, rev));
    return st ? this.view(s.id, st) : { sessionId: s.id, revision: rev, state: 'none' as const };
  }
  /** The stored preview file (authenticated): a short-lived link on S3, else the bytes. */
  async previewFile(u: AuthUser, sessionId: string, revision?: number) {
    const s = await editSessionsOf(this.ctx).row(u, sessionId);
    const key = this.previewKey(s.studioId, s.id, revision ?? s.revision);
    return this.serve(key);
  }
  async serve(key: string): Promise<{ redirect: string } | { body: NodeJS.ReadableStream; contentType: string } | null> {
    const st = await this.state(key);
    if (!st || st.state !== 'ready') return null;
    if (this.ctx.storage.kind === 's3') return { redirect: await this.ctx.storage.presignGet(key, 3600) };
    const obj = await this.ctx.storage.get(key);
    return obj ? { body: obj.body as NodeJS.ReadableStream, contentType: 'video/mp4' } : null;
  }
}

const services = new WeakMap<Ctx, EditRenders>();
export const rendersOf = (ctx: Ctx) => { let s = services.get(ctx); if (!s) { s = new EditRenders(ctx); services.set(ctx, s); } return s; };
