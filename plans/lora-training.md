# Identity LoRA (spec)

_Added 2026-11-04._ A LoRA is a small add-on trained on one model. On top of the 6 reference shots, it keeps her **face and physique** steady across every photo and video. Each model can have one, trained in two parts:

| | Photo LoRA | Video LoRA |
|---|---|---|
| Used by | Photoshoot, outfit sets, character-sheet fills | H3 character swaps |
| Base | The photo model (not chosen yet; train for whichever we pick) | MiniMax H3 (Ref2VA) |
| Trained with | ai-toolkit or a hosted trainer | ai-toolkit (H3 support since commit 8502a84), or fal's H3 reference-to-video trainer |
| Starting settings | rank 16, about 1,500 steps | rank 16, 1,000–2,500 steps; stop when identity peaks |
| Time / cost (estimate) | ~25 min on an H100 ≈ $1.66 | ~75 min on an H100/H200 ≈ $4.99 |

The app shows "about $7.25" in total: $0.60 for the training set plus $6.65 for training. **These numbers are estimates until we run one real training** (see "Before we ship").

## Flow (in the app)
1. **Profile → Identity LoRA → Build training set ($0.60).** The app generates 30 shots from the character sheet. They cover new angles, outfits, light and expressions, and include full-body shots so her physique is learned too.
2. **Review.** The user keeps or drops each shot.
   - The app pre-flags risky shots (a leftover tattoo, a ring or choker, face drift) and drops them, but the user can bring any of them back.
   - At least **20 kept** shots are needed to train.
   - The user decides. Nothing trains on shots they haven't seen.
3. **Train both LoRAs.** One click, with time and cost shown. It is blocked if the balance is too low. Training runs in the background, with a notification when done.
4. **Done.**
   - A before/after shows the same prompt and seed, references only vs with the LoRA.
   - A "Use in new renders" switch is on by default.
   - "Retrain with more shots" makes v2, v3 and so on, and older versions are kept.

## Rules
- **Training data:** the training set is the shots the user approved, plus their 6 reference shots. For the video LoRA, it can also include short clips from approved Final takes, but only ones the user picks.
- **Captions:** each training image gets a trigger token (`demo_v1`) and a plain caption. Never-add items are kept out of the training set: shots with tattoos, rings or chokers are flagged.
- **Prompt engine:** when the LoRA is on, the identity layer adds it, e.g. "Identity from 6 locked reference images + LoRA demo_v1." The exact LoRA version is saved with every render, so results can be reproduced.
- **Turning it off:** the model falls back to references only.
- **Deleting a model** deletes its LoRAs and its training set.

## Before we ship
- [ ] Run one real training of each LoRA on one model (about $8 of GPU) and compare against references only, on the same clip and seed.
- [ ] Check that the H3 LoRA stacks with the reference images and doesn't fight them, and that it doesn't slow down rendering.
- [ ] Pick the photo model, then confirm the photo LoRA trainer for it.
- [ ] Replace the estimated times and prices in the app with the measured ones.
