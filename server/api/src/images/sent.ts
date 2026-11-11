// Images sent (owner, 2026-11-11): "When working with Claude, it should also be able to control what images go to a model
// outside MUSE's normal function." MUSE picks the images a generation sends by itself (face, face ¾ or profile, a body
// angle, the outfit, products and references, ranked and cut to the model's limit). Every image-taking generation also
// takes an explicit choice that Claude or the person can set:
//   sentImages: [{image, role, label?}]  REPLACES the automatic list (order kept);
//   addImages / excludeImages            add to / drop from the automatic list;
//   sentImages: null                     back to automatic.
// `image` is an image of this studio (an ImageRef of ours), an upload id, or a take's frame {takeId, at?}. Outside links
// and other studios' images are refused. Too many for the model is refused in plain words, never cut silently.
// Every estimate returns `sentImages` (what would be sent, automatic or changed, each with why) for Claude and the apps.
import { execFile } from 'node:child_process';
import { and, eq } from 'drizzle-orm';
import { z } from 'zod';
import type { AuthUser, Ctx } from '../ctx.js';
import { takes, uploads, type ImageRef } from '../db/schema.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { putObject } from '../storage/objects.js';
import type { ShootGuide } from '../prompt/engine.js';

export const SENT_ROLES = ['person', 'outfit', 'product', 'location', 'style', 'pose', 'other'] as const;
export type SentRole = (typeof SENT_ROLES)[number];
/** One image a generation sends, as estimates show it. `guides`: how a reference image is used in a photo prompt. */
export type SentImage = { image: ImageRef; role: SentRole; label: string; why: string; guides?: ShootGuide[] };
/** What an estimate returns: the images in the order sent, whether they differ from MUSE's own pick, and the limit. */
export type SentView = { images: SentImage[]; changed: boolean; changedBy?: 'claude' | 'person'; max?: number; note?: string };

const ID = z.string().regex(/^[A-Za-z0-9_-]{1,80}$/, 'an upload id');
const RefIn = z.object({ asset: z.string().max(80).optional(), url: z.string().max(2000).optional() }).refine(v => !!v.asset || !!v.url, 'an image needs asset or url');
const TakeFrame = z.object({ takeId: ID, at: z.number().min(0).max(3600).optional() }).strict();
/** An image as Claude or an app names it: one of ours, an upload id, or a take's frame. */
export const ImageInSchema = z.union([RefIn, ID, TakeFrame]);
export const SentImageInSchema = z.object({ image: ImageInSchema, role: z.enum(SENT_ROLES).default('other'), label: z.string().trim().max(60).optional() }).strict();
export type SentImageIn = z.infer<typeof SentImageInSchema>;
/** The request fields (spread into each route's body schema). */
export const SENT_FIELDS = {
  sentImages: z.array(SentImageInSchema).max(16).nullable().optional(),
  addImages: z.array(SentImageInSchema).max(8).optional(),
  excludeImages: z.array(ImageInSchema).max(16).optional(),
  /** Who changed them (the app's "Changed by Claude" tag). */
  sentImagesBy: z.enum(['claude', 'person']).optional(),
};
export const SentInputSchema = z.object(SENT_FIELDS).strict();
export type SentInput = z.infer<typeof SentInputSchema>;
/** A choice resolved to studio images: `list` replaces; else `add` / `exclude` adjust MUSE's pick. `reset`: automatic. */
export type Resolved = { list?: SentImage[]; add: SentImage[]; exclude: ImageRef[]; by: 'claude' | 'person'; reset?: boolean };

