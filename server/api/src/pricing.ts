// Pricing and simulated progress. The same numbers as prototype/app/app.js, server/mock/sim.js,
// android/core Pricing.kt and the Mac Pricing.swift; checked against android/core/src/test/resources/pricing_fixture.json.
import type { ClipCheck } from './db/schema.js';

export const DEMO_SPEED = 24;
export const STEPS_MIN = 4, STEPS_MAX = 30, STEPS_DEFAULT = 10, TAKES_MAX = 4, MAX_CLIP_SEC = 15;
export const SEC_PER_STEP_5S = 57.8, GPU_PER_HOUR = 3.99, GPU_STARTUP_MIN = 0.5, LIP_SYNC_MIN = 4;
export const VIGGLE_MIN_5S = 1.6, VIGGLE_COST_5S = 0.13, BASE_LEN = 5.2;
export const SHOOT_COST = 0.12, OUTFIT_SET_COST = 0.08, FILL_ANGLE_COST = 0.02;
export const LORA_SET_COST = 0.60, LORA_CANDIDATES = 30, LORA_MIN_KEEP = 20, LORA_PHOTO_MIN = 25, LORA_VIDEO_MIN = 75;

export type RenderReq = {
  engine?: string; steps?: number; use?: string; lipSync?: boolean; takes?: number; clipSeconds?: number | null;
};

export const secPerLen = (len: number) => SEC_PER_STEP_5S * Math.pow(len / BASE_LEN, 1.3);

/** Seconds actually rendered: the first 5.2 s, or the whole clip (max 15 s). */
export function lengthSec(r: RenderReq) {
  const clip = r.clipSeconds ?? null;
  if ((r.use ?? 'first') === 'full') return Math.min(clip ?? 9.4, MAX_CLIP_SEC);
  return Math.min(BASE_LEN, clip ?? BASE_LEN);
}
/** Minutes for one take. */
export function estMin(r: RenderReq) {
  const L = lengthSec(r);
  if (r.engine === 'viggle') return VIGGLE_MIN_5S * (L / BASE_LEN);
  return (r.steps ?? STEPS_DEFAULT) * secPerLen(L) / 60 + GPU_STARTUP_MIN + (r.lipSync ? LIP_SYNC_MIN : 0);
}
/** Dollars for one take. */
export function estCost(r: RenderReq) {
  const L = lengthSec(r);
  return r.engine === 'viggle' ? VIGGLE_COST_5S * (L / BASE_LEN) : estMin(r) / 60 * GPU_PER_HOUR;
}
const nTakes = (r: RenderReq) => Math.max(1, r.takes ?? 1);
export const totalMin = (r: RenderReq) => estMin(r) * nTakes(r);
export const totalSeconds = (r: RenderReq) => estMin(r) * 60 * nTakes(r);
export const totalCost = (r: RenderReq) => estCost(r) * nTakes(r);

export const money = (v: number) => '$' + v.toFixed(2);
export const engineLabel = (r: RenderReq) => r.engine === 'viggle' ? 'Fast · beta' : `Standard · ${r.steps ?? STEPS_DEFAULT} steps`;
export const takeLabel = (r: RenderReq) => r.engine === 'viggle' ? 'Fast · beta' : `${r.steps ?? STEPS_DEFAULT} steps`;

/** "Generate · 10 min · $0.67" (the app's button label). */
export function genLabel(r: RenderReq) {
  const m = totalMin(r);
  const time = m < 2 ? `${Math.round(m * 60)}s` : `${Math.round(m)} min`;
  return `Generate · ${time} · ${money(totalCost(r))}${nTakes(r) > 1 ? ` · ${nTakes(r)} takes` : ''}`;
}
/** The hint under the steps slider. */
export function stepsDelta(r: RenderReq) {
  const steps = r.steps ?? STEPS_DEFAULT;
  if (steps === STEPS_DEFAULT) return 'Same quality as 15 or 20 steps in testing, for less time.';
  const d = (steps - STEPS_DEFAULT) * secPerLen(lengthSec(r)) / 60, c = d / 60 * GPU_PER_HOUR;
  const sign = d > 0 ? '+' : '−';
  return `${sign}${Math.abs(d).toFixed(1)} min · ${sign}${money(Math.abs(c))} vs 10 steps${steps > STEPS_DEFAULT ? ' · no visible gain in testing' : ' · may lose detail'}`;
}
export function sourceOption(use: 'first' | 'full', steps: number, clipSeconds?: number) {
  const L = lengthSec({ use, clipSeconds });
  const m = steps * secPerLen(L) / 60 + GPU_STARTUP_MIN, c = m / 60 * GPU_PER_HOUR;
  const trim = (v: number) => v.toFixed(1).replace(/\.0$/, '');
  const label = clipSeconds == null ? (use === 'first' ? 'First 5.2s' : 'Full 9.4s') : use === 'first' ? `First ${trim(L)}s` : `Full ${trim(L)}s`;
  return `${label} · ~${Math.round(m)}m · ${money(c)}`;
}
export const fillAnglesCost = (missing: number) => FILL_ANGLE_COST * missing;
export const videosLeft = (balance: number) => Math.max(0, Math.floor(balance / estCost({})));

export const loraTrainMinutes = () => LORA_PHOTO_MIN + LORA_VIDEO_MIN;
export const loraTrainCost = () => Math.round(loraTrainMinutes() / 60 * GPU_PER_HOUR * 100) / 100; // $6.65

const leftText = (s: number) => s >= 60 ? `~${Math.ceil(s / 60)} min left` : `~${Math.ceil(s)}s left`;
export const totalStepsFor = (r: RenderReq) => r.engine === 'viggle' ? 4 : r.steps ?? STEPS_DEFAULT;

