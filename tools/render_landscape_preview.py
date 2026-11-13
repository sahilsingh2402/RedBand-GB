"""Render the landscape face from a layout dump (the panel as installed, 212x520), then turn it
upright (520x212). Optionally paint a game frame into the screen area the way the band shows
the BIG view (224x202, exactly 7/5).
  python3 tools/render_landscape_preview.py <dump.jsonl> <orient> <out.png> [frames.bin frame]"""
import json, struct, sys
from PIL import Image, ImageDraw
dump, orient, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
W, H = 212, 520
def rgb(c): return ((c >> 16) & 255, (c >> 8) & 255, c & 255)
def load_img(path):
    b = open(path, 'rb').read()
    _, cf, _, w, h, stride, _ = struct.unpack_from('<BBHHHHH', b, 0)
    if cf == 0x0A:
        pal = [tuple(b[12 + i * 4:16 + i * 4]) for i in range(256)]; px = b[12 + 1024:]
        data = [px[y * stride + x] for y in range(h) for x in range(w)]
    else:                                  # I2
        pal = [tuple(b[12 + i * 4:16 + i * 4]) for i in range(4)]; px = b[12 + 16:]
        data = [(px[y * stride + (x >> 2)] >> (6 - 2 * (x & 3))) & 3 for y in range(h) for x in range(w)]
    im = Image.new('RGBA', (w, h)); im.putdata([(pal[v][2], pal[v][1], pal[v][0], pal[v][3]) for v in data])
    return im
objs = [json.loads(l) for l in open(dump)]
img = Image.new('RGBA', (W, H), (0, 0, 0, 255))
for o in objs:
    if o['hidden'] in (True, 'true'): continue
    if o['kind'] == 'Object' and o['bg'] >= 0:
        opa = 255 if o['opa'] >= 100 else int(o['opa'] * 255 / 100)
        if opa == 0 and o['border'] == 0: continue
        a, b = rgb(o['bg']), (rgb(o['grad']) if o['grad'] >= 0 else rgb(o['bg']))
        x, y, w, h, r = o['x'], o['y'], o['w'], o['h'], min(o['r'], o['w'] // 2, o['h'] // 2)
        if w <= 0 or h <= 0: continue
        g = Image.new('RGBA', (w, h)); d = ImageDraw.Draw(g)
        for xx in range(w):                # sideways gradients on this face
            t = xx / max(1, w - 1); d.line([(xx, 0), (xx, h)], fill=tuple(int(a[k] + (b[k] - a[k]) * t) for k in range(3)) + (opa,))
        m = Image.new('L', (w, h), 0); ImageDraw.Draw(m).rounded_rectangle([0, 0, w - 1, h - 1], r, fill=255)
        layer = Image.new('RGBA', (w, h), (0, 0, 0, 0)); layer.paste(g, (0, 0), m)
        if o['border'] > 0 and o['bc'] >= 0: ImageDraw.Draw(layer).rounded_rectangle([0, 0, w - 1, h - 1], r, outline=rgb(o['bc']) + (255,), width=o['border'])
        img.alpha_composite(layer, (x, y))
    elif o['kind'] == 'Image' and o['src']:
        try: img.alpha_composite(load_img(o['src']), (o['x'], o['y']))
        except FileNotFoundError: pass
pill = Image.new('L', (W, H), 0); ImageDraw.Draw(pill).rounded_rectangle([0, 0, W - 1, H - 1], 106, fill=255)
phys = Image.new('RGBA', (W, H), (0, 0, 0, 255)); phys.paste(img, (0, 0), pill)
up = phys.transpose(Image.Transpose.ROTATE_90 if orient == 1 else Image.Transpose.ROTATE_270)
if len(sys.argv) > 5:
    SH = [(0xE0, 0xF8, 0xD0), (0x88, 0xC0, 0x70), (0x34, 0x68, 0x56), (0x08, 0x18, 0x20)]
    raw = open(sys.argv[4], 'rb').read(); REC = 6 + 5760; want = int(sys.argv[5])
    for i in range(len(raw) // REC):
        fr, _, bgp = struct.unpack_from('<IBB', raw, i * REC)
        if fr == want:
            fb = raw[i * REC + 6:(i + 1) * REC]; pal = [SH[(bgp >> (2 * c)) & 3] for c in range(4)]
            g = Image.new('RGB', (224, 202))
            g.putdata([pal[(fb[((y * 144) // 202) * 40 + (((x * 5) // 7) >> 2)] >> (6 - 2 * (((x * 5) // 7) & 3))) & 3] for y in range(202) for x in range(224)])
            up.paste(g, (132, 5)); break
up.save(out); print('landscape preview', up.size, out)
