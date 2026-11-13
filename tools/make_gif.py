"""Showcase GIF of the watchface: real gameplay at the watch's own resolution (212x520, pill).

Frames come from tools/gif_capture.lua (the real emulator core playing a scripted new game, every
4th game frame) and are drawn exactly like the BIG view on the band (I8, 53/40 x 21/16 nearest).
The watchface around them is rendered from the real main.lua layout (tests/layout_dump.lua),
with the buttons that are held at that moment shown pressed and the LED blinking as on the band.
  python3 tools/make_gif.py <frames.bin> <layout_clock.jsonl> <layout_on.jsonl> <app dir> <out.gif> [short]"""
import json, struct, sys
from PIL import Image, ImageDraw, ImageFont
W, H = 212, 520
frames_bin, lay_clock, lay_on, appdir, out = sys.argv[1:6]
short = len(sys.argv) > 6 and sys.argv[6] == 'short'
FONT = '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'
def rgb(c): return ((c >> 16) & 255, (c >> 8) & 255, c & 255)
def load_layout(p): return [json.loads(l) for l in open(p)]
def load_i8(path):
    b = open(path, 'rb').read()
    _, cf, _, w, h, _, _ = struct.unpack_from('<BBHHHHH', b, 0)
    pal = [tuple(b[12 + i * 4:16 + i * 4]) for i in range(256)]
    im = Image.new('RGBA', (w, h))
    im.putdata([(pal[v][2], pal[v][1], pal[v][0], pal[v][3]) for v in b[12 + 1024:12 + 1024 + w * h]])
    return im
