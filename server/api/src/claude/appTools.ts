// One Claude, full control · batch B1 (plans/claude-control-audit.md): the screens' read and organise actions that
// spend nothing and delete nothing, as tools on every page for everyone. Each calls the app's own route as the person
// (claude/appCall.ts), so what a member may see or change is exactly what their app allows.
import type { EditTool } from '../editor/mcpTools.js';
import { badRequest } from '../errors.js';
import { appCall, slim } from './appCall.js';

const str = (d: string, max?: number) => ({ type: 'string', description: d, ...(max ? { maxLength: max } : {}) });
const int = (d: string, min: number, max: number) => ({ type: 'integer', description: d, minimum: min, maximum: max });
const obj = (properties: Record<string, unknown>, required: string[] = []) => ({ type: 'object', properties, required, additionalProperties: false });
const id = (v: unknown, what: string) => {
  if (typeof v !== 'string' || !/^[A-Za-z0-9_-]{1,80}$/.test(v)) throw badRequest(`${what}: an id`);
  return v;
};
const enc = encodeURIComponent;
const lim = (v: unknown, d = 30) => (typeof v === 'number' ? Math.min(100, Math.max(1, Math.floor(v))) : d);
const has = (q: string, ...xs: unknown[]) => xs.some(x => typeof x === 'string' && x.toLowerCase().includes(q));
const read = { scope: 'edit:read', readOnly: true, idempotent: true } as const;

