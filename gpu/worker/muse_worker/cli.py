"""Command line: `python -m muse_worker [--dry-run] [--self-test] ...`.

Real pod:   MUSE_API_URL, WORKER_TOKEN and POD_ID in the env (bootstrap.sh starts this).
Dry run:    a fake H3 backend (no torch, no GPU) against a real API, so the API side can be tested:
              WORKER_TOKEN=... python -m muse_worker --dry-run --api-url http://localhost:3000 --once
Self test:  dry run against a built-in fake API, then check the result:
              python -m muse_worker --self-test
"""

from __future__ import annotations

import argparse
import hashlib
import logging
import os
import socket
import sys
from pathlib import Path

from . import __version__
from .api import ApiClient
from .config import Config, ConfigError, detect_gpu_name
from .jobs import build_handlers
from .log import add_secret, setup_logging
from .worker import EXIT_CONFIG, Worker

log = logging.getLogger("muse")


def _parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="muse-worker", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true", help="fake H3 backend: no torch, no GPU, synthetic outputs")
    ap.add_argument("--self-test", action="store_true", help="dry run against a built-in fake API, then verify")
    ap.add_argument("--api-url", help="overrides MUSE_API_URL")
    ap.add_argument("--pod-id", help="overrides POD_ID")
    ap.add_argument("--once", action="store_true", help="exit after one job")
    ap.add_argument("--max-jobs", type=int, help="exit after N jobs")
    ap.add_argument("--step-seconds", type=float, default=0.5, help="dry run: seconds per fake step (default 0.5)")
    ap.add_argument("--no-fake-video", action="store_true", help="dry run: write placeholder bytes, not an MP4")
    ap.add_argument("--log-level", default=os.environ.get("MUSE_LOG_LEVEL", "INFO"))
    ap.add_argument("--version", action="version", version=f"muse-worker {__version__}")
    return ap


def _fake_backend(args):
    from .backends.fake_h3 import FakeH3Backend

    return FakeH3Backend(step_seconds=args.step_seconds, make_video=not args.no_fake_video)


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    setup_logging(args.log_level)
    if args.self_test:
        return self_test(args)

    env = dict(os.environ)
    if args.dry_run:
        env.setdefault("POD_ID", f"dry-run-{socket.gethostname()}")
        env.setdefault("WORKER_TOKEN", "dry-run-token")
    try:
        cfg = Config.from_env(env, api_url=args.api_url, pod_id=args.pod_id)
    except ConfigError as e:
        log.error("%s", e)
        return EXIT_CONFIG
    add_secret(cfg.token)
    add_secret(cfg.runpod_api_key)
    if args.once:
        cfg.max_jobs = 1
    elif args.max_jobs is not None:
        cfg.max_jobs = args.max_jobs

    if args.dry_run:
        cfg.gpu_name = cfg.gpu_name or "dry-run (no GPU)"
        handlers = build_handlers(_fake_backend(args), lipsync=False)
        log.info("DRY RUN: fake H3 backend, %.2fs per step, no GPU work", args.step_seconds)
    else:
        from .backends.diffsynth_h3 import DiffSynthH3Backend

        cfg.gpu_name = cfg.gpu_name or detect_gpu_name()
        handlers = build_handlers(DiffSynthH3Backend.from_env())
    code = Worker(cfg, ApiClient(cfg), handlers).run()
    # A job thread may still sit in a CUDA call after a SIGTERM (its failure is already reported).
    # Don't let interpreter teardown wait on it or on CUDA: flush the logs and leave.
    logging.shutdown()
    sys.stdout.flush()
    os._exit(code)


def self_test(args) -> int:
    from .devtools.fake_api import FakeApi

    with FakeApi(token="self-test-token") as api:
        job = api.add_job(params={"steps": 10, "use": "first", "takes": 1, "keepAudio": True},
                          outputs=["take1.mp4", "take1.jpg"])
        cfg = Config.from_env({"MUSE_API_URL": api.url, "WORKER_TOKEN": "self-test-token", "POD_ID": "self-test"},
                              heartbeat_interval=1.0, poll_interval=0.2, max_jobs=1,
                              work_dir=Path(os.environ.get("TMPDIR", "/tmp")) / "muse-self-test")
        cfg.gpu_name = "self-test"
        add_secret(cfg.token)
        code = Worker(cfg, ApiClient(cfg), build_handlers(_fake_backend(args), lipsync=False)).run()
        done = api.done.get(job["id"])
        problems = []
        if code != 0:
            problems.append(f"worker exit code {code}")
        if not done:
            problems.append(f"no done report (failed: {api.failed.get(job['id'])})")
        else:
            for o in done["outputs"]:
                blob = api.uploads.get(f"{job['id']}/{o['name']}")
                if blob is None or hashlib.sha256(blob).hexdigest() != o["sha256"] or len(blob) != o["bytes"]:
                    problems.append(f"upload {o['name']} does not match its sha256/bytes")
        steps = sorted({b.get("step") for _, b in api.progress_for(job["id"]) if b.get("phase") == "denoising"})
        if not api.heartbeats:
            problems.append("no heartbeats")
        print(f"self-test: {len(api.claims)} claim(s), {len(api.heartbeats)} heartbeat(s), "
              f"{len(api.progress_for(job['id']))} progress post(s) (denoising steps seen {steps}), "
              f"outputs {[(o['name'], o['bytes']) for o in (done or {}).get('outputs', [])]}")
        print("SELF-TEST " + ("PASSED" if not problems else "FAILED: " + "; ".join(problems)))
        return 0 if not problems else 1


if __name__ == "__main__":
    sys.exit(main())
