// Real Postgres for tests that need the wire protocol (COPY): TEST_DATABASE_URL when set, else a throwaway server started
// from local Postgres binaries (/usr/lib/postgresql/*/bin) on a free port. Returns null when neither is available.
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import pg from 'pg';

export type TempPg = { url: (db: string) => string; createDb: (name: string) => Promise<string>; stop: () => Promise<void> };

function findBin(): string | null {
  const roots = ['/usr/lib/postgresql'];
  for (const r of roots) {
    if (!fs.existsSync(r)) continue;
    const versions = fs.readdirSync(r).sort((a, b) => Number(b) - Number(a));
    for (const v of versions) if (fs.existsSync(path.join(r, v, 'bin', 'initdb'))) return path.join(r, v, 'bin');
  }
  const w = spawnSync('sh', ['-c', 'command -v initdb'], { encoding: 'utf8' });
  return w.status === 0 && w.stdout.trim() ? path.dirname(w.stdout.trim()) : null;
}

const freePort = () => new Promise<number>((res, rej) => {
  const s = net.createServer();
  s.once('error', rej);
  s.listen(0, '127.0.0.1', () => { const p = (s.address() as net.AddressInfo).port; s.close(() => res(p)); });
});

export async function startTempPg(): Promise<TempPg | null> {
  const ext = process.env.TEST_DATABASE_URL;
  if (ext) {
    const base = new URL(ext);
    base.searchParams.set('sslmode', 'disable');
    const url = (db: string) => { const u = new URL(base); u.pathname = `/${db}`; return u.toString(); };
    const made: string[] = [];
    return {
      url,
      createDb: async name => {
        const c = new pg.Client({ connectionString: base.toString() }); await c.connect();
        await c.query(`drop database if exists "${name}" with (force)`); await c.query(`create database "${name}"`); await c.end();
        made.push(name); return url(name);
      },
      stop: async () => {
        const c = new pg.Client({ connectionString: base.toString() }); await c.connect();
        for (const n of made) await c.query(`drop database if exists "${n}" with (force)`).catch(() => {});
        await c.end();
      },
    };
  }
  const bin = findBin();
  if (!bin) return null;
  const isRoot = process.getuid?.() === 0;
  if (isRoot && spawnSync('id', ['postgres']).status !== 0) return null;
  const run = (cmd: string, args: string[]) => {
    if (!isRoot) return execFileSync(cmd, args, { stdio: 'pipe' });
    const q = [cmd, ...args].map(a => `'${a.replace(/'/g, `'\\''`)}'`).join(' ');
    return execFileSync('su', ['postgres', '-s', '/bin/sh', '-c', q], { stdio: 'pipe' });
  };
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-pg-'));
  fs.chmodSync(dir, 0o777);
  if (isRoot) execFileSync('chown', ['postgres', dir]);
  const data = path.join(dir, 'data');
  const port = await freePort();
  try {
    run(path.join(bin, 'initdb'), ['-D', data, '-A', 'trust', '-U', 'postgres', '-E', 'UTF8', '--no-sync']);
    run(path.join(bin, 'pg_ctl'), ['-D', data, '-o', `-p ${port} -k ${dir} -c listen_addresses=127.0.0.1 -c fsync=off`, '-l', path.join(dir, 'log'), '-w', 'start']);
  } catch {
    fs.rmSync(dir, { recursive: true, force: true });
    return null;
  }
  const url = (db: string) => `postgres://postgres@127.0.0.1:${port}/${db}?sslmode=disable`;
  return {
    url,
    createDb: async name => {
      const c = new pg.Client({ connectionString: url('postgres') }); await c.connect();
      await c.query(`create database "${name}"`); await c.end();
      return url(name);
    },
    stop: async () => {
      try { run(path.join(bin, 'pg_ctl'), ['-D', data, '-m', 'immediate', 'stop']); } catch { /* already gone */ }
      fs.rmSync(dir, { recursive: true, force: true });
    },
  };
}
