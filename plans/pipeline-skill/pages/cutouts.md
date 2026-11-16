# Cut-outs [trials 17–35, 57–59, 98, 104–108] — the biggest cost of the Icon edit (~25 trials)
**Route.** Free first:
1. macOS Vision subject lift (`subject_matte.swift`, seed point on the subject).
2. Union with the person-segmentation matte + 3-frame median to repair misses (person segmentation alone is bad, but its head repairs a lift that loses the head). [58]
3. Against plain sky a colour key is enough. [57]
4. Finisher (`cutout_finish.swift`) → ProRes 4444 or HEVC with alpha; MUSE keeps the transparency. [19]
Paid matte failed twice: it matted the whole 94 s source for a 0.5 s shot (failed at 56 %), and a second run cost $1.64 vs an $0.82 estimate with a looser matte than the free one. Always trim a shot to its own file before any paid matte. [18, 29] (MUSE now bills the trimmed clip and caps at the estimate, but free is still better.)

**Why cut-outs read as cut-outs, and the fix**
- Speed break / keyframe slide → the cut-out plays at the shot's speed with its own motion only; never slide it by keyframes to fake motion. [21]
- Repeated pack frames → build from unique frames. [22]
- Thin things (web) dropped by the lift → a separate pass. [21, 22]
- Sky-coloured fringe → pull the edge in, repaint it from the subject's inner colours. [23]
- Flicker over a changing background → the MASK wobbles: smooth the mask through time first; ink/outline hides nothing while the mask wobbles. [28, 30, 31, 34]
- A leak no matte separates (white lens vs white glow) → fit the outline of the rigid part through time, reject bad frames; never patch frame by frame. [32, 33]
- "It's more of a lighting issue" → tint 12 % toward the wall behind, light wrap 0.4 lighten-only (≤ 0.5), shared grain. [35]
- A heavy finisher ate his hands → one edge strength for the whole body is wrong; head and hands need different treatment; a borrowed region must be no bigger than what it replaces. [105, 106, 108]
- A post-process mask replaced parts of him → limit a mask to the area that changes. [104]
- Look at what is under the cut-out in the new shot before placing it. Fill matte holes by flood-filling the outside, not by closing. Opening before closing when a bright neighbour touches the matte.

**Finished recipe (start here):** two finishes (gentle for body and hands, fitted outline for the head) + grade to the background. In the template library as `cover-freeze` and `cutout-carry-over`.

**Checking a cut-out:** judge the whole feature against the source on every frame, on zoomed consecutive frames — never single stills. Trial 32 was logged as working and was wrong because only the fixed spot was checked. [31, 33]
