import os as _os
exec(open(_os.path.join(_os.path.dirname(_os.path.abspath(__file__)), 'mock.py')).read().split("def option1():")[0])
def variantB2():
    img = body()
    screen(img, 132, 5, 224, 202, 4)                 # big screen, 14 px left of centre
    # right: a bigger D-pad (120 px), POWER/PAUSE above-left of it, the light below-left of it
    dpad(img, 446, 106, 40, 40)
    pill(img, 364, 22, 58, 24, 'POWER', 10); pill(img, 364, 52, 58, 24, 'PAUSE', 10)
    led(img, 404, 148, 11)
    # left: bigger A and B side by side (A nearer the screen), TURBO/UNSAFE above, START/SELECT below
    berry(img, 44, 106, 24); berry(img, 100, 106, 24)
    pill(img, 66, 22, 58, 24, 'TURBO', 10); pill(img, 66, 52, 58, 24, 'UNSAFE', 10)
    pill(img, 66, 136, 58, 24, 'START', 10); pill(img, 66, 166, 58, 24, 'SELECT', 10)
    return img
im = variantB2()
out = Image.new('RGBA', (520, 212), (17, 19, 23, 255)); out.alpha_composite(im)
big = out.convert('RGB').resize((1040, 424), Image.NEAREST); big.save(OUT + '/variantB2.png')
# comparison with today's portrait screen, at the same scale
from PIL import ImageDraw
port = Image.open(os.environ.get('PORTRAIT_PREVIEW','docs/media/preview_main.png')).convert('RGBA')
sheet = Image.new('RGB', (1040 + 40 + 424 + 40, 1080), (17, 19, 23)); d = ImageDraw.Draw(sheet)
fT, fS = ImageFont.truetype(B, 24), ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf', 17)
d.text((40, 24), 'Variant B, bigger controls, full names', font=fT, fill=(230, 232, 235))
d.text((40, 58), 'screen 224x202 (45,248 px), 14 px left of centre', font=fS, fill=(160, 166, 174))
sheet.paste(big, (40, 100))
d.text((1120, 24), 'Today (portrait)', font=fT, fill=(230, 232, 235))
d.text((1120, 58), 'BIG view 212x189 (40,068 px)', font=fS, fill=(160, 166, 174))
pb = Image.new('RGBA', (212, 520), (17, 19, 23, 255)); pb.alpha_composite(port)
sheet.paste(pb.convert('RGB').resize((424, 1040), Image.NEAREST).crop((0, 0, 424, 960)), (1120, 100))
sheet.save(OUT + '/RedBand_landscape_variantB2_compare.png'); print('ok')
