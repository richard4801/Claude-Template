"""Smaller pieces: transfers, progress coalescing, log redaction, config."""

import hashlib
import io
import logging
import time

import pytest

from muse_worker.api import ApiError, JobGone
from muse_worker.config import Config, ConfigError
from muse_worker.log import RedactingFormatter, add_secret, safe_url
from muse_worker.progress import ProgressReporter
from muse_worker.transfer import TransferError, download, upload


def test_download_verifies_and_upload_checks_etag(api, tmp_path):
    data = b"x" * 3_000_000
    api.blobs["k/file.bin"] = data
    sha = hashlib.sha256(data).hexdigest()
    info = download(f"{api.url}/blobs/k/file.bin?sig=1", tmp_path / "f.bin", expected_bytes=len(data),
                    expected_sha256=sha, backoff=0)
    assert info.sha256 == sha and (tmp_path / "f.bin").read_bytes() == data
    assert not (tmp_path / "f.bin.part").exists()
    with pytest.raises(TransferError) as e:
        download(f"{api.url}/blobs/k/file.bin", tmp_path / "g.bin", expected_bytes=5, backoff=0)
    assert e.value.retryable is False and not (tmp_path / "g.bin").exists()
    up = upload(tmp_path / "f.bin", f"{api.url}/uploads/out/f.bin?sig=1", backoff=0)
    assert api.uploads["out/f.bin"] == data and up.md5 == hashlib.md5(data).hexdigest()


def test_download_404_is_reported(api, tmp_path):
    with pytest.raises(TransferError):
        download(f"{api.url}/blobs/missing", tmp_path / "m", backoff=0)


def test_progress_reporter_coalesces_and_respects_interval():
    sent = []
    r = ProgressReporter(lambda p: sent.append((time.monotonic(), p)), min_interval=0.5)
    end = time.monotonic() + 1.2
    i = 0
    while time.monotonic() < end:
        i += 1
        r.update(step=i)
        time.sleep(0.005)
    r.close(flush=True)
    assert 2 <= len(sent) <= 4
    assert sent[-1][1]["step"] == i  # the newest state is never lost on flush
    assert all(b[0] - a[0] >= 0.49 for a, b in zip(sent, sent[1:]))


def test_progress_reporter_cancel_on_gone_or_flag():
    calls = []

    def send(p):
        if p["step"] == 2:
            raise JobGone("gone", 409)
        if p["step"] == 3:
            raise ApiError("flaky", 500)
        return {}

    r = ProgressReporter(send, min_interval=0.0, on_cancel=calls.append)
    for s in (1, 2, 3):
        r.update(step=s)
        time.sleep(0.05)
    r.close()
    assert calls == ["gone"]

    calls.clear()
    r = ProgressReporter(lambda p: {"cancel": True}, min_interval=0.0, on_cancel=calls.append)
    r.update(step=1)
    r.close()
    assert calls == ["api asked to cancel"]


def test_redaction_and_safe_url():
    add_secret("tok-123456")
    stream = io.StringIO()
    h = logging.StreamHandler(stream)
    h.setFormatter(RedactingFormatter("%(message)s"))
    lg = logging.getLogger("redact-test")
    lg.addHandler(h)
    lg.propagate = False
    lg.error("Authorization: Bearer %s", "tok-123456")
    try:
        raise RuntimeError("boom tok-123456")
    except RuntimeError:
        lg.exception("crash")
    assert "tok-123456" not in stream.getvalue() and "***" in stream.getvalue()
    assert safe_url("https://r2.example/b/k.mp4?X-Amz-Signature=abc") == "https://r2.example/b/k.mp4"


def test_config_from_env():
    with pytest.raises(ConfigError) as e:
        Config.from_env({})
    assert "MUSE_API_URL" in str(e.value)
    cfg = Config.from_env({"MUSE_API_URL": "https://api.example/", "WORKER_TOKEN": "t0ken", "RUNPOD_POD_ID": "abc",
                           "MUSE_PROGRESS_INTERVAL": "0.1"})
    assert cfg.api_url == "https://api.example" and cfg.pod_id == "abc"
    assert cfg.progress_interval == 0.5  # never faster than 2/s
    assert "t0ken" not in repr(cfg)