const ROLE_WORDS: Record<SentRole, string> = { person: 'her', outfit: 'outfit', product: 'product', location: 'location', style: 'style', pose: 'pose', other: 'reference' };
/** Whether a choice says anything (null = back to automatic counts: it overrides a stored choice). */
export const hasSent = (b: Partial<SentInput> | null | undefined) => !!b && (b.sentImages !== undefined || !!b.addImages?.length || !!b.excludeImages?.length);
/** The fields of a body that make the choice (the rest of the body is left alone). */
export function sentOfBody(b: unknown): SentInput | null {
  const o = (b ?? {}) as Record<string, unknown>;
  if (!('sentImages' in o) && !('addImages' in o) && !('excludeImages' in o)) return null;
  const p = SentInputSchema.safeParse({ sentImages: o.sentImages, addImages: o.addImages, excludeImages: o.excludeImages, sentImagesBy: o.sentImagesBy });
  if (!p.success) throw badRequest(`Invalid images: ${p.error.issues[0]?.path.join('.')} ${p.error.issues[0]?.message}`);
  return p.data;
}

/** The storage key of one of our image links ("…/uploads/<key>"). */
const keyOf = (url?: string) => (url ? /\/uploads\/([A-Za-z0-9][A-Za-z0-9._/-]*)$/.exec(url)?.[1] ?? null : null);
/** The same image (bundled still, or the same stored object, whatever host the link names). */
export function sameImage(a: ImageRef | null | undefined, b: ImageRef | null | undefined) {
  if (!a || !b) return false;
  if (a.asset || b.asset) return !!a.asset && a.asset === b.asset;
  const ka = keyOf(a.url), kb = keyOf(b.url);
  return ka && kb ? ka === kb : !!a.url && a.url === b.url;
}

export type SentPage = 'photo' | 'outfit' | 'fill_angles';
type Estimator = (u: AuthUser, body: Record<string, unknown>) => Promise<SentView | null>;

export class SentImages {
  constructor(private ctx: Ctx) {}
  /** What a page's generation would send (set by the routes; Claude's get_sent_images). */
  estimators: Partial<Record<SentPage, Estimator>> = {};
  private url(key: string) { return `${this.ctx.config.PUBLIC_URL ?? ''}/uploads/${key}`; }

