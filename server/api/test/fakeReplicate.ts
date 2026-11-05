// A FAKE Replicate on localhost (api.replicate.com + replicate.com stand-in) for the tests: no real predictions, no money.
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';
import type { RawModel } from '../src/replicate/mapping.js';

const FIX = path.join(path.dirname(fileURLToPath(import.meta.url)), 'fixtures/replicate');
export const MODELS = JSON.parse(fs.readFileSync(path.join(FIX, 'models.json'), 'utf8')) as Record<string, RawModel>;
const page = (id: string) => fs.readFileSync(path.join(FIX, `page_${id.replace('/', '_')}.html`), 'utf8');
export const TOKEN = 'r8_tools_test';

export type Pred = { id: string; model: string; version?: string; input: any; polls: number };
/** api.replicate.com + replicate.com stand-in: catalog reads, predictions that finish after one poll, output images, model pages. */
export async function fakeReplicate(extra: Record<string, RawModel> = {}) {
  const preds = new Map<string, Pred>();
  const state = { creates: [] as Pred[], failNext: 0, catalogCalls: [] as string[] };
  let n = 0;
  const jpeg = await sharp({ create: { width: 64, height: 96, channels: 3, background: '#8090a0' } }).jpeg().toBuffer();
  const all = { ...MODELS, ...extra };
  const byName = (id: string) => all[id];
  const versionOf = (v: string) => Object.entries(all).find(([, m]) => m.latest_version?.id === v)?.[0];
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', c => (body += c));
    req.on('end', () => {
      const url = req.url ?? '';
      const json = (status: number, o: unknown) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(o)); };
      if (url.startsWith('/files/')) { res.writeHead(200, { 'content-type': 'image/jpeg' }); res.end(jpeg); return; }
      const web = /^\/web\/([^/]+\/[^/]+)$/.exec(url);
      if (web) {
        let html: string | null = null;
        try { html = page(web[1]!); } catch { /* no page */ }
        if (html) { res.writeHead(200, { 'content-type': 'text/html' }); res.end(html); } else { res.writeHead(404); res.end(); }
        return;
      }
      if (req.headers.authorization !== `Bearer ${TOKEN}`) return json(401, { detail: 'Unauthenticated' });
      if (req.method === 'GET') state.catalogCalls.push(url);
      if (url === '/v1/collections') return json(200, JSON.parse(fs.readFileSync(path.join(FIX, 'collections.json'), 'utf8')));
      const col = /^\/v1\/collections\/([a-z0-9-]+)$/.exec(url);
      if (col) {
        const ids: Record<string, string[]> = { 'super-resolution': ['philz1337x/clarity-upscaler', 'topazlabs/image-upscale', 'nightmareai/real-esrgan'],
          'image-editing': ['qwen/qwen-image-edit-2511', 'black-forest-labs/flux-2-pro', 'google/nano-banana', 'bytedance/seedream-4'],
          'text-to-image': ['black-forest-labs/flux-2-pro', 'stability-ai/sdxl', 'black-forest-labs/flux-krea-dev'], 'ai-image-restoration': [] };
        if (!ids[col[1]!]) return json(404, { detail: 'Not found' });
        return json(200, { slug: col[1], name: col[1], models: ids[col[1]!]!.map(byName) });
      }
      if (url.startsWith('/v1/search')) return json(200, { query: 'x', models: [{ model: { ...byName('topazlabs/image-upscale'), latest_version: null } }, { model: { ...byName('philz1337x/clarity-upscaler'), latest_version: null } }], collections: [] });
      const model = /^\/v1\/models\/([^/]+\/[^/]+)$/.exec(url);
      if (model && req.method === 'GET') return byName(model[1]!) ? json(200, byName(model[1]!)) : json(404, { detail: 'Not found' });
      const create = /^\/v1\/models\/([^/]+\/[^/]+)\/predictions$/.exec(url);
      if ((create || url === '/v1/predictions') && req.method === 'POST') {
        const b = JSON.parse(body);
        const p: Pred = { id: `p${++n}`, model: create ? create[1]! : versionOf(b.version) ?? 'unknown', version: b.version, input: b.input, polls: 0 };
        if (state.failNext > 0) { state.failNext--; (p as any).fail = true; }
        preds.set(p.id, p); state.creates.push(p);
        return json(201, { id: p.id, status: 'starting' });
      }
      const get = /^\/v1\/predictions\/([^/]+)$/.exec(url);
      if (get) {
        const p = preds.get(get[1]!);
        if (!p) return json(404, { detail: 'Not found' });
        if (++p.polls < 2) return json(200, { id: p.id, status: 'processing' });
        if ((p as any).fail) return json(200, { id: p.id, status: 'failed', error: 'CUDA out of memory' });
        const out = `http://127.0.0.1:${(server.address() as any).port}/files/${p.id}.jpg`;
        const array = ['qwen/qwen-image-edit-2511', 'black-forest-labs/flux-krea-dev', 'philz1337x/clarity-upscaler'].includes(p.model);
        return json(200, { id: p.id, status: 'succeeded', output: array ? [out] : out, metrics: { predict_time: p.model === 'philz1337x/clarity-upscaler' ? 10 : 2 } });
      }
      return json(404, { detail: 'Not found' });
    });
  });
  await new Promise<void>(r => server.listen(0, '127.0.0.1', r));
  const port = (server.address() as any).port;
  return { base: `http://127.0.0.1:${port}/v1`, web: `http://127.0.0.1:${port}/web`, state, close: () => new Promise<void>(r => server.close(() => r())) };
}

