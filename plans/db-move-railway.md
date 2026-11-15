# Moving the database from Neon to Railway (one time)

Neon's free plan ran out of network transfer, so the server can't reach its database. These steps copy everything
into a PostgreSQL database inside Railway. The server does the copy by itself when it starts. You only click.

**Before you start:** the new server code must already be deployed (the branch with this file merged into the
production branch). Do steps 1 and 2 first. Upgrade Neon (step 3) only when you're ready to do steps 4 to 6 straight
away, because Neon bills by the hour while it's upgraded.

## 1. Add PostgreSQL in Railway

1. Open your Railway project (the one with the `angelic-elegance` service).
2. Click **+ Create** (or **+ New**), then **Database**, then **Add PostgreSQL**.
3. Wait until the new **Postgres** box shows it's running (about a minute).

## 2. Keep the old Neon address handy (inside Railway)

1. Click the **angelic-elegance** service, then the **Variables** tab.
2. Find **DATABASE_URL**. Click the eye icon (or the three dots, then copy) to copy its current value. That's the old
   Neon address.
   Don't paste it into chats, emails or documents. Paste it only into Railway, as described in step 4.

## 3. Upgrade Neon (only now)

In the Neon console, upgrade the project to a paid plan so that it can be reached again. Neon bills by the hour from
here on. The copy takes a minute or two.

## 4. Set the variables (all in one go)

Still in **angelic-elegance → Variables**:

| Variable | Set it to |
|---|---|
| `MIGRATE_FROM_DATABASE_URL` | *New variable.* Paste the old Neon address you copied in step 2. |
| `DATABASE_URL` | Replace the value with exactly `${{Postgres.DATABASE_URL}}` (Railway turns this into the new database's address). |
| `DATABASE_URL_UNPOOLED` | **Delete** this variable (it points at Neon). If you forget, the server ignores it anyway. |

Then click **Deploy** (Railway shows a "Deploy changes" bar after you edit variables).

## 5. Watch it finish

Open `https://<your server address>/health` in a browser (the same address the app uses). Look for `dbCopy`:

| You see | Meaning |
|---|---|
| `"state": "running"`, `tablesDone` going up | Copying. Refresh in 30 seconds. |
| `"state": "done"` and `rowsCopied` = `rowsTotal` | **Finished.** Every table was checked: each has the same number of rows as in Neon. |
| `"state": "failed"`, `"willRetry": true` | It couldn't reach Neon (`error: source_unreachable` or `source_quota`). Neon isn't upgraded yet, or it's still waking up. It tries again by itself. |
| `"state": "failed"`, `"willRetry": false` | It stopped. Nothing was changed in the new database. The app stays offline. Send the `error` word to Claude. |
| `"state": "refused"` | The new database already had accounts in it, so nothing was copied (it never overwrites). Send this to Claude. |

While it copies, the app shows "moving its database" and `/health` reports `"phase": "database_copy"`. When it's done,
the app starts normally, and `/health` shows the usual fields plus `"dbCopy": {"state": "done", …}`.

Error words: `source_auth` means the Neon address is wrong (paste it again in step 4). `target_auth` or
`target_unreachable` means `DATABASE_URL` isn't exactly `${{Postgres.DATABASE_URL}}`. `source_quota` means Neon is
still blocked (upgrade it).

## 6. Afterwards

1. Sign in to the app and check that your models, posts and balance are all there.
2. Downgrade Neon back to free (or delete the Neon project once you're happy). The copy won't run again.
   `MIGRATE_FROM_DATABASE_URL` can stay set (the new database remembers that the copy is done) or you can delete it.
   Deleting it is tidier.

## How it works (for Claude)

`server/api/src/db/copy.ts`, called from `src/index.ts` before `buildApp`. The copy reads Neon once, in one read-only
snapshot (the `-pooler` host is swapped for the direct one). It runs the target's migrations up to the source's
version, truncates, COPYs every `public`/`drizzle` table in foreign-key order, copies the sequences (never below
`max(id)`), checks the row count of every table, and writes `public._muse_copy_state`. All of this happens in one
transaction on the target, so a failure leaves it empty. A target with rows in `users` and no marker is refused. A
temporary `/health`-only server answers during the copy, so Railway's 60 s health check doesn't kill it. The app
isn't started after a failed copy, because it would seed rows into the empty database. Neither the logs nor
`/health` show addresses, hosts or user names. The logs show table names and row counts only.
