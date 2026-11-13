#!/bin/sh
# RedBand GB 4.6.0 test suite. Run from the release root:
#   sh tests/run_all.sh [path/to/gb-test-roms]
# Needs: lua5.4 + liblua5.4-dev, gcc + gcc-multilib, git (to build the Lua 5.4.0 32-bit host), python3.
set -e
cd "$(dirname "$0")/.."
fail() { echo "FAIL: $1"; exit 1; }
[ -x tests/bandhost32 ] && [ -x tests/bandhost64 ] || sh tests/build_hosts.sh
(cd tools && python3 build_cores.py > /dev/null && python3 build_assets.py > /dev/null && python3 build_main.py > /dev/null && python3 split_rom.py > /dev/null)
ROM=rom/pokemon_red.gb
echo "core: Blargg, golden frames, save-states (core unchanged since 3.2.0)"
if [ -n "$1" ]; then lua5.4 tests/run_tests.lua blargg "$1"; fi
OUT=$(mktemp -d)
SHOTS=$(python3 -c "import json; print(','.join(json.load(open('tests/golden_frames.json'))))")
lua5.4 tests/run_tests.lua golden "$ROM" "$OUT" "$SHOTS" > /dev/null
python3 - "$OUT" << 'PY'
import json, hashlib, sys
g = json.load(open('tests/golden_frames.json'))
bad = [f for f, h in g.items() if hashlib.sha1(open(f'{sys.argv[1]}/{f}.png', 'rb').read()).hexdigest()[:16] != h]
print(f'golden frames identical to the JS reference: {len(g) - len(bad)}/{len(g)}'); sys.exit(1 if bad else 0)
PY
lua5.4 tests/run_tests.lua state "$ROM"
for C in l xl; do
  rm -rf "$OUT"; mkdir -p "$OUT"
  lua5.4 -e "RBGB_CORE_FILE='tools/gbcore_$C.lua'" tests/run_tests.lua golden "$ROM" "$OUT" "$SHOTS" > /dev/null
  python3 - "$OUT" "$C" << 'PY'
import json, hashlib, sys
g = json.load(open('tests/golden_frames.json'))
bad = [f for f, h in g.items() if hashlib.sha1(open(f'{sys.argv[1]}/{f}.png', 'rb').read()).hexdigest()[:16] != h]
print(f'{sys.argv[2]} engine (bank 0 unpacked): golden frames {len(g) - len(bad)}/{len(g)}'); sys.exit(1 if bad else 0)
PY
done
(cd tools && mv aot_blocks.inc.lua aot_keep.tmp && python3 assemble_lua.py > /dev/null && cp gbcore.lua /tmp/gbcore_noaot.lua && mv aot_keep.tmp aot_blocks.inc.lua && python3 assemble_lua.py > /dev/null)
for C in s l xl; do
  R4=$(lua5.4 tests/lockstep_aot.lua tools/gbcore_$C.lua); echo "$C: $R4"
  case "$R4" in *"compiled-block core == interpreter core"*) ;; *) fail "compiled blocks ($C) differ from the interpreter";; esac
done
(cd tools && python3 assemble_reference.py > /dev/null)
for C in s l xl; do
  R7=$(lua5.4 tests/lockstep_battle.lua tools/gbcore_$C.lua 30000); echo "$R7" | cut -c1-150
  case "$R7" in *"== interpreter through"*) ;; *) fail "engine $C differs from the interpreter in battles";; esac
