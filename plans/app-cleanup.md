# App clean-up: provider-neutral MUSE (spec)

_Decided 2026-11-04._ The apps were built when RunPod was the only engine, so GPU and RunPod language runs through them. Replicate now does the everyday work (Draft / Standard / HD video, photos). RunPod is only for add-ons. This clean-up makes the apps speak in outcomes, not hardware.

## Decisions (owner)
1. **Language:** users see results, time and price ("Rendering · about 2 min · $0.14"). No GPUs, warm-ups, steps, start-up, or provider names in member-facing UI.
2. **Provider names** (Replicate, RunPod, H3, Lite, SeedVR2) appear **only in owner Settings**, in one "Engines" section: status of each engine and which keys are set.
3. **Keep GPU warm** becomes an **owner-only setting** in Settings ("Keep add-on engine ready", with the cost warning and auto-off rules unchanged). Members never see the nudge, switch, bar, notification or warnings. The owner sees a small indicator only while it is on.
4. **Wallets:** an **owner-loaded studio balance**. The owner records top-ups ("Added $20"), every engine's spending is tracked against it in the server's own ledger, and the owner sends credit to members as now. No "RunPod balance", "Top up RunPod" or "paused: GPU credit low" messages for members. Jobs never pause because one provider's balance is low; if a provider refuses for lack of credit, the job fails cleanly with a refund and the owner gets a notice.
5. **Video options** (members):
   - **Render:** Draft (default) / Standard / HD.
   - **Add-ons:** **Edit** (was "Exact edit": the frame-by-frame swap; nothing technical shown), **Fast · beta** (kept), **Upscale** with **1080p / 2K / 4K** on a finished render.
6. **Upscale:** SeedVR2 on RunPod. Sizes: 1080p = 1080×1920, 2K = 1440×2560, 4K = 2160×3840. Prices come from measured times (the first 2K test is running); 4K is about 2.3× the pixels of 2K and may need a larger GPU, so it is priced only after a measurement.

## Remove or rewrite (member-facing)
- Keep GPU warm: nudge, switch in the video studio, warm bar, menu-bar flame, ongoing notification, 5-minute warning, "Warm GPU turned off" toasts.
- Cost lines "GPU warm-up $x"; "Who pays GPU warm-up" setting moves to owner Settings or goes away.
- "Waiting for a GPU", "The GPU disconnected", "the GPU stopped responding" → "Waiting to start", "Something went wrong, you weren't charged".
- Steps (10/15/30) and first 5.2 s / full clip choice: hidden; Edit always uses the whole clip and the default steps.
- "RunPod balance", "Top up RunPod", runpod.io links, "Paused: the studio's GPU credit is low" (member and owner wording replaced by the studio balance).
- "#2 in the Replicate line" → "#2 in line".

## Keep (owner Settings → Engines)
- Engine status (Replicate, RunPod), key presence, add-on GPU limits, Keep add-on engine ready, idle/max minutes, who pays start-up.

## Order
After the Replicate engine build (server, Android, Mac) lands. Server first (contract changes in `plans/api.md`: studio balance top-ups, `Edit` / `Upscale` job kinds and labels, owner-only warm), then Android and Mac in parallel.
