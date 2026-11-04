// npm run invite -- someone@example.com [--owner|--member] [--studio "Studio name"] [--days 14]
// Prints a one-time invite code. The first invite for a studio with no owner is an owner invite.
// Uses DATABASE_URL like the server (run it in Railway's shell, or locally against the Railway database URL).
import { loadConfig } from '../config.js';
import { openDb } from '../db/client.js';
import { createInvite, ensureStudio } from '../auth/auth.js';

const args = process.argv.slice(2);
const email = args.find(a => !a.startsWith('--') && a.includes('@'));
const flag = (n: string) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : undefined; };
const role = args.includes('--owner') ? 'owner' : args.includes('--member') ? 'member' : undefined;

const config = loadConfig();
if (!config.DATABASE_URL || config.DATABASE_URL.startsWith('pglite')) {
  console.error('Set DATABASE_URL to the Postgres database first (an embedded database would forget the invite).');
  process.exit(1);
}
const h = await openDb(config.DATABASE_URL);
try {
  const studio = await ensureStudio({ db: h.db }, flag('--studio') ?? 'MUSE Studio');
  const inv = await createInvite({ db: h.db }, { studioId: studio.id, email: email ?? null, role, days: Number(flag('--days') ?? 14) });
  console.log(`\nInvite for ${inv.email ?? 'anyone'} (${inv.role}) to "${studio.name}", valid until ${new Date(inv.expiresAt).toISOString().slice(0, 10)}:\n\n    ${inv.code}\n\nIt works once. Sign up in the MUSE app with this code.\n`);
} finally {
  await h.close();
}
