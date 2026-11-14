// Claude's raw JSON Patch (the apply_edit_ops "patch" op), read generously (owner report ci_a801154189c0: "bad patch
// operation" five times in a row, and Claude could not tell which operation or why). Accepts RFC 6902 as written —
// add, remove, replace, move, copy, test — and the usual near-misses: an op name in any case or a common synonym
// (set/update → replace, delete → remove, insert/append → add), a path without its leading "/", a dotted or bracketed
// path (tracks.3.items[2].blend), a path given as a list of keys, a "#/…" URI fragment. Everything ends up as plain
// add/remove/replace applied one at a time, so the session still stores (and the apps still receive) a diff of the
// result only. Each refusal names the operation's index, its op and path, and what is allowed.
import { badRequest } from '../errors.js';
import { applyPatch, jsonEqual, PatchError, type PatchOp } from './jsonpatch.js';

const ALIASES: Record<string, PatchOp['op'] | 'move' | 'copy' | 'test'> = {
  add: 'add', insert: 'add', append: 'add', push: 'add', create: 'add',
  remove: 'remove', delete: 'remove', del: 'remove', unset: 'remove',
  replace: 'replace', set: 'replace', update: 'replace', put: 'replace', change: 'replace',
  move: 'move', copy: 'copy', test: 'test',
};
export const PATCH_EXAMPLE = '{"op":"replace","path":"/tracks/1/items/0/blend","value":"screen"}';
const ALLOWED = `allowed: add, remove, replace (need "value" except remove), move and copy (need "from"), test (RFC 6902), e.g. ${PATCH_EXAMPLE}`;