done
echo "core: a real in-game save passes through half-written states"
lua5.4 tests/ingame_save.lua || fail "in-game save"
R5=$(lua5.4 tests/render_equiv.lua 1); echo "$R5"
case "$R5" in *", 0 differ; CPU + RAM identical"*) ;; *) fail "catch-up rendering differs from line-by-line rendering";; esac
rm -f tests/gbcore_perline_reference.lua
APP=$(mktemp -d)/; cp RedBandLuaWatchface/app/lua/* "$APP"
echo "watchface: engine size and collector from free memory; 5.4.0 bytecode; fallbacks"
./tests/bandhost32 0 tests/core_tiers.lua "$APP" | head -1 | grep -q "core tiers OK" || fail "engine sizes"
echo "watchface: layout inside the pill, text fits, controls separate, no CPU-drawn shadows"
./tests/bandhost64 0 tests/layout_dump.lua "$APP" /tmp/rbgb_layout.jsonl > /dev/null
python3 tests/check_layout.py /tmp/rbgb_layout.jsonl || fail "layout"
echo "watchface: rendered as installed (clock showing): images inside their panel and the pill, none overlapping"
./tests/bandhost64 0 tests/layout_dump.lua "$APP" /tmp/rbgb_layout_t.jsonl fixedtime > /dev/null
python3 tools/render_preview.py /tmp/rbgb_layout_t.jsonl "$APP" /tmp/rbgb_preview.png || fail "visible scene"
echo "watchface: flow - clock, game, views, BROWSE + delete, fault recovery, out-of-memory frame (Lua 5.4.0, 32-bit)"
mkdir -p /data 2>/dev/null || true
./tests/bandhost32 0 tests/flow_check.lua "$APP" | head -1 | grep -q "flow OK" || fail "flow"
echo "watchface: resilience - recovery point, fault -> restored, repeated faults -> clean stop"
./tests/bandhost32 0 tests/resilience.lua "$APP" | head -1 | grep -q "resilience OK" || fail "resilience"
echo "watchface: battery save - only finished saves, atomic write with backup, recovery from a crash mid-write"
./tests/bandhost32 0 tests/save_safety.lua "$APP" | head -1 | grep -q "save safety OK" || fail "save safety"
./tests/bandhost32 0 tests/save_e2e.lua "$APP" | head -1 | grep -q "save end-to-end OK" || fail "save end-to-end"
echo "watchface: battles (rival + Route 1 wild encounters) through the watchface, every shown frame checked"
for T in "none S" "8000 XL"; do set -- $T
  R8=$(./tests/bandhost32 0 tests/drive_battle.lua "$APP" 30000 $1 2>&1 | tail -2 | head -1); echo "  $R8" | sed 's/battles battle1.*| shown/| shown/' | cut -c1-200
  case "$R8" in "engine $2"*"mismatches 0 "*"problems 0 | stopped false"*) ;; *) fail "battle session ($2)";; esac
done
echo "watchface: STRESS - simulated band, 60,000 frames each: battles, random screen off / pause / TURBO / views / BROWSE / POWER, bursts of allocation failures"
for T in "1 10 0" "2 14 0" "3 10 8000"; do set -- $T
  R9=$(./tests/bandhost32 0 tests/stress.lua "$APP" 60000 $1 $2 $3 2>&1)
  echo "$R9" | grep "^stress" | cut -c1-230
  echo "$R9" | grep -q "^STRESS OK" || fail "stress seed $1"
done
echo "watchface: STRESS with memory that really runs out (free memory = what the Lua heap has not used): 6.5 / 4.5 / 3.2 MB"
for T in "6500 31" "4500 32" "3200 33"; do set -- $T
  R12=$(./tests/bandhost32 $1 tests/stress.lua "$APP" 20000 $2 12 0 0 $1 2>&1)
  echo "$R12" | grep -E "^stress|PEAK" | sed 's/| events.*//' | cut -c1-200
  echo "$R12" | grep -q "^STRESS OK" || fail "stress with $1 KB"
done
echo "watchface: SAFE/FAST - the running game handed between engine sizes exactly; FAST falls back to SAFE when memory gets short"
./tests/bandhost32 0 tests/engine_handoff.lua "$APP" > /tmp/redband_handoff.txt 2>&1
grep -E "^engine handoff" /tmp/redband_handoff.txt | cut -c1-200
[ "$(grep -c '^engine handoff OK' /tmp/redband_handoff.txt)" = "2" ] || fail "engine handoff"
echo "watchface: display path - old settings start clean, memory path never dropped for good by a crash, LED toggles"
./tests/bandhost32 0 tests/probe_states.lua "$APP" | head -1 | grep -q "probe states OK" || fail "display path rules"
echo "watchface: black box - last figures kept during play, shown after a crash; LED tap shows live figures"
./tests/bandhost32 0 tests/blackbox.lua "$APP" | head -1 | grep -q "black box OK" || fail "black box"
echo "watchface: CONTINUE from a real save, every engine and view, and with settings left by older builds"
./tests/bandhost32 0 tests/save_e2e.lua "$APP" > /dev/null 2>&1
for E in S L XL; do for V in big smooth fast; do
  R10=$(./tests/bandhost32 0 tests/continue_save.lua "$APP" /tmp/redband_realsave.sav $E $V "disp=auto;probe=ok" 6000 2>&1 | head -1)
  case "$R10" in *"mismatches 0, loaded from /data/redbandgb_red.sav, map 12"*"stopped false, error nil"*"problems 0"*) ;; *) echo "$R10"; fail "continue $E $V";; esac
done; done
for C in "disp=file;probe=failed" "disp=auto;probe=pending;enginecap=S;coremax=S;hud=1"; do
  R11=$(./tests/bandhost32 0 tests/continue_save.lua "$APP" /tmp/redband_realsave.sav XL big "$C" 6000 2>&1 | head -1); echo "  $R11" | cut -c1-200
  case "$R11" in *"mismatches 0"*"path direct, stopped false, error nil"*) ;; *) fail "continue with old settings ($C)";; esac
