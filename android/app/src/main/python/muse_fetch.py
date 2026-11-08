"""Recreate links fetched on the phone (WS4).

TikTok, Instagram and YouTube block the studio server, so the phone downloads the shared video itself with yt-dlp and
uploads it as an ordinary reference (with its sourceUrl). The same rules as the server: no cookies (signed out), at most
`max_sec` seconds and `max_bytes` bytes, one video (no playlists), and, when the owner's "Strict link rules" is on,
public videos only (not private, members-only, sign-in-walled or age-restricted). No ffmpeg: only formats that already
carry video and sound are picked.

fetch() returns JSON: {"ok": true, "path", "title", "durationSec", "id"} or {"ok": false, "code", "message"}.
Codes: too_long, link_too_big, link_private, link_downloads_off (rules; the caller doesn't retry elsewhere) and
fetch_failed (the caller falls back to the server, then to the saved file).

With `tiktok_refuse` (strict rules), a TikTok video whose creator turned downloads off is refused, read from its public
page exactly as the server reads it (server/api/src/recreate/links.ts tiktokDownloadsOff); a page that can't be read is
fetch_failed, so the phone never downloads a TikTok it couldn't check.
"""
import json
import os
import re

import yt_dlp


class _Quiet:
    def debug(self, msg): pass
    def info(self, msg): pass
    def warning(self, msg): pass
    def error(self, msg): pass


def _fail(code, message):
    return json.dumps({"ok": False, "code": code, "message": message})


def tiktok_downloads_off(html):
    """True: the creator turned downloads off; False: on; None: the page doesn't say."""
    m = re.search(r'<script[^>]+id="__UNIVERSAL_DATA_FOR_REHYDRATION__"[^>]*>([\s\S]*?)</script>', html)
    if not m:
        return None
    try:
        data = json.loads(m.group(1))
    except ValueError:
        return None
    item = (((data.get("__DEFAULT_SCOPE__") or {}).get("webapp.video-detail") or {}).get("itemInfo") or {}).get("itemStruct")
    if not item:
        return None
    flags = [item.get("downloadSetting"), (item.get("author") or {}).get("downloadSetting"),
             (item.get("itemControl") or {}).get("can_download"), (item.get("video_control") or {}).get("allow_download"),
             item.get("allowDownload")]
    known = [f for f in flags if f is not None]
    if not known:
        return None
    return any(f is False or (isinstance(f, (int, float)) and not isinstance(f, bool) and f != 0) for f in known)


def fetch(url, out_dir, max_sec, max_bytes, strict, tiktok_refuse=False, platform=""):
    fmt = "best[ext=mp4][vcodec!=none][acodec!=none]/best[vcodec!=none][acodec!=none]"
    opts = {
        "logger": _Quiet(), "quiet": True, "no_warnings": True, "noprogress": True,
        "noplaylist": True, "playlist_items": "1", "format": fmt,
        "outtmpl": os.path.join(out_dir, "link_%(id).40s.%(ext)s"),
        "max_filesize": int(max_bytes), "socket_timeout": 20, "retries": 2,
        "cachedir": False, "cookiefile": None, "nopart": True, "overwrites": True,
    }
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(url, download=False)
            if info is None:
                return _fail("fetch_failed", "Couldn't read this link")
            if info.get("_type") == "playlist":
                entries = [e for e in (info.get("entries") or []) if e]
                if not entries:
                    return _fail("fetch_failed", "There's no video at this link")
                info = entries[0]
            duration = info.get("duration")
            if duration is not None and float(duration) > float(max_sec) + 0.5:
                return _fail("too_long", "This video is longer than %d seconds · pick a shorter one" % int(max_sec))
            if strict:
                availability = info.get("availability")
                if availability not in (None, "public", "unlisted") or (info.get("age_limit") or 0) >= 18:
                    return _fail("link_private", "This video isn't public, so it can't be used")
            if tiktok_refuse and (platform == "tiktok" or "tiktok" in (info.get("extractor_key") or "").lower()):
                page_url = info.get("webpage_url") or url
                try:
                    html = ydl.urlopen(page_url).read().decode("utf-8", "replace")
                except Exception:
                    return _fail("fetch_failed", "Couldn't check this TikTok's download setting")
                off = tiktok_downloads_off(html)
                if off is None:
                    return _fail("fetch_failed", "Couldn't check this TikTok's download setting")
                if off:
                    return _fail("link_downloads_off", "The creator turned downloads off for this video, so MUSE won't fetch it. Use another video, or ask the creator")
            size = info.get("filesize") or info.get("filesize_approx")
            if size and int(size) > int(max_bytes):
                return _fail("link_too_big", "This video is too big to use")
            done = ydl.process_ie_result(info, download=True)
            path = None
            for d in (done.get("requested_downloads") or []):
                path = d.get("filepath") or path
            path = path or ydl.prepare_filename(done)
            if not path or not os.path.exists(path) or os.path.getsize(path) == 0:
                return _fail("fetch_failed", "Couldn't download this video")
            if os.path.getsize(path) > int(max_bytes):
                os.remove(path)
                return _fail("link_too_big", "This video is too big to use")
            return json.dumps({"ok": True, "path": path, "title": done.get("title") or "", "id": done.get("id") or "",
                               "durationSec": float(done.get("duration") or 0)})
    except yt_dlp.utils.DownloadError as e:
        text = str(e).lower()
        if any(w in text for w in ("private", "login", "log in", "sign in", "members", "age-restricted", "age restricted", "confirm your age")):
            return _fail("link_private", "This video isn't public, so it can't be used")
        if "larger than max-filesize" in text or "file is larger" in text:
            return _fail("link_too_big", "This video is too big to use")
        return _fail("fetch_failed", "Couldn't get this video on the phone")
    except Exception:
        return _fail("fetch_failed", "Couldn't get this video on the phone")
