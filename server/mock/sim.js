// Pricing and simulation rules. Same numbers as prototype/app/app.js and android/core Pricing.kt.
export const DEMO_SPEED = 24;
export const STEPS_MIN = 4, STEPS_MAX = 30, MAX_CLIP_SEC = 15;
export const SHOOT_COST = 0.12, OUTFIT_SET_COST = 0.08, FILL_ANGLE_COST = 0.02;

export const secPerLen = len => 57.8 * Math.pow(len / 5.2, 1.3);

/** Seconds actually rendered: the first 5.2 s, or the whole clip (max 15 s). */
export function lengthSec(req) {
  const clip = req.clipSeconds ?? null;
  if ((req.use ?? 'first') === 'full') return Math.min(clip ?? 9.4, MAX_CLIP_SEC);
  return Math.min(5.2, clip ?? 5.2);
}
/** Minutes for one take. */
export function estMin(req) {
  const L = lengthSec(req);
  if (req.engine === 'viggle') return 1.6 * (L / 5.2);
  return (req.steps ?? 10) * secPerLen(L) / 60 + 0.5 + (req.lipSync ? 4 : 0);
}
export function estCost(req) {
  const L = lengthSec(req);
  return req.engine === 'viggle' ? 0.13 * (L / 5.2) : estMin(req) / 60 * 3.99;
}
const takes = req => Math.max(1, req.takes ?? 1);
export const totalSeconds = req => estMin(req) * 60 * takes(req);
export const totalCost = req => estCost(req) * takes(req);

const leftText = s => s >= 60 ? `~${Math.ceil(s / 60)} min left` : `~${Math.ceil(s)}s left`;

/** Where a job is after `elapsed` simulated seconds (GPU start, steps, lip sync per take). */
export function progress(req, elapsed) {
  const total = totalSeconds(req), n = takes(req), perTake = total / n;
  const viggle = req.engine === 'viggle';
  const totalSteps = viggle ? 4 : req.steps ?? 10;
  const startup = viggle ? 0 : 30, lip = !viggle && req.lipSync ? 240 : 0;
  const stepsTime = perTake - startup - lip;
  const e = Math.min(Math.max(elapsed, 0), total);
  const take = Math.min(n, Math.floor(e / perTake) + 1);
  const inTake = e - (take - 1) * perTake, left = total - e;
  const prefix = n > 1 ? `take ${take}/${n} · ` : '';
  let step, phase;
  if (e >= total) { step = totalSteps; phase = 'Done'; }
  else if (inTake < startup) { step = 0; phase = `${prefix}Starting GPU · ${leftText(left)}`; }
  else if (inTake < startup + stepsTime) {
    step = Math.min(totalSteps, Math.floor((inTake - startup) / stepsTime * totalSteps) + 1);
    phase = `${prefix}step ${step}/${totalSteps} · ${leftText(left)}`;
  } else { step = totalSteps; phase = `${prefix}Lip sync · ${leftText(left)}`; }
  return { progress: Math.min(100, Math.max(0, e / total * 100)), take, step, totalSteps, phase, secondsLeft: left };
}

/** Simulated seconds at which a failing job breaks (step 3 of take 1). */
export function failAt(req) {
  const perTake = totalSeconds(req) / takes(req), viggle = req.engine === 'viggle';
  const totalSteps = viggle ? 4 : req.steps ?? 10, startup = viggle ? 0 : 30, lip = !viggle && req.lipSync ? 240 : 0;
  return startup + (perTake - startup - lip) * 2.5 / totalSteps;
}

/** Source clip checks. People/watermark detection is mocked from the metadata the client sends. */
export function clipChecks(m) {
  const out = [];
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

export const money = v => '$' + v.toFixed(2);
export const engineLabel = r => r.engine === 'viggle' ? 'Fast · beta' : `Standard · ${r.steps} steps`;