  /** One image as named, checked to be this studio's. */
  async image(studioId: string, x: z.infer<typeof ImageInSchema>): Promise<ImageRef> {
    if (typeof x === 'string') {
      const [up] = await this.ctx.db.select().from(uploads).where(and(eq(uploads.id, x), eq(uploads.studioId, studioId)));
      if (!up) throw notFound('Upload');
      if (!/^image\//i.test(up.contentType)) throw badRequest(`${x} is not an image`);
      return { url: this.url(up.storageKey) };
    }
    if ('takeId' in x) return this.takeFrame(studioId, x.takeId, x.at);
    if (x.asset) {
      const { ASSET_KEYS } = await import('./service.js');
      if (!ASSET_KEYS.includes(x.asset)) throw badRequest(`Unknown image ${x.asset}`);
      return { asset: x.asset };
    }
    const key = keyOf(x.url);
    if (!key) throw badRequest('Only images in this studio can be sent (an upload, a take, a character or outfit picture)');
    if (key.startsWith('assets/')) return { url: x.url };
    const [row] = await this.ctx.db.select({ id: uploads.id, ct: uploads.contentType }).from(uploads).where(and(eq(uploads.storageKey, key), eq(uploads.studioId, studioId)));
    if (!row) throw badRequest('That image isn’t in this studio');
    if (!/^image\//i.test(row.ct)) throw badRequest('That file is not an image');
    return { url: this.url(key) };
  }

  /** A take's picture: a photo as it is; a video's frame at `at` seconds (default its first), stored once. */
  async takeFrame(studioId: string, takeId: string, at?: number): Promise<ImageRef> {
    const [t] = await this.ctx.db.select().from(takes).where(and(eq(takes.id, takeId), eq(takes.studioId, studioId)));
    if (!t) throw notFound('Take');
    if (t.kind === 'shot') {
      if (!t.thumb) throw new ApiError(409, 'not_ready', `${takeId} has no picture yet`);
      return t.thumb as ImageRef;
    }
    if (!t.mediaKey) throw new ApiError(409, 'not_ready', `${takeId} has no video yet`);
    const ms = Math.round((at ?? 0) * 1000);
    const key = `g/frame_${takeId}_${ms}.jpg`;
    const [have] = await this.ctx.db.select({ id: uploads.id }).from(uploads).where(and(eq(uploads.storageKey, key), eq(uploads.studioId, studioId)));
    if (have) return { url: this.url(key) };
    const src = await this.ctx.storage.presignGet(t.mediaKey, 600);
    const jpg = await new Promise<Buffer>((resolve, reject) => {
      execFile(this.ctx.config.FFMPEG_PATH, ['-v', 'error', '-ss', (ms / 1000).toFixed(3), '-i', src, '-frames:v', '1', '-q:v', '2', '-f', 'image2', '-c:v', 'mjpeg', 'pipe:1'],
        { encoding: 'buffer', maxBuffer: 32 * 1024 * 1024, timeout: 60_000 }, (err, out) => (err || !out?.length ? reject(err ?? new Error('no frame')) : resolve(out)));
    }).catch(() => { throw new ApiError(422, 'no_frame', `Couldn’t take a frame from ${takeId} at ${ms / 1000} s`); });
    await putObject(this.ctx, { key, body: jpg, studioId, kind: 'generated', contentType: 'image/jpeg' });
    return { url: this.url(key) };
  }

  /** The choice with every image resolved and checked (studio scope). */
  async resolve(studioId: string, b: SentInput | null | undefined, by: 'claude' | 'person' = 'person'): Promise<Resolved | null> {
    if (!b || !hasSent(b)) return null;
    const who = b.sentImagesBy ?? by;
    const one = async (x: SentImageIn): Promise<SentImage> => ({ image: await this.image(studioId, x.image), role: x.role, label: x.label || ROLE_WORDS[x.role],
      why: who === 'claude' ? 'chosen by Claude' : 'chosen by you' });
    if (b.sentImages === null) return { add: [], exclude: [], by: who, reset: true };
    if (b.sentImages) return { list: await Promise.all(b.sentImages.map(one)), add: [], exclude: [], by: who };
    return { add: await Promise.all((b.addImages ?? []).map(one)), exclude: await Promise.all((b.excludeImages ?? []).map(x => this.image(studioId, x))), by: who };
  }

  // ---- Claude's choices for pages without a shared draft (outfit sheet, Fill angles), per person and target.
  // The Suite keeps its choice in the composer's draft. Kept in memory (a restart falls back to automatic, which the
  // estimate then shows); the app hears each change on the hub.
  private stored = new Map<string, { input: SentInput; at: number }>();
  private k(u: { studioId: string; id: string }, scope: string) { return `${u.studioId}:${u.id}:${scope}`; }
  storedFor(u: { studioId: string; id: string }, scope: string): SentInput | null {
    const v = this.stored.get(this.k(u, scope));
    if (!v || Date.now() - v.at > 12 * 3600_000) return null;
    return v.input;
  }
  store(u: { studioId: string; id: string }, scope: string, input: SentInput | null) {
    if (input && hasSent(input) && input.sentImages !== null) this.stored.set(this.k(u, scope), { input, at: Date.now() });
    else this.stored.delete(this.k(u, scope));
    if (this.stored.size > 2000) this.stored.delete(this.stored.keys().next().value!);
    this.ctx.hub.emit(u.studioId, x => (x.userId === u.id ? { type: 'sentImages', scope, sentImages: input && input.sentImages !== null ? input : null } : null));
  }
  /** A route's choice: the body's own (null = automatic) wins; else what Claude set for this page. */
  async forRequest(u: { studioId: string; id: string }, body: unknown, scope?: string): Promise<Resolved | null> {
    const own = sentOfBody(body);
    if (own) return this.resolve(u.studioId, own);
    // The Suite composer's draft carries Claude's (or the person's) choice (set_sent_images).
    const inDraft = sentOfBody((body as { draft?: { sent?: unknown } } | null)?.draft?.sent ?? null);
    if (inDraft) return this.resolve(u.studioId, inDraft);
    const kept = scope ? this.storedFor(u, scope) : null;
    return kept ? this.resolve(u.studioId, kept, 'claude') : null;
  }
}

/**
 * The images to send: MUSE's pick (`auto`, already within the model's limit), or the choice. Refuses more than `max`
 * ("This model takes up to N images"); nothing is dropped silently. `min`: the fewest the step works with.
 */
export function applySent(auto: SentImage[], r: Resolved | null | undefined, max: number, o: { min?: number; what?: string } = {}): SentView {
  if (!r || r.reset) return { images: auto, changed: false, max };
  const images = r.list ? r.list.map(x => ({ ...x, why: whyFrom(auto, x) }))
    : [...auto.filter(a => !r.exclude.some(e => sameImage(a.image, e))), ...r.add.filter(x => !auto.some(a => sameImage(a.image, x.image)) || r.exclude.some(e => sameImage(x.image, e)))];
  if (images.length > max) throw new ApiError(400, 'too_many_images', max <= 0 ? 'This model takes no images here' : `This model takes up to ${max} image${max === 1 ? '' : 's'}${o.what ? ` ${o.what}` : ''} · ${images.length} chosen`);
  if (o.min && images.length < o.min) throw new ApiError(400, 'too_few_images', `Send at least ${o.min} image${o.min === 1 ? '' : 's'} of her`);
  const changed = images.length !== auto.length || images.some((x, i) => !sameImage(x.image, auto[i]?.image) || x.role !== auto[i]?.role);
  return { images, changed, ...(changed ? { changedBy: r.by } : {}), max };
}
/** An override entry that is one of MUSE's own picks keeps MUSE's reason with who chose it. */
const whyFrom = (auto: SentImage[], x: SentImage) => { const a = auto.find(y => sameImage(y.image, x.image)); return a ? `${a.why} · ${x.why}` : x.why; };

/** The photo-prompt use of a reference: pose → pose & framing, style → look & colour, location → scene. */
export const guidesOf = (x: SentImage): ShootGuide[] | null =>
  x.guides?.length ? x.guides : x.role === 'pose' ? ['pose'] : x.role === 'style' ? ['look'] : x.role === 'location' ? ['scene'] : null;
export const roleOfGuides = (g: ShootGuide[]): SentRole => (g[0] === 'pose' ? 'pose' : g[0] === 'scene' ? 'location' : 'style');

/** Why MUSE picked one of her images (identity labels from images/identity.ts and the sheet labels of video refs). */
export function whyOf(label: string, role: string): string {
  const l = label.toLowerCase();
  if (l === 'face' || l === 'face, front') return 'her face, front · always sent first';
  if (l.includes('¾') && l.startsWith('face')) return 'her face from ¾';
  if (l.includes('profile')) return 'her face in profile';
  if (l.startsWith('outfit,')) return `the outfit from the ${l.slice(8)}`;
  if (l.startsWith('body')) return l === 'body' ? 'her figure (body shape and proportions)' : `her figure from the ${l.slice(6)}`;
  if (role === 'outfit' || l === 'outfit') return 'the outfit she wears (front)';
  if (role === 'product') return 'the product photo';
  return `your ${l || 'reference'}`;
}
/** A sheet label ("face, front", "outfit, ¾", "person 1 · body, front") as a role. */
export function roleOfLabel(label: string, fallback: SentRole = 'other'): SentRole {
  const l = label.replace(/^person \d+ · /, '');
  if (/^(face|body)/.test(l)) return 'person';
  if (/^outfit/.test(l)) return 'outfit';
  return fallback;
}

const services = new WeakMap<Ctx, SentImages>();
export const sentImagesOf = (ctx: Ctx) => { let s = services.get(ctx); if (!s) { s = new SentImages(ctx); services.set(ctx, s); } return s; };
