"""Render the watchface as installed (game off, Poketch clock showing) to a 212x520 PNG, from the
layout dump of the real main.lua (tests/layout_dump.lua). Used for the package preview and to
check the visible scene: every visible image inside its panel and inside the pill, no two
images of the clock overlapping.
  python3 tools/render_preview.py <layout.jsonl> <app/lua dir> <out.png>"""
import json, struct, sys, math
from PIL import Image, ImageDraw, ImageFont
W, H = 212, 520
objs = [json.loads(l) for l in open(sys.argv[1])]
appdir, out = sys.argv[2], sys.argv[3]
FONT = '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'

def rgb(c): return ((c >> 16) & 255, (c >> 8) & 255, c & 255)
def load_i8(path):
    b = open(path, 'rb').read()
    magic, cf, flags, w, h, stride, _ = struct.unpack_from('<BBHHHHH', b, 0)
    assert magic == 0x19 and cf == 0x0A, path
    pal = [tuple(b[12 + i * 4:16 + i * 4]) for i in range(256)]
    im = Image.new('RGBA', (w, h))
    data = b[12 + 1024:]
    im.putdata([(pal[v][2], pal[v][1], pal[v][0], pal[v][3]) for v in data[:w * h]])
    return im

def in_pill(x, y, m=0):
    r = 106
    if y < r: return math.hypot(x - 106, y - r) <= r - m
    if y > H - r: return math.hypot(x - 106, y - (H - r)) <= r - m
    return m <= x <= W - m

img = Image.new('RGBA', (W, H), (0, 0, 0, 255))
d = ImageDraw.Draw(img)
def rect(o, fill_top, fill_bot, alpha):
    x, y, w, h, r = o['x'], o['y'], o['w'], o['h'], min(o['r'], o['w'] // 2, o['h'] // 2)
    if w <= 0 or h <= 0: return
    layer = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    grad = Image.new('RGBA', (w, h))
    gd = ImageDraw.Draw(grad)
    for yy in range(h):
        t = yy / max(1, h - 1)
        c = tuple(int(fill_top[k] + (fill_bot[k] - fill_top[k]) * t) for k in range(3))
        gd.line([(0, yy), (w, yy)], fill=c + (alpha,))
    mask = Image.new('L', (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, w - 1, h - 1], r, fill=255)
    layer.paste(grad, (0, 0), mask)
    if o['border'] > 0 and o['bc'] >= 0:
        ImageDraw.Draw(layer).rounded_rectangle([0, 0, w - 1, h - 1], r, outline=rgb(o['bc']) + (255,), width=o['border'])
    img.alpha_composite(layer, (x, y))

problems, images = [], []
for o in objs:
    if o['hidden'] in (True, 'true'): continue
    if o['kind'] == 'Object':
        if o['bg'] < 0: continue
        opa = 255 if o['opa'] >= 100 else int(o['opa'] * 255 / 100)
        if opa == 0 and o['border'] == 0: continue
        top = rgb(o['bg'])
        bot = rgb(o['grad']) if o['grad'] >= 0 else top
        rect(o, top, bot, opa)
    elif o['kind'] == 'Label' and o['text']:
        f = ImageFont.truetype(FONT, max(8, int(o['font'] * 0.92)))
        tw = d.textlength(o['text'], font=f)
        tx = o['x'] + (o['w'] - tw) / 2 if o['align'] == 2 else o['x']
        ImageDraw.Draw(img).text((tx, o['y'] + 1), o['text'], font=f, fill=rgb(o['tc']) + (255,))
    elif o['kind'] == 'Image' and o['src']:
        im = load_i8(o['src'] if o['src'].startswith('/') and not o['src'].startswith(appdir) else o['src'])
        img.alpha_composite(im, (o['x'], o['y']))
        images.append((o, im.size))
# checks on the visible scene
byIdx = {o['i']: o for o in objs}
for o, (w, h) in images:
    for px, py in ((o['x'], o['y']), (o['x'] + w - 1, o['y']), (o['x'], o['y'] + h - 1), (o['x'] + w - 1, o['y'] + h - 1)):
        if not in_pill(px, py, 3): problems.append('image %d outside the pill' % o['i'])
    par = byIdx.get(o['parent'])
    if par and par['kind'] == 'Object' and par['w'] < W:
        b = par['border']
        if not (o['x'] >= par['x'] + b and o['y'] >= par['y'] + b and o['x'] + w <= par['x'] + par['w'] - b and o['y'] + h <= par['y'] + par['h'] - b):
            problems.append('image %d cropped by its panel' % o['i'])
for a in range(len(images)):
    for b2 in range(a + 1, len(images)):
        (o1, (w1, h1)), (o2, (w2, h2)) = images[a], images[b2]
        if o1['x'] < o2['x'] + w2 and o2['x'] < o1['x'] + w1 and o1['y'] < o2['y'] + h2 and o2['y'] < o1['y'] + h1:
            problems.append('images %d and %d overlap' % (o1['i'], o2['i']))
# the pill: outside is black
mask = Image.new('L', (W, H), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, W - 1, H - 1], 106, fill=255)
final = Image.new('RGBA', (W, H), (0, 0, 0, 255))
final.paste(img, (0, 0), mask)
final.save(out)
print('preview: %d visible images, %s' % (len(images), 'no problems' if not problems else 'PROBLEMS: ' + '; '.join(problems)))
sys.exit(1 if problems else 0)
