// save_to_mac (ci_741e03646382, ci_c62906bcd1c1): Claude saves a studio file to the person's Mac for local work: a take's
// video or still, an upload, or a saved outfit's full-size picture. Free. The server only names the file and its link;
// the person's Mac (claude/permissions.ts save) downloads the original into the folder (default ~/Downloads/MUSE), never
// over another file ("name (2).mp4"), after a card unless the folder is always allowed, and answers with the local path.
// The Mac's ClaudeFilePolicy decides which folders it may write (its save folders and the person's allowed folders);
// keys and credential paths are refused here and there.
import { and, eq } from 'drizzle-orm';
import type { AuthUser, Ctx } from '../ctx.js';
import { outfits, takes, uploads, type ImageRef } from '../db/schema.js';
import { ApiError, badRequest } from '../errors.js';
import { isSecretPath, permissionsOf, type SaveRequest } from './permissions.js';

export const DEFAULT_SAVE_FOLDER = '~/Downloads/MUSE';
/** An outfit's pictures by name: the four angles, then Dress up's three face close-ups. */
export const OUTFIT_PICTURES = ['front', 'threeQuarter', 'side', 'back', 'face', 'faceThreeQuarter', 'profile'] as const;
export type OutfitPicture = typeof OUTFIT_PICTURES[number];

/** "mia-living-room-dance": lowercase words joined by "-", at most `max` characters, cut at a word (the Mac's SaveFileName.slug). */
export function slug(s: string, max = 40): string {
  const words = s.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  let out = '';
  for (const w of words) { const next = out ? `${out}-${w}` : w; if (next.length > max) break; out = next; }
  return out || (words[0] ?? '').slice(0, max);
}
/** "s_9381c89cde04" → "s9381c89c" (the Mac's SaveFileName.shortId). */
export const shortId = (id: string) => id.replace(/[^A-Za-z0-9]/g, '').slice(0, 9);
/** A readable file name: what it is, its id, its number (the Mac's SaveFileName.base), plus the extension. */
export function fileNameFor(o: { title?: string | null; prompt?: string | null; id: string; index?: number; ext: string }): string {
  const parts = [slug(o.title ?? '') || slug(o.prompt ?? '') || 'muse', shortId(o.id)].filter(Boolean);
  if (o.index && o.index > 0) parts.push(String(o.index));
  return `${parts.join('-')}.${o.ext}`;
}

const EXT_BY_TYPE: Record<string, string> = { 'video/mp4': 'mp4', 'video/quicktime': 'mov', 'video/webm': 'webm', 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp',
  'image/heic': 'heic', 'audio/mpeg': 'mp3', 'audio/mp4': 'm4a', 'audio/aac': 'aac', 'audio/wav': 'wav', 'audio/x-wav': 'wav' };
const extOf = (key: string, contentType?: string, fallback = 'bin') => {
  const e = /\.([A-Za-z0-9]{2,5})$/.exec(key)?.[1]?.toLowerCase();
  return e ?? (contentType ? EXT_BY_TYPE[contentType.toLowerCase()] : undefined) ?? fallback;
};

/** The folder Claude named, checked on the server's side (the Mac decides which folders it may write). */
export function saveFolder(v: unknown): string {
  if (v === undefined || v === null || v === '') return DEFAULT_SAVE_FOLDER;
  if (typeof v !== 'string') throw badRequest('folder: a folder on the Mac (absolute, or ~/…)');
  const f = v.trim().replace(/\/+$/, '');
  if (!f || f.length > 512 || !(f.startsWith('/') || f === '~' || f.startsWith('~/'))) throw badRequest('folder: a folder on the Mac (absolute, or ~/…); default ~/Downloads/MUSE');
  if (f.split('/').some(p => p === '..' || p === '.')) throw badRequest('folder: no "." or ".." in it');
  if (isSecretPath(f) || isSecretPath(`${f}/`)) throw new ApiError(403, 'credential_path', 'MUSE never writes into folders for keys, passwords or tokens.');
  return f === '~' ? '~' : f;
}

type Source = Omit<SaveRequest, 'folder'>;

