// MUSE mock backend. Plain Node 22 http, no dependencies.
// REST + Server-Sent Events, contract in plans/api.md. Renders are simulated SPEED× faster than real time
// (default 24×, like the prototype). No GPU or RunPod calls are ever made.
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { seed, SLOT_SAMPLE } from './data.js';
import * as sim from './sim.js';

const PORT = Number(process.env.PORT ?? 8787);
const SPEED = Number(process.env.SPEED ?? sim.DEMO_SPEED);
const GEN_MS = Number(process.env.GEN_MS ?? 1600);
const UPLOAD_DIR = process.env.UPLOAD_DIR ?? path.join(os.tmpdir(), 'muse-mock-uploads');
fs.mkdirSync(UPLOAD_DIR, { recursive: true });

let db = seed();
const clients = new Set();
const runners = new Map();
const uid = () => crypto.randomUUID().slice(0, 8);

class ApiError extends Error { constructor(status, code, message) { super(message); this.status = status; this.code = code; } }
const notFound = what => new ApiError(404, 'not_found', `${what} not found`);

function emit(ev) {
  const line = `data: ${JSON.stringify(ev)}\n\n`;
  for (const res of clients) res.write(line);
}
const emitBalance = () => emit({ type: 'balance', balance: db.balance });
function charge(cost) { db.balance.balance = Math.max(0, db.balance.balance - cost); db.balance.month += cost; }
function refund(cost) { db.balance.balance += cost; db.balance.month = Math.max(0, db.balance.month - cost); }
const model = id => db.models.find(m => m.id === id) ?? (() => { throw notFound('Model'); })();
const outfit = id => db.outfits.find(o => o.id === id) ?? (() => { throw notFound('Outfit'); })();
const filled = m => m.slots.filter(s => s.image && !s.busy).length;

function h3Prompt(m, o, r) {
  // Structured H3 Ref2VA format (see plans/prompt-system.md). The full engine lives in android/core PromptEngine.
  const never = [...m.neverAdd, 'logos', 'extra fingers', 'warped jewellery'];
  return `subject_definitions:\n<Subject 1> is the person in <Video 1>.\n<Subject 2> is ${m.name}: ${m.look || m.age + '-year-old woman'}, with NO tattoos, shown in <Image 1>-<Image ${Math.max(1, filled(m))}>.\n<Video 1> is the source video for the editing task.\n\n` +
    `summary:\n[video editing + character replacement${r.keepAudio ? ' + audio reuse' : ''}] <Subject 1> is replaced by <Subject 2>; motion and timing are kept frame by frame.\n\n` +
    `retention_analysis:\n<Subject 2>: reference - wears the ${(o?.name ?? 'outfit').toLowerCase()}. She wears no ${never.join(', no ')}.\n<Audio 1>: ${r.keepAudio ? 'fully_copy' : 'replaced'}.\n\n` +
    `detailed_description:\nRealistic smartphone video. ${r.steps} steps.\n`;
}

function runJob(job) {
  if (SPEED <= 0) return;
  const failThis = db.failNext; db.failNext = false;
  const t0 = Date.now();
  const failAt = failThis ? sim.failAt(job.request) : Infinity;
  const iv = setInterval(() => {
    const cur = db.jobs.find(j => j.id === job.id);
    if (!cur) { clearInterval(iv); runners.delete(job.id); return; }
    const elapsed = (Date.now() - t0) / 1000 * SPEED;
    if (elapsed >= failAt) {
      const p = sim.progress(cur.request, failAt);
      Object.assign(cur, { state: 'failed', progress: p.progress, step: p.step, phase: `Failed at step ${p.step}`, refunded: cur.cost, error: `The GPU disconnected at step ${p.step}.`, finishedAt: Date.now() });
      refund(cur.cost);
      emit({ type: 'job', job: cur }); emitBalance();
    } else if (elapsed >= cur.totalSeconds) {
      Object.assign(cur, { state: 'done', progress: 100, step: cur.totalSteps, take: cur.request.takes, phase: 'Done', secondsLeft: 0, finishedAt: Date.now() });
      const o = db.outfits.find(x => x.id === cur.outfitId);
      const angles = (o?.angles ?? []).filter(Boolean);
      const takes = Array.from({ length: cur.request.takes }, (_, i) => ({
        id: `t_${cur.id}_${i + 1}`, kind: 'take', jobId: cur.id, index: i + 1, of: cur.request.takes, title: cur.title,
        label: cur.request.engine === 'viggle' ? 'Fast · beta' : `${cur.request.steps} steps`, engineLabel: sim.engineLabel(cur.request),
        cost: cur.cost / cur.request.takes, seed: cur.seed + i, status: 'test', thumb: angles.length ? angles[i % angles.length] : cur.thumb, prompt: cur.prompt, createdAt: Date.now(),
      }));
      db.takes.unshift(...takes);
      emit({ type: 'job', job: cur, takes });
    } else {
      Object.assign(cur, sim.progress(cur.request, elapsed));
      emit({ type: 'job', job: cur });
      return;
    }
    clearInterval(iv); runners.delete(job.id);
  }, 250);
  runners.set(job.id, iv);
}

