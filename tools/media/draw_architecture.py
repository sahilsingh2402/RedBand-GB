"""Draw docs/media/architecture.png: the layers of RedBand GB and how data flows between them.
  python3 tools/media/draw_architecture.py docs/media/architecture.png"""
import sys
from PIL import Image, ImageDraw, ImageFont
OUT = sys.argv[1] if len(sys.argv) > 1 else 'architecture.png'
W, H = 1800, 1180
BG, FG, MUTED = (17, 19, 23), (232, 234, 237), (150, 157, 166)
B = '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'; R = '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'
fT, fH, fB, fS = ImageFont.truetype(B, 34), ImageFont.truetype(B, 21), ImageFont.truetype(B, 16), ImageFont.truetype(R, 13)
img = Image.new('RGB', (W, H), BG); d = ImageDraw.Draw(img)
LAYER = {'hw': ((44, 48, 56), (110, 116, 126)), 'fw': ((32, 52, 74), (88, 140, 196)), 'wf': ((68, 30, 44), (196, 70, 111)),
         'core': ((38, 58, 40), (112, 180, 112)), 'build': ((58, 50, 30), (200, 168, 80))}
def box(x, y, w, h, title, lines, kind):
    fill, edge = LAYER[kind]
    d.rounded_rectangle([x, y, x + w, y + h], 12, fill=fill, outline=edge, width=2)
    d.text((x + 12, y + 10), title, font=fB, fill=FG)
    for i, t in enumerate(lines): d.text((x + 12, y + 34 + i * 17), t, font=fS, fill=(205, 210, 216))
    return (x, y, w, h)
def band(y, h, label, kind):
    fill, edge = LAYER[kind]
    d.rounded_rectangle([20, y, W - 20, y + h], 16, outline=edge, width=2)
    d.text((36, y + 8), label, font=fH, fill=edge)
def arrow(p, q, label=None, ly=None, color=(230, 232, 235)):
    d.line([p, q], fill=color, width=3)
    import math
    a = math.atan2(q[1] - p[1], q[0] - p[0])
    for s in (2.6, -2.6):
        d.line([q, (q[0] + 14 * math.cos(a + s), q[1] + 14 * math.sin(a + s))], fill=color, width=3)
    if label:
        mx, my = (p[0] + q[0]) / 2, (p[1] + q[1]) / 2
        if ly is not None and q[1] != p[1]:          # put the label in the gap between two layers
            t = (ly - p[1]) / (q[1] - p[1]); mx, my = p[0] + (q[0] - p[0]) * t, ly
        tw = d.textlength(label, font=fS)
        d.rectangle([mx - tw / 2 - 4, my - 9, mx + tw / 2 + 4, my + 9], fill=BG)
        d.text((mx - tw / 2, my - 8), label, font=fS, fill=(250, 220, 120))