export class SaveToMac {
  constructor(private ctx: Ctx) {}
  private base() { return this.ctx.config.PUBLIC_URL ?? ''; }
  private urlOfKey(key: string) { return `${this.base()}/uploads/${key}`; }
  private async uploadRow(studioId: string, key: string) {
    const [r] = await this.ctx.db.select({ contentType: uploads.contentType, bytes: uploads.bytes }).from(uploads).where(and(eq(uploads.storageKey, key), eq(uploads.studioId, studioId)));
    return r;
  }
  /** A picture of ours as a link the Mac can fetch, with its type and size when known. */
  private async ofRef(studioId: string, ref: ImageRef) {
    const key = this.ctx.images.keyOf(ref);
    if (key) { const r = await this.uploadRow(studioId, key); return { url: this.urlOfKey(key), key, contentType: r?.contentType, bytes: r?.bytes ?? undefined }; }
    if (ref.asset) return { url: `${this.base()}/assets/ref/${ref.asset}.jpg`, key: `${ref.asset}.jpg`, contentType: 'image/jpeg' };
    if (ref.url && /^https:\/\//.test(ref.url)) return { url: ref.url, key: ref.url.split('?')[0]!, contentType: undefined };
    return null;
  }

  /** A take of the studio: its video (renders, edited versions) or still (photos), as stored (original quality). */
  async take(u: Pick<AuthUser, 'studioId'>, id: string): Promise<Source> {
    const [t] = await this.ctx.db.select().from(takes).where(and(eq(takes.id, id), eq(takes.studioId, u.studioId)));
    if (!t) throw new ApiError(404, 'not_found', `${id} is not a take of this studio now (deleted, or not a take id) · suite_feed or library lists the current ids`);
    const video = t.kind !== 'shot';
    const title = t.title || t.label;
    if (t.mediaKey) {
      const r = await this.uploadRow(u.studioId, t.mediaKey);
      return { url: this.urlOfKey(t.mediaKey), fileName: fileNameFor({ title, prompt: t.prompt, id: t.id, index: t.index, ext: extOf(t.mediaKey, r?.contentType, video ? 'mp4' : 'jpg') }),
        what: `${video ? 'the video' : 'the photo'} ${t.id}${title ? ` (${title})` : ''}`, ...(r?.contentType ? { contentType: r.contentType } : {}), ...(r?.bytes ? { bytes: r.bytes } : {}) };
    }
    if (video) throw new ApiError(409, 'not_ready', `${id} has no video yet (still rendering, or it failed)`);
    const p = t.thumb ? await this.ofRef(u.studioId, t.thumb as ImageRef) : null;
    if (!p) throw new ApiError(409, 'not_ready', `${id} has no picture yet`);
    return { url: p.url, fileName: fileNameFor({ title, prompt: t.prompt, id: t.id, index: t.index, ext: extOf(p.key, p.contentType, 'jpg') }), what: `the photo ${t.id}${title ? ` (${title})` : ''}`,
      ...(p.contentType ? { contentType: p.contentType } : {}), ...(p.bytes ? { bytes: p.bytes } : {}) };
  }

  /** An upload of the studio (an attached image or video, a sound, an Edit upload). */
  async upload(u: Pick<AuthUser, 'studioId'>, id: string): Promise<Source> {
    const [r] = await this.ctx.db.select().from(uploads).where(and(eq(uploads.id, id), eq(uploads.studioId, u.studioId)));
    if (!r) throw new ApiError(404, 'not_found', `${id} is not an upload of this studio (deleted, or not an upload id)`);
    if (r.state !== 'ready') throw new ApiError(409, 'not_ready', `${id} hasn't finished uploading yet`);
    const kind = r.contentType.split('/')[0] ?? 'file';
    return { url: this.urlOfKey(r.storageKey), fileName: fileNameFor({ title: `upload ${kind}`, id: r.id, ext: extOf(r.storageKey, r.contentType) }), what: `the upload ${r.id}`,
      contentType: r.contentType, ...(r.bytes ? { bytes: r.bytes } : {}) };
  }

  /** A saved outfit's full-size picture: front (default), threeQuarter, side, back, or a Dress up face close-up. */
  async outfit(u: Pick<AuthUser, 'studioId'>, id: string, which: unknown): Promise<Source> {
    const pick = (which ?? 'front') as OutfitPicture;
    if (!OUTFIT_PICTURES.includes(pick)) throw badRequest(`picture: one of ${OUTFIT_PICTURES.join(', ')}`);
    const [o] = await this.ctx.db.select().from(outfits).where(and(eq(outfits.id, id), eq(outfits.studioId, u.studioId)));
    if (!o) throw new ApiError(404, 'not_found', `${id} is not an outfit of this studio (deleted, or not an outfit id) · list_outfits lists them`);
    const i = OUTFIT_PICTURES.indexOf(pick);
    const ref = (i < 4 ? o.angles?.[i] : o.faces?.[i - 4]) ?? null;
    if (!ref) {
      const have = OUTFIT_PICTURES.filter((_, n) => (n < 4 ? o.angles?.[n] : o.faces?.[n - 4]));
      throw new ApiError(404, 'no_picture', `${o.name} has no ${pick} picture${have.length ? ` · it has: ${have.join(', ')}` : ' yet'}`);
    }
    const p = await this.ofRef(u.studioId, ref as ImageRef);
    if (!p) throw new ApiError(409, 'not_ready', `${o.name}'s ${pick} picture isn't stored yet`);
    return { url: p.url, fileName: fileNameFor({ title: `${o.name} ${pick}`, id: o.id, ext: extOf(p.key, p.contentType, 'jpg') }), what: `${o.name}'s ${pick} picture (outfit ${o.id})`,
      ...(p.contentType ? { contentType: p.contentType } : {}), ...(p.bytes ? { bytes: p.bytes } : {}) };
  }

  /** What Claude named → the file to save (exactly one of takeId, uploadId, outfitId). */
  async source(u: Pick<AuthUser, 'studioId'>, a: Record<string, unknown>): Promise<Source> {
    const id = (k: string) => (typeof a[k] === 'string' && (a[k] as string).trim() ? (a[k] as string).trim() : '');
    const given = (['takeId', 'uploadId', 'outfitId'] as const).filter(k => id(k));
    if (given.length !== 1) throw badRequest('Name one file: takeId (a take\'s video or photo), uploadId, or outfitId (+ picture)');
    const k = given[0]!, v = id(k);
    if (!/^[A-Za-z0-9_-]{1,80}$/.test(v)) throw badRequest(`${k}: an id`);
    return k === 'takeId' ? this.take(u, v) : k === 'uploadId' ? this.upload(u, v) : this.outfit(u, v, a.picture);
  }
}

const services = new WeakMap<Ctx, SaveToMac>();
export const saveToMacOf = (ctx: Ctx) => { let s = services.get(ctx); if (!s) { s = new SaveToMac(ctx); services.set(ctx, s); } return s; };

/** save_to_mac (owner and members): a studio file saved to the person's Mac, after they approve (or into an allowed folder). */
export const SAVE_TOOL = {
  name: 'save_to_mac', scope: 'edit:read', title: 'Save a file to this Mac (asks first)',
  description: 'Free. Saves a studio file to the person\'s Mac in original quality so you can work on it locally (ffmpeg, scripts, other apps): a take\'s video or photo (takeId), an upload (uploadId), or a saved outfit\'s full-size picture (outfitId + picture: front (default), threeQuarter, side, back, face, faceThreeQuarter, profile). '
    + `folder: where on the Mac (default ${DEFAULT_SAVE_FOLDER}); the Mac saves only into Downloads, Desktop, Documents, Movies, Pictures, ~/MUSE or a folder the person always allowed, and never over another file (a second copy is "name (2).mp4"). `
    + 'The person approves a card ("Save … to …?") unless that folder is always allowed. Answers within 40 s: {status: "done", path, bytes} (use path with your file and shell tools), {status: "failed", error}, or {status: "waiting_for_approval" | "downloading", saveTicket, percent?, message}: then call save_to_mac {saveTicket} again (each call waits up to 40 s) until done, and tell the person what the message says.',
  inputSchema: { type: 'object', properties: {
    takeId: { type: 'string', maxLength: 80, description: 'A take (Suite feed, Library, an edited version): its video, or a photo\'s still' },
    uploadId: { type: 'string', maxLength: 80, description: 'An upload (an attached image or video, a sound)' },
    outfitId: { type: 'string', maxLength: 80, description: 'A saved outfit' },
    picture: { type: 'string', enum: [...OUTFIT_PICTURES], description: 'With outfitId: which picture (default front)' },
    folder: { type: 'string', maxLength: 512, description: `A folder on the Mac, absolute or ~/… (default ${DEFAULT_SAVE_FOLDER})` },
    saveTicket: { type: 'string', maxLength: 120, description: 'To follow a save already asked for' },
  }, additionalProperties: false },
  run: async (env: { ctx: Ctx; user: AuthUser }, a: Record<string, unknown>) => {
    const hub = permissionsOf(env.ctx);
    const ticket = typeof a.saveTicket === 'string' ? a.saveTicket.trim() : '';
    if (ticket) return { mcpContent: [{ type: 'text', text: JSON.stringify(await hub.uploadStatus(env.user, ticket)) }] };
    const folder = saveFolder(a.folder);
    const src = await saveToMacOf(env.ctx).source(env.user, a);
    const out = await hub.save(env.user, { ...src, folder });
    return { mcpContent: [{ type: 'text', text: JSON.stringify(out) }], structuredContent: out };
  },
};
