# Prompt scripts (workstream 4)

_Owner decisions 2026-11-05. Code: `server/api/src/prompt/scripts/**` (engine), `server/api/src/audio/**` (talking detection, beat-only audio). Contract: `plans/api.md` "Prompt scripts"._

Every prompt the server sends to a model is assembled by a **script**: typed **inputs** (facts about the job) → **rules** (conditions on the inputs that choose blocks) → **blocks** (owner-editable texts with `{placeholders}`: the prompt library entries). Assembly is deterministic, needs no AI call, and is unit-tested branch by branch.

## 1. Why
Video models lip-synced to the clip's audio even when the performer wasn't talking: the swap prompt always said "mouth and lip movement … the words being mouthed" and the clip went out with its sound. Fixing that needs a prompt that depends on facts about the job (is she speaking? which audio is sent?), and so does everything the AI suite will build. Scripts make those dependencies explicit, testable and editable by the owner, without anyone writing code.

## 2. The format
```ts
Script   { id, group, title, description, format: "lines" | "sections", inputs: InputDef[], sections: Section[], values?: ValueSlot[], rules: Rule[], vars?: {name, description, sample}[] }
InputDef { name, label, description, type: "bool"|"enum"|"number"|"text"|"list", options?: {id,label}[], fields?: InputDef[] /* list items */, sample }
Section  { id, label, kind: "system"|"user", pick: "first"|"all", join?, heading? /* "summary:" */, layer?, each? /* repeat per list item */, alias? }
ValueSlot{ name, label, prefix? }        // a placeholder whose value is chosen by rules (target "@name")
Rule     { id, label, target /* section id or "@value" */, when: Cond[] /* all must hold */, block /* library key */, optional?, locked?, enabled? }
Cond     { input /* or "item.<field>" in an each-section */, op: is|isNot|in|notIn|atLeast|atMost|has|hasNot|empty|notEmpty, value? }
```
**Running** (`runScript`): (1) value slots: the first matching rule's block, rendered, becomes `{name}` for the other blocks (with `prefix` when non-empty); (2) sections in order: matching rules (first or all) render their blocks with the values the code supplies (`vars`: her name, look, image ranges …); empty renders are dropped; an `each` section makes one part per list item (one prompt line per reference image). `format: "lines"` joins parts with new lines (photo prompts; parts are the apps' slots); `"sections"` writes `heading:\nbody` blocks separated by a blank line (the video models' structured prompt), a section without a heading continuing the previous one.

**Presets off** skips rules marked `optional` (the scene, camera, light, style and never-add lines of a photoshoot), exactly as before.

**System text and the user's text stay apart.** A script has system sections and at most one `user` section. Only a user section's blocks receive `{direction}` = the user's words, after the existing identity sanitiser (clauses that would change her identity or add a never-add item are dropped and listed in `removed`), collapsed to one line (it can't fake a new section) and inserted as-is (braces in it are not placeholders). System blocks never see it, even if a caller passes it as a value. In the video prompts the user section is a delimited last line `Direction from the user: …` (it used to be appended to `detailed_description`); in photo prompts it stays the `Direction: …` line.

## 3. The scripts
| id | group | inputs | branches (default rules) |
|---|---|---|---|
| `photoshoot` | photoshoot | presets, lockSeed, outfitSource (set/described/product), lens, refs[{refIndex, guides}] | outfit line by source; `@lensNote` wide ≤ 24 mm / long ≥ 85 mm; reference lines per image (pose/look/scene + guard, locked); seed locked/new; optional style blocks |
| `template` | templates | view (full/visible), outfitSource, hasScene/Camera/Light/Pose, product (none/photo/noPhoto), seed (locked/known/none), refs | hidden layers only in the full view; the locked `Template: <name>` line only in the visible view |
| `sheet` | sheet | angle | identity, task, style, never-add |
| `outfit.angle`, `outfit.edit` | outfits | outfitSource, angle | outfit line by source |
| `enhance` | enhance | — | one block |
| `dressup` | dressup | closeup, anchor | close-up vs full-body block; `@anchor` when the dressed front is sent |
| `lora.candidate` | lora | angle | the sheet image + variation line |
| `video.replicate` | video | **speaking**, audioSent | speaking: the tested short prompt (unchanged); **not speaking**: `summary.silent` + `detailed.silent` (no "lip movement"/"words being mouthed"; "her mouth follows <Video 1> exactly; she does not speak, sing or mouth words"); user section last |
| `video.edit` | video | **speaking**, keepAudio, keepBackground | audio/background sentences as value rules (were fixed strings in code, now blocks); not speaking adds `video.mouth.silent` to the details; user section last |
| `video.audio` | video | audio (speech/music/none), speaking | `audio.lipsync` / `audio.beat` ("moves to the beat of <Audio 1>; she does not sing, speak or mouth lyrics") / `audio.silent`: the AI suite's audio sentence |

The default rules reproduce every prompt exactly as the builders made it before scripts (checked in `test/prompt-scripts.test.ts` over every outfit source, lens, presets, lock, refs, keep-audio and background combination). The only intended change at default settings: in video prompts the user's direction moves into the user section.

The AI suite (workstream 1) builds its shot prompts through this engine: it defines its scripts with `registerScript()`, adds its blocks with `registerPromptDefs()` (they appear in Settings → Prompts), and runs them with `run(id, texts, {inputs, vars, direction})`; `audioLine()` gives the audio sentence.