/** Where a render is after `elapsed` GPU seconds (start-up, steps, lip sync per take). Same as the mock. */
export function progressAt(r: RenderReq, elapsed: number) {
  const total = totalSeconds(r), n = nTakes(r), perTake = total / n;
  const viggle = r.engine === 'viggle';
  const totalSteps = totalStepsFor(r);
  const startup = viggle ? 0 : 30, lip = !viggle && r.lipSync ? 240 : 0;
  const stepsTime = perTake - startup - lip;
  const e = Math.min(Math.max(elapsed, 0), total);
  const take = Math.min(n, Math.floor(e / perTake) + 1);
  const inTake = e - (take - 1) * perTake, left = total - e;
  const prefix = n > 1 ? `take ${take}/${n} · ` : '';
  let step: number, phase: string;
  if (e >= total) { step = totalSteps; phase = 'Done'; }
  else if (inTake < startup) { step = 0; phase = `${prefix}Starting GPU · ${leftText(left)}`; }
  else if (inTake < startup + stepsTime) {
    step = Math.min(totalSteps, Math.floor((inTake - startup) / stepsTime * totalSteps) + 1);
    phase = `${prefix}step ${step}/${totalSteps} · ${leftText(left)}`;
  } else { step = totalSteps; phase = `${prefix}Lip sync · ${leftText(left)}`; }
  return { progress: Math.min(100, Math.max(0, e / total * 100)), take, step, totalSteps, phase, secondsLeft: left };
}

/** Progress from a worker report (step of take), on the same scale as progressAt. */
export function progressFromWorker(r: RenderReq, p: { step: number; totalSteps: number; take?: number; phase?: string; etaSeconds?: number }) {
  const n = nTakes(r), take = Math.min(n, Math.max(1, p.take ?? 1));
  const totalSteps = Math.max(1, p.totalSteps || totalStepsFor(r));
  const step = Math.min(totalSteps, Math.max(0, p.step));
  const progress = Math.min(99.9, ((take - 1) + step / totalSteps) / n * 100);
  const secondsLeft = p.etaSeconds ?? Math.max(0, totalSeconds(r) * (1 - progress / 100));
  const prefix = n > 1 ? `take ${take}/${n} · ` : '';
  // Worker phases other than denoising ("loading", "lip sync", "upload") are shown as-is; denoising shows the step.
  const raw = (p.phase ?? '').trim();
  const isSteps = !raw || /^(denoise|denoising|steps?|sampling)$/i.test(raw);
  const label = isSteps ? `step ${step}/${totalSteps}` : raw.charAt(0).toUpperCase() + raw.slice(1);
  const phase = `${prefix}${label} · ${leftText(secondsLeft)}`;
  return { progress, take, step, totalSteps, phase, secondsLeft };
}

/** Simulated seconds at which a failing job breaks (step 3 of take 1). */
export function failAt(r: RenderReq) {
  const perTake = totalSeconds(r) / nTakes(r), viggle = r.engine === 'viggle';
  const totalSteps = totalStepsFor(r), startup = viggle ? 0 : 30, lip = !viggle && r.lipSync ? 240 : 0;
  return startup + (perTake - startup - lip) * 2.5 / totalSteps;
}

/** LoRA: overall progress p (0–100) → the two bars: photo is the first 25 %, video the remaining 75 %. */
export function loraParts(p: number) {
  const photoShare = 100 * LORA_PHOTO_MIN / loraTrainMinutes(), videoShare = 100 * LORA_VIDEO_MIN / loraTrainMinutes();
  const photo = Math.min(100, p * 100 / photoShare);
  const video = Math.max(0, (p - photoShare) / videoShare * 100);
  return { photo: { state: photo >= 100 ? 'ready' : 'training', progress: photo }, video: { state: video >= 100 ? 'ready' : video > 0 ? 'training' : 'waiting', progress: video } };
}

/** Source clip checks. People and watermark come from the client's metadata until server-side detection exists. */
export function clipChecks(m: { people?: number | null; watermark?: string | null; width: number; height: number; fps: number; durationSec: number; talking?: boolean | null }): ClipCheck[] {
  const out: ClipCheck[] = [];
  out.push(m.people === 1 || m.people == null ? { label: 'One person in frame', value: 'Yes', status: 'good' }
    : { label: 'People in frame', value: `${m.people} found`, status: 'bad', fix: 'Crop it, or pick a clip with one person' });
  out.push(!m.watermark ? { label: 'Watermark', value: 'None', status: 'good' }
    : { label: 'Watermark', value: m.watermark, status: 'bad', fix: 'Use the original file, not a download' });
  const res = `${m.width}×${m.height} · ${m.fps}fps`;
  if (m.height < m.width) out.push({ label: res, value: 'Landscape', status: 'bad', fix: 'Use a vertical 9:16 clip' });
  else if (Math.min(m.width, m.height) < 720) out.push({ label: res, value: 'Low res', status: 'bad', fix: 'Use a clip at least 720 wide' });
  else out.push({ label: res, value: 'OK', status: 'good' });
  const len = m.durationSec.toFixed(1).replace(/\.0$/, '');
  out.push(m.durationSec <= MAX_CLIP_SEC ? { label: `Length ${len}s`, value: 'Max 15s', status: 'good' }
    : { label: `Length ${len}s`, value: 'Over 15s', status: 'bad', fix: 'Trim to 15s or less' });
  out.push({ label: 'Performer talking', value: m.talking ? 'Yes' : 'No', status: 'info' });
  return out;
}
