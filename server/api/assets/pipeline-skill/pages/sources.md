# Sources [Icon edit, trials 7, 22, 52, 53, 55, 59, 68, 98]
- Split long scene packs into ~100 s parts on import. Edit starts at song 0:00 so song time = timeline time; no offsets anywhere.
- Permanent work folder `<project>/work/` (frames, helpers, builds). /tmp was wiped three times and cost re-fetches and rebuilt helpers. Cache frames by source + second.
- Sweep every pack ONCE before cutting, and write the findings in the pack log:
  - Repeated frames: packs repeated 2 of every 10 frames. Build cut-outs and slow-mo from unique frames only. [22]
  - Hidden cuts and baked dissolves inside a "shot": `ffmpeg -i in -vf "select='gt(scene,0.2)',showinfo" -f null -`. A cut in a clip's last 2 frames made the next pose feel late. [7, 52, 53]
  - Colour flashes on the first frames of a shot. [59]
- Watch every pack fully and log what is in each second (a table of source seconds → content). This is what makes fast shot picking possible.
