// App downloads for invite links: GET /get (a small public page), GET /download/{android|mac} (a short-lived link to the
// build in storage) and the owner-only PUT /v1/releases/{android|mac} that uploads a new build.
import type { Readable } from 'node:stream';
import type { FastifyInstance, FastifyReply } from 'fastify';
import type { Ctx } from '../ctx.js';
import { ApiError } from '../errors.js';

export type Platform = 'android' | 'mac';
export const RELEASES: Record<Platform, { key: string; filename: string; contentType: string; label: string }> = {
  android: { key: 'releases/android/latest.apk', filename: 'MUSE.apk', contentType: 'application/vnd.android.package-archive', label: 'Android' },
  mac: { key: 'releases/mac/MUSE-mac.zip', filename: 'MUSE-mac.zip', contentType: 'application/zip', label: 'Mac' },
};
const isPlatform = (p: string): p is Platform => p === 'android' || p === 'mac';

/** Download links live this long; the page links to /download/*, which always makes a fresh one. */
export const DOWNLOAD_TTL_SEC = 600;
/** Largest build the upload accepts. */
export const RELEASE_MAX_BYTES = 1024 ** 3;

/** The message the owner sends with an invite code (POST /v1/invites → shareText). */
export function inviteShareText(publicBase: string, code: string, email: string | null | undefined, days = 14) {
  const who = email ? ` (email: ${email})` : '';
  return `You're invited to MUSE, the AI model studio. 1) Download: ${publicBase}/get 2) Sign up with this invite code: ${code}${who}. ` +
    `The code works once and expires in ${days} ${days === 1 ? 'day' : 'days'}.`;
}

const esc = (s: string) => s.replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

// The Editorial theme (Android theme A) in light mode, Camera Body (theme B) in dark mode.
const STYLE = `
:root{--bg:#EFEBE3;--surface:#F8F5EF;--ink:#141210;--muted:#6E675E;--line:#CFC7BA;--accent:#B5121B;--cta:#141210;--cta-ink:#F8F5EF;--r:2px}
@media (prefers-color-scheme:dark){:root{--bg:#0D0E0F;--surface:#17191B;--ink:#ECEAE5;--muted:#A9A6A0;--line:#2C3033;--accent:#F2A93B;--cta:#F2A93B;--cta-ink:#1A1205;--r:10px}}
*{box-sizing:border-box}
html,body{margin:0;background:var(--bg);color:var(--ink)}
body{font:16px/1.5 Archivo,"Helvetica Neue",Arial,sans-serif;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px 16px}
main{width:100%;max-width:420px;background:var(--surface);border:1px solid var(--line);border-radius:var(--r);padding:32px 24px}
.kicker{font:600 12px/1 "IBM Plex Mono",ui-monospace,monospace;letter-spacing:.12em;text-transform:uppercase;color:var(--accent);margin:0 0 12px}
h1{font:400 44px/1.05 "Instrument Serif",Georgia,"Times New Roman",serif;margin:0 0 8px}
p{margin:0 0 20px;color:var(--muted)}
.btn{display:flex;align-items:center;justify-content:center;gap:10px;min-height:52px;margin:0 0 12px;padding:0 18px;border-radius:var(--r);
  background:var(--cta);color:var(--cta-ink);font-weight:600;text-decoration:none;border:1px solid var(--cta)}
.btn.alt{background:transparent;color:var(--ink);border-color:var(--line)}
.btn.off{opacity:.45;pointer-events:none}
.btn small{font-weight:400;opacity:.8}
.step{margin:20px 0 0;padding-top:16px;border-top:1px solid var(--line);color:var(--ink)}
.fine{font-size:13px;margin:12px 0 0}
`;