export const APP_TOOLS: EditTool[] = [
  {
    name: 'queue_list', title: 'Queue: jobs and queued shots', ...read,
    description: 'The studio\'s generation jobs (newest first: status, progress, what each is making, its takes when done) and the AI Suite shots queued to run later. Use it to watch progress, find a failed job, or tell the person when something is done.',
    inputSchema: obj({ status: str('Only jobs in this state (e.g. running, done, failed)', 20), limit: int('How many jobs (default 20)', 1, 100) }),
    run: async (env, a) => {
      const [jobs, queued] = await Promise.all([appCall(env.ctx, env.user, 'GET', '/v1/jobs'), appCall(env.ctx, env.user, 'GET', '/v1/suite/queue').catch(() => [])]);
      const list = (Array.isArray(jobs) ? jobs : (jobs?.jobs ?? [])) as { status?: string }[];
      const f = typeof a.status === 'string' && a.status ? list.filter(j => j.status === a.status) : list;
      return slim({ jobs: f.slice(0, lim(a.limit, 20)), total: f.length, queuedShots: queued }, 20);
    },
  },
  {
    name: 'characters_list', title: 'Cast: the studio\'s characters', ...read,
    description: 'The studio\'s characters (MUSE models): id, name, look, sheet angles filled, "never" notes. Use suite_see or watch to look at their pictures.',
    inputSchema: obj({ query: str('Words in the name', 60) }),
    run: async (env, a) => {
      const rows = (await appCall(env.ctx, env.user, 'GET', '/v1/models')) as { name?: string }[];
      const q = typeof a.query === 'string' ? a.query.trim().toLowerCase() : '';
      return slim({ characters: q ? rows.filter(r => has(q, r.name)) : rows }, 50);
    },
  },
  {
    name: 'outfits_list', title: 'Outfits', ...read,
    description: 'The studio\'s outfits (id, name, character, angles), optionally for one character. To see an outfit\'s pictures use suite_see in a Suite draft.',
    inputSchema: obj({ modelId: str('Only this character\'s outfits', 80), query: str('Words in the name', 60) }),
    run: async (env, a) => {
      let rows = (await appCall(env.ctx, env.user, 'GET', '/v1/outfits')) as { name?: string; modelId?: string }[];
      if (typeof a.modelId === 'string' && a.modelId) rows = rows.filter(r => r.modelId === a.modelId);
      const q = typeof a.query === 'string' ? a.query.trim().toLowerCase() : '';
      return slim({ outfits: q ? rows.filter(r => has(q, r.name)) : rows }, 60);
    },
  },
  {
    name: 'outfit_rename', title: 'Rename an outfit', scope: 'edit:write',
    description: 'Renames an outfit (as on its page). Free; nothing else changes.',
    inputSchema: obj({ outfitId: str('The outfit', 80), name: str('The new name', 60) }, ['outfitId', 'name']),
    run: async (env, a) => slim(await appCall(env.ctx, env.user, 'PATCH', `/v1/outfits/${enc(id(a.outfitId, 'outfitId'))}`, { name: a.name })),
  },
  {
    name: 'library_find', title: 'Library: find takes', ...read,
    description: 'Finds takes and edited versions in the Library, newest first: by words in the prompt, title or template, by kind (take, photo, edit…), by status (test or final = approved), or made after a date. Returns ids you can watch, open (open_page take) or edit (open_edit).',
    inputSchema: obj({ query: str('Words in the prompt, title or template', 80), kind: str('take, photo, edit…', 20), status: { type: 'string', enum: ['test', 'final'] },
      since: { type: 'integer', description: 'Made after (ms)' }, limit: int('How many (default 30)', 1, 100) }),
    run: async (env, a) => {
      let rows = (await appCall(env.ctx, env.user, 'GET', '/v1/takes')) as { kind?: string; status?: string; createdAt?: number; prompt?: string; title?: string; label?: string; templateName?: string; name?: string }[];
      const q = typeof a.query === 'string' ? a.query.trim().toLowerCase() : '';
      if (q) rows = rows.filter(r => has(q, r.prompt, r.title, r.label, r.templateName, r.name));
      if (typeof a.kind === 'string' && a.kind) rows = rows.filter(r => r.kind === a.kind);
      if (typeof a.status === 'string') rows = rows.filter(r => r.status === a.status);
      if (typeof a.since === 'number') rows = rows.filter(r => (r.createdAt ?? 0) > (a.since as number));
      const n = lim(a.limit);
      return { takes: rows.slice(0, n).map(r => slim({ ...r, draft: undefined, refs: undefined, edits: undefined })), total: rows.length };
    },
  },
  {
    name: 'take_status', title: 'Approve a take (or undo it)', scope: 'edit:write',
    description: 'Marks a take final (approved, as the ✓ in the Library) or back to test. Free.',
    inputSchema: obj({ takeId: str('The take', 80), status: { type: 'string', enum: ['final', 'test'] } }, ['takeId', 'status']),
    run: async (env, a) => slim(await appCall(env.ctx, env.user, 'PATCH', `/v1/takes/${enc(id(a.takeId, 'takeId'))}`, { status: a.status })),
  },
  {
    name: 'library_collections', title: 'Library collections', ...read,
    description: 'The Library\'s collections (folders of takes), or one collection with its takes when you pass collectionId. Also which collections hold a take (takeId).',
    inputSchema: obj({ collectionId: str('Open this collection', 80), takeId: str('Which collections hold this take', 80) }),
    run: async (env, a) => {
      if (typeof a.collectionId === 'string' && a.collectionId) return slim(await appCall(env.ctx, env.user, 'GET', `/v1/library/collections/${enc(id(a.collectionId, 'collectionId'))}`), 60);
      if (typeof a.takeId === 'string' && a.takeId) return slim(await appCall(env.ctx, env.user, 'GET', `/v1/library/takes/${enc(id(a.takeId, 'takeId'))}/collections`));
      return slim(await appCall(env.ctx, env.user, 'GET', '/v1/library/collections'), 60);
    },
  },
  {
    name: 'library_collect', title: 'Organise the Library', scope: 'edit:write',
    description: 'Organises the Library: create a collection (name, optional takeIds), rename one, add takes to one, or take takes out of one (the takes themselves stay in the Library). Free. Deleting a whole collection is not here: it needs the person\'s go-ahead.',
    inputSchema: obj({ action: { type: 'string', enum: ['create', 'rename', 'add', 'remove'] }, collectionId: str('The collection (rename, add, remove)', 80),
      name: str('Its name (create, rename)', 80), takeIds: { type: 'array', items: { type: 'string', maxLength: 80 }, maxItems: 200, description: 'Takes (create, add, remove)' } }, ['action']),
    run: async (env, a) => {
      const takeIds = Array.isArray(a.takeIds) ? a.takeIds : undefined;
      if (a.action === 'create') return slim(await appCall(env.ctx, env.user, 'POST', '/v1/library/collections', { name: a.name, ...(takeIds ? { takeIds } : {}) }));
      const c = enc(id(a.collectionId, 'collectionId'));
      if (a.action === 'rename') return slim(await appCall(env.ctx, env.user, 'PATCH', `/v1/library/collections/${c}`, { name: a.name }));
      if (a.action === 'add') return slim(await appCall(env.ctx, env.user, 'POST', `/v1/library/collections/${c}/items`, { takeIds }));
      if (a.action === 'remove') return slim(await appCall(env.ctx, env.user, 'POST', `/v1/library/collections/${c}/items/remove`, { takeIds }));
      throw badRequest('action: create, rename, add or remove');
    },
  },
  {
    name: 'templates_list', title: 'Templates', ...read,
    description: 'The studio\'s templates (photo presets): id, name, what each makes. To use one, open the AI Suite on Photo and set its preset in the draft (suite_set_draft).',
    inputSchema: obj({ query: str('Words in the name', 60), templateId: str('Open one template in full', 80) }),
    run: async (env, a) => {
      if (typeof a.templateId === 'string' && a.templateId) return slim(await appCall(env.ctx, env.user, 'GET', `/v1/templates/${enc(id(a.templateId, 'templateId'))}`));
      const r = await appCall(env.ctx, env.user, 'GET', '/v1/templates');
      let rows = (Array.isArray(r) ? r : (r?.templates ?? [])) as { name?: string; title?: string }[];
      const q = typeof a.query === 'string' ? a.query.trim().toLowerCase() : '';
      if (q) rows = rows.filter(t => has(q, t.name, t.title));
      return slim({ templates: rows }, 60);
    },
  },
  {
    name: 'posts_list', title: 'Posts: scheduled and posted', ...read,
    description: 'The studio\'s social posts: scheduled, posted and failed, with the character, platform, time and caption.',
    inputSchema: obj({ state: str('Only this state (e.g. scheduled, posted, failed)', 20), modelId: str('Only this character', 80) }),
    run: async (env, a) => {
      const qs = new URLSearchParams();
      if (typeof a.state === 'string' && a.state) qs.set('state', a.state);
      if (typeof a.modelId === 'string' && a.modelId) qs.set('modelId', a.modelId);
      return slim({ posts: await appCall(env.ctx, env.user, 'GET', `/v1/posts${qs.size ? `?${qs}` : ''}`) }, 50);
    },
  },
  {
    name: 'recreate_list', title: 'Recreate: references', ...read,
    description: 'The studio\'s Recreate references (analysed reference videos): id, title, status, when. Open one with open_page {page:"recreate", id} or read its recipe with get_recipe.',
    inputSchema: obj({}),
    run: async env => slim({ references: await appCall(env.ctx, env.user, 'GET', '/v1/recreate/references') }, 50),
  },
];
