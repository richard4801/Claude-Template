// One Claude, full control · batch B1 (plans/claude-control-audit.md): the screens' read and organise actions that
// spend nothing and delete nothing, as tools on every page for everyone. Each calls the app's own route as the person
// (claude/appCall.ts), so what a member may see or change is exactly what their app allows.
import type { EditTool } from '../editor/mcpTools.js';
import { badRequest } from '../errors.js';
import { appCall, slim } from './appCall.js';
import { assistOf } from '../suite/assist.js';

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
  // B3b
  {
    name: 'templates_manage', title: 'Make or change a template', scope: 'edit:write',
    description: 'Templates (photo presets), as the Templates screen: create (fields as the screen sends them; templates_list shows existing ones to copy), update one (only the fields to change), duplicate, favourite or unfavourite. Free. Deleting is a separate tool with the person\'s go-ahead.',
    inputSchema: obj({ action: { type: 'string', enum: ['create', 'update', 'duplicate', 'favourite', 'unfavourite'] }, templateId: str('The template (all but create)', 80),
      fields: { type: 'object', description: 'create/update: the template fields' } }, ['action']),
    run: async (env, a) => {
      const f = (a.fields && typeof a.fields === 'object' ? a.fields : {}) as object;
      if (a.action === 'create') return slim(await appCall(env.ctx, env.user, 'POST', '/v1/templates', f));
      const t = enc(id(a.templateId, 'templateId'));
      if (a.action === 'update') return slim(await appCall(env.ctx, env.user, 'PATCH', `/v1/templates/${t}`, f));
      if (a.action === 'duplicate') return slim(await appCall(env.ctx, env.user, 'POST', `/v1/templates/${t}/duplicate`, {}));
      if (a.action === 'favourite') return slim(await appCall(env.ctx, env.user, 'POST', `/v1/templates/${t}/favourite`, {}));
      if (a.action === 'unfavourite') return slim(await appCall(env.ctx, env.user, 'DELETE', `/v1/templates/${t}/favourite`));
      throw badRequest('action: create, update, duplicate, favourite or unfavourite');
    },
  },
  {
    name: 'recipes', title: 'Learn: edit recipes', scope: 'edit:write',
    description: 'The studio\'s edit recipes (Learn → Recipes: the edits learned from references and posts): list (query/tag), open one (recipeId), or rename / retag one (name, tags). Free. Deleting needs the person\'s go-ahead (recipe_delete).',
    inputSchema: obj({ action: { type: 'string', enum: ['list', 'get', 'update'] }, recipeId: str('The recipe (get, update)', 80), query: str('Words to find', 80), tag: str('Only this tag', 40),
      name: str('New name (update)', 120), tags: { type: 'array', items: { type: 'string', maxLength: 40 }, maxItems: 20, description: 'The tags it should have (update)' } }, ['action']),
    run: async (env, a) => {
      if (a.action === 'list') {
        const qs = new URLSearchParams();
        if (typeof a.query === 'string' && a.query) qs.set('q', a.query);
        if (typeof a.tag === 'string' && a.tag) qs.set('tag', a.tag);
        return slim(await appCall(env.ctx, env.user, 'GET', `/v1/learn/recipes${qs.size ? `?${qs}` : ''}`), 40);
      }
      const r = enc(id(a.recipeId, 'recipeId'));
      if (a.action === 'get') return slim(await appCall(env.ctx, env.user, 'GET', `/v1/learn/recipes/${r}`), 40);
      if (a.action === 'update') return slim(await appCall(env.ctx, env.user, 'PATCH', `/v1/learn/recipes/${r}`, { ...(typeof a.name === 'string' ? { name: a.name } : {}), ...(Array.isArray(a.tags) ? { tags: a.tags } : {}) }));
      throw badRequest('action: list, get or update');
    },
  },
  {
    name: 'import_link', title: 'Import a video link', scope: 'edit:write',
    description: 'Imports a public video link (TikTok, Instagram Reel, YouTube Shorts…) into the studio as a clip, as Link import does; check: true only checks it can be fetched. Free (server download). A link that is private or blocked is refused with a reason: ask the person to save the video and drop the file in. Lists earlier imports when no url is given.',
    inputSchema: obj({ url: str('The link', 500), name: str('A name for it', 120), check: { type: 'boolean', description: 'Only check the link' } }),
    run: async (env, a) => {
      if (typeof a.url !== 'string' || !a.url) return slim({ imports: await appCall(env.ctx, env.user, 'GET', '/v1/imports') }, 40);
      if (a.check === true) return slim(await appCall(env.ctx, env.user, 'POST', '/v1/links/check', { url: a.url }));
      return slim(await appCall(env.ctx, env.user, 'POST', '/v1/imports', { url: a.url, ...(typeof a.name === 'string' && a.name ? { name: a.name } : {}) }));
    },
  },
  {
    name: 'edit_jobs', title: 'Edit helper jobs', ...read,
    description: 'The Edit AI helper jobs (captions, cuts, cut-out, denoise, reverse, stabilize, slow motion, translate, separate…): their state and results, optionally for one take; or which helpers exist and what they cost (features: true).',
    inputSchema: obj({ takeId: str('Only this take\'s', 80), features: { type: 'boolean', description: 'List the helpers instead' } }),
    run: async (env, a) => {
      if (a.features === true) return slim(await appCall(env.ctx, env.user, 'GET', '/v1/editor/features'), 40);
      return slim(await appCall(env.ctx, env.user, 'GET', `/v1/editor/jobs${typeof a.takeId === 'string' && a.takeId ? `?takeId=${enc(a.takeId)}` : ''}`), 30);
    },
  },
  {
    name: 'character_archive', title: 'Archive a character (owner)', scope: 'edit:write',
    description: 'Archives a character (hidden from every list and picker, nothing deleted) or restores one (archived: false), as Archive on her page. Owner only. Free.',
    inputSchema: obj({ modelId: str('The character', 80), archived: { type: 'boolean' } }, ['modelId', 'archived']),
    run: async (env, a) => slim(await appCall(env.ctx, env.user, 'POST', `/v1/models/${enc(id(a.modelId, 'modelId'))}/${a.archived === false ? 'unarchive' : 'archive'}`, {})),
  },
  // B3c
  {
    name: 'character_create', title: 'Start a new character', scope: 'edit:write',
    description: 'Starts a new character (a draft on the Cast screen) with a name and, optionally, niche, personality, look and notes. Free. Her sheet pictures come from uploads on her page, or from character_fill_angles once she has a face picture.',
    inputSchema: obj({ name: str('Her name', 80), niche: str('Niche', 80), personality: str('Personality', 2000), look: str('Her look in words', 1000), notes: str('Notes', 4000) }, ['name']),
    run: async (env, a) => {
      const m = await appCall(env.ctx, env.user, 'POST', '/v1/models', { name: a.name });
      const rest = Object.fromEntries(['niche', 'personality', 'look', 'notes'].filter(k => typeof a[k] === 'string' && a[k]).map(k => [k, a[k]]));
      return slim(Object.keys(rest).length ? await appCall(env.ctx, env.user, 'PATCH', `/v1/models/${enc(m.id)}`, rest) : m);
    },
  },
  {
    name: 'character_update', title: 'Change a character\'s details', scope: 'edit:write',
    description: 'Changes a character\'s details as on her page: name, niche, personality, look, notes, and her "never add" list (neverAdd: the whole list as it should be: read it first with characters_list). Free; only the fields you send change.',
    inputSchema: obj({ modelId: str('The character', 80), name: str('Name', 80), niche: str('Niche', 80), personality: str('Personality', 2000), look: str('Look', 1000), notes: str('Notes', 4000),
      neverAdd: { type: 'array', items: { type: 'string', maxLength: 80 }, maxItems: 50, description: 'The whole "never add" list' } }, ['modelId']),
    run: async (env, a) => {
      const patch = Object.fromEntries(['name', 'niche', 'personality', 'look', 'notes', 'neverAdd'].filter(k => a[k] !== undefined).map(k => [k, a[k]]));
      if (!Object.keys(patch).length) throw badRequest('Send at least one field to change');
      return slim(await appCall(env.ctx, env.user, 'PATCH', `/v1/models/${enc(id(a.modelId, 'modelId'))}`, patch));
    },
  },
  {
    name: 'suite_queue_add', title: 'Queue the shot for later', scope: 'edit:write',
    description: 'Puts the AI Suite shot being set up (the open draft) in the run-later queue, as Add to queue does. Free: nothing runs until it is run from the queue (suite_queue_run, with the person\'s go-ahead).',
    inputSchema: obj({ assistId: str('The Suite draft (filled in when the Suite is open)', 80), title: str('A title for it', 80) }, ['assistId']),
    run: async (env, a) => {
      const v = await assistOf(env.ctx).get(env.user, id(a.assistId, 'assistId'));
      return slim(await appCall(env.ctx, env.user, 'POST', '/v1/suite/queue', { ...v.request, ...(typeof a.title === 'string' && a.title ? { title: a.title } : {}) }));
    },
  },
  {
    name: 'tool_run', title: 'Review a Dress up / Enhance run', scope: 'edit:write',
    description: 'A Dress up or Enhance run\'s results (get; list without runId), and the review as on the screen: decide one picture (slot, decision keep|reject, pick a|b), pick a or b for all, then apply the kept pictures to her sheet (apply; her old sheet stays in her sheet versions). Free. Watch the pictures before deciding.',
    inputSchema: obj({ action: { type: 'string', enum: ['list', 'get', 'decide', 'pick', 'apply'] }, runId: str('The run', 80), slot: str('The picture (decide)', 40),
      decision: { type: 'string', enum: ['keep', 'reject'] }, pick: { type: 'string', enum: ['a', 'b'] } }, ['action']),
    run: async (env, a) => {
      if (a.action === 'list') return slim(await appCall(env.ctx, env.user, 'GET', '/v1/tool-runs'), 20);
      const r = enc(id(a.runId, 'runId'));
      if (a.action === 'get') return slim(await appCall(env.ctx, env.user, 'GET', `/v1/tool-runs/${r}`), 40);
      if (a.action === 'decide') return slim(await appCall(env.ctx, env.user, 'PATCH', `/v1/tool-runs/${r}/items/${enc(id(a.slot, 'slot'))}`, { decision: a.decision, ...(a.pick ? { pick: a.pick } : {}) }), 40);
      if (a.action === 'pick') return slim(await appCall(env.ctx, env.user, 'POST', `/v1/tool-runs/${r}/pick`, { pick: a.pick }), 40);
      if (a.action === 'apply') return slim(await appCall(env.ctx, env.user, 'POST', `/v1/tool-runs/${r}/apply`, {}), 40);
      throw badRequest('action: list, get, decide, pick or apply');
    },
  },
];