## 4. Blocks (the library) and backwards compatibility
Blocks are the prompt library entries (`library.ts`, `plans/api.md` §3 of "Shoot references and the prompt library"). **No existing key changed**, so every saved owner override keeps working, in the branch it always applied to. New entries (group `video`): `video.user.direction`, `video.replicate.summary.silent`, `video.replicate.detailed.silent`, `video.mouth.silent`, `video.edit.audio.subjects|tag|summary|kept|replaced`, `video.edit.background.keep|photo`, `video.edit.video.keep|photo`, `audio.lipsync|beat|silent`. An owner who had edited `video.replicate.summary` keeps that text for speaking performers; the not-speaking branch uses the new silent block until they edit that too.

## 5. Talking detection and the "Performer is speaking" switch
- **Free detection** (`audio/detect.ts`): ffmpeg decodes up to 30 s of the clip's audio to 16 kHz mono; three classic features vote: the **low-energy ratio** (speech pauses between syllables and phrases; music fills the time), **syllabic modulation** of the energy envelope (2–8 Hz), and **zero-crossing variability** (voiced/unvoiced alternation). Result `{kind: speech|music|silence|none, speaking, confidence}`. Music with a singer is classed as music (most such clips are people moving to a song, and the reported bug was lip-sync to music); speech over a quiet music bed is speech; a music bed as loud as the voice reads as music. Tested on generated speech-like audio (two pitches), music, music with a singing voice, silence and clips without an audio track.
- **On upload** the clip is classified (well under a second; the upload waits up to 8 s, else it finishes in the background and a second `clip` event carries it). Stored in `clips.meta.audio`; the clip's "Performer talking" check follows it; `Clip.audio = {kind, speaking, detected}`. An upload that says `talking: true` wins.
- **The switch.** The studio shows "Performer is speaking", pre-set from `clip.audio.speaking`; the render sends `speaking: true|false`. The server resolves it once, at creation: the switch, else the upload's `talking: true`, else the detection (waited for if still running), else not speaking; the job's `request.speaking` and `request.speakingSource` (`switch|upload|detected|default`) record it.
- **Character swap, not speaking:** the padded clip goes to the model **without audio**, and the clip's own sound is put back on the delivered take with a **stream copy** of the video (audio copied when AAC, else encoded to AAC: audio only); the script uses the silent wording. **Speaking:** the clip goes with its sound and the lip-sync wording; the take is the model's file as delivered. (The strip/restore plumbing is the coordinator's stopgap, `f89060e`; it now follows `request.speaking`.)
- **Edit (GPU) path:** the prompt follows `speaking` (mouth line); the worker's audio handling is unchanged (the owner decides the Edit path).

## 6. Beat-only audio (AI suite)
`beatOnlyAudio(ctx, {studioId, userId, jobId, audioKey})` → `{instrumentalKey, costUsd, predictionId, seconds}`: when the user's music should drive the rhythm but nobody sings or speaks, the vocals are separated on Replicate and the instrumental is stored (`r/<job>/instrumental.m4a`, audio only) for the suite to send as reference audio, with `audioLine({audio: "music", speaking: false})`. Runs only when the user generates; the suite bills it with the job (`costUsd` = prediction time × `AUDIO_SEPARATION_PRICE_PER_SEC`, about $0.0066 a run).
- **Model:** `AUDIO_SEPARATION_MODEL` = `ryan5453/demucs` (Demucs v4 `htdemucs`; A100, about 6 s, about $0.0066 a run on Replicate's page). Demucs code is **MIT**; no separate weights licence is stated (check before relying on it commercially). A community model: it runs by version (`AUDIO_SEPARATION_VERSION`, else the latest version is looked up with a free GET).
- **Input/output not verified against the live schema** (the API page didn't render for us): input = `AUDIO_SEPARATION_INPUT` (default `{"model":"htdemucs","stem":"vocals","output_format":"mp3"}`) + the URL in `AUDIO_SEPARATION_AUDIO_FIELD` (`audio`). Output: a `no_vocals`/`accompaniment`/`instrumental` stem is used as is; otherwise every stem except `vocals` is mixed (audio only). **Check the model's API page before enabling** (no live prediction was run: no money).

## 7. Owner editing (Settings → Prompts)
Owner only (members never see it). The Prompts screen gains a **Scripts** list next to the blocks: each script shows its inputs (name, type, description), its rules as readable sentences ("When *Performer is speaking* is *no* → *Summary* uses *Draft/Standard/HD · summary (not speaking)*"), and the blocks it uses (tap → the existing block editor). Rule editing is a simple structured form: switch a rule on/off; change its conditions (input → test → value, from menus); pick its block (from the script's blocks) and its place; add a rule (same form), delete an added one; reorder within a place. **Locked** rules (who she is, never-add, reference guard, what is kept, the user section) can't be switched off or changed — only their block text. A live preview runs the script with sample inputs the owner can change (switches/menus per input). Reset to default.

Saved per studio (`prompt_script_rules`, migration 0010) as the whole rule list plus the default rule ids known at save time: a default rule added to the script later joins the saved list (after the default before it); a saved list that no longer validates (the script changed) falls back to the defaults and the editor shows it as reset (`stale`).
