-- Scripted play for the showcase GIF: new game (intro, Oak, default names), then walk from Red's
-- room down the stairs, out of the house, across Pallet Town to Route 1 (Oak stops you), and
-- follow Oak to his lab, pressing A through the dialog. Positions come from game RAM:
-- wCurMap D35E, wYCoord D361, wXCoord D362.
local R = {}
local P = { { 'START', 1500, 6 }, { 'A', 1620, 6 } }
for k = 0, 99 do P[#P + 1] = { 'A', 1700 + 40 * k, 5 } end
for k = 0, 7 do P[#P + 1] = { 'B', 5800 + 30 * k, 5 } end
-- name menus: DOWN once so the default names are taken (RED, BLUE) instead of typing
P[#P + 1] = { 'DOWN', DOWN1 or 3240, 4 }; P[#P + 1] = { 'DOWN', DOWN2 or 3930, 4 }
local at = {}
for _, p in ipairs(P) do at[p[2]] = at[p[2]] or {}; table.insert(at[p[2]], p) end
-- waypoints per map: {x, y, axisFirst} ; a final {dir} entry = keep pressing that way (warp)
local ROUTE = {
  [38] = { { 5, 6, 'x' }, { 5, 1, 'y' }, { 7, 1, 'x' }, { 'RIGHT' } },
  [37] = { { 7, 6, 'y' }, { 3, 6, 'x' }, { 3, 7, 'y' }, { 'DOWN' } },
  [0]  = { { 5, 7, 'y' }, { 10, 7, 'x' }, { 10, 1, 'y' }, { 'UP' } },
}
function R.new(gb)
  local s = { held = {}, wp = {}, last = nil, still = 0, aTimer = 0, dir = nil, alt = 0 }
  local function ram(a) return gb._ram[a - 0x7FFF] end
  local function press(btn) if s.dir ~= btn then if s.dir then gb.setButton(s.dir, false) end s.dir = btn; if btn then gb.setButton(btn, true) end end end
  function s.step(frame)
    for _, p in ipairs(at[frame] or {}) do gb.setButton(p[1], true); s.held[#s.held + 1] = { p[1], frame + p[3] } end
    for i = #s.held, 1, -1 do if s.held[i][2] <= frame then gb.setButton(s.held[i][1], false); table.remove(s.held, i) end end
    if frame < 6000 then return nil end
    local map, y, x = ram(0xD35E), ram(0xD361), ram(0xD362)
    local pos = map * 65536 + y * 256 + x
    if pos == s.last then s.still = s.still + 1 else s.still = 0 end
    s.last = pos
    -- dialog / scripted scene: tap A now and then when the player does not move
    if s.aTimer > 0 then s.aTimer = s.aTimer - 1; if s.aTimer == 0 then gb.setButton('A', false) end end
    if s.still > 45 and s.aTimer == 0 and s.still % 24 == 0 then gb.setButton('A', true); s.aTimer = 4 end
    local route = ROUTE[map]
    if not route then press(nil) return map, x, y end
    local i = s.wp[map] or 1
    local w = route[i]
    while w and w[1] and type(w[1]) == 'number' and w[1] == x and w[2] == y do i = i + 1; w = route[i] end
    s.wp[map] = i
    if not w then press(nil) return map, x, y end
    if type(w[1]) == 'string' then press(w[1]) return map, x, y end
    local tx, ty = w[1], w[2]
    local wantX = (tx > x) and 'RIGHT' or ((tx < x) and 'LEFT' or nil)
    local wantY = (ty > y) and 'DOWN' or ((ty < y) and 'UP' or nil)
    local first, second = wantX, wantY
    if w[3] == 'y' then first, second = wantY, wantX end
    if s.still > 40 and (s.still // 40) % 2 == 1 then first, second = second, first end   -- blocked: try the other axis
    press(first or second)
    return map, x, y
  end
  return s
end
return R
