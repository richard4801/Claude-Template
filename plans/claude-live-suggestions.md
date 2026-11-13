# Live suggestion chips (owner request 2026-11-12)

Owner: the chips above Claude's chat input were static ("Watch my edit · Cut to the beat · Add captions"; Shot composer
"Fill this in from my idea · Make it more cinematic · Explain the settings"). They should follow what is on screen and
what just happened. Branch `claude/claude-live-suggestions` (from prod `claude/ecstatic-rubin-2egjfb`).

## How it works
- **Server** `server/api/src/claude/suggest.ts`, route `GET /v1/claude/suggestions` (plans/api.md). Free, fast and
  deterministic. There is **no model call**, so nothing is paid. A cheap model pass was optional; it is left out because it
  is not free on the server path (the owner's Claude plan runs on the Mac, not here).
- **Facts:** the open edit session's project (owner), the Suite shared draft (+ its `screen`), the person's latest job
  (render or editor job, within 15 min), Claude's last reply in the chat. The app adds what only it knows: the selection,
  the platform view (+ text outside the safe area), unsaved changes, a clip just imported, and the edit as it is on
  screen now. The server copy can lag, and a member's edit has no shared session.
- **Picking:** each rule has a priority and names the tools it leads to. A chip whose tools this person's chat lacks is
  never shown: members get no edit chips, because editing with Claude is the owner's. The 3 highest-priority chips are shown
  in a fixed catalog order. When there are fewer than 3, the general chips fill the gap. The page's fixed chips fill only
  when the server has no live facts for the page, so "Cut to the beat" can never show for an edit without music.
- **Apps:** refresh ~1 s after the context changes (page, edit, composer/draft, a job ending) and after each Claude reply.
  A chip that stays keeps its place (`steady`). Changes crossfade in 0.2 s (none with Reduce Motion). Offline, the apps
  show the old fixed chips; an older server gets `GET /v1/claude/chips`.

## Rules (catalog order = the order shown)
| id | Label | When | Tools | Prio |
|---|---|---|---|---|
| job.why | Why did it fail? | any page: the person's last job failed < 15 min ago | queue_list | 100 |
| job.watch | Watch the new take | any page: a video render finished < 15 min ago | watch | 80 |
| edit.watchNew | Watch the new clip | Edit: a video came into the edit (< 2 min, app) | watch, get_edit | 85 |
| edit.listenNew | Listen to the track | Edit: a sound came into the edit (< 2 min, app) | listen | 84 |
| edit.overlap | Fix the overlap | Edit: the app reports overlapping clips | get_edit, apply_edit_ops | 95 |
| edit.safe | Fix the safe area | Edit: platform view on and text centre outside its safe area | get_edit, apply_edit_ops | 90 |
| reply.yes | Yes, go ahead | Claude's last reply ends with a question | (answers Claude) | 78 |
| reply.first | Go with option 1 | Claude's last reply lists numbered options | (answers Claude) | 74 |
| job.retry | Run it again | the failed job is a video render (paid: Claude gives the price first) | job_retry | 70 |
| edit.trimSel | Trim this clip | Edit: a video/image clip is selected | watch, apply_edit_ops | 76 |
| edit.beatsSel | Find the beats | Edit: the music is selected, no beats marked | detect_beats | 76 |
| edit.styleSel | Restyle this text | Edit: a text is selected | get_edit, apply_edit_ops | 75 |
| edit.findTakes | Find takes to use | Edit: a blank project with no clips | library_find | 60 |
| edit.captions | Add captions | Edit: no captions, has a main clip | auto_captions | 62 |
| edit.beat | Cut to the beat | Edit: music, no beats marked | detect_beats, apply_edit_ops | 58 |
| edit.drop | Cut to the drop | Edit: music with strong beats marked | find_action_peaks, apply_edit_ops | 58 |
| edit.silences | Cut the silences | Edit: no music, no captions | cut_silences | 40 |
| edit.captionStyle | Restyle the captions | Edit: captions on | list_caption_styles, apply_edit_ops | 35 |
| edit.save | Save a version | Edit: unsaved changes (app) | save_version | 45 |
| edit.watch | Watch my edit | Edit: anything on the timeline | watch | 30 |
| suite.watchClip | Watch my clip | Swap/Remix/Recast/Extend with a clip | watch | 66 |
| suite.findClip | Find a clip | those tools without a clip | library_find | 64 |
| suite.fill | Build from my idea | Shot: prompt written, rig empty | suite_options, suite_set_draft | 70 |
| suite.write | Write the prompt | empty prompt | suite_set_draft | 60 |
| suite.cast | Pick a character | no @character (not Extend) | suite_cast, suite_set_draft | 56 |
| suite.cinematic | Make it more cinematic | rig set (not Photo) | suite_set_draft | 42 |
| suite.outfit | Look at the outfit | Photo with an outfit | suite_see | 44 |
| suite.price | Check the price | prompt and character set | suite_estimate | 38 |
| suite.explain | Explain the settings | always on the Suite | suite_get_draft | 20 |
| queue.running | What’s running | Queue: a job runs | queue_list | 50 |
| queue.clear | Clear failed jobs | Queue: the last job failed | queue_clear_failed | 40 |

Labels are at most 4 words and start with a verb. "Fill this in from my idea" became "Build from my idea" and "Move
text into safe area" became "Fix the safe area" to stay within 4. Icons are Phosphor names in both apps' sets (a test
checks). The magic-wand icon is not used (design review).

## Patches (apps; NOT compiled for Mac in this session, there is no Swift here)
- `plans/patches/claude-live-suggestions-mac.patch`. **Apply base:** `claude/mac-bundle-9` @4a01e2e1 (bundle-9 as
  integrated), as Mac bundle-10's first patch; then `edit-audio-approvals-mac` (claude/edit-panels-clean) and
  `edit-safe-warning-shots-mac` (claude/edit-platform-preview) apply after it with plain `git apply` (checked).
  MuseCore `ClaudeSuggest.swift` (query, steady order, demo copy of the Edit rules) + tests; `ClaudeAPI.claudeSuggestions`;
  AppStore live refresh (debounced, after replies, jobs, composer); Edit reports its facts; Suite panel live chips;
  crossfade in ChatComposer. CI: new step "Claude live chips check" (`claude-chips-check.txt`, FAIL lines fail CI) with
  shots `mac_a_edit_chips_no_captions.png` / `mac_a_edit_chips_captions.png`.
- `plans/patches/claude-live-suggestions-android.patch` (on prod). Android has no one-Claude page chips yet; its one
  row (the Suite's Claude sheet) goes live with a crossfade. Core `ClaudeSuggest.kt` + test.
  When Android gets the one-Claude panel, it uses `ClaudeSuggestQuery` + `GET /v1/claude/suggestions` the same way.

## Not done / later
- Android Edit chips: they wait for the Android one-Claude panel.
- "Retry on h3" (the owner's example) is not a separate chip. "Run it again" reruns the job with the same settings; choosing
  another engine is a question for Claude.
- The overlap rule needs the app to report `overlap=1`. A saved project can't overlap (the validator refuses it), so the
  Mac sends it only if its timeline ever allows overlaps during a drag. Today it doesn't send it.
