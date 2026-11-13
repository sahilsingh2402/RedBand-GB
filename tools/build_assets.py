"""Static images for the clock (watchface while the game is off) and the AOD screen (4.2.0).

Sources (assets/): the Poketch watchface's own glyphs (Mi Band 6 face "Poketch" by zantfaul,
unpacked with watchface-js) and the Pokemon Red trainer sprite (26x54 pixel art, 20 px cells).
Outputs:
  RedBandLuaWatchface/app/lua/clk_b0..9.bin  big digits 26x62        (LVGL 9 I8 files)
  RedBandLuaWatchface/app/lua/clk_s0..9.bin  small digits 10x16
  RedBandLuaWatchface/app/lua/clk_w0..6.bin  weekdays MON..SUN 34x16
  RedBandLuaWatchface/app/lua/clk_dot.bin    date separator 6x16
  RedBandLuaWatchface/app/lua/clk_red.bin    trainer sprite x3 = 78x162
  assets/aod/*.png                          AOD glyphs (RGBA, light Poketch green, x2, gap included)
I8 = 256-entry BGRA palette + one byte per pixel; LVGL's VG-Lite decoder reads it like Xiaomi's
own (mostly I8) resources."""
import os, struct
from PIL import Image
here = os.path.dirname(os.path.abspath(__file__))
root = os.path.join(here, '..')
src = os.path.join(root, 'assets')
app = os.path.join(root, 'RedBandLuaWatchface', 'app', 'lua')
aod = os.path.join(src, 'aod')
os.makedirs(aod, exist_ok=True)
DARK = (56, 80, 48, 255)          # Poketch LCD ink
AOD_INK = (136, 204, 128, 255)    # light Poketch green on the black AOD screen
AOD_SHADE = (52, 86, 50, 255)     # its shadow, dim

def write_i8(path, im):
    im = im.convert('RGBA')
    w, h = im.size
    pix = list(im.getdata())
    pal, idx = [], {}
    for p in pix:
        if p[3] == 0: p = (0, 0, 0, 0)
        if p not in idx:
            idx[p] = len(pal); pal.append(p)
    assert len(pal) <= 256, path
    data = bytes(idx[(0, 0, 0, 0) if p[3] == 0 else p] for p in pix)
    palb = b''.join(bytes((b, g, r, a)) for r, g, b, a in pal) + bytes(4 * (256 - len(pal)))
    with open(path, 'wb') as f:
        f.write(struct.pack('<BBHHHHH', 0x19, 0x0A, 0, w, h, w, 0) + palb + data)

def recolor(im, ink, pad=0):
    # only the dark Poketch ink becomes the AOD colour; the LCD-green box some glyphs carry goes
    im = im.convert('RGBA')
    out = Image.new('RGBA', (im.size[0] + pad, im.size[1]), (0, 0, 0, 0))
    for y in range(im.size[1]):
        for x in range(im.size[0]):
            r, g, b, a = im.getpixel((x, y))
            if a == 0: continue
            if r + g + b < 250: out.putpixel((x, y), ink)                 # ink
            elif r + g + b < 320: out.putpixel((x, y), AOD_SHADE)         # the Poketch drop shadow
    return out

def x(im, k): return im.resize((im.size[0] * k, im.size[1] * k), Image.NEAREST)
def glyph(i): return Image.open(os.path.join(src, 'poketch', '%d.png' % i)).convert('RGBA')

dot = Image.new('RGBA', (6, 16), (0, 0, 0, 0))
for yy in range(12, 16):
    for xx in range(1, 5): dot.putpixel((xx, yy), DARK)
spr = Image.open(os.path.join(src, 'sprite', 'red_trainer_source.png')).convert('RGBA')
bbox = spr.getbbox()                                   # (60, 60, 580, 1140): cells of 20 px
red = spr.crop(bbox).resize(((bbox[2] - bbox[0]) // 20, (bbox[3] - bbox[1]) // 20), Image.NEAREST)
assert red.size == (26, 54), red.size

for d in range(10):
    write_i8(os.path.join(app, 'clk_b%d.bin' % d), glyph(1 + d))
    write_i8(os.path.join(app, 'clk_s%d.bin' % d), glyph(13 + d))
    x(recolor(glyph(1 + d), AOD_INK, pad=2), 2).save(os.path.join(aod, 'big%d.png' % d))   # 56x124 incl. gap
    x(recolor(glyph(13 + d), AOD_INK, pad=1), 2).save(os.path.join(aod, 'small%d.png' % d))  # 22x32 incl. gap
for k in range(7):
    write_i8(os.path.join(app, 'clk_w%d.bin' % k), glyph(23 + k))
write_i8(os.path.join(app, 'clk_dot.bin'), dot)
write_i8(os.path.join(app, 'clk_red.bin'), x(red, 3))
x(recolor(dot, AOD_INK), 2).save(os.path.join(aod, 'dot.png'))
x(red, 2).save(os.path.join(aod, 'red.png'))
print('assets: 10 big + 10 small digits, 7 weekdays, dot, trainer 78x162; AOD glyphs in assets/aod')
