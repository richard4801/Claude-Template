# MUSE · handover for a new coordinator session (written 2026-11-11)

Read this first, then `plans/coordination.md` (rules, history) and the plan files named below. Everything here is on the
prod branch `claude/ecstatic-rubin-2egjfb` (auto-deploys the server to Railway:
https://angelic-elegance-production-c42b.up.railway.app). Prod head when written: see `git log -1`.

## 1. Your role and the owner's rules
- You coordinate MUSE: Android app (`android/`), Mac app (`mac/`), Node/TS server (`server/api/`). You direct parallel
  sessions, merge only green work, push, and report to the owner in plain language (the owner is not a programmer).
- Standing push rule (owner): "Push anything that's green on all checks and that I've already approved in principle
  (fixes, approved designs). Still ask me for new features or anything that spends money."
- No half-working features. New jobs go to NEW sessions; finished sessions are archived. Ask clarifying questions.
- Urgent server fixes are pushed alone; never make them wait behind a long Android/Mac run.
- Security (verbatim): "Never ask me to paste it into chat, and never read, print, log, or commit it. Keep credentials
  server-side." No production DB reads. Members never see provider or model names. Confirm spend. No @vvspolly.
- The owner is tight on weekly tokens: be economical, save requests to plans, fixes before features.
- Declined for good (do not build): per-download unique hash, micro-scale/gamma shifts, audio perturbation (platform
  detection evasion). AI music is dropped.

## 2. Checks (what "green" means)
- Server: `cd server/api && npx tsc --noEmit -p . && npx vitest run --maxWorkers=2` (run the WHOLE suite before pushing
  prompt or contract changes: a subset missed two fixtures on 2026-11-10). `recreate-motion.test.ts` is a known load flake.
- Prompt text changes: regenerate `npx tsx scripts/gen-shoot-fixture.ts` (Android prompt_library.json) and
  `npx tsx scripts/gen-prompt-scripts.ts` (Mac fixture); `test/legacy/engine.ts` is the old-wording snapshot.
- Android: `:core:test :app:testDebugUnitTest` and `:app:assembleRelease`.
- Mac: CI `.github/workflows/mac.yml` on pushes touching `mac/` (45–55 min; build number = run number; artifact
  `MUSE-mac`). A runner-capacity failure needs the owner to press "Re-run jobs" (our API rerun is 403).
- Shared editor contract: `server/api/src/editor/model.ts` + `server/api/test/fixtures/editor` are shared by Android and
  Mac; a contract change merges only after the Mac CI is green.
- Migrations in prod up to 0028; next free is 0029. Railway is the Trial plan (~512 MB RAM).

## 3. What the owner has installed
- Mac: build 510 (sent 2026-11-10). Android: 0.1.9. Both are behind prod on app-side work only; an Android 0.2.0 build
  and a new Mac build wait for the owner's go. Server-side fixes need no app update.

## 4. Pushed on 2026-11-10 (server, live; NOT yet confirmed by the owner in the app)
- Custom (Muapi/fal/Replicate own-key) image models serve every image purpose (Photo, Outfits, Character photos,
  Background plates) and can be the default for each. Outfits on a custom model = 4 new shots (4 x per shot).
- Video pickers load the studio's custom models themselves (added/renamed models show at once).
- Character swap figure lock: with an outfit, references are face front, face profile (+ Dress up face ¾), then outfit
  front, ¾, side, back (base body shots left out); the prompt takes her figure from her images and never from the clip.
  If the owner edited the swap "Retention" prompt in Settings, their edit wins: tell them.
- Prompt skill (both copies: `.claude/skills/muse-prompt-structure/SKILL.md` and
  `server/api/assets/skills/muse-prompt-structure.md`, keep them identical): "Figure lock" rule.
- Claude in Edit: `detect_beats` returns beatTimes and strongTimes.
- Check first: the Mac CI run for the last pushes (a Mac test fixture changed), and that Railway deployed.

## 4b. PRIORITY ORDER (read this before section 5; it overrides the lettering there)
1. Bugs the owner hits today: Claude chat typing disturbs the Edit page (5A.6); Mac Edit oval (5A.1); Mac Export to
   file (5A.2).
2. Character consistency (the owner's top concern): matching body angle per outfit picture (server-only,
   `plans/outfit-head-looks.md` §1); confirm the swap figure lock with the owner; Claude sees outfit/model images (5A.5);
   body-notes box.
3. Metadata cleanup + AI-label switch (5A.3).
4. Claude made capable: ops reference, motion strip, loudness (5D first part); video flip book + video uploads (5C).
5. One Claude with full control (section 6): design to the owner, then build in the order given there.
6. Head looks + accessories (designs first); custom video models in Character swap (5B).
7. Editor depth: on-preview dragging and free Mac timeline (5A.4), chroma on images, rounded masks, layer order, groups.
8. The rest of 5E and 5F.
The owner may reorder: ask at the start of the new session.

## 5. The queue, in order (owner-approved unless marked ASK)
A. Owner bugs first (`plans/edit-xl-options.md`, "Owner bugs to fix FIRST"):
   1. Mac Edit oval bug: the clip's subject turns see-through and the background shows as an oval. Clue: the app applies
      the cut-out matte itself (alphaMatte); suspect an inverted or stand-in matte on the Mac. Prove with a pixel probe.
   2. Mac Export must also save the file to the Mac (Save panel, "Show in Finder"), not only to the Library.
   3. Required metadata cleanup on every stored/exported generated file (video remux `-map_metadata -1 -c copy`; photos
      re-saved without EXIF/XMP), then the "Label as AI-generated" switch adds MUSE's label only when on.
   4. Direct manipulation: on-preview drag/resize/rotate for text, captions, stickers, overlays with safe-area snapping;
      free timeline dragging on the Mac.
   5. Flaw: Claude in the Suite can't see outfit or model images (name and id only). Send the images (small) + dates.
   6. NEW bug (2026-11-11): typing in the Claude chat inside Edit triggers things on the edit page (likely the editor's
      keyboard shortcuts firing while the chat field has focus: space = play, delete = remove clip, letters = tools).
      Fix: shortcuts off while any text field is focused; add a test. Ask the owner which app (assume Mac first).
B. Custom video models that take a video input in Character swap, Recast, Extend, Recreate swaps (server-only; plan in
   `plans/edit-xl-options.md`, "Custom … video models"). Owner said: after the reset.
C. Claude video vision (`plans/claude-video-vision.md`): Stage 1 free flip book (motion-picked frames, contact sheets,
   "look closer" tool) + video uploads in Claude chat (both apps + server). Stage 2 (paid video-notes pass) only if
   Stage 1 still misses: ASK (needs a key and spend).
D. Claude-in-Edit gaps (`plans/claude-edit-gaps.md`): ops reference Claude can read, fine-step motion strip, loudness
   summary; then chroma key on images + rounded-rectangle masks; then free layer order + grouped layers; then uploads
   from the Mac; frame extension (ASK: spend).
E. Small items: body-notes box on the character page in both apps (server field `look` already exists; ~20 min);
   "Photos sent" row in a job's details (ASK); photo size picker 1K/2K/4K and relabel "7 shapes" as aspect ratios;
   Android Suite stage fix (`plans/suite-stage-fix.md`, "Android (later)"); download log and "Suggest caption and
   hashtags" helper (offered, saved); Railway Hobby upgrade (ASK: money).
   Outfits (`plans/outfit-head-looks.md`, owner-decided 2026-11-11): (1) matching body angle per outfit picture
   (server-only fix, do early); (2) Head looks inventory (hair, makeup, face accessories; 4 pictures incl. back of
   head) chosen or generated when making an outfit; (3) accessories baked into the Head look or the Outfit, from
   product photos, description optional. Designs to the owner before building 2 and 3.
F. Unmerged work: branch `claude/muse-android-edit` has ONE commit not in prod (90dc3c11 "Cut to the music":
   cutToMusic / musicBeatTimes with fixture, Android Edit pace control). It touches the shared editor contract: run the
   server suite and the Mac CI before merging. The rest of that session's list is NOT built: pen mask, save as template,
   find shorts, brush refine, upscale in Export, teleprompter, Post button (Android), their Mac ports, and the
   effects-library server render. Start these in new sessions.

## 6. NEW owner vision (2026-11-11): one Claude with full control. Design first, then ASK before building.
The owner's words: "too rough that we have a different Claude for every mode… I think it makes sense to be one"; "Claude
should have full control anywhere on our app… provided I give it the go ahead"; "I mean it when I say full access."
1. One Claude everywhere: the same assistant, tools and memory on every page, aware of the page the owner is on, able to
   navigate the app itself (open a page, a take, a character, the editor). Today: separate tool sets and a thread per
   mode (`0028_claude_thread_sessions`, suite/mcpTools.ts, editor/mcpTools.ts, recreate/mcpTools.ts, routes/mcp.ts).
   DECIDED (owner, 2026-11-11): one Claude with several chats. Chats are per piece of work (not per page/mode) and
   follow the owner across pages; one shared memory (her figure rules, style, preferred models, rejections) in every
   chat; Claude can look into other chats when asked.
2. Full capability inside Edit: everything the app offers (Shot, Photo, Talking, UGC, Storyboard, Recast, Swap, Extend,
   Upscale, Recreate, outfits, characters) without leaving the edit. Runs in the background; Claude reports progress and
   drops the result on the timeline or in the Library.
3. Blocking with Blender (the 3D camera guide): Claude opens that page itself, runs a blocking session with the owner,
   and passes the result to a model.
4. Long videos: Claude alone makes a video longer than 15 s by chaining: generate ≤15 s, take the last frame, extend
   from it, repeat, then join (one continuous character, figure lock, matching light). H3 stops at 15 s.
5. Go-ahead model: Claude may do anything, but spends money, deletes, posts or changes settings only after the owner's
   yes (price shown first). Never sees or handles credentials. Members never see provider names.
6. Capabilities to cover that the owner did not list (propose, let the owner choose): Library (find, tag, organise,
   delete with confirm); characters and outfits (create, fill angles, Dress up); Queue (watch, cancel, retry, notify
   when done); versions and undo everywhere; export and posting/scheduling with captions and hashtags; templates and
   presets; model/provider choice and defaults (never keys); prompts library and playbook/memory of the owner's taste;
   budgets (a spend cap per session, a running total); batch jobs ("make 5 variants"); multi-step plans with
   checkpoints; reading its own results (video vision, outfit images) to self-check before showing the owner.
7. Order suggested: (a) one tool registry + page context + navigation, (b) generation tools in Edit with background
   progress, (c) long-video chain, (d) Blender blocking, (e) the rest of 6.

## 7. Sessions
All sub-sessions are archived as of this handover (their work is merged, except item 5F). Start fresh ones per job.
