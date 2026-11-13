# Edit: continue a draft (owner, 2026-11-12)

"When you click on Edit, you should see the last draft you were editing." Mac first, Android after.

## Owner decision (2026-11-12, after the first build)
Edit does NOT jump into the last draft. The Edit home opens on a choice with two tiles: "New" and "Continue draft" (the last
edit's picture, name and "5 min ago"; the primary, with the accent edge). With no draft, only New shows. Older Recent edits
are listed below. Continue draft does everything below; New starts a blank project (Mac). Android has no blank project yet,
so its New scrolls to the videos to start from.

## What it does
- Continue draft opens the last edit, back where it was left: timeline, playhead, zoom, selected clip, inspector tab, media
  bin tab (Uploads…), platform view (TikTok/Reels/Shorts or off), timeline/captions mode. With no edit yet: the Edit home.
- Autosave: the project is already pushed to the owner's edit session about 0.5 s after each change. Where the editor
  stands is now saved about 0.8 s after it changes, and again when the editor closes: on this Mac and on the session.
- Edit home: the New / Continue draft choice, then "Recent edits" (picture, name, when it was last worked on), up to 8
  more. The editor's Back leads here. A take tile with a recent edit continues that edit.
- Missing media: an edit whose take or upload is gone still opens. Its clips show a "Missing" mark on the timeline.
- Owner: the server's sessions, so all devices match (`GET /v1/edit-sessions?recent=1`, `POST …/{id}/view`, migration
  0035 `edit_sessions.view`). Members: edit sessions are owner-only, so a member's last edits (project + view) are
  kept on their Mac (`~/Library/Application Support/MUSE/EditDrafts/recent.json`, 12 edits).
- An empty blank project ("New edit" opened and left with nothing added) isn't listed.

## Pieces
- Server: `editor/sessions.ts` (`saveView`, `recent`, `cleanView`, `lastTouched`), `sessionRoutes.ts`, test in
  `editor-sessions.test.ts`.
- Mac patch `plans/patches/edit-continue-draft-mac.patch`. It applies after edit-panels-clean-mac, link-to-uploads-mac
  and note-icon-mac on prod 852d6b53. Contents: MuseCore `Edit/EditRecent.swift` (view snapshot/restore, the recent-list
  merge, the local store, missing assets, "5 min ago"), `EditRecentTests` (10 tests), and API + fake. App:
  `EditSuiteResume.swift`, `AppStore+EditRecent.swift`, `EditSuiteView` (opens the last edit, Recent edits, New edit),
  the timeline's Missing mark, and the CI check `SnapshotRunner+EditResume.swift` → `edit-resume-check.txt` (open Edit →
  the choice shows and nothing opens by itself → Continue draft reopens at the saved place → a deleted take's edit opens
  with Missing → New starts blank; a mac.yml step fails on FAIL or a missing ALL DONE).

## Android
Patch `plans/patches/edit-continue-draft-android.patch`. It applies on prod 852d6b53 after edit-platform-preview-android.patch
(Android bundle-8). Contents:
- Core `edit/EditRecent.kt`: `EditPlace` (the same `view` JSON as the Mac and the server), the recent-list merge, the phone's
  file format, missing assets, "5 min ago"; `EditRecentTest` (6 tests).
- App: `EditResume.kt` (the phone's `edit-recent.json`, the recent list, `placeOf` / `restorePlace`). In
  `EditSuiteScreen`: the home opens on the New / Continue draft choice, with older "Recent edits" below. In the view
  model: the place is restored after load and saved 0.8 s after changes and on close (the owner's on the session). A
  member's project is kept on the phone and reopened. A deleted take's edit opens from the session or the phone copy, with
  its clips marked "Missing" on the timeline. API `recentEditSessions` / `saveEditView` (Http + Fake);
  `EditResumeTest` (4 tests).
- The place saved: playhead, zoom (dp/s), the open panel as `tab` (Mac "captions"/"text"/"audio" match), selection, and
  the platform view as `safeArea`. Fields Android doesn't show (Mac `binTab`, `mode`) are kept from the last place.
- Android has no blank project yet: its New tile scrolls to the videos (picking one starts the edit).
- The owner opening an edit whose take was deleted: the place goes to the session; the project changes are kept on
  the phone (a session opens by take id), and reopening there uses the phone copy.

## Known limits
- Member drafts are per Mac, not per signed-in member (a shared Mac shows the last member's edits).
- A blank project resumed after its first save still saves the next time as a new Library video (as before for blanks).
