-- Scripted play into intense scenes: new game (default names), Oak's lab, take CHARMANDER, the
-- rival battle, then out to Route 1 and through the tall grass for wild encounters (battle
-- transitions, flashes, sprite and move animations). Game RAM: map D35E, y D361, x D362,
-- in battle D057, party count D163.
local R = {}
local P = { { 'START', 1500, 6 }, { 'A', 1620, 6 } }
for k = 0, 99 do P[#P + 1] = { 'A', 1700 + 40 * k, 5 } end
for k = 0, 7 do P[#P + 1] = { 'B', 5800 + 30 * k, 5 } end
P[#P + 1] = { 'DOWN', 3240, 4 }; P[#P + 1] = { 'DOWN', 3930, 4 }
local at = {}
for _, p in ipairs(P) do at[p[2]] = at[p[2]] or {}; table.insert(at[p[2]], p) end
local ROUTE1 = {                    -- before having a Pokemon
  [38] = { { 5, 6, 'x' }, { 5, 1, 'y' }, { 7, 1, 'x' }, { 'RIGHT' } },
  [37] = { { 7, 6, 'y' }, { 3, 6, 'x' }, { 3, 7, 'y' }, { 'DOWN' } },
  [0]  = { { 5, 7, 'y' }, { 10, 7, 'x' }, { 10, 1, 'y' }, { 'UP' } },
  [40] = { { 6, 3, 'x' } },         -- face the left ball (CHARMANDER) and keep tapping A
}
local ROUTE2 = {                    -- with CHARMANDER
  [40] = { { 5, 11, 'y' }, { 'DOWN' } },
  [37] = { { 3, 6, 'x' }, { 3, 7, 'y' }, { 'DOWN' } },
  [38] = { { 5, 6, 'x' }, { 5, 1, 'y' }, { 7, 1, 'x' }, { 'RIGHT' } },
  [0]  = { { 9, 12, 'x' }, { 9, 7, 'y' }, { 10, 7, 'x' }, { 10, 0, 'y' }, { 'UP' } },
  [12] = 'wander',
}
local WANDER = { { 10, 33 }, { 13, 33 }, { 13, 29 }, { 10, 29 }, { 11, 31 }, { 13, 31 } }
function R.new(gb)
  local s = { held = {}, wp = {}, last = nil, still = 0, tap = 0, tapBtn = nil, dir = nil, wpAge = 0, wi = 1,
    battles = 0, inBattle = false, events = {} }
  local function ram(a) return gb._ram[a - 0x7FFF] end
  function s.rebind(g) gb = g end        -- the same game continued by another engine
  -- the watchface releases every button on pause / screen off, so the held direction is
  -- asserted again on every frame (setButton is idempotent)
  local function press(btn)
    if s.dir ~= btn then if s.dir then gb.setButton(s.dir, false) end s.dir = btn end
    if btn then gb.setButton(btn, true) end
  end
  local function tapKey(btn) if s.tap == 0 then gb.setButton(btn, true); s.tap = 4; s.tapBtn = btn end end
  function s.step(frame)
    for _, p in ipairs(at[frame] or {}) do gb.setButton(p[1], true); s.held[#s.held + 1] = { p[1], frame + p[3] } end
    for i = #s.held, 1, -1 do if s.held[i][2] <= frame then gb.setButton(s.held[i][1], false); table.remove(s.held, i) end end
    if s.tap > 0 then s.tap = s.tap - 1; if s.tap == 0 then gb.setButton(s.tapBtn, false) end end
    if frame < 6000 then return nil end
    local map, y, x = ram(0xD35E), ram(0xD361), ram(0xD362)
    local battle, party = ram(0xD057), ram(0xD163)
    if map ~= s.map then s.wp[1000 + map] = nil s.wp[2000 + map] = nil s.map = map end   -- a new visit
    local inb = battle ~= 0
    if inb and not s.inBattle then s.battles = s.battles + 1; s.events[#s.events + 1] = 'battle' .. s.battles .. '@' .. frame end
    s.inBattle = inb
    if inb then press(nil); if frame % 20 == 0 then tapKey('A') end return map, x, y, true end
    local pos = map * 65536 + y * 256 + x
    if pos == s.last then s.still = s.still + 1 else s.still = 0 end
    s.last = pos
    -- stuck for 10 s (e.g. the game went back to a recovery point): start this map's route over
    if s.still > 600 and s.still % 600 == 0 then s.wp[1000 + map] = nil s.wp[2000 + map] = nil end
    -- text and yes/no boxes: A before having a Pokemon (take the ball, YES), B after (NO nickname)
    if s.still > 45 and s.still % 24 == 0 then tapKey(party == 0 and 'A' or 'B') end
    local route = (party == 0 and ROUTE1 or ROUTE2)[map]
    if not route then press(nil) return map, x, y, false end
    local tx, ty
    if route == 'wander' then
      s.wpAge = s.wpAge + 1
      local w = WANDER[s.wi]
      if (w[1] == x and w[2] == y) or s.wpAge > 240 then s.wi = s.wi % #WANDER + 1; s.wpAge = 0; w = WANDER[s.wi] end
      tx, ty = w[1], w[2]
    else
      local key = (party == 0 and 1 or 2) * 1000 + map
      local i = s.wp[key] or 1
      local w = route[i]
      while w and type(w[1]) == 'number' and w[1] == x and w[2] == y do i = i + 1; w = route[i] end
      s.wp[key] = i
      if not w then press(nil) return map, x, y, false end
      if type(w[1]) == 'string' then press(w[1]) return map, x, y, false end
      tx, ty = w[1], w[2]
      if w[3] == 'y' and ty ~= y then press((ty > y) and 'DOWN' or 'UP') if s.still > 40 and (s.still // 40) % 2 == 1 and tx ~= x then press((tx > x) and 'RIGHT' or 'LEFT') end return map, x, y, false end
    end
    local wantX = (tx > x) and 'RIGHT' or ((tx < x) and 'LEFT' or nil)
    local wantY = (ty > y) and 'DOWN' or ((ty < y) and 'UP' or nil)
    local first, second = wantX, wantY
    if s.still > 40 and (s.still // 40) % 2 == 1 then first, second = second, first end
    -- blocked for long (facing something to talk to): let go of the direction now and then so
    -- the A/B taps are taken as a talk, not a bump
    if s.still > 120 and (s.still // 60) % 2 == 0 then press(nil) return map, x, y, false end
    press(first or second)
    return map, x, y, false
  end
  return s
end
return R
