"""Every visible object at least 3 px inside the 212x520 pill; every label fits its button;
no two touch controls overlap. Input: the JSON lines written by tests/layout_dump.lua."""
import json, math, sys
objs = [json.loads(l) for l in open(sys.argv[1])]
R, W, H, M = 106, 212, 520, 3
def inside(x, y, M=M):
    if x < M or x > W - M: return False
    if y < R: return math.hypot(x - R, y - R) <= R - M
    if y > H - R: return math.hypot(x - R, y - (H - R)) <= R - M
    return M <= y <= H - M
def boundary(o):
    x, y, w, h, r = o['x'], o['y'], o['w'], o['h'], min(o['r'], o['w'] // 2, o['h'] // 2)
    pts = []
    for t in range(0, 360, 5):
        a = math.radians(t)
        for cx, cy in ((x + r, y + r), (x + w - r, y + r), (x + r, y + h - r), (x + w - r, y + h - r)):
            px, py = cx + r * math.cos(a), cy + r * math.sin(a)
            if (px <= x + r or px >= x + w - r) and (py <= y + r or py >= y + h - r): pts.append((px, py))
    for s in range(0, 101, 5):
        pts += [(x + r + (w - 2 * r) * s / 100, y), (x + r + (w - 2 * r) * s / 100, y + h),
                (x, y + r + (h - 2 * r) * s / 100), (x + w, y + r + (h - 2 * r) * s / 100)]
    return pts
fail = 0
# the full-width screen and its bezel are display surfaces: they may reach the pill edge (margin 0)
# (the game picture of the landscape face is turned 90 degrees by the GPU around its centre: its
# upright box is wider than the panel, the picture itself is not; it is checked turned)
def turned(o):
    if o['kind'] == 'Image' and not o['src'] and o['w'] == 224 and o['h'] == 202:
        cx, cy = o['x'] + o['w'] / 2, o['y'] + o['h'] / 2
        return dict(o, x=cx - o['h'] / 2, y=cy - o['w'] / 2, w=o['h'], h=o['w'])
    return o
out = [o for o in map(turned, objs[1:]) if not (o['kind'] == 'Label' and not o['text']) and any(not inside(px, py, 0 if max(o['w'], o['h']) >= 200 else M) for px, py in boundary(o))]
for o in out: print('OUTSIDE THE PILL:', o['i'], o['kind'], o['x'], o['y'], o['w'], o['h'])
fail += len(out)
for o in objs:
    if o['kind'] == 'Label' and o['text']:
        par = objs[o['parent'] - 1]
        if not (o['w'] <= par['w'] and len(o['text']) * 0.68 * o['font'] <= o['w'] - 4 and o['font'] + 2 <= par['h']):
            print('TEXT TOO BIG:', o['text']); fail += 1
cl = [o for o in objs if o['click'] in (True, 'true') and o['kind'] == 'Object' and o['w'] < 200]
for i, a in enumerate(cl):
    for b in cl[i + 1:]:
        if a['x'] < b['x'] + b['w'] and b['x'] < a['x'] + a['w'] and a['y'] < b['y'] + b['h'] and b['y'] < a['y'] + a['h']:
            print('OVERLAP:', a['i'], b['i']); fail += 1
sh = [o['i'] for o in objs if o.get('shadow', 0)]
if sh: print('BOX SHADOWS (drawn by the CPU on this firmware):', sh); fail += len(sh)
print(f'layout: {len(objs)} objects, {len(out)} outside the pill, labels fit, controls separate, no box shadows' if not fail else f'LAYOUT FAILURES: {fail}')
sys.exit(1 if fail else 0)
