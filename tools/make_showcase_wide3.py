"""Third 1920x1080 showcase, four RedBand GB watchfaces side by side, no labels:
1-2: the three views (BIG crisp, SMOOTH GPU-scaled, 1:1), switching in a different order;
3: BROWSE (save files, DELETE -> SURE?, CLOSE), POWER, then a tap on the LED (live figures);
4: play with UNSAFE on, then TURBO fast-forward, then normal again.
Real emulator footage; the views are drawn the way the band draws them.
  python3 tools/make_showcase_wide.py <walk frames.bin> <battle frames.bin> <layout_clock.jsonl>
         <layout_on.jsonl> <app dir> <aod.png> <out.gif>"""
import json, struct, sys
from PIL import Image, ImageDraw, ImageFont
walk_bin, battle_bin, lay_clock, lay_on, appdir, lay_browse, lay_sure, lay_unsafe, out = sys.argv[1:10]
W, H = 212, 520
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
_img = {}
def render(objs, over=None, hide=()):
    over = over or {}
    img = Image.new('RGBA', (W, H), (0, 0, 0, 255))
    for o in objs:
        if o['hidden'] in (True, 'true') or o['i'] in hide: continue
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
            if o['src'] not in _img: _img[o['src']] = load_i8(o['src'])
            img.alpha_composite(_img[o['src']], (o['x'], o['y']))
    return img
ON, CLOCK = load_layout(lay_on), load_layout(lay_clock)
def find(objs, x, y, w, h, opa=None):
    for o in objs:
        if o['kind'] == 'Object' and (o['x'], o['y'], o['w'], o['h']) == (x, y, w, h) and (opa is None or o['opa'] == opa): return o['i']
    raise SystemExit('control not found %s' % ((x, y, w, h),))
G = {'RIGHT': (127, 362, 37, 42), 'LEFT': (48, 362, 37, 42), 'UP': (85, 325, 42, 37), 'DOWN': (85, 404, 42, 37),
     'A': (148, 312, 44, 44), 'B': (20, 312, 44, 44), 'SELECT': (36, 452, 66, 28), 'START': (110, 452, 66, 28),
     'POWER': (22, 62, 66, 30), 'TURBO': (112, 30, 62, 26), 'LED': (96, 67, 20, 20)}
IDX = {k: find(ON, *g) for k, g in G.items()}
IDX['GLOW'] = find(ON, 91, 62, 30, 30, opa=30)
PILL_DOWN, PAD_DOWN, AB_DOWN = (rgb(0x18191C), rgb(0x2F3238)), (rgb(0x41454B), rgb(0x5E636B)), (rgb(0x470A23), rgb(0x7C1A3F))
PILL_UP = (rgb(0x3D4147), rgb(0x212327))
LED_ON, LED_OFF = (rgb(0xFF6A5A), rgb(0xC4100C)), (rgb(0x481313), rgb(0x1E0505))
BITS = [('RIGHT', 1), ('LEFT', 2), ('UP', 4), ('DOWN', 8), ('A', 16), ('B', 32), ('SELECT', 64), ('START', 128)]
DOWNC = {'RIGHT': PAD_DOWN, 'LEFT': PAD_DOWN, 'UP': PAD_DOWN, 'DOWN': PAD_DOWN, 'A': AB_DOWN, 'B': AB_DOWN, 'SELECT': PILL_DOWN, 'START': PILL_DOWN}
_ui = {}
def ui(mask, led, turbo=False):
    key = (mask, led, turbo)
    if key not in _ui:
        over = {IDX[n]: DOWNC[n] for n, bit in BITS if mask & bit}
        if turbo: over[IDX['TURBO']] = PILL_DOWN
        over[IDX['LED']] = LED_ON if led else LED_OFF
        _ui[key] = render(ON, over, hide=() if led else (IDX['GLOW'],))
    return _ui[key]
_clk = {}
def clock_ui(power_down):
    if power_down not in _clk:
        over = {IDX['LED']: LED_OFF, IDX['POWER']: PILL_DOWN if power_down else PILL_UP}
        _clk[power_down] = render(CLOCK, over, hide=(IDX['GLOW'],))
    return _clk[power_down]
