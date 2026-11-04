import crypto from 'node:crypto';

/** Short random id with a prefix, like the mock ("j_3f2a9c1b"). */
export const uid = (prefix: string) => `${prefix}_${crypto.randomBytes(6).toString('hex')}`;
export const randomToken = (bytes = 32) => crypto.randomBytes(bytes).toString('base64url');
export const sha256 = (s: string | Buffer) => crypto.createHash('sha256').update(s).digest('hex');
export const sleep = (ms: number) => new Promise<void>(r => setTimeout(r, ms));
export const round2 = (v: number) => Math.round(v * 100) / 100;

/** Local midnight and the first of the month, in the server's time zone (set TZ on the host). */
export function dayStart(now = Date.now()) { const d = new Date(now); d.setHours(0, 0, 0, 0); return d.getTime(); }
export function monthStart(now = Date.now()) { const d = new Date(now); d.setDate(1); d.setHours(0, 0, 0, 0); return d.getTime(); }

/** Drop null/undefined fields so optional contract fields are absent rather than null. */
export function compact<T extends Record<string, any>>(o: T): T {
  const out: any = {};
  for (const [k, v] of Object.entries(o)) if (v !== null && v !== undefined) out[k] = v;
  return out;
}
