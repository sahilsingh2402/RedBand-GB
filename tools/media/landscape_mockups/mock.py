# Landscape layout options for RedBand GB (520x212 = the band turned sideways), drawn in the
# watchface's own style with a real game frame.
import struct
from PIL import Image, ImageDraw, ImageFont
B = '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'
def rgb(c): return ((c >> 16) & 255, (c >> 8) & 255, c & 255)
C = dict(bodyTop=0x3A3E44, bodyBot=0x24272B, bezel=0x0B0D10, pillTop=0x3D4147, pillBot=0x212327, pillEdge=0x55595F,
         pillText=0xC2C7CD, padTop=0x80868F, padBot=0x5A5F67, padEdge=0x9AA0A8, abTop=0xA3254F, abBot=0x590C2A, abEdge=0xC23A66,
         led=0xFF6A5A, ledBot=0xC4100C, grille=0x16181B)
SH = [(0xE0, 0xF8, 0xD0), (0x88, 0xC0, 0x70), (0x34, 0x68, 0x56), (0x08, 0x18, 0x20)]
def gb_frame(path, fr):
    raw = open(path, 'rb').read(); REC = 6 + 5760
    for i in range(len(raw) // REC):
        f, _, bgp = struct.unpack_from('<IBB', raw, i * REC)
        if f == fr:
            fb = raw[i * REC + 6:(i + 1) * REC]; pal = [SH[(bgp >> (2 * c)) & 3] for c in range(4)]
            im = Image.new('RGB', (160, 144))
            im.putdata([pal[(fb[y * 40 + (x >> 2)] >> (6 - 2 * (x & 3))) & 3] for y in range(144) for x in range(160)])
            return im
import os
OUT = os.environ.get('OUT', 'mockups_out'); os.makedirs(OUT, exist_ok=True)
FRAME = gb_frame(os.environ.get('FRAMES', 'walk_frames.bin'), 6520)
def grad_rr(img, box, r, top, bot, edge=None, width=1):
    x0, y0, x1, y1 = box; w, h = x1 - x0, y1 - y0
    g = Image.new('RGBA', (w, h)); d = ImageDraw.Draw(g)
    for yy in range(h):
        t = yy / max(1, h - 1); d.line([(0, yy), (w, yy)], fill=tuple(int(rgb(top)[k] + (rgb(bot)[k] - rgb(top)[k]) * t) for k in range(3)) + (255,))
    m = Image.new('L', (w, h), 0); ImageDraw.Draw(m).rounded_rectangle([0, 0, w - 1, h - 1], r, fill=255)
    img.paste(g, (x0, y0), m)
    if edge is not None: ImageDraw.Draw(img).rounded_rectangle([x0, y0, x1 - 1, y1 - 1], r, outline=rgb(edge), width=width)
def pill(img, x, y, w, h, text, size=10):
    grad_rr(img, (x, y, x + w, y + h), h // 2, C['pillTop'], C['pillBot'], C['pillEdge'])
    f = ImageFont.truetype(B, size); d = ImageDraw.Draw(img)
    tw = d.textlength(text, font=f); d.text((x + (w - tw) / 2, y + (h - size) / 2 - 1), text, font=f, fill=rgb(C['pillText']))
def dpad(img, cx, cy, arm, length):
    hw = arm // 2
    grad_rr(img, (cx - hw, cy - hw - length, cx + hw, cy - hw + 6), 7, C['padTop'], C['padBot'], C['padEdge'])
    grad_rr(img, (cx - hw, cy + hw - 6, cx + hw, cy + hw + length), 7, C['padTop'], C['padBot'], C['padEdge'])
    grad_rr(img, (cx - hw - length, cy - hw, cx - hw + 6, cy + hw), 7, C['padTop'], C['padBot'], C['padEdge'])
    grad_rr(img, (cx + hw - 6, cy - hw, cx + hw + length, cy + hw), 7, C['padTop'], C['padBot'], C['padEdge'])
    grad_rr(img, (cx - hw, cy - hw, cx + hw, cy + hw), 0, C['padBot'], C['padTop'])
def berry(img, cx, cy, r):
    grad_rr(img, (cx - r, cy - r, cx + r, cy + r), r, C['abTop'], C['abBot'], C['abEdge'])
def led(img, cx, cy, r=10):
    glow = Image.new('RGBA', img.size, (0, 0, 0, 0)); ImageDraw.Draw(glow).ellipse([cx - r - 5, cy - r - 5, cx + r + 5, cy + r + 5], fill=(255, 42, 42, 70))
    img.alpha_composite(glow); grad_rr(img, (cx - r, cy - r, cx + r, cy + r), r, C['led'], C['ledBot'])
def body():
    img = Image.new('RGBA', (520, 212), (0, 0, 0, 0))
    grad_rr(img, (0, 0, 520, 212), 106, C['bodyTop'], C['bodyBot'])
    return img
def screen(img, gx, gy, gw, gh, pad, smooth=False):
    ImageDraw.Draw(img).rounded_rectangle([gx - pad, gy - pad, gx + gw + pad - 1, gy + gh + pad - 1], 8, fill=rgb(C['bezel']))
    img.paste(FRAME.resize((gw, gh), Image.BILINEAR if smooth else Image.NEAREST), (gx, gy))
def option1():
    img = body()
    screen(img, 160, 16, 200, 180, 6)
    dpad(img, 64, 106, 32, 33)
    berry(img, 474, 82, 21); berry(img, 440, 138, 21)
    pill(img, 110, 22, 42, 24, 'POWER', 9); pill(img, 110, 54, 42, 24, 'PAUSE', 9); pill(img, 110, 134, 42, 24, 'SELECT', 8); led(img, 131, 176, 9)
    pill(img, 368, 22, 42, 24, 'TURBO', 9); pill(img, 368, 54, 42, 24, 'UNSAFE', 8); pill(img, 368, 134, 42, 24, 'START', 9)
    return img
def option2():
    img = body()
    screen(img, 148, 5, 224, 202, 4)
    dpad(img, 58, 106, 32, 32)
    berry(img, 470, 80, 20); berry(img, 436, 136, 20)
    pill(img, 108, 22, 34, 22, 'PWR', 9); pill(img, 108, 52, 34, 22, 'PSE', 9); pill(img, 108, 136, 34, 22, 'SEL', 9); led(img, 125, 177, 8)
    pill(img, 378, 22, 34, 22, 'TRB', 9); pill(img, 378, 52, 34, 22, 'UNS', 9); pill(img, 378, 136, 34, 22, 'STA', 9)
    return img
def option3():
    img = body()
    screen(img, 180, 34, 160, 144, 8)
    dpad(img, 62, 106, 34, 35)
    berry(img, 462, 80, 23); berry(img, 430, 136, 23)
    pill(img, 110, 22, 60, 24, 'POWER', 10); pill(img, 110, 54, 60, 24, 'PAUSE', 10); pill(img, 110, 164, 60, 24, 'SELECT', 10); led(img, 140, 146, 10)
    pill(img, 350, 22, 60, 24, 'TURBO', 10); pill(img, 350, 54, 60, 24, 'UNSAFE', 10); pill(img, 350, 164, 60, 24, 'START', 10)
    return img
opts = [(option1(), 'Option 1  Handheld', 'screen 200x180, crisp 1.25x, full-word buttons in two side columns'),
        (option2(), 'Option 2  Big screen', 'screen 224x202, crisp 1.4x (fills the height), short-label buttons'),
        (option3(), 'Option 3  Pixel perfect', 'screen 160x144, exact 1:1 pixels, roomiest controls, lightest on the CPU')]
for k, (im, t, s) in enumerate(opts):
    out = Image.new('RGBA', (520, 212), (17, 19, 23, 255)); out.alpha_composite(im)
    out.convert('RGB').resize((1040, 424), Image.NEAREST).save(f'{OUT}/option{k + 1}.png')
sheet = Image.new('RGB', (1120, 3 * 500 + 20), (17, 19, 23)); d = ImageDraw.Draw(sheet)
fT, fS = ImageFont.truetype(B, 26), ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf', 18)
for k, (im, t, s) in enumerate(opts):
    y = 20 + k * 500
    d.text((40, y), t, font=fT, fill=(230, 232, 235)); d.text((40, y + 34), s, font=fS, fill=(160, 166, 174))
    sheet.paste(Image.open(f'{OUT}/option{k + 1}.png'), (40, y + 66))
sheet.save(OUT + '/RedBand_landscape_options.png'); print('ok')
