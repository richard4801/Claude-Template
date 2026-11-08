// Bring your own provider · API keys at rest. AES-256-GCM with a server secret (PROVIDER_KEYS_SECRET: 32 bytes as 64 hex
// characters or base64). Fails closed: without a valid secret nothing is encrypted or decrypted. The provider row id is
// bound as associated data, so a ciphertext copied onto another row doesn't decrypt. Keys never appear in errors or logs.
import crypto from 'node:crypto';
import { ApiError } from '../errors.js';

const VERSION = 'v1';

/** The 32-byte key from the env value, or null when it is missing or malformed. */
export function keyFromSecret(secret: string | undefined | null): Buffer | null {
  const s = (secret ?? '').trim();
  if (!s) return null;
  if (/^[0-9a-fA-F]{64}$/.test(s)) return Buffer.from(s, 'hex');
  if (/^[A-Za-z0-9+/_-]{43}=?$/.test(s)) {
    const b = Buffer.from(s.replace(/-/g, '+').replace(/_/g, '/'), 'base64');
    if (b.length === 32) return b;
  }
  return null;
}

export const keysUnavailable = () =>
  new ApiError(503, 'provider_keys_unavailable', "Provider keys can't be stored on this server yet · the owner must set PROVIDER_KEYS_SECRET");

export function sealKey(secret: Buffer | null, plain: string, rowId: string): string {
  if (!secret) throw keysUnavailable();
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv('aes-256-gcm', secret, iv);
  c.setAAD(Buffer.from(rowId));
  const ct = Buffer.concat([c.update(plain, 'utf8'), c.final()]);
  return `${VERSION}:${Buffer.concat([iv, c.getAuthTag(), ct]).toString('base64')}`;
}

export function openKey(secret: Buffer | null, sealed: string, rowId: string): string {
  if (!secret) throw keysUnavailable();
  const [v, body] = sealed.split(':');
  if (v !== VERSION || !body) throw new ApiError(500, 'provider_key_unreadable', "The provider's key can't be read · add it again in Settings");
  const raw = Buffer.from(body, 'base64');
  try {
    const d = crypto.createDecipheriv('aes-256-gcm', secret, raw.subarray(0, 12));
    d.setAAD(Buffer.from(rowId));
    d.setAuthTag(raw.subarray(12, 28));
    return Buffer.concat([d.update(raw.subarray(28)), d.final()]).toString('utf8');
  } catch {
    throw new ApiError(500, 'provider_key_unreadable', "The provider's key can't be read · add it again in Settings");
  }
}

/** "…a1b2": the only part of a key the API ever returns. */
export const last4 = (key: string) => `…${key.trim().slice(-4)}`;
