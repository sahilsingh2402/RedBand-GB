# Version history

How RedBand GB went from 3–4 frames per second to full speed, and from crashing in battles to
long crash-free sessions. Each step's numbers and reasoning are in
[ENGINEERING_REPORT.md](ENGINEERING_REPORT.md).

| Version | What changed | What we learned |
|---|---|---|
| 3.2.0 | Starting point: frames converted to RGB565 in Lua and written as up to 9 image strip files per frame; game clock tied to the LVGL timer | About 3–4 fps. File round trips and per-pixel colour conversion in Lua are far too slow, and a game clock tied to the screen slows the game itself. |
| 4.0.0 | Frames as **in-memory indexed images** (I2 / I8) handed straight to LVGL; **real-time game clock**; **frame-locked showing** | Band reading: game at 55.7 fps (93% of real time); 14 ms emulation per game frame; 22 ms to build a crisp frame; 2.1 ms LVGL drawing. |
| 4.1.0 | **Three engine sizes** with compiled blocks, shipped as **Lua 5.4.0 bytecode**; cheaper frame building | Reported by the user as a clear improvement. Bytecode loads about 10× faster and uses about 20% less memory. |
| 4.2.0 | Poketch clock and AOD, BROWSE, button layout, and a **memory budget** that showed fewer frames under pressure | Felt slow again. The budget throttled play in normal scenes: 1,634 shown frames where 4.1.0 showed 2,413 in the same test. |
| 4.3.0 | Budget removed; purely reactive memory safety | Smooth again, but crashed in a wild battle, and the save was destroyed. |
| 4.4.0 | **ROM bank cache fixed:** 12 slots caused about 700 reloads in 8 battles; now 14–32 slots refilled in place. **Atomic saves with backup.** | Battles use about 35 banks. The old save writer wrote in the middle of the game's own save and erased the old file first. |
| 4.5.0 | **Stress testing** on a simulated band. Battery RAM scratch ignored (no more saves after every battle); **CPU breathing room** (busy ≤ 80%); out-of-memory never stops the game | Pokémon decompresses battle sprites into its save memory. A UI thread that never sleeps can starve the band's watchdog and services. |
| 4.5.1 | Settings start clean per build; **memory planned from real free memory** (XL only from 6 MB free); black box | Old settings could lock a band into a slow fallback path. Oak's lab is the heaviest early scene (+65% emulation). Reached Viridian City without a crash. |
| 4.6.0 | Controls away from the band's edges; **SAFE / FAST** with a live, exact engine handoff; ROM-free packages | FAST brings back 4.5.0's speed with automatic fallback to SAFE. |
| 4.6.0 Landscape | The face turned sideways: logical 520×212 canvas, rotated text images, GPU-rotated 224×202 picture (exact 1.4×), two orientations | About 13% more picture than portrait. GPU rotation on the band is still to be confirmed. |
| (4.7.0, not released) | Battery RAM kept as tables; bigger row cache | Correct, but no speed gain: busy scenes are limited by the game's own work, not by memory handling. |

## Things that were tried and dropped

- **RGB565 frames from Lua memory.** The graphics chip needs aligned, cache-flushed buffers,
  which Lua strings can't guarantee. Indexed images are copied by LVGL's decoder instead.
- **GPU scaling for the crisp view.** It always filters, which looks soft. It's kept as the
  SMOOTH view; the crisp view is built in Lua.
- **A strict memory budget (4.2.0).** It throttled normal play. Replaced by reactive safety.
- **Writing saves on a timer.** It caught half-written saves. Replaced by finished-only, verified
  saves.
- **A bigger row cache and table-based battery RAM (4.7.0 experiment).** Measured, correct, but
  no gain.
