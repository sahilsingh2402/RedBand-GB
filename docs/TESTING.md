# Testing

The band can't be debugged directly, so the watchface is tested on the desktop. The tests run
the real watchface code (`main.lua` and the engines) on Lua hosts and an LVGL stand-in that
behave like the band.

## Running

```sh
./build.sh                                       # builds hosts, engines and watchfaces (needs your ROM)
git clone --depth 1 https://github.com/retrio/gb-test-roms /tmp/gb-test-roms
sh tests/run_all.sh /tmp/gb-test-roms            # about 6 minutes; ends with ALL ... TESTS PASSED
```

Individual tests run as `tests/bandhost32 <heap cap KB or 0> tests/<test>.lua <app dir>/ [args]`
from the repository root. `<app dir>` is `RedBandLuaWatchface/app/lua/`, or a landscape app
folder after `./build.sh`.

## The hosts and the stand-in

| Part | Behaves like the band because |
|---|---|
| `tests/bandhost.c` → `bandhost32` | Real Lua 5.4.0 built 32-bit: the same pointer size, string header size and bytecode format. It also has: freed memory overwritten with 0xDD; an optional hard heap cap (allocations really fail); `inject_alloc_failures(every, burst)`; `peek()` / `srcptr()` to read raw memory as LVGL would; `heap_usage()`. |
| `tests/mock_lvgl_band.lua` | An LVGL stand-in. It reads image descriptors from **raw memory at draw time**, keeps a 6 MB cache keyed by descriptor address, decodes I2 / I8, records problems, and handles events, flags and timers. |
| `tests/common.lua` | Loads the watchface with a fake `/proc/meminfo`, settings and saves, and checks that what LVGL would draw equals what was presented, pixel by pixel. |

## The tests

| Test | Proves |
|---|---|
| `run_tests.lua` | Blargg `cpu_instrs` and `instr_timing`; golden frames for every engine; save-state round trip |
| `lockstep_aot.lua`, `lockstep_battle.lua` | Compiled engines S / L / XL are identical to the interpreter (registers and all RAM every 250 frames), through intro, house, lab and battles |
| `render_equiv.lua` | Catch-up rendering gives exactly the same frames as line-by-line rendering |
| `flow_check.lua` | Feature walkthrough: clock, POWER, LED, pause, TURBO, three views, file path and back, fault recovery, out-of-memory frame, UNSAFE / SAFE, BROWSE with two-tap delete, screen off / on, power off |
| `resilience.lua` | Recovery point, restore after a fault, clean stop after repeated faults |
| `probe_states.lua` | Display-path rules: first try, confirmation, old settings reset, LED toggle, session-only fallback |
| `blackbox.lua` | The "last run" line after a crash, and the LED figures |
| `save_safety.lua` | Half-written saves never written; waits until settled; `.tmp` + read-back + rename + `.bak`; truncated save loads the `.bak`; interrupted rename loads the `.tmp` |
| `ingame_save.lua` | A real in-game save passes through half-written states (why finished-only saving is needed) |
| `save_e2e.lua` | A real in-game save through the watchface: the file is good after every callback, and battles afterwards cause no write |
| `continue_save.lua` | CONTINUE from a real save with every engine and view, and with settings left by older builds |
| `engine_handoff.lua` | SAFE ↔ FAST engine handoff gives an identical game; FAST falls back to SAFE when memory gets short |
| `core_tiers.lua` | Engine choice and collector settings from free memory (both `/proc/meminfo` layouts) |
| `drive_long.lua` | 26,000 frames across views, display paths, screen off / on, pause and power cycles; every shown frame checked, pixels checked; real heap caps of 1.9 / 1.8 / 1.7 MB |
| `drive_game.lua`, `drive_battle.lua` | A scripted new game; battles with bank-load counts and heap peaks |
| `pace_check.lua` | Simulated band costs: game speed, shown-frame interval, evenness |
| `stress.lua` | 60,000–100,000 frames on a simulated band: virtual clock with band-like costs, random screen off / pause / TURBO / views / BROWSE / UNSAFE / POWER, bursts of allocation failures, and memory that really runs out. Pass: no escaped error, no mismatch, never stopped by itself, no save written without an in-game save, enough idle time per second |
| `layout_dump.lua` + `check_layout.py` | Every object inside the pill, labels fit, touch controls don't overlap, no CPU-drawn shadows (portrait and landscape) |
| `norom_package.lua` | The ROM-free package works as a clock face and explains that there is no ROM |

Scripted play comes from `tests/battle_route.lua`. It reads the game's RAM (map, position,
battle and party, from the pokered disassembly) to walk Red through the house, Oak's lab, the
rival battle and Route 1 wild battles.

Latest results: [VERIFICATION.md](VERIFICATION.md).