// ---------------------------------------------------------------- body parsing
async function readBody(req) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  return Buffer.concat(chunks);
}
async function json(req) {
  const b = await readBody(req);
  if (!b.length) return {};
  try { return JSON.parse(b.toString('utf8')); } catch { throw new ApiError(400, 'bad_json', 'Body is not valid JSON'); }
}
/** Minimal multipart/form-data parser: returns { fieldName: { filename?, contentType?, data: Buffer } }. */
async function multipart(req) {
  const m = /boundary=(?:"([^"]+)"|([^;]+))/.exec(req.headers['content-type'] ?? '');
  if (!m) throw new ApiError(400, 'bad_request', 'Expected multipart/form-data');
  const boundary = Buffer.from('--' + (m[1] ?? m[2]));
  const body = await readBody(req);
  const parts = {};
  let i = body.indexOf(boundary);
  while (i !== -1) {
    const start = i + boundary.length;
    if (body.slice(start, start + 2).toString() === '--') break;
    const next = body.indexOf(boundary, start);
    if (next === -1) break;
    const part = body.slice(start + 2, next - 2);
    const sep = part.indexOf('\r\n\r\n');
    const head = part.slice(0, sep).toString('utf8'), data = part.slice(sep + 4);
    const name = /name="([^"]+)"/.exec(head)?.[1], filename = /filename="([^"]*)"/.exec(head)?.[1];
    const ct = /content-type:\s*([^\r\n]+)/i.exec(head)?.[1];
    if (name) parts[name] = { filename, contentType: ct, data };
    i = next;
  }
  return parts;
}

// ---------------------------------------------------------------- routes
const routes = [];
const route = (method, pattern, fn) => routes.push({ method, re: new RegExp('^' + pattern.replace(/:(\w+)/g, '(?<$1>[^/]+)') + '$'), fn });

route('GET', '/health', () => ({ ok: true, speed: SPEED }));

route('POST', '/v1/auth/signin', async req => {
  const b = await json(req);
  if (!b.email) throw new ApiError(400, 'bad_request', 'Enter your email');
  return { token: 'mock-' + uid(), user: { id: 'u1', studioName: 'Jenne Studio', email: b.email } };
});
route('POST', '/v1/auth/signup', async req => {
  const b = await json(req);
  if (!b.attestAdultRightsOriginal || !b.attestLabelAi) throw new ApiError(400, 'attestation_required', 'Tick both boxes to continue');
  return { token: 'mock-' + uid(), user: { id: 'u1', studioName: b.studioName || 'My Studio', email: b.email } };
});

route('GET', '/v1/models', () => db.models);
route('POST', '/v1/models', async req => {
  const b = await json(req);
  const m = { id: 'm_' + uid(), name: b.name || 'New model', age: Math.min(70, Math.max(18, b.age ?? 27)), niche: b.niche ?? 'Beauty', look: '', neverAdd: [],
    slots: Object.keys(SLOT_SAMPLE).map(k => ({ key: k, image: null, source: 'upload', busy: false })), outfitIds: [] };
  db.models.push(m);
  return m;
});
route('PUT', '/v1/models/:id/slots/:slot', async (req, p) => {
  const b = await json(req), m = model(p.id), s = m.slots.find(x => x.key === p.slot);
  if (!s) throw notFound('Slot');
  Object.assign(s, { image: b.image ?? null, source: b.source ?? 'upload', busy: false });
  return m;
});
route('POST', '/v1/models/:id/fill-angles', (req, p) => {
  const m = model(p.id), missing = m.slots.filter(s => !s.image);
  const cost = sim.FILL_ANGLE_COST * missing.length;
  if (cost > db.balance.balance) throw new ApiError(402, 'insufficient_balance', 'Not enough balance · top up in Credits');
  charge(cost); emitBalance();
  missing.forEach(s => { s.busy = true; });
  setTimeout(() => {
    m.slots.forEach(s => { if (s.busy) Object.assign(s, { busy: false, image: { asset: SLOT_SAMPLE[s.key] }, source: 'generated' }); });
    emit({ type: 'model', model: m });
  }, GEN_MS);
  return { model: m, cost };
});

