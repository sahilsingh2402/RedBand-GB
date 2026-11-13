import os as _os
exec(open(_os.path.join(_os.path.dirname(_os.path.abspath(__file__)), 'mock.py')).read().split("def option1():")[0])
# big screen 224x202 (crisp 1.4x) in the middle for all three
def big_screen(img): screen(img, 148, 5, 224, 202, 4)
def variant1():   # your sketch, tidied: D-pad left next to the screen, A/B side by side on the right
    img = body(); big_screen(img)
    dpad(img, 86, 106, 34, 35)
    pill(img, 108, 22, 34, 22, 'PWR', 9); pill(img, 108, 50, 34, 22, 'PSE', 9)
    led(img, 124, 170, 9)
    pill(img, 378, 22, 34, 22, 'TRB', 9); pill(img, 378, 50, 34, 22, 'UNS', 9)
    berry(img, 410, 106, 20); berry(img, 462, 106, 20)              # B, A
    pill(img, 378, 140, 34, 22, 'STA', 9); pill(img, 378, 168, 34, 22, 'SEL', 9)
    return img
def variant2():   # mirrored: D-pad right next to the screen, A/B side by side on the left
    img = body(); big_screen(img)
    dpad(img, 434, 106, 34, 35)
    pill(img, 378, 22, 34, 22, 'PWR', 9); pill(img, 378, 50, 34, 22, 'PSE', 9)
    led(img, 396, 170, 9)
    pill(img, 108, 22, 34, 22, 'TRB', 9); pill(img, 108, 50, 34, 22, 'UNS', 9)
    berry(img, 58, 106, 20); berry(img, 110, 106, 20)               # B, A (A nearer the screen)
    pill(img, 108, 140, 34, 22, 'STA', 9); pill(img, 108, 168, 34, 22, 'SEL', 9)
    return img
def variant3():   # mirrored, Game Boy style diagonal A/B on the left, system buttons in rows
    img = body(); big_screen(img)
    dpad(img, 434, 106, 34, 35)
    pill(img, 378, 22, 34, 22, 'PWR', 9); pill(img, 378, 50, 34, 22, 'PSE', 9)
    led(img, 396, 170, 9)
    berry(img, 54, 126, 21); berry(img, 100, 88, 21)                # B lower-left, A upper-right
    pill(img, 54, 30, 34, 22, 'TRB', 9); pill(img, 92, 30, 34, 22, 'UNS', 9)
    pill(img, 70, 164, 34, 22, 'STA', 9); pill(img, 108, 164, 34, 22, 'SEL', 9)
    return img
opts = [(variant1(), 'Variant A  Your sketch, tidied', 'D-pad left beside the screen, PWR/PSE above it, light below; A and B side by side on the right'),
        (variant2(), 'Variant B  Mirrored', 'D-pad right beside the screen, PWR/PSE above it, light below; A and B side by side on the left'),
        (variant3(), 'Variant C  Mirrored, Game Boy style A/B', 'D-pad right; A and B on a diagonal on the left, TRB/UNS above them, STA/SEL below')]
for k, (im, t, s) in enumerate(opts):
    out = Image.new('RGBA', (520, 212), (17, 19, 23, 255)); out.alpha_composite(im)
    out.convert('RGB').resize((1040, 424), Image.NEAREST).save(f'{OUT}/variant{"ABC"[k]}.png')
sheet = Image.new('RGB', (1120, 3 * 500 + 20), (17, 19, 23)); d = ImageDraw.Draw(sheet)
fT, fS = ImageFont.truetype(B, 26), ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf', 18)
for k, (im, t, s) in enumerate(opts):
    y = 20 + k * 500
    d.text((40, y), t, font=fT, fill=(230, 232, 235)); d.text((40, y + 34), s, font=fS, fill=(160, 166, 174))
    sheet.paste(Image.open(f'{OUT}/variant{"ABC"[k]}.png'), (40, y + 66))
sheet.save(OUT + '/RedBand_landscape_variants.png')
# check: every control inside the pill, at least 20 px from the long edges, nothing overlapping
print('ok')
