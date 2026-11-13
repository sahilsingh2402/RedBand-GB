# RedBand GB 4.6.0 Landscape

The same watchface turned sideways: hold the band horizontally. The emulator, engines, saves,
SAFE/UNSAFE modes, TURBO, BROWSE, the black box and every safety net are the tested 4.6.0
code; only the screen layer is new.

## Which file

| File | Hold the band so that... |
|---|---|
| `RedBand_GB_4_6_0_Landscape_TopLeft.bin` | the band's top end (the end above the screen when you wear it normally) is on your LEFT |
| `RedBand_GB_4_6_0_Landscape_TopRight.bin` | the band's top end is on your RIGHT |

Each comes with `_noAOD` (no always-on display) and `_noROM` (for publishing) versions. The
landscape faces have their own watchface IDs, so they install next to the portrait face
instead of replacing it. Saves are shared: the same game save works in portrait and landscape.

## Layout (logical 520x212)

- Screen: 224x202, the Game Boy picture at exactly 1.4x, 14 px left of centre (portrait BIG is
  212x189: about 13% more picture).
- Right: D-pad (120 px cross), PAUSE and POWER above it, the LED low beside the screen.
- Left: A and B side by side (A nearer the screen), TURBO and UNSAFE above (UNSAFE reads BROWSE
  with the game off), START and SELECT below.
- Every control stays 20 px from the band's long edges and away from its rounded ends.
- Long-press the screen: crisp (224x202) -> smooth (GPU-scaled 1.4x) -> 1:1 (160x144).
- Messages ("last run", LED figures, mode changes) now sit on a dark strip, readable on any scene.

## How it works

- Every object is placed on a logical 520x212 canvas and mapped onto the 212x520 panel.
- The game picture is built upright and turned 90 degrees by the graphics chip (image angle,
  no filtering for the crisp and 1:1 views).
- Text cannot be rotated by the band's Lua binding, so all text is drawn as small rotated
  images from a pre-rendered font (`fontland.lua`, DejaVu Sans Bold 11).
- The clock uses rotated copies of the Poketch images (`clkr_*.bin`).
- The always-on display stays as in the portrait face.

## Not yet confirmed on the band

The graphics chip turning the game picture: the firmware has the image rotation property and
the tests show the right picture, but whether rotating every frame costs anything noticeable
on the band is only known once it runs there. If the picture shows sideways, or the game feels
slower than portrait, the portrait 4.6.0 face is unaffected.

## Rebuild

`./build.sh` builds both landscape faces after the portrait one. By hand, for one orientation:

```
python3 tools/make_landscape.py 1 RedBandLuaWatchfaceLA/app/lua/main.lua     # 1: top end left, -1: right
python3 tools/build_landscape_assets.py 1 RedBandLuaWatchfaceLA/app/lua
RB_ID=781209301 RB_TITLE="REDBAND LAND-L" RB_NAME=RedBand_GB_4_6_0_Landscape_TopLeft python3 RedBandLuaWatchfaceLA/build_face.py
```
