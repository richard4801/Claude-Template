// The Edit suite's content library (plans/edit-content-licences.md): stickers, sound effects, fonts and in-house
// packs, built by scripts/editor-content.ts into assets/content/ with catalog.json. On start the files are copied into
// storage (content/<version>/<path>); the apps read the catalog and download each file on first use.
//   GET /v1/editor/content                 → the catalog
//   GET /v1/editor/content/files/<path>    → a file (public: open-licence content; a redirect on S3)
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { FastifyInstance } from 'fastify';
import type { Ctx } from '../ctx.js';
import { notFound } from '../errors.js';

export const CONTENT_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../assets/content');

export type PackKind = 'stickers' | 'sfx' | 'fonts' | 'looks' | 'captions' | 'transitions';
export type PackItem = { id: string; name: string; [k: string]: unknown };
export type Pack = { id: string; kind: PackKind; title: string; licence: string; attribution?: string; categories?: { id: string; label: string }[]; items: PackItem[] };
export type Catalog = { version: string; packs: Pack[] };

/** A project's reference to a catalog item: `content:<pack>/<item>`. */
export const CONTENT_REF = /^content:([a-z0-9-]+)\/([a-z0-9_.-]+)$/;

let cached: Catalog | null | undefined;
/** The bundled catalog (null when the content hasn't been built). */
export function catalog(): Catalog | null {
  if (cached === undefined) {
    const f = path.join(CONTENT_DIR, 'catalog.json');
    cached = fs.existsSync(f) ? JSON.parse(fs.readFileSync(f, 'utf8')) as Catalog : null;
  }
  return cached;
}
/** For tests: read the catalog again (or use [c]). */
export function resetCatalog(c?: Catalog | null) { cached = c === undefined ? undefined : c; }

/** The catalog item a `content:` ref names, or null. */
export function contentItem(ref: string): { pack: Pack; item: PackItem } | null {
  const m = CONTENT_REF.exec(ref);
  if (!m) return null;
  const pack = catalog()?.packs.find(p => p.id === m[1]);
  const item = pack?.items.find(i => i.id === m[2]);
  return pack && item ? { pack, item } : null;
}
/** The local file of a sticker or sound-effect ref (for the server render), or null. */
export function contentFile(ref: string): string | null {
  const f = contentItem(ref)?.item.file;
  return typeof f === 'string' ? path.join(CONTENT_DIR, f) : null;
}
/** A font family's file for a weight (400/700/900, nearest below), or null when the family isn't in the catalog. */
export function contentFont(family: string, weight: number): string | null {
  const it = catalog()?.packs.find(p => p.kind === 'fonts')?.items.find(i => i.id === family);
  const files = it?.files as Record<string, string> | undefined;
  if (!files) return null;
  const w = weight >= 900 ? '900' : weight >= 700 ? '700' : '400';
  return path.join(CONTENT_DIR, files[w] ?? files['400']!);
}

const TYPES: Record<string, string> = { '.png': 'image/png', '.m4a': 'audio/mp4', '.ttf': 'font/ttf', '.json': 'application/json', '.txt': 'text/plain; charset=utf-8' };
const typeOf = (f: string) => TYPES[path.extname(f)] ?? 'application/octet-stream';
const SAFE = /^[a-z0-9-]+(\/[A-Za-z0-9_.-]+)+$/;

/** Every file of the content dir, relative. */
function files(dir = CONTENT_DIR, base = ''): string[] {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap(e => e.isDirectory() ? files(path.join(dir, e.name), `${base}${e.name}/`) : [`${base}${e.name}`]);
}

/** Copies the content into storage under content/<version>/ (files already there are skipped). Returns how many it wrote. */
export async function seedContent(ctx: Ctx): Promise<number> {
  const c = catalog();
  if (!c) return 0;
  let n = 0;
  for (const f of files()) {
    const key = `content/${c.version}/${f}`;
    if (await ctx.storage.head(key)) continue;
    await ctx.storage.put(key, fs.readFileSync(path.join(CONTENT_DIR, f)), typeOf(f));
    n++;
  }
  return n;
}

export async function registerContentRoutes(app: FastifyInstance, ctx: Ctx) {
  // Copy into storage in the background; files are served from the bundle until they're there.
  if (!process.env.VITEST) void seedContent(ctx).then(n => { if (n) ctx.log.info({ files: n }, 'editor content copied to storage'); }).catch(e => ctx.log.warn({ err: (e as Error).message }, 'editor content copy failed'));

  app.get('/v1/editor/content', async (_req, reply) => {
    const c = catalog();
    if (!c) throw notFound('Content');
    return reply.header('cache-control', 'private, max-age=300').send(c);
  });

  app.get('/v1/editor/content/files/*', { config: { public: true } }, async (req, reply) => {
    const rel = (req.params as { '*': string })['*'];
    const c = catalog();
    if (!c || !SAFE.test(rel) || rel.includes('..')) throw notFound('Content file');
    const local = path.join(CONTENT_DIR, rel);
    if (!fs.existsSync(local)) throw notFound('Content file');
    const key = `content/${c.version}/${rel}`;
    // The catalog version as the ETag (also on the redirect), so a cached file can be checked without the catalog.
    if (ctx.storage.kind === 's3' && await ctx.storage.head(key)) return reply.header('etag', `"${c.version}"`).redirect(await ctx.storage.presignGet(key, 3600), 302);
    return reply.header('content-type', typeOf(rel)).header('etag', `"${c.version}"`).header('cache-control', 'public, max-age=86400').send(fs.createReadStream(local));
  });
}
