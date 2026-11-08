// Recreate this edit · a reference from a link (workstream 1; the owner's decision in
// plans/research/platform-download-rules.md, "Keep link fetching"). Guardrails, all enforced here or in references.ts:
// - public videos only: no sign-ins or cookies, and nothing private, members-only or age-gated is fetched;
// - the creator's downloads-off setting is respected where the platform shows it (TikTok);
// - one fetch per request (the metadata is read once and reused for the download), no lists, no crawling;
// - cached by the normalized link; ≤ 60 s checked before the download; a size cap;
// - the file goes into the ordinary reference pipeline (private rx/ storage, deleted after 30 days).
// The resolver is yt-dlp, pinned in the Dockerfile. Tests replay recorded-shape fixtures through a fake binary.
import { execFile } from 'node:child_process';
import dns from 'node:dns/promises';
import fs from 'node:fs';
import path from 'node:path';
import { ApiError } from '../errors.js';

export type Platform = 'tiktok' | 'instagram' | 'youtube';
/** With "Strict link rules" off (the owner's setting), any public link yt-dlp reads is accepted: platform "other". */
export type AnyPlatform = Platform | 'other';
export const FALLBACK = 'Couldn’t fetch this link — save the video and drop the file in';

/** What the apps show: every code but too_long ends in the same fallback (drop the saved file in). */
export type LinkErrorCode = 'link_unsupported' | 'link_private' | 'link_downloads_off' | 'link_too_big' | 'link_blocked' | 'too_long';
export const linkError = (code: LinkErrorCode, message: string, status = code === 'link_blocked' ? 502 : 422) => new ApiError(status, code, message);

/**
 * The canonical form of a TikTok, Instagram Reel or YouTube Short link (https, no tracking parameters), or a
 * link_unsupported error. Short links (vm.tiktok.com, youtu.be) keep their own form until the metadata names the video.
 */
export function normalizeLink(raw: string): { url: string; platform: Platform } {
  let u: URL;
  try { u = new URL(raw.trim()); } catch { throw linkError('link_unsupported', 'That isn’t a link MUSE can read'); }
  if (u.protocol !== 'https:' && u.protocol !== 'http:') throw linkError('link_unsupported', 'That isn’t a link MUSE can read');
  const host = u.hostname.toLowerCase().replace(/^(www|m)\./, '');
  const seg = u.pathname.split('/').filter(Boolean);
  if (host === 'tiktok.com') {
    const i = seg.indexOf('video');
    if (seg[0]?.startsWith('@') && i === 1 && /^\d{5,25}$/.test(seg[2] ?? '')) return { platform: 'tiktok', url: `https://www.tiktok.com/${seg[0].toLowerCase()}/video/${seg[2]}` };
  } else if ((host === 'vm.tiktok.com' || host === 'vt.tiktok.com') && /^[A-Za-z0-9]{5,20}$/.test(seg[0] ?? '') && seg.length === 1) {
    return { platform: 'tiktok', url: `https://${host}/${seg[0]}/` };
  } else if (host === 'instagram.com') {
    if (['reel', 'reels', 'p'].includes(seg[0] ?? '') && /^[A-Za-z0-9_-]{5,40}$/.test(seg[1] ?? '') && seg.length === 2) return { platform: 'instagram', url: `https://www.instagram.com/reel/${seg[1]}/` };
  } else if (host === 'youtube.com') {
    if (seg[0] === 'shorts' && /^[A-Za-z0-9_-]{11}$/.test(seg[1] ?? '')) return { platform: 'youtube', url: `https://www.youtube.com/shorts/${seg[1]}` };
    const v = u.searchParams.get('v');
    if (seg[0] === 'watch' && v && /^[A-Za-z0-9_-]{11}$/.test(v)) return { platform: 'youtube', url: `https://www.youtube.com/watch?v=${v}` };
  } else if (host === 'youtu.be' && /^[A-Za-z0-9_-]{11}$/.test(seg[0] ?? '')) {
    return { platform: 'youtube', url: `https://www.youtube.com/watch?v=${seg[0]}` };
  }
  throw linkError('link_unsupported', 'MUSE can fetch TikTok, Instagram Reel and YouTube Shorts links. For anything else, save the video and drop the file in');
}

