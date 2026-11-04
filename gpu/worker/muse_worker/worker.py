"""The worker loop: heartbeat, claim, download, run, progress, upload, done/failed, clean shutdown.

Threads:
  main       claims jobs, watches for SIGTERM, owns the shutdown decision
  heartbeat  posts {podId, busy} every 15 s, independent of the GPU
  job        downloads, runs the handler (GPU), uploads, reports
  progress   posts the newest progress at most twice a second

Between claims (never during a job or upload) the main thread also checks the dead-man's switch
(selfstop.py): idle too long, or the API unreachable too long while idle, and the pod terminates itself.
"""

from __future__ import annotations

import logging
import shutil
import signal
import threading
import time
from pathlib import Path

from .api import ApiClient, ApiError, AuthError, JobGone
from .config import Config
from .heartbeat import Heartbeat
from .jobs.base import Job, JobCancelled, JobContext, JobFailure, JobHandler
from .progress import ProgressReporter
from .selfstop import SelfStop
from .transfer import TransferError, download, safe_name, upload

log = logging.getLogger("muse.worker")

EXIT_OK, EXIT_CONFIG, EXIT_AUTH = 0, 2, 3
EXIT_SELF_STOP = 4  # the pod asked RunPod to terminate it; bootstrap.sh must not restart the worker
SHUTDOWN = "shutdown"


class ActiveJob:
    def __init__(self, raw: dict):
        self.raw = raw
        self.id = str(raw["id"]) if isinstance(raw, dict) and raw.get("id") else None
        self.kind = raw.get("kind") if isinstance(raw, dict) else None
        self.phase = "starting"
        self.cancel_event = threading.Event()
        self.cancel_reason = ""
        self.t0 = time.monotonic()
        self._report_lock = threading.Lock()
        self._reported = False

    def cancel(self, reason: str) -> None:
        if not self.cancel_event.is_set():
            self.cancel_reason = reason
            self.cancel_event.set()

    def claim_report(self) -> bool:
        """Exactly one final report (done or failed) per job, from whichever thread gets here first."""
        with self._report_lock:
            if self._reported:
                return False
            self._reported = True
            return True


def classify(exc: BaseException) -> tuple[str, bool]:
    """Error text and retryable flag for an unexpected exception from a handler."""
    name = type(exc).__name__
    text = f"{name}: {exc}"[:500]
    if "OutOfMemory" in name or "out of memory" in str(exc).lower():
        return f"GPU out of memory ({text}); try a shorter clip", False
    return text, True


