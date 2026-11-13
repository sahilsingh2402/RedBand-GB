# Firmware 3.1.33 (miwear_watch_o66cn) - evidence table (full story: REPORT.md)

Method: `strings` plus Thumb-2 disassembly (capstone) of `vela_ap.bin`. Data is mapped at
0x2C0A0000 and code at 0x0C0A0000 (file offset = address - base); the luavgl method table at
file 0x68A18C points at "set_src" at 0x2C7296A8, which fixes the base.

| Finding | Evidence | Consequence for RedBand |
|---|---|---|
| Xiaomi Smart Band 10, BES2700iMP (Cortex-M33) | "Xiaomi Smart Band 10", "miwear.watch.o66cn" | No double-precision FPU: keep floats out of hot loops |
| Lua 5.4.0, double floats, 64-bit integers | "Lua 5.4.0 Copyright", "%.14g", "%lld" | `string.format('%p')` exists; TString contents at +16 on 32-bit (measured at run time) |
| Watchface Lua state from `luaL_newstate` | `bl 0xC166678` in `miwear_lua_run` | System heap, no per-state limit found; >3 MB failed in an earlier build, so stay lean |
| LVGL ~9.1 (`_lv_cache_lru_rb.c`) on NuttX fbdev | source paths in asserts | `lv_image_dsc_t` = header(12) + data_size + data pointer |
| VeriSilicon VG-Lite GPU draw unit | "VGLite API version", `init_vglite`, `lv_draw_vg_lite_*.c` | Images are drawn by the GPU; image buffers must be aligned and cache-clean |
| VG-Lite image decoder (`lv_vg_lite_decoder.c`) | source path, "decode_indexed" | Indexed sources are copied by the CPU into an aligned I8 buffer, cache invalidated, cached |
| No VG-Lite box shadow | `lv_draw_vg_lite_box_shadow.c` absent | Shadows fall back to the CPU: removed from the UI |
| Image cache: own 6 MB heap | `mov.w r2, #0x600000` in `lv_nuttx_image_cache_init` | Decoded frames are cached by source address: descriptors kept alive (ring of 480) |
| VG-Lite asserts off | "buffer address(%p) is not aligned" absent | A misaligned direct RGB565 source would not crash but could draw garbage: not used |
| luavgl `set_src` | `0xC456EDA`: `luavgl_to_obj`, `luavgl_toimgsrc` (`0xC45FAB4`: userdata -> `lua_touserdata`, string -> `lua_tolstring`), then `lv_image_set_src` (`0xC30B8BC`) | The Lua string's own bytes reach LVGL unchanged |
| `lv_image_src_get_type` | `0xC272194`: 0x20..0x7F file, >= 0x80 symbol, else variable | A string starting with 0x19 is read as an `lv_image_dsc_t` |
| Image properties | table at file 0x688430: src, offset_x, offset_y, angle, zoom (`lv_image_set_scale`), antialias, pivot | SMOOTH view uses `zoom=338` (GPU bilinear) |
| luavgl widgets | lv_img, lv_label, lv_led, lv_list, lv_textarea, lv_btnm, lv_keyboard, lv_checkbox, lv_calendar, lv_roller, lv_dropdown + Xiaomi Pointer, AnalogTime, ImageLabel, ImageBar, CurvedLabel, Thumbnail, ImageLineBar | No canvas: an image source is the only pixel path |
| Image formats Xiaomi uses | about 90% of 2,966 LVGL image headers found in the resource images are I8 (incl. compressed) | The GPU palette path is the device's main path |
| Mounts | "mount -t tmpfs /tmp", "mount -t yaffs ... /data", romfs for system parts | `/tmp` is RAM (file fallback); ROM banks and saves are on NAND (bank cache 12) |
| `clock()` | NuttX `clock_systime_timespec`, microseconds | `os.clock()` is a monotonic wall clock: used for pacing |
| `/proc/meminfo` | procfs/fs_procfsmeminfo.c, "Umem", "Kmem" | 4.1.0 reads free memory to choose engine size and collector pause |
| Lua chunk loading | `luaL_loadfilex` (mode "bt") | Precompiled 5.4.0 bytecode can be loaded; header checked by the loader |