SHADE = [(0xE0, 0xF8, 0xD0), (0x88, 0xC0, 0x70), (0x34, 0x68, 0x56), (0x08, 0x18, 0x20)]
XS = [(x * 40) // 53 for x in range(212)]
YS = [(y * 16) // 21 for y in range(189)]
def load_caps(path):
    raw = open(path, 'rb').read(); REC = 6 + 5760; caps = {}
    for i in range(len(raw) // REC):
        fr, mask, bgp = struct.unpack_from('<IBB', raw, i * REC)
        caps[fr] = (mask, bgp, raw[i * REC + 6:(i + 1) * REC])
    return caps
WALK, BATTLE = load_caps(walk_bin), load_caps(battle_bin)
_gi = {}
def game(caps, fr):
    key = (id(caps), fr)
    if key not in _gi:
        mask, bgp, fb = caps[fr]
        pal = [SHADE[(bgp >> (2 * c)) & 3] for c in range(4)]
        src = [[pal[(fb[y * 40 + (x >> 2)] >> (6 - 2 * (x & 3))) & 3] for x in range(160)] for y in range(144)]
        im = Image.new('RGB', (212, 189)); im.putdata([src[YS[y]][XS[x]] for y in range(189) for x in range(212)])
        _gi[key] = im
    return _gi[key]
def gameplay(caps, a, b, step=4, turbo=False):
    seq = []
    for fr in range(a, b + 1, step):
        if fr in caps: seq.append(('game', caps, fr, turbo))
    return seq

BROWSE, SURE, UNSAFE = load_layout(lay_browse), load_layout(lay_sure), load_layout(lay_unsafe)
MSG = find(ON, 8, 116, 196, 30) if False else None
for o in ON:
    if o['kind'] == 'Label' and (o['x'], o['y'], o['w']) == (8, 116, 196): MSG = o['i']
BTN = find(ON, 38, 30, 68, 26)
CLOSE = [o['i'] for o in BROWSE if o['kind'] == 'Object' and o['w'] == 80 and o['h'] == 24][0]
DEL1 = [o for o in BROWSE if o['kind'] == 'Object' and o['w'] == 58 and o['h'] == 26 and not o['hidden']][0]['i']
_st = {}
def state(name, over=None, hide=()):
    key = (name, tuple(sorted((over or {}).items())), tuple(hide))
    if key not in _st:
        objs = {'clock': CLOCK, 'browse': BROWSE, 'sure': SURE}[name]
        o2 = {IDX['LED']: LED_OFF}; o2.update(over or {})
        _st[key] = render(objs, o2, hide=(IDX['GLOW'],) + tuple(hide))
    return _st[key]
_uns = {}
def ui_unsafe(mask, led, turbo):
    key = (mask, led, turbo)
    if key not in _uns:
        over = {IDX[n]: DOWNC[n] for n, bit in BITS if mask & bit}
        if turbo: over[IDX['TURBO']] = PILL_DOWN
        over[IDX['LED']] = LED_ON if led else LED_OFF
        hide = (MSG,) + (() if led else (IDX['GLOW'],))
        _uns[key] = render(UNSAFE, over, hide=hide)
    return _uns[key]
def game_view(caps, fr, view):
    if view == 'big': return game(caps, fr), (0, 110)
    mask, bgp, fb = caps[fr]
    pal = [SHADE[(bgp >> (2 * c)) & 3] for c in range(4)]
    im = Image.new('RGB', (160, 144))
    im.putdata([pal[(fb[y * 40 + (x >> 2)] >> (6 - 2 * (x & 3))) & 3] for y in range(144) for x in range(160)])
    if view == 'fast': return im, (26, 132)
    # SMOOTH: the GPU scales 160x144 by 338/256 around the centre with bilinear filtering
    return im.resize((211, 190), Image.BILINEAR), (1, 110)
FONT11 = ImageFont.truetype(FONT, 11)
def draw_msg(img, text):
    d = ImageDraw.Draw(img)
    words, lines, cur = text.split(' '), [], ''
    for w in words:
        t = (cur + ' ' + w).strip()
        if d.textlength(t, font=FONT11) <= 196: cur = t
        else: lines.append(cur); cur = w
    lines.append(cur)
    for k, ln in enumerate(lines[:2]):
        tw = d.textlength(ln, font=FONT11)
        d.text((8 + (196 - tw) / 2, 117 + k * 14), ln, font=FONT11, fill=rgb(0xC2C7CD) + (255,))
N = 240
def seq_views(caps, a, order):
    frs = [fr for fr in range(a, a + 4 * N, 4)]
    return [(caps, frs[k], order[k * 3 // N]) for k in range(N)]
P1 = seq_views(WALK, 5960, ['big', 'smooth', 'fast'])
P2 = seq_views(BATTLE, 11600, ['smooth', 'fast', 'big'])
LEDMSG = 'fps 60 busy 58% lua 3.3M free 8.1M XL b32 map 0'
P3 = ([('clock', {}, ())] * 20 + [('clock', {BTN: PILL_DOWN}, ())] * 4 + [('browse', {}, ())] * 36 +
      [('browse', {DEL1: (rgb(0xC4302B), rgb(0x470A23))}, ())] * 4 + [('sure', {}, ())] * 36 +
      [('sure', {CLOSE: PILL_DOWN}, ())] * 4 + [('clock', {}, ())] * 16 + [('clock', {IDX['POWER']: PILL_DOWN}, ())] * 4)
P3 = P3 + [('game', fr) for fr in range(172, 172 + 4 * (N - len(P3)), 4)]
P4 = ([('n', fr, False) for fr in range(16300, 16620, 4)] + [('n', fr, True) for fr in range(16620, 17900, 16)] +
      [('n', fr, False) for fr in range(18300, 18620, 4)])[:N]
PW, PH = 424, 1040
GAP = 40
X0 = (1920 - (4 * PW + 3 * GAP)) // 2
Y0 = (1080 - PH) // 2
BG = (17, 19, 23)
PILL = Image.new('L', (W, H), 0); ImageDraw.Draw(PILL).rounded_rectangle([0, 0, W - 1, H - 1], 106, fill=255)
PILL2 = PILL.resize((PW, PH), Image.NEAREST)
def blink(t, turbo=False): return (int(t / 0.25) % 2 == 0) if turbo else (int(t / 0.5) % 2 == 0)
frames = []
for k in range(N):
    t = k * 4 / 59.7275
    imgs = []
    for caps, fr, view in (P1[k], P2[k]):
        base = ui(caps[fr][0], blink(t), False).copy()
        gi, pos = game_view(caps, fr, view)
        base.paste(gi, pos)
        imgs.append(base)
    it = P3[k]
    if it[0] == 'game':
        fr = it[1]
        base = ui(WALK[fr][0] if fr in WALK else 0, blink(t + 0.2), False).copy()
        base.paste(game(WALK, fr), (0, 110))
        if fr >= 336: draw_msg(base, LEDMSG)        # tapped the LED: live figures for a few seconds
        imgs.append(base)
    else:
        imgs.append(state(it[0], it[1]))
    _, fr, turbo = P4[k]
    if k < 8: base = ui(BATTLE[fr][0], blink(t + 0.4), turbo).copy()
    elif k < 12:                                   # the UNSAFE tap
        over = {IDX[n]: DOWNC[n] for n, bit in BITS if BATTLE[fr][0] & bit}
        over[BTN] = PILL_DOWN; over[IDX['LED']] = LED_ON if blink(t + 0.4) else LED_OFF
        base = render(ON, over, hide=() if blink(t + 0.4) else (IDX['GLOW'],))
    else: base = ui_unsafe(BATTLE[fr][0], blink(t + 0.4, turbo), turbo).copy()
    base.paste(game(BATTLE, fr), (0, 110))
    imgs.append(base)
    canvas = Image.new('RGB', (1920, 1080), BG)
    for p in range(4):
        canvas.paste(imgs[p].convert('RGB').resize((PW, PH), Image.NEAREST), (X0 + p * (PW + GAP), Y0), PILL2)
    frames.append(canvas)
durs = [60 if i % 3 == 2 else 70 for i in range(N)]
sample = Image.new('RGB', (1920, 1080 * 4))
for j, i in enumerate([30, 100, 150, 220]): sample.paste(frames[i], (0, j * 1080))
pal = sample.quantize(colors=255, method=Image.Quantize.MEDIANCUT)
q = [f.quantize(palette=pal, dither=Image.Dither.NONE) for f in frames]
q[0].save(out, save_all=True, append_images=q[1:], duration=durs, loop=0, optimize=False, disposal=1)
frames[95].save(out.replace('.gif', '_still.png'))
print('wrote', out, N, 'frames', sum(durs) / 1000, 's')