done
echo "watchface: scripted new game through the on-screen buttons, 1.9 MB Lua heap cap"
R1=$(./tests/bandhost32 1945 tests/drive_game.lua "$APP" 7000 2>&1 | tail -2); echo "$R1" | head -1
case "$R1" in *"map 38"*"timer paused: false"*) ;; *) fail "the scripted game did not reach the bedroom (map 38)";; esac
echo "watchface: 26,000-frame session; every shown frame drawn from raw memory through an address-keyed 6 MB cache"
R2=$(./tests/bandhost32 0 tests/drive_long.lua "$APP" 26000 2>&1 | tail -2 | head -1); echo "  $R2" | cut -c1-240
case "$R2" in *"mismatches 0 "*"wrong pixels 0 "*"problems 0 "*"errors on screen: none"*) ;; *) fail "drawn frames differ from presented frames";; esac
case "$R2" in *"views big+fast+smooth"*"paths direct+file"*) ;; *) fail "not every view / display path was exercised";; esac
echo "watchface: same session with the XL engine and a roomy collector (6 MB free reported)"
R6=$(./tests/bandhost32 0 tests/drive_long.lua "$APP" 26000 full 8000 2>&1 | tail -2 | head -1); echo "  $R6" | cut -c1-120
case "$R6" in "engine XL"*"mismatches 0 "*"wrong pixels 0 "*"problems 0 "*) ;; *) fail "XL session";; esac
for CAP in 1945 1800 1700; do
  echo "watchface: same session with real allocation failures (Lua heap capped at $CAP KB): must keep playing, never stop"
  R3=$(./tests/bandhost32 $CAP tests/drive_long.lua "$APP" 26000 mem 2>&1 | tail -2); echo "$R3" | tail -1
  case "$R3" in *"TIMER PAUSED"*|*"STATUS error"*) fail "stopped under the memory cap";; esac
  case "$R3" in *"frames 26001"*) ;; *) fail "did not finish under the memory cap";; esac
done
echo "watchface: pacing on a simulated band (ms per game frame + drawn frame, Lua ms and LVGL ms per shown frame)"
# calm scenes must stay at full speed; the heaviest one may give up a little speed to the
# breathing room (the UI thread never stays busy above 80%)
for T in "5 2 1.5 6:99" "9 3 3 10:99" "12 4 4 14:88"; do
  sc=${T%%:*}; min=${T##*:}
  P=$(./tests/bandhost64 0 tests/pace_check.lua "$APP" $sc 2>&1 | head -1); echo "  $P"
  python3 -c "import re,sys; s=float(re.search(r'\(([0-9.]+)% speed\)',sys.argv[1]).group(1)); m=float(re.search(r', ([0-9.]+)% a multiple',sys.argv[1]).group(1)); sys.exit(0 if s>=float(sys.argv[2]) and m>=88 else 1)" "$P" "$min" || fail "pacing ($sc)"
done
echo "watchface: FAST mode pacing (informational: the same costs, the 85% busy limit)"
for sc in "12 4 4 14" "14 0 22 2.1"; do P=$(./tests/bandhost64 0 tests/pace_check.lua "$APP" $sc 40 fast 2>&1 | head -1); echo "  FAST $P" | cut -c1-150; done
echo "package: both containers, the vendored AOD packer byte-identical to ours for the main screen"
python3 RedBandLuaWatchface/build_face.py | tail -2 || fail "packing"
echo "package: ROM-free variant for publishing (clock, BROWSE, AOD work; POWER explains there is no ROM)"
python3 RedBandLuaWatchface/build_face.py norom > /dev/null || fail "ROM-free packing"
NR=$(mktemp -d)/; python3 - "$NR" << 'PY'
import struct, sys
b = open('output/RedBand_GB_4_6_0_noROM.bin', 'rb').read(); n = struct.unpack_from('<I', b, 216)[0]
for i in range(n):
    _, tag, _, off, size = struct.unpack_from('<HHIII', b, 360 + i * 16)
    cl = int.from_bytes(b[off:off + 3], 'little'); nl = b[off + 3]
    name = b[off + 20:off + 20 + nl].decode(); open(sys.argv[1] + name.split('/')[-1], 'wb').write(b[off + 20 + nl:off + 20 + nl + cl])
PY
./tests/bandhost32 0 tests/norom_package.lua "$NR" | head -1 | grep -q "ROM-free package OK" || fail "ROM-free package"
echo "ALL 4.6.0 TESTS PASSED"