class Worker:
    def __init__(self, cfg: Config, api: ApiClient, handlers: list[JobHandler], *, install_signals: bool = True,
                 selfstop: SelfStop | None = None):
        self.cfg = cfg
        self.api = api
        self.handlers = {h.kind: h for h in handlers}
        self.install_signals = install_signals
        self.stop_event = threading.Event()
        self.stop_reason = ""
        self.jobs_processed = 0
        self.current: ActiveJob | None = None
        self._preloading = 0
        self._heartbeat = Heartbeat(api, cfg.heartbeat_interval, self._status)
        self.selfstop = selfstop or SelfStop.from_config(cfg)
        self.idle_since = time.monotonic()  # worker start, then the end of each job
        self.self_stopped: str | None = None  # how the pod was terminated, once it was
        self._self_stop_next_try = 0.0

    # -- state ------------------------------------------------------------------------
    def capabilities(self) -> list[str]:
        caps = []
        for h in self.handlers.values():
            reason = h.availability()
            if reason is None:
                caps.append(h.capability)
        return caps

    def _status(self) -> dict:
        job = self.current
        if job is not None:
            return {"busy": True, "jobId": job.id, "state": job.phase}
        return {"busy": False, "state": "loading" if self._preloading else "idle"}

    def request_stop(self, reason: str = "requested") -> None:
        if not self.stop_event.is_set():
            self.stop_reason = reason
            log.info("stopping (%s)", reason)
            self.stop_event.set()

    def _on_signal(self, signum, _frame) -> None:
        if self.stop_event.is_set():
            log.warning("signal %s again while stopping; still finishing up", signal.Signals(signum).name)
            return
        self.request_stop(signal.Signals(signum).name)

    # -- main loop --------------------------------------------------------------------
    def run(self) -> int:
        if self.install_signals and threading.current_thread() is threading.main_thread():
            signal.signal(signal.SIGTERM, self._on_signal)
            signal.signal(signal.SIGINT, self._on_signal)
        self.cfg.work_dir.mkdir(parents=True, exist_ok=True)
        for kind, h in self.handlers.items():
            reason = h.availability()
            log.info("job kind %-10s %s", kind, "enabled" if reason is None else f"off: {reason}")
        caps = self.capabilities()
        log.info("worker up: api=%s pod=%s gpu=%s capabilities=%s", self.cfg.api_url, self.cfg.pod_id,
                 self.cfg.gpu_name, caps)
        log.info("self-stop %s", self.selfstop.describe())
        if self.cfg.preload:
            for h in self.handlers.values():
                if h.availability() is None:
                    threading.Thread(target=self._preload, args=(h,), name=f"preload-{h.kind}", daemon=True).start()
        self._heartbeat.start()
        code, backoff = EXIT_OK, self.cfg.poll_interval
        self.idle_since = time.monotonic()
        try:
            while not self.stop_event.is_set():
                if self.cfg.max_jobs is not None and self.jobs_processed >= self.cfg.max_jobs:
                    log.info("processed %d job(s); exiting", self.jobs_processed)
                    break
                if self._maybe_self_stop():
                    code = EXIT_SELF_STOP
                    break
                try:
                    raw = self.api.claim(self.cfg.gpu_name, caps)
                except AuthError as e:
                    log.error("the API rejected WORKER_TOKEN (%s); exiting", e)
                    code = EXIT_AUTH
                    break
                except ApiError as e:
                    log.warning("claim failed: %s; retrying in %.0fs", e, backoff)
                    self.stop_event.wait(backoff)
                    backoff = min(backoff * 2, 60.0)
                    continue
                backoff = self.cfg.poll_interval
                if raw is None:
                    self.stop_event.wait(self.cfg.poll_interval)
                    continue
                self._process(raw)
        finally:
            self._heartbeat.stop(final=self.self_stopped is None)
            log.info("worker stopped after %d job(s)%s", self.jobs_processed,
                     f" ({self.stop_reason})" if self.stop_reason else "")
        return code

    # -- dead-man's switch ---------------------------------------------------------------
    def _maybe_self_stop(self) -> bool:
        """Main thread, between claims only, so never during a job or an upload. True = the pod is being terminated."""
        now = time.monotonic()
        if now < self._self_stop_next_try:
            return False
        d = self.selfstop.check(busy=self.current is not None, idle_since=self.idle_since, api_last_ok=self.api.last_ok)
        if d is None:
            return False
        log.warning("SELF-STOP: %s and no job is running. Terminating RunPod pod %s so it stops billing "
                    "(the API would normally do this; it may be down).", d.describe(), self.selfstop.pod_id)
        self._heartbeat.stop(final=False)
        try:  # tell the API first, briefly; it then marks the pod stopped (and terminates it too)
            self.api.heartbeat(False, timeout=5.0, state="self-stopping", reason=d.reason)
            log.info("SELF-STOP: told the API (heartbeat state=self-stopping)")
        except ApiError as e:
            log.info("SELF-STOP: could not tell the API (%s); stopping anyway", e)
        method = self.selfstop.terminate()
        if method:
            self.self_stopped = method
            self.stop_reason = f"self-stop: {d.describe()}; pod terminated via {method}"
            log.warning("SELF-STOP: RunPod accepted the request (%s); exiting, the pod will disappear shortly", method)
            return True
        retry = max(self.cfg.self_stop_retry_seconds, 1.0)
        log.error("SELF-STOP FAILED: could not terminate pod %s; still serving jobs, trying again in %.0fs. "
                  "Terminate it by hand in the RunPod console if this keeps happening.", self.selfstop.pod_id, retry)
        self._self_stop_next_try = now + retry
        self._heartbeat = Heartbeat(self.api, self.cfg.heartbeat_interval, self._status)
        self._heartbeat.start()
        return False

    def _preload(self, h: JobHandler) -> None:
        self._preloading += 1
        try:
            h.prepare()
        except Exception as e:  # jobs will report the same reason
            log.error("preloading %s failed: %s", h.kind, e)
        finally:
            self._preloading -= 1

    def _process(self, raw: dict) -> None:
        active = ActiveJob(raw)
        self.current = active
        log.info("claimed job %s (%s)", active.id, active.kind)
        if self.stop_event.is_set():  # claimed just as SIGTERM arrived
            self._fail(active, "worker shutting down (pod stopped) before the job started", True)
            self.current = None
            return
        t = threading.Thread(target=self._execute, args=(active,), name=f"job-{active.id}", daemon=True)
        t.start()
        while t.is_alive():
            t.join(0.2)
            if self.stop_event.is_set():
                self._shutdown_during(active, t)
                break
        self.current = None
        self.idle_since = time.monotonic()
        self.jobs_processed += 1

    def _shutdown_during(self, active: ActiveJob, t: threading.Thread) -> None:
        if active.phase in ("upload", "report"):
            log.info("SIGTERM during %s of job %s: finishing it (up to %.0fs)", active.phase, active.id,
                     self.cfg.shutdown_grace)
            t.join(self.cfg.shutdown_grace)
            if not t.is_alive():
                return
            log.warning("job %s did not finish uploading in time", active.id)
        active.cancel(SHUTDOWN)
        if active.claim_report():
            self._send_failed(active, f"worker shutting down (pod stopped) during {active.phase}", True,
                              deadline=min(10.0, self.cfg.shutdown_grace))
        else:
            t.join(min(10.0, self.cfg.shutdown_grace))  # a done/failed report is in flight; let it land

    # -- one job ------------------------------------------------------------------------
    def _execute(self, active: ActiveJob) -> None:
        reporter: ProgressReporter | None = None
        work: Path | None = None
        ok = False
        try:
            if active.id is None:
                log.error("claimed a job without an id; cannot report on it: %r", str(active.raw)[:200])
                return
            job = Job.from_dict(active.raw)
            handler = self.handlers.get(job.kind)
            if handler is None:
                raise JobFailure(f"unknown job kind {job.kind!r}", retryable=False)
            reason = handler.availability()
            if reason:
                raise JobFailure(reason, retryable=False)

            reporter = ProgressReporter(lambda p: self.api.progress(job.id, p), self.cfg.progress_interval,
                                        on_cancel=lambda why: self._api_cancel(active, why))
            total = job.params.get("steps") or job.steps
            total = total if isinstance(total, int) and not isinstance(total, bool) and total >= 1 else 1
            work = self.cfg.work_dir / safe_name(job.id)
            shutil.rmtree(work, ignore_errors=True)
            (work / "in").mkdir(parents=True)

            active.phase = "download"
            reporter.update(step=0, totalSteps=total, phase="downloading")
            inputs = {}
            for spec in job.inputs:
                if active.cancel_event.is_set():
                    raise JobCancelled(active.cancel_reason)
                dest = work / "in" / spec.name
                info = download(spec.url, dest, expected_bytes=spec.bytes, expected_sha256=spec.sha256,
                                attempts=self.cfg.transfer_attempts, should_abort=active.cancel_event.is_set)
                log.info("input %s: %d bytes sha256 %s…", spec.name, info.bytes, info.sha256[:12])
                inputs[spec.name] = dest

            active.phase = "run"
            ctx = JobContext(job, work, inputs, reporter.update, active.cancel_event, lambda: active.cancel_reason)
            produced = handler.run(ctx)
            ctx.check_cancel()

            active.phase = "upload"
            reporter.update(step=total, totalSteps=total, phase="uploading", etaSeconds=0)
            by_name = {o.name: o for o in job.outputs}
            unknown = [p.name for p in produced if p.name not in by_name]
            missing = sorted(set(by_name) - {p.name for p in produced})
            if unknown or missing:
                raise JobFailure(f"outputs do not match the job (unexpected {unknown}, not produced {missing})",
                                 retryable=False)
            outputs = []
            for p in produced:
                spec = by_name[p.name]
                info = upload(p.path, spec.upload_url, headers=spec.headers, attempts=self.cfg.transfer_attempts)
                log.info("output %s: %d bytes sha256 %s… uploaded", p.name, info.bytes, info.sha256[:12])
                meta = {"name": p.name, "bytes": info.bytes, "sha256": info.sha256, "width": p.width,
                        "height": p.height, "fps": p.fps, "durationSec": p.duration_sec}
                outputs.append({k: v for k, v in meta.items() if v is not None})  # API: optional, not nullable
            reporter.close(flush=True)

            active.phase = "report"
            gpu_seconds = round(time.monotonic() - active.t0, 1)
            if active.claim_report():
                self.api.done(job.id, {"outputs": outputs, "gpuSeconds": gpu_seconds, "stats": ctx.stats},
                              deadline_s=self.cfg.report_deadline)
                log.info("job %s done in %.0fs", job.id, gpu_seconds)
            ok = True
        except JobCancelled as e:
            if e.reason == SHUTDOWN:
                log.info("job %s stopped for shutdown", active.id)
            else:
                log.info("job %s cancelled by the API (%s); not reporting", active.id, e.reason)
        except JobFailure as e:
            self._fail(active, str(e), e.retryable)
        except TransferError as e:
            if active.cancel_event.is_set():
                log.info("job %s transfer stopped (%s)", active.id, active.cancel_reason)
            else:
                self._fail(active, str(e), e.retryable)
        except JobGone as e:
            log.warning("job %s: API no longer knows it (%s)", active.id, e)
        except ApiError as e:
            log.error("job %s: could not report the result to the API: %s", active.id, e)
        except Exception as e:
            if active.cancel_event.is_set():
                log.info("job %s stopped (%s): %s", active.id, active.cancel_reason, e)
            else:
                log.exception("job %s crashed", active.id)
                msg, retryable = classify(e)
                self._fail(active, msg, retryable)
        finally:
            if reporter is not None:
                reporter.close(flush=False)
            if work is not None and (ok or not self.cfg.keep_failed):
                shutil.rmtree(work, ignore_errors=True)

    def _api_cancel(self, active: ActiveJob, why: str) -> None:
        if active.phase in ("download", "run", "starting"):
            log.info("job %s: API cancelled it (%s); stopping at the next step", active.id, why)
            active.cancel(f"api: {why}")

    def _fail(self, active: ActiveJob, error: str, retryable: bool) -> None:
        if active.id is None or not active.claim_report():
            return
        self._send_failed(active, error, retryable, deadline=self.cfg.report_deadline)

    def _send_failed(self, active: ActiveJob, error: str, retryable: bool, deadline: float) -> None:
        log.warning("job %s failed (retryable=%s): %s", active.id, retryable, error)
        try:
            self.api.failed(active.id, error, retryable, deadline_s=deadline)
        except ApiError as e:
            log.error("job %s: could not report the failure: %s", active.id, e)
