#!/bin/sh
# RedBand GB: build every watchface from your own Pokemon Red ROM (see rom/PLACE_ROM.GB_HERE.txt).
#   ./build.sh            portrait + landscape (top end left / right), with and without AOD
# Needs: python3 with Pillow, a C compiler with 32-bit support (gcc -m32) and internet access the
# first time (tests/build_hosts.sh downloads the Lua 5.4.0 sources from github.com/lua/lua).
set -e
cd "$(dirname "$0")"
ROM=rom/pokemon_red.gb
if [ ! -f "$ROM" ]; then
  echo "No ROM found. Put your own Pokemon Red (UE) ROM at $ROM - see rom/PLACE_ROM.GB_HERE.txt"; exit 1
fi
python3 - "$ROM" <<'PY'
import hashlib, sys
h = hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest()
if h != '5ca7ba01642a3b27b0cc0b5349b52792795b62d3ed977e98a09390659af96b7b':
    sys.exit('This is not the expected Pokemon Red (UE) ROM (sha256 %s). The compiled blocks and the save logic are made for that exact ROM.' % h)
PY
echo "[1/7] Lua 5.4.0 hosts (32-bit, like the band)"; sh tests/build_hosts.sh
echo "[2/7] ROM -> 64 bank files";                   python3 tools/split_rom.py
echo "[3/7] engines S / L / XL (compiled blocks + bytecode)"; (cd tools && python3 build_cores.py)
echo "[4/7] Poketch clock and AOD images";            (cd tools && python3 build_assets.py)
echo "[5/7] main.lua";                                (cd tools && python3 build_main.py)
echo "[6/7] portrait watchface";                      python3 RedBandLuaWatchface/build_face.py
python3 RedBandLuaWatchface/build_face.py norom
echo "[7/7] landscape watchfaces"
for O in 1 -1; do
  if [ "$O" = 1 ]; then V=TopLeft; D=RedBandLuaWatchfaceLA; ID=781209301; T="REDBAND LAND-L"
  else V=TopRight; D=RedBandLuaWatchfaceLB; ID=781209302; T="REDBAND LAND-R"; fi
  rm -rf "$D"; mkdir -p "$D/app/lua" "$D/images"
  cp RedBandLuaWatchface/app/lua/* "$D/app/lua/"
  cp RedBandLuaWatchface/build_face.py "$D/"
  cp "RedBandLuaWatchface/images/preview_landscape_$V.png" "$D/images/preview.png"
  python3 tools/make_landscape.py "$O" "$D/app/lua/main.lua"
  python3 tools/build_landscape_assets.py "$O" "$D/app/lua"
  rm -f "$D"/app/lua/clk_*.bin
  RB_ID=$ID RB_TITLE="$T" RB_NAME="RedBand_GB_4_6_0_Landscape_$V" python3 "$D/build_face.py"
  RB_ID=$ID RB_TITLE="$T" RB_NAME="RedBand_GB_4_6_0_Landscape_$V" python3 "$D/build_face.py" norom
done
rm -f output/*.face
echo; echo "Done. Watchfaces in output/:"; ls -l output | awk 'NR>1 {print "  " $9 "  (" $5 " bytes)"}'