d.text((36, 14), 'RedBand GB - architecture', font=fT, fill=FG)
d.text((620, 28), 'a Game Boy emulator in a stock Lua watchface on the Xiaomi Smart Band 10', font=fS, fill=MUTED)
# --- hardware
band(70, 150, 'Band hardware', 'hw')
cpu = box(40, 106, 330, 100, 'BES2700iMP (BEST1503) CPU', ['runs Lua: emulation and frame building', 'is where almost all the time goes'], 'hw')
gpu = box(400, 106, 330, 100, 'VeriSilicon VG-Lite (2D)', ['draws images with palette lookup,', 'scaling and rotation (~2 ms / frame)'], 'hw')
ram = box(760, 106, 330, 100, 'RAM (shared system heap)', ['Lua shares it with everything else;', 'free memory read from /proc/meminfo'], 'hw')
nand = box(1120, 106, 640, 100, 'NAND flash', ['watchface files: main.lua, engines, 64 ROM bank files, clock images', '/data: battery save (+ .tmp, .bak), settings, black box'], 'hw')
# --- firmware
band(240, 150, 'Stock firmware 3.1.x (no custom firmware needed)', 'fw')
os_ = box(40, 276, 400, 100, 'NuttX-based OS', ['/proc/meminfo, /tmp RAM disk, watchdog,', 'dataman (time), microsecond clock()'], 'fw')
lvgl = box(470, 276, 480, 100, 'LVGL 9.1', ['VG-Lite draw unit + decoder, 6 MB image cache', 'string src: first byte < 0x20 = in-memory image'], 'fw')
luav = box(980, 276, 360, 100, 'luavgl', ['passes Lua string bytes to', 'lv_image_set_src unchanged'], 'fw')
lua = box(1370, 276, 390, 100, 'Lua 5.4.0', ['32-bit pointers, 64-bit integers,', 'bytecode load, string.format("%p")'], 'fw')
# --- watchface
band(410, 300, 'RedBand GB watchface (main.lua)', 'wf')
sch = box(40, 446, 330, 118, 'Scheduler (8 ms timer)', ['real-time game clock (59.7275 fps)', 'frame-locked showing: every P (2..6)', 'CPU breathing: busy <= 80% / 85%', 'TURBO 4x'], 'wf')
pres = box(400, 446, 400, 118, 'Presenter', ['I2 160x144 = palette + FB bytes', 'I8 crisp 212x189 / 224x202: run tables,', 'row cache; descriptor = header + address', 'ring of 2048 (LVGL cache keyed by address)'], 'wf')
mem = box(830, 446, 450, 118, 'Memory & safety', ['engine from free memory (SAFE 6/4 MB, FAST 3/1.8)', 'GC headroom, early give-back < 2.5 MB', 'out-of-memory -> recovery point (30 s)', 'every callback protected; black box'], 'wf')
save = box(1310, 446, 450, 118, 'Battery save', ['only finished saves (checksum + 1 s settled)', 'sprite scratch area ignored', '.tmp -> read back -> .bak -> rename', 'load: save, .tmp, .bak'], 'wf')
banks = box(40, 580, 400, 112, 'ROM bank cache', ['16 KB bank files read from NAND', '14 / 24 / 32 packed banks (S / L / XL)', 'dropped bank refilled in place: no garbage'], 'wf')
modes = box(470, 580, 420, 112, 'SAFE / FAST', ['UNSAFE button while playing', 'engine handoff by save state (exact)', 'FAST falls back to SAFE on low memory'], 'wf')
ui = box(920, 580, 840, 112, 'UI layer, clock, BROWSE, messages', ['portrait 212x520, or landscape canvas 520x212 mapped onto the panel (rotated text images,', 'GPU-rotated picture); Poketch clock + AOD; save browser; LED: live figures; "last run" after a crash', 'all controls >= 20 px from the long edges (band gestures)'], 'wf')
# --- core
band(730, 170, 'Emulator engine: gbcore S / L / XL (Lua 5.4.0 bytecode, loaded at POWER)', 'core')
interp = box(40, 766, 400, 116, 'CPU interpreter', ['every opcode, exact cycle counts', '(gen_cpu_lua.py); events: timers,', 'interrupts, LCD, DMA; fast HALT skip'], 'core')
aot = box(470, 766, 420, 116, 'Compiled blocks', ['hot game code pre-translated to Lua', '(gen_aot_lua.py, budgets 260/520/1000 KB)', 'lockstep-identical to the interpreter'], 'core')
ppu = box(920, 766, 400, 116, 'Picture unit', ['catch-up rendering (only shown frames)', 'per-frame sprite buckets', 'FB: 144 x 40 bytes, 2-bit pixels'], 'core')
mbc = box(1350, 766, 410, 116, 'MBC3 + battery RAM + states', ['packed ROM: 8 bytes per integer', 'battery RAM window A000-BFFF', 'saveState / loadState (one string)'], 'core')
# --- build
band(920, 240, 'Build on a computer (./build.sh, your own ROM)', 'build')
steps = [('ROM', ['rom/pokemon_red.gb', '(sha256 checked)']), ('split_rom.py', ['64 bank files']), ('build_cores.py', ['gen_cpu + gen_aot +', 'assemble + luac 5.4.0']),
         ('build_assets.py', ['clock + AOD images']), ('build_main.py', ['main.lua']), ('build_face.py', ['+ facebin_mb11 (AOD)', '.bin packages']), ('make_landscape.py', ['landscape main.lua,', 'font, rotated clock'])]
x = 40; prev = None
for i, (t, ls) in enumerate(steps):
    b = box(x, 960, 230, 92, t, ls, 'build')
    if prev: arrow((prev[0] + prev[2], 1006), (x, 1006))
    prev = b; x += 246
d.text((40, 1066), 'Tests (tests/run_all.sh): band-like Lua 5.4.0 hosts (32-bit, memory caps, allocation-failure bursts) + an LVGL stand-in that reads image', font=fS, fill=(205, 210, 216))
d.text((40, 1084), 'descriptors from raw memory: Blargg ROMs, golden frames, lockstep engines, 26,000-frame pixel checks, real in-game saves, stress runs with random events.', font=fS, fill=(205, 210, 216))
d.text((40, 1112), 'No ROM and no ROM-derived data in the repository. Created by Ryntra.', font=fB, fill=(250, 220, 120))
# --- data flow arrows
arrow((sch[0] + 300, sch[1] + sch[3]), (interp[0] + 300, interp[1]), 'run frames', 720)
arrow((ppu[0] + 120, ppu[1]), (pres[0] + 300, pres[1] + pres[3]), 'framebuffer', 720)
arrow((pres[0] + 200, pres[1]), (lvgl[0] + 160, lvgl[1] + lvgl[3]), 'lv_image_dsc_t in a Lua string', 400)
arrow((lvgl[0] + 100, lvgl[1]), (gpu[0] + 160, gpu[1] + gpu[3]), 'draw', 230)
arrow((mbc[0] + 200, mbc[1]), (save[0] + 200, save[1] + save[3]), 'battery RAM', 720)
arrow((save[0] + 300, save[1]), (nand[0] + 500, nand[1] + nand[3]), 'atomic write', 400)
arrow((mem[0] + 220, mem[1]), (ram[0] + 160, ram[1] + ram[3]), '/proc/meminfo', 400)
img.save(OUT); print('architecture chart', img.size, OUT)
