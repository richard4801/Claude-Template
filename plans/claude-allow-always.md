# Allow always (owner, 2026-11-12)

Owner: "Claude always asks me for permission every single time… When I give it access to a folder or bash once, it
shouldn't ask again. The options should be Allow now or Allow always."

Mac only (Claude Code's file and command calls on the person's Mac). Patch: `plans/patches/claude-allow-always-mac.patch`,
applies after Mac bundle-9 (edit-panels-clean → link-to-uploads → note-icon → edit-continue-draft → hdr-export-5) and
bundle-10 (claude-live-suggestions → edit-audio-approvals → edit-safe-warning-shots). No server change: the Mac answers
covered questions itself, so Claude Code gets an allow without a card.

## What the person sees
- Card: **Allow once** (filled), **Allow always** / **Allow always: ffmpeg commands** (quiet), **Deny** (plain). One line
  under the detail says what Always covers ("Allow always covers ~/Movies/Shoot in every chat"), or why it isn't offered
  ("Always asks: it deletes files").
- Settings → Account → Claude: **Ask before anything** switch (pauses the whole list, keeps it), and one **Always allowed**
  list of folders and command kinds, each with Remove.
- Old per-chat folders move to the list on first launch (folders too wide to always allow are dropped and ask again).

## Rules (MuseCore `ClaudeAlwaysRules`, tests `ClaudeAlwaysRulesTests`)
- File calls: Always allows the file's folder (a listing's folder itself) for every chat. Never for the home folder,
  a top-level or system folder, a whole disk, or ~/Library. Writes outside allowed folders still ask. Keys refused as before.
- Commands: the rule is the program (`ffmpeg`, `ffprobe`, `afconvert`, `ls`, `cat`, `cp`, `mkdir`, `grep`, `find`, `jq`…),
  `git <sub>` for read/record subcommands (status, log, diff, show, add, commit…), or `<interpreter> scripts`
  (python3/node/bash… with a script file; never `-c`/`-e`/`-m`). A covered command runs without a card only when every
  path it names (arguments, `key=/path` and `scheme:/path` parts, redirect targets) is inside an allowed folder or the
  chat's own run folder. A path outside: the card offers Always and names the folder it would add.
- Scripts are read: delete/move/run/network calls, `expanduser`/`environ`, or a written path outside the folders → asks.
- Never Always (card shows Allow once / Deny + why): rm/rmdir/unlink/trash/`find -delete`, mv, sudo/su, chmod/chown,
  kill/killall, curl/wget/ssh/rsync, brew/pip/npm installs, URLs/network schemes, git push/reset/clean/checkout/…,
  osascript/open/launchctl/defaults…, ~/Library, keys, `; && || | &`, `$( )`, backticks, variables, here-documents,
  redirects outside allowed folders, `VAR=x cmd`, xargs/env/eval/awk/sed/make, unknown programs, programs run by path.
- Paid, delete and post actions in MUSE keep their own Approve cards (unchanged).

## Checks
- MuseCore: whole suite green on Linux (Swift 6.0.3), incl. `ClaudeAlwaysRulesTests` (10) and `ClaudeFileAccessTests`.
- Mac CI step "Claude allow-always check" (`SnapshotRunner+ClaudeAllowAlways.swift`, `claude-allow-check.txt`, shots
  `mac_a_claude_allow_*.png`). Not yet run on a Mac (the app target can't build on Linux).

## Known limits / follow-ups
- Pipes (`ffmpeg … 2>&1 | tail`) and `cd dir && …` always ask, as the owner's rule says; if the owner finds that too
  chatty, a later step could allow a pipe into tail/head/grep/wc when each part is itself covered.
- A script's dynamic paths (built at run time) can't be checked; obvious delete/run/network calls and written paths are.
