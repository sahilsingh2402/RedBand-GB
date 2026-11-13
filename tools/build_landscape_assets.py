"""Assets for the landscape face, for one orientation:
  fontland.lua  DejaVu Sans Bold 11 as rotated glyphs: for each character its advance and its
                rows (16 px line, I2, 4 alpha levels), already turned for this orientation
  clkr_*.bin    the Poketch clock images turned 90 degrees (from the portrait clk_*.bin)
  python3 tools/build_landscape_assets.py <orient 1|-1> <app lua dir>"""
import sys, struct, glob, os
from PIL import Image, ImageDraw, ImageFont
ORIENT = int(sys.argv[1]); APP = sys.argv[2]
F = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf', 11)
LH = 16
adv, rows = {}, {}
for code in range(32, 127):
    ch = chr(code)
    a = max(1, int(round(F.getlength(ch))))
    im = Image.new('L', (a, LH), 0)
    ImageDraw.Draw(im).text((0, 1), ch, font=F, fill=255)
    px = im.load()
    def lvl(v): return 0 if v < 48 else (1 if v < 120 else (2 if v < 200 else 3))
    cols = range(a) if ORIENT == 1 else range(a - 1, -1, -1)
    out = bytearray()
    for X in cols:
        ys = range(LH - 1, -1, -1) if ORIENT == 1 else range(LH)
        vals = [lvl(px[X, Y]) for Y in ys]
        for k in range(0, LH, 4):
            out.append((vals[k] << 6) | (vals[k + 1] << 4) | (vals[k + 2] << 2) | vals[k + 3])
    adv[code] = a; rows[code] = bytes(out)
def lua_str(b): return '"' + ''.join('\\%d' % c for c in b) + '"'
with open(os.path.join(APP, 'fontland.lua'), 'w') as f:
    f.write('-- DejaVu Sans Bold 11, rotated for the landscape face (orientation %d): advance and\n-- rows (16 px, I2) per character\nreturn {adv={%s},\ng={%s}}\n' % (
        ORIENT, ','.join('[%d]=%d' % (c, adv[c]) for c in sorted(adv)),
        ',\n'.join('[%d]=%s' % (c, lua_str(rows[c])) for c in sorted(rows))))
# clock images, turned
n = 0
for path in sorted(glob.glob(os.path.join(APP, 'clk_*.bin'))):
    b = open(path, 'rb').read()
    magic, cf, flags, w, h, stride, res = struct.unpack_from('<BBHHHHH', b, 0)
    assert cf == 0x0A, path
    pal = b[12:12 + 1024]; pix = b[12 + 1024:12 + 1024 + stride * h]
    src = [[pix[y * stride + x] for x in range(w)] for y in range(h)]
    nw, nh = h, w
    out = bytearray()
    for y in range(nh):
        for x in range(nw):
            # ORIENT 1 turns the picture clockwise: new (x,y) <- old (y, h-1-x)
            out.append(src[h - 1 - x][y] if ORIENT == 1 else src[x][w - 1 - y])
    name = os.path.basename(path).replace('clk_', 'clkr_')
    open(os.path.join(APP, name), 'wb').write(struct.pack('<BBHHHHH', magic, cf, flags, nw, nh, nw, res) + pal + bytes(out))
    n += 1
print('fontland.lua: %d glyphs; %d clock images turned' % (len(adv), n))
