#!/bin/sh
# Regenerate every picture, GIF and video in docs/media from the real emulator.
# Needs: ./build.sh run first (ROM in place, engines and hosts built), Pillow, ffmpeg for the MP4s.
# Run from the repository root:  sh tools/media/make_media.sh
set -e
T=$(mktemp -d); APP=RedBandLuaWatchface/app/lua/; M=docs/media
echo "captures (scripted play, every 4th frame)"
lua5.4 tools/gif_capture.lua $T/walk.bin 8600                                       # intro, house, Pallet Town, Oak, lab
lua5.4 -e "ROUTE_FILE='tests/battle_route.lua'" tools/gif_capture.lua $T/battle.bin 19600   # rival + wild battles
lua5.4 tools/media/capture_menus.lua $T/menus.bin 23000                            # lab, START menu, save, more battles
echo "layout dumps (the real main.lua in the LVGL stand-in)"
dump() { rm -f /data/redbandgb_last.txt /data/redbandgb_red.sav*; tests/bandhost64 0 tests/layout_dump.lua $1 $2 fixedtime $3 > /dev/null; }
dump $APP $T/clock.jsonl; dump $APP $T/on.jsonl powered
dump $APP $T/browse.jsonl browse; dump $APP $T/sure.jsonl sure; dump $APP $T/unsafe.jsonl unsafe
rm -f /data/redbandgb_red.sav* /data/redbandgb_last.txt
echo "previews"
python3 tools/render_preview.py $T/clock.jsonl $APP $M/preview_main.png
python3 tools/render_aod_preview.py $M/preview_aod.png
echo "pill GIFs"
python3 tools/make_gif.py $T/walk.bin $T/clock.jsonl $T/on.jsonl $APP $M/RedBand_GB_showcase.gif
python3 tools/make_gif.py $T/walk.bin $T/clock.jsonl $T/on.jsonl $APP $M/RedBand_GB_showcase_short.gif short
python3 - $M <<'PY'
import sys
from PIL import Image
m = sys.argv[1]; g = Image.open(m + '/RedBand_GB_showcase.gif'); fr, du = [], []
for i in range(g.n_frames):
    g.seek(i); du.append(g.info.get('duration', 70)); fr.append(g.convert('RGB').resize((424, 1040), Image.NEAREST))
s = Image.new('RGB', (424 * 4, 1040))
for k, i in enumerate([0, len(fr) // 3, len(fr) // 2, len(fr) - 1]): s.paste(fr[i], (k * 424, 0))
p = s.quantize(colors=255, method=Image.Quantize.MEDIANCUT)
q = [f.quantize(palette=p, dither=Image.Dither.NONE) for f in fr]
q[0].save(m + '/RedBand_GB_showcase_2x.gif', save_all=True, append_images=q[1:], duration=du, loop=0, disposal=1)
PY
echo "1920x1080 showcases"
python3 tools/make_showcase_wide.py $T/walk.bin $T/battle.bin $T/clock.jsonl $T/on.jsonl $APP $M/preview_aod.png $M/wide/RedBand_GB_showcase_1920x1080.gif
python3 tools/make_showcase_wide.py $T/walk.bin $T/battle.bin $T/clock.jsonl $T/on.jsonl $APP $M/preview_aod.png $M/wide/RedBand_GB_showcase2_1920x1080.gif $T/menus.bin
python3 tools/make_showcase_wide3.py $T/walk.bin $T/battle.bin $T/clock.jsonl $T/on.jsonl $APP $T/browse.jsonl $T/sure.jsonl $T/unsafe.jsonl $M/wide/RedBand_GB_showcase3_1920x1080.gif
for n in "" 2 3; do
  ffmpeg -y -loglevel error -i $M/wide/RedBand_GB_showcase${n}_1920x1080.gif -vf "fps=30,format=yuv420p" -c:v libx264 -preset slow -crf 16 -tune animation -movflags +faststart $M/wide/RedBand_GB_showcase${n}_1920x1080.mp4
done
echo "landscape previews and design mock-ups"
for V in A B; do
  O=$([ $V = A ] && echo 1 || echo -1); N=$([ $V = A ] && echo TopLeft || echo TopRight); LA=RedBandLuaWatchfaceL$V/app/lua/
  dump $LA $T/l$V.jsonl; python3 tools/render_landscape_preview.py $T/l$V.jsonl $O $M/landscape/landscape_$N.png
done
dump RedBandLuaWatchfaceLA/app/lua/ $T/lAon.jsonl powered
python3 tools/render_landscape_preview.py $T/lAon.jsonl 1 $M/landscape/landscape_game_x2.png $T/walk.bin 6520
OUT=$M/landscape FRAMES=$T/walk.bin python3 tools/media/landscape_mockups/mock.py
OUT=$M/landscape FRAMES=$T/walk.bin python3 tools/media/landscape_mockups/mock2.py
OUT=$M/landscape FRAMES=$T/walk.bin python3 tools/media/landscape_mockups/mock3.py
python3 tools/media/draw_architecture.py $M/architecture.png
rm -f /data/redbandgb_last.txt; rm -rf $T
echo "done"
