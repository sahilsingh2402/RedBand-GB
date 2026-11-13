# RedBandLuaWatchface (4.6.0)

The portrait watchface project. `./build.sh` (repository root) fills `app/lua/` with the files
made from your ROM (`gbank*.dat`, `gbcore*`); they are never committed. The landscape faces are
built from this folder into `RedBandLuaWatchfaceLA/` and `RedBandLuaWatchfaceLB/`.

`app/lua/` holds:

- `main.lua`: UI, in-memory indexed presenter (BIG / SMOOTH / FAST, file fallback), real-time
  frame-locked scheduler, diagnostics line (from `../tools/main_template.lua`);
- `gbcore.lua` (source) and `gbcore_s/l/xl.luac` (Lua 5.4.0 bytecode, three sizes): the engine, chosen at POWER from free memory;
- `gbank00.dat` ... `gbank63.dat`: the ROM.

`python3 build_face.py` writes `../output/RedBand_GB_4_6_0.bin`; `main.lua` sorts last
(entry 65, sentinel 65).

- `clk_*.bin`: Poketch clock digits/weekdays and the trainer sprite (LVGL I8), from `../tools/build_assets.py`.