/**
 * A link under the studio's rules: strict (the default) takes only TikTok, Instagram Reels and YouTube; with strict
 * off, any other public web link too (https or http on the standard ports, a public host name: no addresses, no
 * localhost or internal names, so the server can't be pointed at its own network), without tracking parameters.
 */
export function linkFor(raw: string, o: { strict: boolean }): { url: string; platform: AnyPlatform } {
  try { return normalizeLink(raw); } catch (e) { if (o.strict) throw e; }
  let u: URL;
  try { u = new URL(raw.trim()); } catch { throw linkError('link_unsupported', 'That isn’t a link MUSE can read'); }
  if ((u.protocol !== 'https:' && u.protocol !== 'http:') || u.username || u.password || (u.port && u.port !== '443' && u.port !== '80'))
    throw linkError('link_unsupported', 'That isn’t a link MUSE can read');
  const host = u.hostname.toLowerCase().replace(/\.$/, '');
  const ip = /^\d{1,3}(\.\d{1,3}){3}$/.test(host) || host.includes(':') || /^\[/.test(host);
  const internal = !host.includes('.') || /(^|\.)(localhost|local|internal|intranet|lan|home|corp|localdomain|test|invalid|example)$/.test(host) || /\.railway\.internal$/.test(host);
  if (ip || internal) throw linkError('link_unsupported', 'MUSE only fetches public web links');
  u.hash = '';
  for (const k of [...u.searchParams.keys()]) if (/^(utm_|fbclid|gclid|igsh|si$|feature$|ref$|_r$)/i.test(k)) u.searchParams.delete(k);
  return { url: u.toString(), platform: 'other' };
}

/** The fields of yt-dlp's info JSON this file reads. */
export type LinkInfo = {
  _type?: string; id?: string; title?: string; webpage_url?: string; extractor_key?: string; duration?: number | null;
  availability?: string | null; age_limit?: number | null; is_live?: boolean | null; live_status?: string | null;
  filesize?: number | null; filesize_approx?: number | null; uploader?: string | null; width?: number | null; height?: number | null;
  requested_formats?: { filesize?: number | null; filesize_approx?: number | null }[];
};

/** What the metadata alone refuses: lists, live streams, anything not public, age-gated, too long, too big. */
export function checkInfo(info: LinkInfo, o: { maxSec: number; maxBytes: number; what?: string }) {
  if (info._type === 'playlist' || info._type === 'multi_video') throw linkError('link_unsupported', 'That link is a list of videos: paste the link of one video');
  if (info.is_live || ['is_live', 'is_upcoming', 'post_live'].includes(info.live_status ?? '')) throw linkError('link_unsupported', 'MUSE can’t fetch a live stream');
  if (info.availability && info.availability !== 'public' && info.availability !== 'unlisted')
    throw linkError('link_private', 'This video isn’t public, so MUSE won’t fetch it. Save it yourself and drop the file in');
  if ((info.age_limit ?? 0) > 0) throw linkError('link_private', 'This video is age-restricted, so MUSE won’t fetch it. Save it yourself and drop the file in');
  if (info.duration != null && info.duration > o.maxSec + 0.5) throw linkError('too_long', `${o.what ?? 'References'} can be up to ${o.maxSec} s for now (this one is ${Math.round(info.duration)} s)`, 400);
  const size = info.filesize ?? info.filesize_approx ?? (info.requested_formats?.length ? info.requested_formats.reduce((a, f) => a + (f.filesize ?? f.filesize_approx ?? 0), 0) || null : null);
  if (size != null && size > o.maxBytes) throw linkError('link_too_big', `This video is too big to fetch (${Math.round(size / 1048576)} MB; the limit is ${Math.round(o.maxBytes / 1048576)} MB)`);
}

/**
 * TikTok's downloads setting from the video's public page (the item's own setting and its author's): true = the creator
 * turned downloads off; false = on; null = the page doesn't say. 0 is "everyone"; any other value or an explicit
 * false counts as off.
 */
export function tiktokDownloadsOff(html: string): boolean | null {
  const m = /<script[^>]+id="__UNIVERSAL_DATA_FOR_REHYDRATION__"[^>]*>([\s\S]*?)<\/script>/.exec(html);
  if (!m) return null;
  let data: any;
  try { data = JSON.parse(m[1]!); } catch { return null; }
  const item = data?.__DEFAULT_SCOPE__?.['webapp.video-detail']?.itemInfo?.itemStruct;
  if (!item) return null;
  const flags: unknown[] = [item.downloadSetting, item.author?.downloadSetting, item.itemControl?.can_download, item.video_control?.allow_download, item.allowDownload];
  const known = flags.filter(f => f !== undefined && f !== null);
  if (!known.length) return null;
  return known.some(f => f === false || (typeof f === 'number' && f !== 0));
}

/** The host's addresses are all public (a public name can still point inside: checked right before fetching). */
export async function assertPublicHost(url: string, lookup: (h: string) => Promise<{ address: string }[]> = h => dns.lookup(h, { all: true })) {
  const host = new URL(url).hostname;
  const addrs = await lookup(host).catch(() => { throw linkError('link_unsupported', 'MUSE couldn’t find that site'); });
  const priv = (a: string) => /^(10\.|127\.|0\.|169\.254\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)/.test(a)
    || /^(::1?$|f[cd]|fe[89ab]|::ffff:(10|127|169\.254|192\.168)\.)/i.test(a);
  if (!addrs.length || addrs.some(x => priv(x.address))) throw linkError('link_unsupported', 'MUSE only fetches public web links');
}

/** Why yt-dlp failed, in a word, for the server log (never the link): the platform's wall, not the user's mistake. */
export type LinkFailure = 'bot_check' | 'login' | 'rate_limited' | 'forbidden' | 'not_found' | 'geo' | 'timeout' | 'private' | 'age' | 'too_big' | 'unsupported' | 'no_ytdlp' | 'other';
export function failureOf(stderr: string): LinkFailure {
  const s = stderr.toLowerCase();
  if (/not a bot|confirm you.?re not a robot|captcha/.test(s)) return 'bot_check';
  if (/unsupported url/.test(s)) return 'unsupported';
  if (/age[- ]restricted|confirm your age|inappropriate for some users|age limit/.test(s)) return 'age';
  if (/private|members[- ]only|subscriber|join this channel|premium/.test(s)) return 'private';
  if (/429|too many requests|rate[- ]limit/.test(s)) return 'rate_limited';
  if (/sign in|log ?in|login required|cookies/.test(s)) return 'login';
  if (/403|forbidden/.test(s)) return 'forbidden';
  if (/not available in your country|geo[- ]?restrict/.test(s)) return 'geo';
  if (/404|not found|unavailable|removed|does not exist|deleted/.test(s)) return 'not_found';
  if (/max[- ]?filesize|larger than max-filesize|file is larger/.test(s)) return 'too_big';
  if (/timed out|timeout/.test(s)) return 'timeout';
  return 'other';
}

/** yt-dlp's error text → the code the apps show (private, sign-in and age walls are refusals; the rest is "blocked"). */
export function errorFor(stderr: string): ApiError {
  const e = errorCode(stderr);
  return Object.assign(e, { failure: failureOf(stderr) });
}
function errorCode(stderr: string): ApiError {
  const s = stderr.toLowerCase();
  if (/unsupported url/.test(s)) return linkError('link_unsupported', 'MUSE can’t fetch from that link. Save the video and drop the file in');
  if (/private|members[- ]only|subscriber|join this channel|premium/.test(s)) return linkError('link_private', 'This video isn’t public, so MUSE won’t fetch it. Save it yourself and drop the file in');
  if (/age[- ]restricted|confirm your age|inappropriate for some users|age limit/.test(s)) return linkError('link_private', 'This video is age-restricted, so MUSE won’t fetch it. Save it yourself and drop the file in');
  if (/max[- ]?filesize|larger than max-filesize|file is larger/.test(s)) return linkError('link_too_big', 'This video is too big to fetch');
  // Sign-in walls, 403s, rate limits, blocked server addresses, timeouts, removed videos.
  return linkError('link_blocked', FALLBACK);
}

/**
 * Flags that keep yt-dlp to one public video (no config files, no cookies, no cache, no lists), with the server's own
 * Node as its JavaScript runtime (YouTube needs one; only deno is on by default) and no code fetched at run time: the
 * yt-dlp-ejs scripts are pinned in the image next to yt-dlp.
 */
export const baseArgs = (node = process.execPath) => ['--ignore-config', '--no-cookies', '--no-cookies-from-browser', '--no-cache-dir', '--no-playlist', '--no-warnings',
  '--socket-timeout', '20', '--no-js-runtimes', '--js-runtimes', `node:${node}`, '--no-remote-components'];
export const BASE_ARGS = baseArgs();

export type Resolver = {
  /** The video's metadata (one request to the platform). */
  info(url: string): Promise<LinkInfo>;
  /** Downloads from metadata already read (`--load-info-json`: the page isn't fetched again) into `dir`; returns the file. */
  download(infoFile: string, dir: string, o: { maxBytes: number; ffmpeg: string }): Promise<string>;
};

function run(bin: string, args: string[], timeoutMs: number): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(bin, args, { timeout: timeoutMs, maxBuffer: 16 * 1024 * 1024, env: { PATH: process.env.PATH ?? '', HOME: process.env.TMPDIR ?? '/tmp', LANG: 'C.UTF-8' } }, (err, out, errOut) => {
      if (err) {
        const e = err as NodeJS.ErrnoException & { killed?: boolean };
        if (e.code === 'ENOENT') return reject(Object.assign(linkError('link_blocked', FALLBACK), { failure: 'no_ytdlp' }));
        return reject(errorFor(`${String(errOut ?? '')}\n${e.killed ? 'timed out' : ''}`));
      }
      resolve(String(out));
    });
  });
}

/** The yt-dlp resolver (the binary path from config; the environment is stripped so no user config or cookies leak in). */
export function ytDlp(bin: string): Resolver {
  return {
    async info(url) {
      const out = await run(bin, [...BASE_ARGS, '--skip-download', '--dump-single-json', '--', url], 60_000);
      try { return JSON.parse(out) as LinkInfo; } catch { throw linkError('link_blocked', FALLBACK); }
    },
    async download(infoFile, dir, o) {
      await run(bin, [...BASE_ARGS, '--no-part', '--no-mtime', '--max-filesize', String(o.maxBytes), '--ffmpeg-location', o.ffmpeg,
        '-f', 'b[height<=1080][ext=mp4]/bv*[height<=1080]+ba/b[height<=1080]/b', '--merge-output-format', 'mp4',
        '-o', path.join(dir, 'video.%(ext)s'), '--load-info-json', infoFile], 180_000);
      const f = fs.readdirSync(dir).find(n => n.startsWith('video.') && !n.endsWith('.json'));
      if (!f) throw linkError('link_blocked', FALLBACK);
      if (fs.statSync(path.join(dir, f)).size > o.maxBytes) throw linkError('link_too_big', 'This video is too big to fetch');
      return path.join(dir, f);
    },
  };
}
