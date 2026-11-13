# Verification results

Results of the desktop test suite (`tests/run_all.sh`), on hosts and an LVGL stand-in that behave like the band. Written per release.

```
RedBand GB 4.6.0 - local verification (desktop hosts matching the band; not yet run on the physical Band 10)

HOSTS    tests/bandhost32: real Lua 5.4.0, 32-bit pointers, 64-bit integers, doubles; freed memory overwritten
         with 0xDD; optional hard heap cap (allocations really fail); peek()/srcptr() = what LVGL sees
LVGL     tests/mock_lvgl_band.lua follows firmware 3.1.33: string bytes reach lv_image_set_src unchanged, first
         byte < 0x20 = in-memory descriptor (address only), VG-Lite decoder reads memory at draw time,
         6 MB image cache keyed by address
CORE     Blargg cpu_instrs + instr_timing pass | golden 12/12 with S, L and XL engines | save-state exact |
         compiled blocks == interpreter over 14,000 frames (S 0.128, L 0.105, XL 0.098 ms/frame) |
         catch-up == line-by-line rendering over 13,991 frames
FLOW     clock while off (11 images drawn, current minute), game, LED, pause, TURBO, BIG/SMOOTH/FAST, file path
         and back, fault -> recovered, out-of-memory frame -> skipped and play continues, BROWSE list + two-tap delete (game stopped
         first) + close, screen off/on, power off back to the clock
RESIL    recovery point after 20 s, then every 2 minutes; fault -> same engine restored; repeated faults -> clean stop, clock shown
EXACT    26,000-frame sessions (3 views, both paths, screen off/on, pause, POWER off/on): S engine 3,215 and XL
         engine 3,194 drawn-frame checks, 0 mismatches, 0 wrong pixels
NEGATIVE ring of 4 descriptors -> 723 stale frames; pixel string not kept -> 1000/1000 released reads;
         (4.2.0 fixed: POWER probe overwrote ring slot 1 -> one possible stale frame after a power cycle)
MEMORY   4.3.0: no budget (4.2.0's governor showed 1,634 frames in the session, 4.3.0 / 4.1.0 show 2,413);
         real allocation failures with the Lua heap capped at 1.9 / 1.8 / 1.7 MB (59 / 119 / 3,973 failures):
         all 26,000 frames completed, never stopped; injected out-of-memory frame -> skipped, play continues
TIERS    XL >= 3 MB free, L >= 1.8 MB, else S (both /proc/meminfo layouts); collector pause 110-200 (4.1.0 rule);
         broken bytecode -> next size; no bytecode -> source
PACING   simulated band (game frame + drawn frame, Lua per shown frame, LVGL per shown frame):
         (5+2, 1.5, 6) 100% speed P2 | (9+3, 3, 10) 100% P2 | (12+4, 4, 14) 99.9% P5;
         your 4.0.0 reading (14, 22, 2.1) reproduced at 94.7% (band: 93.3%)
LAYOUT   66 objects inside the pill, labels fit, touch controls separate, no CPU-drawn shadows; the installed
         scene rendered from main.lua: 11 visible images inside their panel and the pill, none overlapping
PACKAGE  98 files, main.lua last (sentinel = main); vendored AOD packer byte-identical to ours for the main screen;
         AOD container: "structure correct" (reference verifier), 6 widgets; the files extracted from the AOD .bin
         pass flow, resilience and the 1.8 MB-cap session again
BATTLES  rival battle + Route 1 wild encounters through the watchface: every shown frame drawn exactly
         (S 5,970, XL 5,943 checks, 0 mismatches); ROM bank loads during battles 695 (4.3.0) -> 7 (XL) / 350 (S),
         no garbage per load; S/L/XL engines == interpreter through 30,000 frames with 5 battles
SAVES    real in-game save passes through half-written states (checksum flips 3 times); unit test: half-written
         never written, settles 1 s, .tmp + read-back + rename + .bak, truncated -> .bak, interrupted -> .tmp;
         end to end through the watchface: file good after every callback; control: 4.3.0 had not written the
         finished save ~17 s after the game saved
STRESS   simulated band (virtual clock, band-like costs, battle frames x1.4), real game 60,000-100,000 frames with
         battles, seeded random screen off/pause/TURBO/view/path/BROWSE/POWER, bursts of allocation failures (up to
         2,748 injected): 0 escaped errors, 0 mismatches, never stopped by itself, no save written, worst idle 13%
SAVES2   battery RAM used as sprite scratch (bank 0) is ignored: in-game save -> 1 write; 3,804 battle frames after
         it -> 0 writes (4.4.0 control: rewritten)
CPU      UI thread busy share capped at 80%: calm scenes 100% speed, heaviest simulated scene 90%
4.5.1    settings from older builds start clean (only the view kept); memory path never dropped for good by a crash;
         CONTINUE from a real save: S/L/XL x big/smooth/fast and with old settings -> 0 mismatches, never stopped;
         stress with memory that really runs out (6.5 / 4.5 / 3.2 / 2.6 MB): engine XL/L/S/S chosen, peaks 4.5 / 2.7 /
         2.1 / 2.0 MB, 0 failed allocations, through Oak's lab and 2 battles; black box line shown after a crash
4.6.0    layout: D-pad centred, B/A top-left/top-right 20 px from the sides, POWER/PAUSE 22 px in; 66 objects inside the
         pill, controls separate; SAFE/FAST: S->XL->S engine handoff identical to the unchanged game through 24,000
         frames (3 battles); watchface L->XL->L with every shown frame exact; FAST -> SAFE by itself when memory
         gets short; stress with random UNSAFE taps: worst idle 9-13%, 0 errors, 0 mismatches; ROM-free package:
         clock, BROWSE, AOD work, POWER says there is no ROM; files extracted from the final .bin pass again
```
