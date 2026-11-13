"""Picture of the AOD screen as packed (digits shown as 10:09, 11.12), for the report."""
import sys
from PIL import Image, ImageDraw
sys.path.insert(0, 'RedBandLuaWatchface')
import importlib.util
spec = importlib.util.spec_from_file_location('bf', 'RedBandLuaWatchface/build_face.py'); bf = importlib.util.module_from_spec(spec); spec.loader.exec_module(bf)
widgets, images = bf.aod_screen()
show = {'0811': '10', '1011': '09', '1012': '11', '1812': '12'}
im = Image.new('RGBA', (212, 520), (0, 0, 0, 255))
for w in widgets:
    if w['kind'] == 30:
        iw, ih, raw = images[w['img']]; im.alpha_composite(Image.frombytes('RGBA', (iw, ih), raw), (w['x'], w['y']))
    else:
        for k, ch in enumerate(show[w['src']]):
            iw, ih, raw = images[w['list'][int(ch)]]; im.alpha_composite(Image.frombytes('RGBA', (iw, ih), raw), (w['x'] + k * w['dw'], w['y']))
mask = Image.new('L', (212, 520), 0); ImageDraw.Draw(mask).rounded_rectangle([0, 0, 211, 519], 106, fill=255)
out = Image.new('RGBA', (212, 520), (0, 0, 0, 255)); out.paste(im, (0, 0), mask)
outline = ImageDraw.Draw(out); outline.rounded_rectangle([0, 0, 211, 519], 106, outline=(40, 40, 40, 255), width=1)
out.save(sys.argv[1]); print('aod preview written')