function page(title: string, body: string) {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark"><meta name="robots" content="noindex"><title>${esc(title)}</title>
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Archivo:wght@400;600&family=IBM+Plex+Mono:wght@600&family=Instrument+Serif&display=swap" rel="stylesheet">
<style>${STYLE}</style></head><body><main>${body}</main></body></html>`;
}

export function getPage(available: Record<Platform, boolean>) {
  const btn = (p: Platform, alt: boolean) => available[p]
    ? `<a class="btn${alt ? ' alt' : ''}" href="/download/${p}" download="${RELEASES[p].filename}">Download for ${RELEASES[p].label}</a>`
    : `<span class="btn alt off" aria-disabled="true">Download for ${RELEASES[p].label} <small>· coming soon</small></span>`;
  return page('Get MUSE', `<p class="kicker">MUSE · AI model studio</p><h1>Get MUSE</h1>
<p>Install the app on your phone or your Mac.</p>
${btn('android', false)}
${btn('mac', true)}
<p class="step">Then sign up with the invite code you were sent.</p>
<p class="fine">Android: if your phone asks, allow installs from your browser. Mac: unzip, then move MUSE to Applications.</p>`);
}

function notFoundPage(p: Platform | null) {
  const what = p ? `The ${RELEASES[p].label} app` : 'That download';
  return page('Not available yet · MUSE', `<p class="kicker">MUSE</p><h1>Not here yet</h1>
<p>${what} isn't available to download yet. Ask the studio owner, or try again later.</p>
<a class="btn alt" href="/get">Back to Get MUSE</a>`);
}

const html = (reply: FastifyReply, status: number, body: string) =>
  reply.status(status).header('content-type', 'text/html; charset=utf-8').header('cache-control', 'no-store').send(body);

export async function registerReleaseRoutes(app: FastifyInstance, ctx: Ctx) {
  const exists = async (p: Platform) => {
    try { return !!(await ctx.storage.head(RELEASES[p].key)); } catch (e) {
      ctx.log.warn({ err: (e as Error).message }, 'release check failed');
      return true; // let /download/* say so if it's really missing
    }
  };

  app.get('/get', { config: { public: true } }, async (_req, reply) => {
    const [android, mac] = await Promise.all([exists('android'), exists('mac')]);
    return html(reply, 200, getPage({ android, mac }));
  });

  app.get<{ Params: { platform: string } }>('/download/:platform', { config: { public: true } }, async (req, reply) => {
    const p = req.params.platform;
    if (!isPlatform(p)) return html(reply, 404, notFoundPage(null));
    const r = RELEASES[p];
    const head = await ctx.storage.head(r.key);
    if (!head) return html(reply, 404, notFoundPage(p));
    if (ctx.storage.kind === 's3') {
      const url = await ctx.storage.presignGet(r.key, DOWNLOAD_TTL_SEC, { filename: r.filename, contentType: r.contentType });
      return reply.header('cache-control', 'no-store').redirect(url, 302);
    }
    const obj = await ctx.storage.get(r.key);
    if (!obj) return html(reply, 404, notFoundPage(p));
    reply.header('content-type', r.contentType).header('content-disposition', `attachment; filename="${r.filename}"`).header('cache-control', 'no-store');
    if (obj.size != null) reply.header('content-length', obj.size);
    return reply.send(obj.body);
  });

  // Owner-only upload of a new build. The body is the raw file (any content type), streamed straight to storage.
  await app.register(async scoped => {
    scoped.removeAllContentTypeParsers();
    scoped.addContentTypeParser('*', (_req, payload, done) => done(null, payload));
    scoped.put<{ Params: { platform: string } }>('/v1/releases/:platform', { config: { owner: true } }, async req => {
      const p = req.params.platform;
      if (!isPlatform(p)) throw new ApiError(404, 'not_found', 'Platform must be android or mac');
      const bytes = Number(req.headers['content-length']);
      if (!Number.isFinite(bytes) || bytes <= 0) throw new ApiError(411, 'length_required', 'Send the file as the request body with a Content-Length (curl --data-binary @file)');
      if (bytes > RELEASE_MAX_BYTES) throw new ApiError(413, 'too_large', 'That build is too large');
      const r = RELEASES[p];
      await ctx.storage.putStream(r.key, req.body as Readable, r.contentType, bytes);
      const head = await ctx.storage.head(r.key);
      if (!head || head.size !== bytes) throw new ApiError(400, 'upload_failed', 'The upload was cut off · try again');
      req.log.info({ platform: p, bytes }, 'release uploaded');
      return { platform: p, key: r.key, bytes, filename: r.filename, downloadUrl: `${ctx.publicBase()}/download/${p}`, pageUrl: `${ctx.publicBase()}/get` };
    });
  });
}