route('GET', '/v1/outfits', () => db.outfits);
route('POST', '/v1/outfits', async req => {
  const b = await json(req), m = model(b.modelId);
  const cost = b.mode === 'own' ? 0 : sim.OUTFIT_SET_COST;
  if (cost > db.balance.balance) throw new ApiError(402, 'insufficient_balance', 'Not enough balance · top up in Credits');
  charge(cost); if (cost) emitBalance();
  const o = { id: 'o_' + uid(), modelId: m.id, name: b.name || 'New outfit', mode: b.mode ?? 'describe', description: b.description ?? '', angles: [null, null, null, null], state: 'generating', prompt: `Outfit set for ${m.name}: ${b.description ?? b.name}` };
  db.outfits.push(o);
  setTimeout(() => {
    o.angles = b.mode === 'own' && b.images?.length ? [0, 1, 2, 3].map(i => b.images[i] ?? null) : ['c_front', 'c_tq', 'c_face', 'c_front'].map(a => ({ asset: a }));
    o.state = 'preview';
    emit({ type: 'outfit', outfit: o });
  }, b.mode === 'own' ? 300 : GEN_MS + 100);
  return o;
});
route('POST', '/v1/outfits/:id/save', (req, p) => {
  const o = outfit(p.id), m = model(o.modelId);
  o.state = 'ready';
  if (!m.outfitIds.includes(o.id)) m.outfitIds.push(o.id);
  emit({ type: 'model', model: m });
  return o;
});

route('POST', '/v1/uploads/images', async req => {
  const parts = await multipart(req), f = parts.file;
  if (!f) throw new ApiError(400, 'bad_request', 'Missing file part');
  const ext = (f.contentType ?? '').includes('png') ? 'png' : 'jpg', name = `img_${uid()}.${ext}`;
  fs.writeFileSync(path.join(UPLOAD_DIR, name), f.data);
  return { url: `/uploads/${name}` };
});
route('POST', '/v1/uploads/clips', async req => {
  const parts = await multipart(req);
  if (!parts.meta) throw new ApiError(400, 'bad_request', 'Missing meta part');
  const meta = JSON.parse(parts.meta.data.toString('utf8'));
  const id = meta.name === 'Living-room dance' && !parts.file ? 'clip_sample' : meta.people === 2 && !parts.file ? 'clip_bad' : 'clip_' + uid();
  if (parts.file) fs.writeFileSync(path.join(UPLOAD_DIR, `${id}.mp4`), parts.file.data);
  const clip = { id, name: meta.name, durationSec: meta.durationSec, width: meta.width, height: meta.height, fps: meta.fps, checks: sim.clipChecks(meta) };
  db.clips[id] = clip;
  return clip;
});
route('GET', '/uploads/:name', (req, p, res) => {
  const f = path.join(UPLOAD_DIR, path.basename(p.name));
  if (!fs.existsSync(f)) throw notFound('Upload');
  res.writeHead(200, { 'content-type': f.endsWith('.png') ? 'image/png' : f.endsWith('.mp4') ? 'video/mp4' : 'image/jpeg' });
  fs.createReadStream(f).pipe(res);
  return undefined;
});

route('GET', '/v1/jobs', () => [...db.jobs].sort((a, b) => b.createdAt - a.createdAt));
route('POST', '/v1/jobs', async req => {
  const r = await json(req);
  r.takes = Math.min(4, Math.max(1, r.takes ?? 1)); r.steps = r.steps ?? 10; r.engine = r.engine ?? 'h3'; r.use = r.use ?? 'first';
  const clip = db.clips[r.clipId];
  if (clip && clip.checks.some(c => c.status === 'bad')) throw new ApiError(422, 'clip_failed_checks', 'Fix the clip checks first');
  if (r.engine === 'h3' && (r.steps < sim.STEPS_MIN || r.steps > sim.STEPS_MAX)) throw new ApiError(400, 'bad_request', 'Steps must be 4–30');
  const cost = sim.totalCost(r);
  if (cost > db.balance.balance + 1e-9) throw new ApiError(402, 'insufficient_balance', 'Not enough balance · top up in Credits');
  if (cost > db.balance.perJobLimit) throw new ApiError(402, 'over_job_limit', `Over your ${sim.money(db.balance.perJobLimit)} per-job limit`);
  const m = model(r.modelId), o = db.outfits.find(x => x.id === r.outfitId);
  charge(cost);
  const p = sim.progress(r, 0), seedN = 1000 + Math.floor(Math.random() * 99000);
  const job = { id: 'j_' + uid(), title: r.title ?? 'Untitled', modelId: m.id, modelName: m.name, outfitId: r.outfitId ?? '', request: r, state: 'running', ...p,
    totalSeconds: sim.totalSeconds(r), cost, refunded: 0, createdAt: Date.now(), prompt: h3Prompt(m, o, r), seed: seedN, thumb: o?.angles?.[0] ?? m.slots[0]?.image ?? null };
  db.jobs.push(job);
  emitBalance(); emit({ type: 'job', job });
  runJob(job);
  return job;
});
route('DELETE', '/v1/jobs/:id', (req, p) => {
  clearInterval(runners.get(p.id)); runners.delete(p.id);
  db.jobs = db.jobs.filter(j => j.id !== p.id);
  return undefined;
});

