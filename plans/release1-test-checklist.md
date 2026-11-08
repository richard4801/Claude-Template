# MUSE Release 1: owner test checklist

## Install
- **Mac:**
  1. Open https://github.com/richard4801/Claude-Template/actions/runs/42505106768.
  2. Under Artifacts, download **MUSE-mac** and unzip it.
  3. Open Terminal and run `xattr -dr com.apple.quarantine ~/Downloads/MUSE.app` (adjust the path if needed).
  4. Open the app.
- **Android:** install **MUSE-0.1.0-release.apk**, which was sent to you in the app.
  - Keep **muse-release.jks** and **muse-release-signing.txt** somewhere safe; every future update needs them.

## Money tests (about $3 in total; each asks before spending)
1. **Upscale:** a finished 5 s take → Upscale → 1080p (about $0.43).
2. **AI editing tools:** one 15 s clip, run each once:
   - Auto-captions;
   - Remove background;
   - Pick what to keep (tap the person);
   - Noise reduction.

   Then tell me. I'll pass the numbers to WS1 so it can correct the prices.
3. **Recreate:**
   - paste a TikTok, Instagram or YouTube Shorts link (if it's blocked, save the video and drop the file in);
   - Cast your model;
   - Build with one shot swapped in and one shot left unticked.

## What to check
- **Recreate:**
  - The recipe reads right: shots, beats, text, transitions and the Look.
  - The swapped shot moves like the reference, the creator's captions are **gone** from it, and there's **no double zoom or double grade**.
  - "Use your own setting" once with one of your locations, and once with a background made from the brief (+$0.06). Your model should appear in the new background.
  - Compare plays your built edit beside the reference, in sync.
  - "Fix shot" changes only that shot and keeps your other edits.
  - Export with the guide sound, then post with "Use this sound".
  - "Write the shot briefs" (about $0.02) fills the shot descriptions.
  - Claude in Recreate: ask it to explain a shot or fix one.
- **Playbook:** pin a rule (for example "No speed ramps"), then ask Claude to edit. It should obey.
- **Suite:**
  - saved rigs;
  - Reuse settings, Vary, Use as start frame;
  - the results feed and Compare;
  - Queued, then Run · $x;
  - Library collections.
- **Edit:**
  - Hook templates (the crash is fixed);
  - every panel;
  - Settings → Studio → AI editing helpers (the switch and the daily limit).
- **Android only:**
  - Share → MUSE from TikTok (a link) and from the gallery (a file);
  - Recreate playback stays in sync;
  - cut-outs aren't rotated or delayed.

## Report back
Tell me anything that crashes, looks wrong, or costs more than it said it would. Fixes only from here on, no new features, until you've finished testing.
