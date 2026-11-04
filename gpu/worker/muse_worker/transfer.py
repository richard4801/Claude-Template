"""Downloads from presigned GET URLs and uploads to presigned PUT URLs, both verified.

The tests lost uploads silently more than once (plans/video-test-results.md §5), so every
transfer is checked: downloads by Content-Length plus the size/sha256 the API sends,
uploads by the ETag (R2/S3 return the MD5 of a single PUT body).
"""

from __future__ import annotations

import hashlib
import http.client
import logging
import mimetypes
import os
import re
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from . import __version__
from .log import safe_url

log = logging.getLogger("muse.transfer")
CHUNK = 1 << 20
_SAFE = re.compile(r"[^A-Za-z0-9._-]")


class TransferError(Exception):
    def __init__(self, message: str, retryable: bool = True):
        super().__init__(message)
        self.retryable = retryable


class _Mismatch(Exception):
    pass


@dataclass
class FileInfo:
    bytes: int
    sha256: str
    md5: str


def safe_name(name: str) -> str:
    """Turn an API-supplied file name into a plain local file name (no paths, no dot-files)."""
    base = os.path.basename(str(name).replace("\\", "/"))
    base = _SAFE.sub("_", base)
    if not base or base.startswith(".") or base in ("_",):
        raise ValueError(f"unusable file name {name!r}")
    return base


def file_info(path: Path) -> FileInfo:
    sha, md5, size = hashlib.sha256(), hashlib.md5(), 0
    with open(path, "rb") as f:
        while chunk := f.read(CHUNK):
            sha.update(chunk)
            md5.update(chunk)
            size += len(chunk)
    return FileInfo(size, sha.hexdigest(), md5.hexdigest())


def _download_once(url: str, part: Path, timeout: float, should_abort: Callable[[], bool] | None) -> FileInfo:
    req = urllib.request.Request(url, headers={"User-Agent": f"muse-worker/{__version__}"})
    sha, md5, size = hashlib.sha256(), hashlib.md5(), 0
    with urllib.request.urlopen(req, timeout=timeout) as resp, open(part, "wb") as out:
        expected = resp.headers.get("Content-Length")
        while chunk := resp.read(CHUNK):
            if should_abort and should_abort():
                raise TransferError("download aborted", retryable=True)
            out.write(chunk)
            sha.update(chunk)
            md5.update(chunk)
            size += len(chunk)
    if expected is not None and int(expected) != size:
        raise ConnectionError(f"truncated download: got {size} of {expected} bytes")
    return FileInfo(size, sha.hexdigest(), md5.hexdigest())


def download(
    url: str,
    dest: Path,
    *,
    expected_bytes: int | None = None,
    expected_sha256: str | None = None,
    attempts: int = 3,
    timeout: float = 60.0,
    backoff: float = 1.0,
    should_abort: Callable[[], bool] | None = None,
) -> FileInfo:
    dest = Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_name(dest.name + ".part")
    last: Exception | None = None
    mismatch = False
    for attempt in range(1, attempts + 1):
        try:
            info = _download_once(url, part, timeout, should_abort)
            if expected_bytes is not None and info.bytes != int(expected_bytes):
                raise _Mismatch(f"size {info.bytes} != expected {expected_bytes}")
            if expected_sha256 and info.sha256 != expected_sha256.lower():
                raise _Mismatch(f"sha256 {info.sha256[:12]}… != expected {expected_sha256[:12]}…")
            os.replace(part, dest)
            return info
        except TransferError:
            raise
        except _Mismatch as e:
            last, mismatch = e, True
        except urllib.error.HTTPError as e:
            last, mismatch = e, False
            if 400 <= e.code < 500 and e.code not in (408, 429):
                # An expired or wrong presigned URL won't fix itself; a retried job gets a fresh one.
                part.unlink(missing_ok=True)
                raise TransferError(f"download {safe_url(url)}: HTTP {e.code}", retryable=True) from None
        except (urllib.error.URLError, http.client.HTTPException, OSError) as e:
            last, mismatch = e, False
        part.unlink(missing_ok=True)
        log.warning("download %s attempt %d/%d failed: %s", safe_url(url), attempt, attempts, last)
        if attempt < attempts:
            time.sleep(backoff * 2 ** (attempt - 1))
    # A checksum that is still wrong after several clean downloads means the stored file is bad.
    raise TransferError(f"download {safe_url(url)} failed: {last}", retryable=not mismatch)


def upload(
    path: Path,
    url: str,
    *,
    headers: dict[str, str] | None = None,
    attempts: int = 3,
    timeout: float = 300.0,
    backoff: float = 1.0,
) -> FileInfo:
    path = Path(path)
    info = file_info(path)
    hdrs = {"Content-Length": str(info.bytes), "User-Agent": f"muse-worker/{__version__}"}
    if not headers or not any(k.lower() == "content-type" for k in headers):
        hdrs["Content-Type"] = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    hdrs.update(headers or {})
    last: Exception | None = None
    for attempt in range(1, attempts + 1):
        try:
            with open(path, "rb") as body:
                req = urllib.request.Request(url, data=body, method="PUT", headers=hdrs)
                with urllib.request.urlopen(req, timeout=timeout) as resp:
                    resp.read()
                    etag = (resp.headers.get("ETag") or "").strip().strip('"').lower()
            if re.fullmatch(r"[0-9a-f]{32}", etag) and etag != info.md5:
                raise _Mismatch(f"ETag {etag} != local md5 {info.md5}")
            if not etag:
                log.info("upload %s: no ETag returned, relying on sha256 in the done report", safe_url(url))
            return info
        except urllib.error.HTTPError as e:
            last = e
            if 400 <= e.code < 500 and e.code not in (408, 429):
                raise TransferError(f"upload {safe_url(url)}: HTTP {e.code}", retryable=True) from None
        except (_Mismatch, urllib.error.URLError, http.client.HTTPException, OSError) as e:
            last = e
        log.warning("upload %s attempt %d/%d failed: %s", safe_url(url), attempt, attempts, last)
        if attempt < attempts:
            time.sleep(backoff * 2 ** (attempt - 1))
    raise TransferError(f"upload {safe_url(url)} failed: {last}", retryable=True)
