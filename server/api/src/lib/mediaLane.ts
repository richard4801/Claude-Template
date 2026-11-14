// Heavy ffmpeg pipelines are rationed here: Claude's watch, the edit's frames and contact sheets, action peaks and listen
// all queue in this lane, so a burst of calls (Claude asks for three frames and a watch at once) can't run several
// full-size decodes side by side and run the box out of memory (2026-11-12 on the Trial: "ffmpeg failed: … Cannot
// allocate memory", ECONNRESET on parallel get_frame calls). How many run at once follows the media profile
// (lib/resources.ts): one on SMALL, 2–3 on LARGE. Re-entrant: work already in the lane that asks for the lane again (a
// watch that grabs frames, a contact sheet's stills) runs at once instead of waiting for itself, so the lane can never
// deadlock. Edit renders are NOT in this lane (editor/renders.ts has its own budget), so a render never waits behind a watch.
import { AsyncLocalStorage } from 'node:async_hooks';
import { decThreads, mediaProfile } from './resources.js';

const inLane = new AsyncLocalStorage<true>();
const waiting: (() => void)[] = [];
let active = 0, running = 0, maxRunning = 0;
let limitOverride: number | null = null;
const limit = () => Math.max(1, limitOverride ?? mediaProfile().laneConcurrency);
type Log = { info: (o: object, msg: string) => void };
let log: Log | undefined;
/** Where lane timings are logged (set once at start-up). */
export function setMediaLog(l: Log | undefined) { log = l; }

function pump() {
  while (active < limit() && waiting.length) { active++; waiting.shift()!(); }
}
/**
 * Runs `fn` once a place in the lane is free, oldest first (at once when called from inside the lane). With a `label`,
 * the time it spent (waiting and running) is logged.
 */
export function oneAtATime<T>(fn: () => Promise<T>, label?: string): Promise<T> {
  if (inLane.getStore()) return fn();
  const queued = Date.now();
  return new Promise<void>(res => { waiting.push(res); pump(); }).then(() => inLane.run(true, async () => {
    const t0 = Date.now();
    running++; maxRunning = Math.max(maxRunning, running);
    try { return await fn(); } finally {
      running--; active--;
      if (label) { const p = mediaProfile(); log?.info({ tool: label, ms: Date.now() - t0, waitMs: t0 - queued, profile: p.name, lane: limit() }, 'media timing'); }
      pump();
    }
  }));
}
/** For tests: the most pipelines that ever ran at once. */
export const laneConcurrency = () => maxRunning;
/** For tests: reset the count and force a lane size (null: the profile's). */
export function resetLane(n: number | null = null) { maxRunning = 0; limitOverride = n; }
/** ffmpeg input options that keep one decode small: one decoder thread, one filter thread (more threads on LARGE). */
export const leanDecode = () => ['-threads', decThreads(1), '-filter_threads', '1'];