const esc = (k: string) => k.replace(/~/g, '~0').replace(/\//g, '~1');
/** A path as a JSON Pointer, or null when it can't be one. */
export function pointer(path: unknown): string | null {
  if (Array.isArray(path)) return path.every(k => typeof k === 'string' || (typeof k === 'number' && Number.isInteger(k))) ? path.map(k => `/${esc(String(k))}`).join('') : null;
  if (typeof path !== 'string') return null;
  let s = path.trim();
  if (s.startsWith('#')) s = s.slice(1);
  if (s === '' || s === '/') return s === '' ? '' : '/';
  if (s.startsWith('/')) return s;
  if (s.includes('/')) return `/${s}`;
  // tracks.3.items[2].blend → /tracks/3/items/2/blend
  return '/' + s.replace(/\[(\d+|-)\]/g, '.$1').split('.').filter(Boolean).join('/');
}
function getAt(doc: unknown, ptr: string): { ok: true; value: unknown } | { ok: false } {
  if (ptr === '') return { ok: true, value: doc };
  let cur: unknown = doc;
  for (const raw of ptr.slice(1).split('/')) {
    const k = raw.replace(/~1/g, '/').replace(/~0/g, '~');
    if (Array.isArray(cur)) { const n = Number(k); if (!Number.isInteger(n) || n < 0 || n >= cur.length) return { ok: false }; cur = cur[n]; }
    else if (cur && typeof cur === 'object') { if (!(k in cur)) return { ok: false }; cur = (cur as Record<string, unknown>)[k]; }
    else return { ok: false };
  }
  return { ok: true, value: cur };
}
const short = (v: unknown) => { const s = JSON.stringify(v); return s === undefined ? 'nothing' : s.length > 60 ? `${s.slice(0, 57)}…` : s; };

/** The operations Claude sent, as a list (a JSON string, one operation on its own, or {patch|ops|operations: [...]}). */
export function patchList(raw: unknown): unknown[] {
  let ops = raw;
  if (typeof ops === 'string') { try { ops = JSON.parse(ops); } catch { throw badRequest(`patch.patch: a JSON Patch array, e.g. [${PATCH_EXAMPLE}] (this text isn't JSON)`); } }
  if (ops && typeof ops === 'object' && !Array.isArray(ops)) {
    const o = ops as Record<string, unknown>;
    if (typeof o.op === 'string') ops = [o];
    else for (const k of ['patch', 'ops', 'operations']) if (Array.isArray(o[k])) { ops = o[k]; break; }
  }
  if (!Array.isArray(ops) || !ops.length) throw badRequest(`patch.patch: a JSON Patch array, e.g. [${PATCH_EXAMPLE}]`);
  return ops;
}

/** Applies Claude's patch to a copy of doc, one operation at a time; a bad one is refused with its index, op, path and why. */
export function applyClaudePatch<T>(doc: T, raw: unknown): T {
  let cur = doc;
  patchList(raw).forEach((o, i) => {
    const at = (op: unknown, path: unknown, why: string) =>
      badRequest(`patch.patch.${i}: ${typeof op === 'string' ? `"${op.slice(0, 20)}"` : 'no op'}${typeof path === 'string' || Array.isArray(path) ? ` at ${short(path)}` : ''}: ${why} · ${ALLOWED}`);
    if (!o || typeof o !== 'object' || Array.isArray(o)) throw at(undefined, undefined, `must be an object like ${PATCH_EXAMPLE}`);
    const x = o as Record<string, unknown>;
    // {"replace": "/path", "value": …}: the op given as the key.
    let opName = x.op, rawPath = x.path;
    if (opName === undefined) { const k = Object.keys(ALIASES).find(a => typeof x[a] === 'string' && x.path === undefined); if (k) { opName = k; rawPath = x[k]; } }
    const kind = typeof opName === 'string' ? ALIASES[opName.trim().toLowerCase()] : undefined;
    if (!kind) throw at(opName, rawPath, typeof opName === 'string' ? 'unknown op' : 'needs "op"');
    const path = pointer(rawPath);
    if (path === null) throw at(opName, rawPath, 'needs "path", a JSON Pointer such as "/canvas/background"');
    const value = x.value;
    const one = (ops: PatchOp[]) => {
      try { cur = applyPatch(cur, ops); }
      catch (e) {
        if (!(e instanceof PatchError)) throw e;
        // Name what is there (the deepest part of the path that exists), so Claude can fix the path without another get_edit.
        const parts = path.split('/');
        let k = parts.length - 1;
        while (k > 0 && !getAt(cur, parts.slice(0, k).join('/')).ok) k--;
        const at0 = parts.slice(0, k).join('/'), v = (getAt(cur, at0) as { value: unknown }).value, missing = parts.slice(0, k + 1).join('/');
        const there = ` (${missing} doesn't exist; ${at0 || '/'} ${Array.isArray(v) ? `is a list of ${v.length}` : v && typeof v === 'object' ? `has ${Object.keys(v).slice(0, 14).join(', ')}` : `is ${short(v)}`})`;
        throw at(opName, path, `${e.message}${there}`);
      }
    };
    switch (kind) {
      case 'add': case 'replace':
        if (!('value' in x)) throw at(opName, path, 'needs "value"');
        // replace of an optional field that isn't set yet (opacity, blend, …) is an add: the project leaves unset fields out.
        if (kind === 'replace' && path !== '') {
          const parent = getAt(cur, path.slice(0, path.lastIndexOf('/')));
          if (parent.ok && parent.value && typeof parent.value === 'object' && !Array.isArray(parent.value) && !getAt(cur, path).ok) return one([{ op: 'add', path, value }]);
        }
        return one([{ op: kind, path, value }]);
      case 'remove': return one([{ op: 'remove', path }]);
      case 'move': case 'copy': {
        const from = pointer(x.from);
        if (from === null) throw at(opName, path, 'needs "from", the JSON Pointer to take the value from');
        const got = getAt(cur, from);
        if (!got.ok) throw at(opName, path, `no ${from} to ${kind} from`);
        if (kind === 'move' && (path === from || path.startsWith(`${from}/`))) { if (path === from) return; throw at(opName, path, 'can\'t move a value into itself'); }
        return one(kind === 'move' ? [{ op: 'remove', path: from }, { op: 'add', path, value: got.value }] : [{ op: 'add', path, value: got.value }]);
      }
      case 'test': {
        const got = getAt(cur, path);
        if (!got.ok) throw at(opName, path, 'test: nothing at this path');
        if (!jsonEqual(got.value, value)) throw at(opName, path, `test failed: it is ${short(got.value)}, not ${short(value)}`);
        return;
      }
    }
  });
  return cur;
}