_imgcache = {}
def render(objs, over=None, hide=()):
    over = over or {}
    img = Image.new('RGBA', (W, H), (0, 0, 0, 255))
    for o in objs:
        if o['hidden'] in (True, 'true') and o['i'] not in over.get('show', ()): continue
        if o['i'] in hide: continue
        if o['kind'] == 'Object':
            if o['bg'] < 0: continue
            opa = 255 if o['opa'] >= 100 else int(o['opa'] * 255 / 100)
            if opa == 0 and o['border'] == 0: continue
            top, bot = rgb(o['bg']), (rgb(o['grad']) if o['grad'] >= 0 else rgb(o['bg']))
            if o['i'] in over: top, bot = over[o['i']]
            x, y, w, h, r = o['x'], o['y'], o['w'], o['h'], min(o['r'], o['w'] // 2, o['h'] // 2)
            if w <= 0 or h <= 0: continue
            grad = Image.new('RGBA', (w, h)); gd = ImageDraw.Draw(grad)
            for yy in range(h):
                t = yy / max(1, h - 1)
                gd.line([(0, yy), (w, yy)], fill=tuple(int(top[k] + (bot[k] - top[k]) * t) for k in range(3)) + (opa,))
            mask = Image.new('L', (w, h), 0); ImageDraw.Draw(mask).rounded_rectangle([0, 0, w - 1, h - 1], r, fill=255)
            layer = Image.new('RGBA', (w, h), (0, 0, 0, 0)); layer.paste(grad, (0, 0), mask)
            if o['border'] > 0 and o['bc'] >= 0:
                ImageDraw.Draw(layer).rounded_rectangle([0, 0, w - 1, h - 1], r, outline=rgb(o['bc']) + (255,), width=o['border'])
            img.alpha_composite(layer, (x, y))
        elif o['kind'] == 'Label' and o['text']:
            f = ImageFont.truetype(FONT, max(8, int(o['font'] * 0.92)))
            d = ImageDraw.Draw(img)
            tw = d.textlength(o['text'], font=f)
            tx = o['x'] + (o['w'] - tw) / 2 if o['align'] == 2 else o['x']
            d.text((tx, o['y'] + 1), o['text'], font=f, fill=rgb(o['tc']) + (255,))
        elif o['kind'] == 'Image' and o['src']:
            if o['src'] not in _imgcache: _imgcache[o['src']] = load_i8(o['src'])
            img.alpha_composite(_imgcache[o['src']], (o['x'], o['y']))
    return img

ON, CLOCK = load_layout(lay_on), load_layout(lay_clock)
# controls (indices from the layout dump, checked by geometry)
def find(objs, x, y, w, h):
    for o in objs:
        if o['kind'] == 'Object' and (o['x'], o['y'], o['w'], o['h']) == (x, y, w, h): return o['i']
    raise SystemExit('control not found %s' % ((x, y, w, h),))
PILL_DOWN, PAD_DOWN, AB_DOWN = (rgb(0x18191C), rgb(0x2F3238)), (rgb(0x41454B), rgb(0x5E636B)), (rgb(0x470A23), rgb(0x7C1A3F))
PILL_UP = (rgb(0x3D4147), rgb(0x212327))
LED_ON, LED_OFF = (rgb(0xFF6A5A), rgb(0xC4100C)), (rgb(0x481313), rgb(0x1E0505))
IDX = {k: find(ON, *g) for k, g in {
    'RIGHT': (127, 362, 37, 42), 'LEFT': (48, 362, 37, 42), 'UP': (85, 325, 42, 37), 'DOWN': (85, 404, 42, 37),
    'A': (148, 312, 44, 44), 'B': (20, 312, 44, 44), 'SELECT': (36, 452, 66, 28), 'START': (110, 452, 66, 28),
    'POWER': (22, 62, 66, 30), 'TURBO': (112, 30, 62, 26), 'LED': (96, 67, 20, 20), 'GLOW': (91, 62, 30, 30)}.items()}
for o in ON:     # the glow disc is the semi-transparent one of the two 30x30 objects at the LED
    if (o['x'], o['y'], o['w'], o['h']) == (91, 62, 30, 30) and o['opa'] == 30: IDX['GLOW'] = o['i']
BITS = [('RIGHT', 1), ('LEFT', 2), ('UP', 4), ('DOWN', 8), ('A', 16), ('B', 32), ('SELECT', 64), ('START', 128)]
DOWNC = {'RIGHT': PAD_DOWN, 'LEFT': PAD_DOWN, 'UP': PAD_DOWN, 'DOWN': PAD_DOWN, 'A': AB_DOWN, 'B': AB_DOWN, 'SELECT': PILL_DOWN, 'START': PILL_DOWN}
ui_cache = {}
def ui(mask, led, turbo):
    key = (mask, led, turbo)
    if key not in ui_cache:
        over = {}
        for name, bit in BITS:
            if mask & bit: over[IDX[name]] = DOWNC[name]
        if turbo: over[IDX['TURBO']] = PILL_DOWN
        over[IDX['LED']] = LED_ON if led else LED_OFF
        ui_cache[key] = render(ON, over, hide=() if led else (IDX['GLOW'],))
    return ui_cache[key]
clock_cache = {}
def clock_ui(power_down):
    if power_down not in clock_cache:
        over = {IDX['LED']: LED_OFF}
        over[IDX['POWER']] = PILL_DOWN if power_down else PILL_UP
        clock_cache[power_down] = render(CLOCK, over, hide=(IDX['GLOW'],))
    return clock_cache[power_down]

# game frames, drawn like the BIG view: 160x144 -> 212x189, x: (x*40)//53, y: (y*16)//21
SHADE = [(0xE0, 0xF8, 0xD0), (0x88, 0xC0, 0x70), (0x34, 0x68, 0x56), (0x08, 0x18, 0x20)]
raw = open(frames_bin, 'rb').read()
REC = 6 + 5760
caps = {}
for i in range(len(raw) // REC):
    fr, mask, bgp = struct.unpack_from('<IBB', raw, i * REC)
    caps[fr] = (mask, bgp, raw[i * REC + 6:(i + 1) * REC])
XS = [(x * 40) // 53 for x in range(212)]
YS = [(y * 16) // 21 for y in range(189)]
def game_image(fr):
    mask, bgp, fb = caps[fr]
    pal = [SHADE[(bgp >> (2 * c)) & 3] for c in range(4)]
    src = [[pal[(fb[y * 40 + (x >> 2)] >> (6 - 2 * (x & 3))) & 3] for x in range(160)] for y in range(144)]
    im = Image.new('RGB', (212, 189))
    im.putdata([src[YS[y]][XS[x]] for y in range(189) for x in range(212)])
    return im

PILL = Image.new('L', (W, H), 0); ImageDraw.Draw(PILL).rounded_rectangle([0, 0, W - 1, H - 1], 106, fill=255)
frames, durs = [], []
def emit(im, ms):
    out = Image.new('RGB', (W, H), (0, 0, 0)); out.paste(im.convert('RGB'), (0, 0), PILL)
    frames.append(out); durs.append(ms)
tick = [0]
def real_ms():          # 4 game frames = 66.97 ms: 70,70,60 averages 66.7 ms (GIF delays are 10 ms steps)
    tick[0] += 1
    return 60 if tick[0] % 3 == 0 else 70
game_t = [0.0]
def play(a, b, step=4, turbo=False):
    for fr in range(a, b + 1, step):
        if fr not in caps: continue
        game_t[0] += step / 59.7275
        t = game_t[0]
        led = (int(t / 0.25) % 2 == 0) if turbo else (int(t / 0.5) % 2 == 0)
        base = ui(caps[fr][0], led, turbo).copy()
        base.paste(game_image(fr), (0, 110))
        emit(base, real_ms())
def clock(seconds, power_down_last=False):
    n = int(seconds * 15)
    for k in range(n): emit(clock_ui(power_down_last and k >= n - 4), real_ms())
def blank(n=3):
    for _ in range(n): emit(ui(0, True, False), real_ms())

if short:      # ~16 s loop: the house, Pallet Town, Oak stops you
    play(5960, 6880)
    play(6880, 7780, step=16, turbo=True)
else:          # the full tour (~40 s)
    clock(1.4, power_down_last=True)
    blank(3)
    play(340, 540)                    # GAME FREAK
    play(880, 1100)                   # Gengar vs Nidorino
    play(1300, 1520)                  # title screen, START
    play(1828, 2080)                  # Prof. Oak: Hello there!
    play(3316, 3420)                  # Right! So your name is RED!
    play(5960, 6676)                  # Red's room, stairs, mom's room, Pallet Town, north
    play(6676, 6880)                  # OAK: Hey! Wait! Don't go out!
    play(6880, 7828, step=16, turbo=True)   # TURBO: Oak leads the way (4x)
    play(8080, 8380)                  # the lab: BLUE and OAK
    clock(1.2)
# one palette for all frames (built from a sample), no dithering: crisp pixels, small deltas
sample = Image.new('RGB', (W * 4, H))
for k, idx in enumerate([0, len(frames) // 3, len(frames) // 2, len(frames) - 1]):
    sample.paste(frames[idx], (k * W, 0))
pal = sample.quantize(colors=255, method=Image.Quantize.MEDIANCUT)
q = [f.quantize(palette=pal, dither=Image.Dither.NONE) for f in frames]
q[0].save(out, save_all=True, append_images=q[1:], duration=durs, loop=0, optimize=False, disposal=1)
print('gif: %d frames, %.1f s, %s' % (len(q), sum(durs) / 1000, out))
