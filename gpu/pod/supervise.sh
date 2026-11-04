#!/usr/bin/env bash
# Runs the worker and restarts it after a crash. Called by bootstrap.sh (and by the tests with a fake worker):
#
#   bash supervise.sh LOGFILE COMMAND [ARGS...]
#
# Worker exit codes:
#   0  normal exit or SIGTERM          -> exit 0
#   2  config error, 3 token rejected  -> exit with that code, no restart (restarting can't fix it)
#   4  deliberate self-stop: the worker asked RunPod to terminate this pod (gpu/worker/muse_worker/selfstop.py)
#      -> never restart it. Wait for RunPod to remove the container, asking again every
#         MUSE_SELF_STOP_RECHECK_SECONDS (300) in case the first request got lost. Exiting instead could make RunPod
#         restart the container, which would start a fresh worker and keep billing.
#   anything else                       -> crash: restart up to 5 times, 10 s apart. After that, give up and (on
#      RunPod, unless MUSE_SELF_STOP=0) terminate the pod: a crash-looping worker can't self-stop, and RunPod would
#      otherwise restart the container and keep billing.
#
# MUSE_SELF_STOP_LINGER_SECONDS (tests only): stop waiting after this long and exit 0.
set -uo pipefail

LOGFILE="${1:?usage: supervise.sh LOGFILE COMMAND [ARGS...]}"; shift
[ "$#" -gt 0 ] || { echo "usage: supervise.sh LOGFILE COMMAND [ARGS...]" >&2; exit 64; }
T0=$(date +%s)
log() { echo "[supervise +$(( $(date +%s) - T0 ))s] $*" | tee -a "$LOGFILE"; }
RESTART_DELAY="${MUSE_RESTART_DELAY_SECONDS:-10}"

child=0; stopping=0
on_term() { stopping=1; [ "$child" != 0 ] && kill -TERM "$child" 2>/dev/null || true; }
trap on_term TERM INT

linger_after_self_stop() {
  log "worker SELF-STOPPED (exit 4): RunPod was asked to terminate pod ${RUNPOD_POD_ID:-?}. Not restarting the worker; waiting for the pod to go away."
  local recheck="${MUSE_SELF_STOP_RECHECK_SECONDS:-300}" linger="${MUSE_SELF_STOP_LINGER_SECONDS:-}" waited=0
  while [ "$stopping" = 0 ]; do
    if [ -n "$linger" ] && [ "$waited" -ge "$linger" ]; then log "linger time over; exiting"; exit 0; fi
    child=0
    sleep 1 & wait $! 2>/dev/null
    waited=$((waited + 1))
    if [ $((waited % recheck)) = 0 ] && [ -n "${RUNPOD_POD_ID:-}" ] && command -v runpodctl >/dev/null; then
      log "pod still running ${waited}s after self-stop; asking RunPod again"
      ask_runpod_to_remove || log "runpodctl failed again"
    fi
  done
  log "stopped while waiting after self-stop"; exit 0
}

ask_runpod_to_remove() {
  runpodctl remove pod "$RUNPOD_POD_ID" >/dev/null 2>&1 || runpodctl pod delete "$RUNPOD_POD_ID" >/dev/null 2>&1 \
    || runpodctl stop pod "$RUNPOD_POD_ID" >/dev/null 2>&1
}

restarts=0
while :; do
  "$@" > >(tee -a "$LOGFILE") 2>&1 &
  child=$!
  wait "$child"; code=$?
  [ "$stopping" = 1 ] && { wait "$child"; code=$?; }   # wait again: the first wait returns on the trap
  [ "$stopping" = 1 ] && { log "worker stopped (exit $code)"; exit 0; }
  case "$code" in
    0) log "worker exited normally"; exit 0 ;;
    2|3) log "worker exit $code (config or token problem): not restarting"; exit "$code" ;;
    4) linger_after_self_stop ;;
  esac
  restarts=$((restarts + 1))
  if [ "$restarts" -gt 5 ]; then
    log "FATAL: worker crashed $restarts times; giving up"
    if [ "${MUSE_SELF_STOP:-1}" != 0 ] && [ -n "${RUNPOD_POD_ID:-}" ] && command -v runpodctl >/dev/null; then
      log "terminating pod $RUNPOD_POD_ID so a crash loop doesn't keep billing"
      ask_runpod_to_remove && linger_after_self_stop
      log "could not terminate the pod: stop it in the RunPod console"
    fi
    exit 1
  fi
  log "worker crashed (exit $code); restart $restarts/5 in ${RESTART_DELAY} s"
  sleep "$RESTART_DELAY"
done