route('GET', '/v1/takes', () => db.takes);
route('PATCH', '/v1/takes/:id', async (req, p) => {
  const b = await json(req), t = db.takes.find(x => x.id === p.id);
  if (!t) throw notFound('Take');
  if (!['test', 'final'].includes(b.status)) throw new ApiError(400, 'bad_request', 'status must be test or final');
  t.status = b.status;
  return t;
});
route('DELETE', '/v1/takes/:id', (req, p) => { db.takes = db.takes.filter(t => t.id !== p.id); return undefined; });

route('POST', '/v1/shoots', async req => {
  const b = await json(req);
  if (sim.SHOOT_COST > db.balance.balance) throw new ApiError(402, 'insufficient_balance', 'Not enough balance · top up in Credits');
  charge(sim.SHOOT_COST); emitBalance();
  await new Promise(r => setTimeout(r, GEN_MS));
  const o = db.outfits.find(x => x.id === b.outfitId);
  const pool = [o?.angles?.[0]?.asset ?? 'g_front', 'c_face', 'face', 'g_tq'], count = Math.min(4, b.count ?? 4);
  const label = (b.scene ?? 'Shoot').split(' · ')[0].slice(0, 28);
  const shots = pool.slice(0, count).map((a, n) => ({ id: 's_' + uid(), kind: 'shot', jobId: null, index: n + 1, of: count, title: `Shoot · ${label}`, label: `${label} · ${n + 1}`,
    engineLabel: '', cost: sim.SHOOT_COST / count, seed: b.seed ?? 0, status: 'test', thumb: { asset: a }, prompt: b.prompt ?? '', createdAt: Date.now() }));
  db.takes.unshift(...shots);
  return shots;
});

route('GET', '/v1/balance', () => db.balance);
route('POST', '/v1/balance/topup', async req => {
  const b = await json(req);
  if (!(b.amount > 0) || b.amount > 500) throw new ApiError(400, 'bad_request', 'Amount must be between $0 and $500');
  db.balance.balance += b.amount; emitBalance();
  return db.balance;
});

route('POST', '/v1/dev/fail-next', async req => { db.failNext = !!(await json(req)).failNext; return undefined; });
route('POST', '/v1/dev/reset', () => { runners.forEach(clearInterval); runners.clear(); db = seed(); return { ok: true }; });

route('GET', '/v1/events', (req, p, res) => {
  res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'keep-alive' });
  res.write(': connected\n\n');
  clients.add(res);
  const ka = setInterval(() => res.write(': keep-alive\n\n'), 15000);
  req.on('close', () => { clearInterval(ka); clients.delete(res); });
  return undefined;
});

// ---------------------------------------------------------------- server
export function createServer() {
  return http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://x');
    res.setHeader('access-control-allow-origin', '*');
    if (req.method === 'OPTIONS') { res.writeHead(204, { 'access-control-allow-methods': 'GET,POST,PUT,PATCH,DELETE', 'access-control-allow-headers': '*' }); return res.end(); }
    for (const r of routes) {
      if (r.method !== req.method) continue;
      const m = r.re.exec(url.pathname);
      if (!m) continue;
      try {
        const out = await r.fn(req, m.groups ?? {}, res);
        if (res.headersSent) return;
        if (out === undefined) { res.writeHead(204); return res.end(); }
        res.writeHead(200, { 'content-type': 'application/json' });
        return res.end(JSON.stringify(out));
      } catch (e) {
        const status = e instanceof ApiError ? e.status : 500;
        if (!(e instanceof ApiError)) console.error(e);
        res.writeHead(status, { 'content-type': 'application/json' });
        return res.end(JSON.stringify({ error: e.message, code: e.code ?? 'server_error' }));
      }
    }
    res.writeHead(404, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: 'No such endpoint', code: 'not_found' }));
  });
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(new URL(import.meta.url).pathname)) {
  createServer().listen(PORT, () => console.log(`MUSE mock server on http://localhost:${PORT} · renders ${SPEED}× real time · no GPU calls`));
}
