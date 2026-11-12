// One heavy ffmpeg pipeline at a time on the small server (Railway Trial, ~512 MB): Claude's watch, the edit's frames
// and contact sheets, action peaks and listen all queue here, so a burst of calls (Claude asks for three frames and a
// watch at once) can't run several full-size decodes side by side and run the box out of memory (2026-11-12: "ffmpeg
// failed: … Cannot allocate memory", ECONNRESET on parallel get_frame calls). Re-entrant: work already in the lane that
// asks for the lane again (a watch that grabs frames, a contact sheet's stills) runs at once instead of waiting for
// itself, so the lane can never deadlock.
import { AsyncLocalStorage } from 'node:async_hooks';

const inLane = new AsyncLocalStorage<true>();
let busy: Promise<unknown> = Promise.resolve();
let running = 0, maxRunning = 0;
/** Runs `fn` after every earlier one has finished (at once when called from inside the lane). */
export function oneAtATime<T>(fn: () => Promise<T>): Promise<T> {
  if (inLane.getStore()) return fn();
  const next = busy.then(() => inLane.run(true, async () => { running++; maxRunning = Math.max(maxRunning, running); try { return await fn(); } finally { running--; } }));
  busy = next.catch(() => {});
  return next;
}
/** For tests: the most pipelines that ever ran at once. */
export const laneConcurrency = () => maxRunning;
/** ffmpeg input options that keep one decode small: one decoder thread, one filter thread. */
export const LEAN_DECODE = ['-threads', '1', '-filter_threads', '1'];
