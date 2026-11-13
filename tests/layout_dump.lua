-- dump the watchface layout (absolute rects, styles, texts) as JSON lines
local dir, out = arg[1], arg[2]
local T = dofile('tests/common.lua')
if arg[3] == 'fixedtime' then os.date = function() return { hour = 10, min = 9, month = 11, day = 12, wday = 5, year = 2026 } end end
local mock, R = T.load(dir, {})
if arg[4] == 'powered' then mock.fire(R.power, mock.EVENT.CLICKED) end   -- game on (screen image filled in by the GIF maker)
-- extra states for showcase pictures: the save browser open (with save files present), the
-- first DELETE tap ("SURE?"), and UNSAFE pressed while playing
if arg[4] == 'browse' or arg[4] == 'sure' then
  for _, p in ipairs({ '/data/redbandgb_red.sav', '/data/redbandgb_red.sav.bak' }) do local fh = io.open(p, 'wb'); fh:write(string.rep('\0', 32768)); fh:close() end
  local fh = io.open('/data/redbandgb_cfg40.txt', 'w'); fh:write('view=big\n'); fh:close()
  mock.fire(R.browse, mock.EVENT.CLICKED)
  if arg[4] == 'sure' then mock.fire(R.rows[1].btn, mock.EVENT.CLICKED) end
end
if arg[4] == 'unsafe' then mock.fire(R.power, mock.EVENT.CLICKED); mock.fire(R.browse, mock.EVENT.CLICKED) end
-- layout as installed: game off, Poketch clock showing
local f = io.open(out, 'w')
local function abs(o)
  local x, y = o.props.x or 0, o.props.y or 0
  local p = o.parent
  while p do x = x + (p.props.x or 0); y = y + (p.props.y or 0); p = p.parent end
  return x, y
end
for i, o in ipairs(mock.objects) do
  local x, y = abs(o)
  local p = o.props
  local font = p.text_font and p.text_font.size or 0
  local parentIdx = 0
  for j, q in ipairs(mock.objects) do if q == o.parent then parentIdx = j end end
  local text = tostring(p.text or '')
  local hidden, q = false, o
  while q do if q.flags[mock.FLAG.HIDDEN] then hidden = true end q = q.parent end
  f:write(string.format('{"i":%d,"kind":"%s","parent":%d,"x":%d,"y":%d,"w":%d,"h":%d,"r":%d,"bg":%d,"grad":%d,"text":"%s","font":%d,"click":%s,"tc":%d,"border":%d,"bc":%d,"shadow":%d,"opa":%d,"hidden":%s,"src":"%s","align":%d}\n',
    i, o.kind, parentIdx, x, y, p.w or 0, p.h or 0, p.radius or 0, p.bg_color or -1, p.bg_grad_color or -1,
    text, font, tostring(o.flags[mock.FLAG.CLICKABLE] == true), p.text_color or -1, p.border_width or 0, p.border_color or -1, p.shadow_width or 0,
    p.bg_opa or 0, tostring(hidden), (o.srcType == 'file') and o.srcKey or '', p.text_align or 0))
end
f:close()
print('objects: ' .. #mock.objects)
