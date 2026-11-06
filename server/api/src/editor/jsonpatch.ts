// A small JSON Patch (RFC 6902 subset: add / remove / replace) for edit sessions: the server and both apps send each
// change to a project as a patch, and undo is the inverse patch. `diff` is deliberately simple so the Kotlin and Swift
// ports give byte-identical patches (fixture test/fixtures/editor/jsonpatch.json):
//   - objects: keys in sorted order; a key only in b → add, only in a → remove, in both → recurse;
//   - arrays: same length → recurse per index; different length → replace the whole array;
//   - anything else that differs (type change, number, string, boolean, null) → replace.
export type PatchOp = { op: 'add' | 'remove' | 'replace'; path: string; value?: unknown };
type J = unknown;

const isObj = (v: J): v is Record<string, J> => !!v && typeof v === 'object' && !Array.isArray(v);
const esc = (k: string) => k.replace(/~/g, '~0').replace(/\//g, '~1');
const unesc = (k: string) => k.replace(/~1/g, '/').replace(/~0/g, '~');

/** Deep equality for JSON values. */
export function jsonEqual(a: J, b: J): boolean {
  if (a === b) return true;
  if (Array.isArray(a)) return Array.isArray(b) && a.length === b.length && a.every((x, i) => jsonEqual(x, b[i]));
  if (isObj(a)) {
    if (!isObj(b)) return false;
    const ka = Object.keys(a).filter(k => a[k] !== undefined), kb = Object.keys(b).filter(k => b[k] !== undefined);
    return ka.length === kb.length && ka.every(k => k in b && jsonEqual(a[k], b[k]));
  }
  return false;
}

export function diff(a: J, b: J, path = ''): PatchOp[] {
  if (jsonEqual(a, b)) return [];
  if (isObj(a) && isObj(b)) {
    const out: PatchOp[] = [];
    const keys = [...new Set([...Object.keys(a), ...Object.keys(b)])].filter(k => a[k] !== undefined || b[k] !== undefined).sort();
    for (const k of keys) {
      const p = `${path}/${esc(k)}`;
      if (a[k] === undefined) out.push({ op: 'add', path: p, value: b[k] });
      else if (b[k] === undefined) out.push({ op: 'remove', path: p });
      else out.push(...diff(a[k], b[k], p));
    }
    return out;
  }
  if (Array.isArray(a) && Array.isArray(b) && a.length === b.length) return a.flatMap((x, i) => diff(x, b[i], `${path}/${i}`));
  return [{ op: 'replace', path, value: b }];
}

export class PatchError extends Error {}
const clone = <T>(v: T): T => (v === undefined ? v : JSON.parse(JSON.stringify(v)));

/** Applies a patch to a copy of doc. Throws PatchError when a path doesn't fit the document. */
export function applyPatch<T>(doc: T, patch: PatchOp[]): T {
  let root: J = clone(doc);
  for (const op of patch) {
    if (!op || typeof op.path !== 'string' || !['add', 'remove', 'replace'].includes(op.op)) throw new PatchError('bad patch operation');
    if (op.path === '') {
      if (op.op === 'remove') throw new PatchError('cannot remove the document');
      root = clone(op.value);
      continue;
    }
    if (!op.path.startsWith('/')) throw new PatchError(`bad path ${op.path}`);
    const parts = op.path.slice(1).split('/').map(unesc);
    let cur: J = root;
    for (let i = 0; i < parts.length - 1; i++) {
      const k = parts[i]!;
      if (Array.isArray(cur)) { const n = Number(k); if (!Number.isInteger(n) || n < 0 || n >= cur.length) throw new PatchError(`no ${op.path}`); cur = cur[n]; }
      else if (isObj(cur)) { if (!(k in cur)) throw new PatchError(`no ${op.path}`); cur = cur[k]; }
      else throw new PatchError(`no ${op.path}`);
    }
    const last = parts[parts.length - 1]!;
    if (Array.isArray(cur)) {
      const n = last === '-' ? cur.length : Number(last);
      if (!Number.isInteger(n) || n < 0 || n > cur.length || (op.op !== 'add' && n >= cur.length)) throw new PatchError(`no ${op.path}`);
      if (op.op === 'add') cur.splice(n, 0, clone(op.value));
      else if (op.op === 'remove') cur.splice(n, 1);
      else cur[n] = clone(op.value);
    } else if (isObj(cur)) {
      if (op.op !== 'add' && !(last in cur)) throw new PatchError(`no ${op.path}`);
      if (op.op === 'remove') delete cur[last];
      else cur[last] = clone(op.value);
    } else throw new PatchError(`no ${op.path}`);
  }
  return root as T;
}
