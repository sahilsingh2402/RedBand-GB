-- Walking-focused profile of the Lua core (with its current compiled blocks): count the addresses the
-- interpreter still runs, over a scripted intro / new game / Oak / house-exploration session.
-- Output: tools/aot/lua_interp.json  {"entries": [[bank<<16|pc or pc, count], ...]}
-- Usage (from the release root): lua5.4 tools/profile_lua.lua
local src = io.open('tools/gbcore.lua'):read('a')
local old = "        if not (blk and blk()) then              -- compiled block (false: event due soon)\n          local op"
local a, b = src:find(old, 1, true)
assert(a, 'main loop not found')
-- count ENTRIES into the interpreter: the first interpreted instruction after a jump or
-- after a compiled block returned (sequential interpreted instructions are not entries)
src = src:sub(1, a - 1) .. "        local ranB = blk and blk()\n        if ranB then LASTNEXT = -1 end\n        if not ranB then\n          if pc ~= LASTNEXT then local k = (pc < 0x4000) and pc or ((pc < 0x8000) and ((romBank << 16) | pc) or -1); if k >= 0 then PROF[k] = (PROF[k] or 0) + 1 end end\n          INTERP = INTERP + 1\n          local op" .. src:sub(b + 1)
-- after the interpreted instruction: remember where sequential flow continues
local c1, c2 = src:find("          pc = pc + 1\n          ops[op]()\n", 1, true)
assert(c1, 'dispatch not found')
src = src:sub(1, c2) .. "          LASTNEXT = pc\n" .. src:sub(c2 + 1)
LASTNEXT, INTERP = -1, 0
PROF = {}
local m = load(src, '=gbcore_prof')()
local f = io.open('rom/pokemon_red.gb', 'rb'); local rom = f:read('a'); f:close()
local c = {}
local gb = m.create({ romBanks = 64, bank0 = function() return m.packBank(rom:sub(1, 16384)) end, bank0bytes = function() return { rom:byte(1, 16384) } end,
  bank = function(n) local t = c[n]; if not t then t = m.packBank(rom:sub(n * 16384 + 1, n * 16384 + 16384)); c[n] = t end; return t end })
-- walking-focused session: scripted intro to Red's bedroom, then long walking patterns
-- (stairs, turning, bumping into walls), menus now and then
local P = { { 'START', 1500, 6 }, { 'A', 1620, 6 } }
for k = 0, 99 do P[#P + 1] = { 'A', 1700 + 40 * k, 5 } end
for k = 0, 7 do P[#P + 1] = { 'B', 5800 + 30 * k, 5 } end
local at = {}
for _, p in ipairs(P) do at[p[2]] = at[p[2]] or {}; table.insert(at[p[2]], p) end
local held = {}
local walk = { 'RIGHT', 'DOWN', 'LEFT', 'UP', 'RIGHT', 'RIGHT', 'DOWN', 'DOWN', 'LEFT', 'LEFT', 'UP', 'UP', 'DOWN', 'DOWN', 'DOWN', 'RIGHT', 'RIGHT', 'RIGHT' }
for frame = 0, 15999 do
  for _, p in ipairs(at[frame] or {}) do gb.setButton(p[1], true); held[#held + 1] = { p[1], frame + p[3] } end
  for i = #held, 1, -1 do if held[i][2] <= frame then gb.setButton(held[i][1], false); table.remove(held, i) end end
  if frame >= 6400 then
    local w = frame - 6400
    if w % 40 == 0 then
      for _, k in ipairs({ 'UP', 'DOWN', 'LEFT', 'RIGHT', 'START', 'B' }) do gb.setButton(k, false) end
      if (w // 40) % 25 == 24 then gb.setButton('START', true) elseif (w // 40) % 25 == 0 then gb.setButton('B', true)
      else gb.setButton(walk[(w // 40) % #walk + 1], true) end
    end
  end
  gb.runFrame()
end
-- merge with earlier rounds (keep the higher count) so selections converge
local merged = {}
local ef = io.open('tools/aot/lua_interp.json', 'r')
if ef then
  for k, v in ef:read('a'):gmatch('%[(%d+),(%d+)%]') do merged[tonumber(k)] = tonumber(v) end
  ef:close()
end
local entries = 0
for k, v in pairs(PROF) do if v > (merged[k] or 0) then merged[k] = v end; entries = entries + v end
local list = {}
for k, v in pairs(merged) do list[#list + 1] = string.format('[%d,%d]', k, v) end
io.open('tools/aot/lua_interp.json', 'w'):write('{"entries": [' .. table.concat(list, ',') .. ']}\n')
print(string.format('interpreted: %.0f instructions per frame (%.0f entries per frame) over 16000 frames', INTERP / 16000, entries / 16000))
