-- Desktop test harness for the Lua core (Lua 5.4):
--   lua5.4 tests/run_tests.lua blargg <dir>          Blargg cpu_instrs + instr_timing
--   lua5.4 tests/run_tests.lua golden <rom> <outdir>  dump PNGs at golden frame numbers
--   lua5.4 tests/run_tests.lua bench <rom>           CPU-only and with-display timing
--   lua5.4 tests/run_tests.lua state <rom>           save-state round-trip check
package.path = "tools/?.lua;" .. package.path
local gbcore = RBGB_CORE_FILE and dofile(RBGB_CORE_FILE) or require("gbcore")
local Frame = require("frame")

local function readFile(path)
  local f = assert(io.open(path, "rb")); local s = f:read("a"); f:close(); return s
end

local function bankHost(rom)
  local cache = {}
  return function(n)
    local t = cache[n]
    if not t then t = gbcore.packBank(rom:sub(n * 16384 + 1, n * 16384 + 16384)); cache[n] = t end
    return t
  end
end
local function bank0Of(rom) return function() return gbcore.packBank(rom:sub(1, 16384)) end end

local mode = arg[1]

if mode == "blargg" then
  local dir = arg[2]
  local roms = {}
  for i, name in ipairs({ "01-special", "02-interrupts", "03-op sp,hl", "04-op r,imm", "05-op rp", "06-ld r,r",
    "07-jr,jp,call,ret,rst", "08-misc instrs", "09-op r,r", "10-bit ops", "11-op a,(hl)" }) do
    roms[#roms + 1] = dir .. "/cpu_instrs/individual/" .. name .. ".gb"
  end
  roms[#roms + 1] = dir .. "/instr_timing/instr_timing.gb"
  local failed = 0
  for _, path in ipairs(roms) do
    local rom = readFile(path)
    local out = {}
    local gb = gbcore.create({ romBanks = math.max(2, #rom // 16384), bank = bankHost(rom), bank0 = bank0Of(rom), bank0bytes = function() return { rom:byte(1, 16384) } end,
      serialOut = function(ch) out[#out + 1] = string.char(ch) end })
    local verdict = "TIMEOUT"
    local t0 = os.clock()
    for _ = 1, 60 * 60 do
      gb.runFrame()
      local s = table.concat(out)
      if s:find("Passed") then verdict = "Passed" break end
      if s:find("Failed") then verdict = "FAILED: " .. s:gsub("\n", " ") break end
    end
    if verdict ~= "Passed" then failed = failed + 1 end
    print(string.format("%-28s %s  (%.1fs)", path:match("[^/]+$"), verdict, os.clock() - t0))
  end
  print(failed == 0 and "ALL BLARGG TESTS PASSED" or (failed .. " FAILED"))
  os.exit(failed == 0 and 0 or 1)
end

-- Scripted new game (same as the JS tests): title -> NEW GAME -> Oak -> names -> walk.
local NEW_GAME = {
  { key = "START", at = 1500 }, { key = "A", at = 1620 },
  { key = "A", at = 1700, every = 40, ["repeat"] = 100, hold = 5 },
  { key = "B", at = 5800, every = 30, ["repeat"] = 8, hold = 5 },
  { key = "RIGHT", at = 6100, hold = 51 }, { key = "DOWN", at = 6200, hold = 102 }, { key = "LEFT", at = 6340, hold = 68 } }

local function runScript(rom, frames, want, onFrame, gbOut)
  local frameNo = 0
  local gb
  gb = gbcore.create({ romBanks = #rom // 16384, bank = bankHost(rom), bank0 = bank0Of(rom), bank0bytes = function() return { rom:byte(1, 16384) } end,
    beginFrame = function() return want(frameNo + 1) end,
    frameReady = function(FB, bgp) onFrame(frameNo + 1, FB, bgp) end })
  if gbOut then gbOut(gb) end
  local at = {}
  for _, p in ipairs(NEW_GAME) do
    for k = 0, (p["repeat"] or 1) - 1 do
      local f = p.at + k * (p.every or 0)
      at[f] = at[f] or {}
      table.insert(at[f], p)
    end
  end
  local held = {}
  while frameNo < frames do
    for _, p in ipairs(at[frameNo] or {}) do gb.setButton(p.key, true); held[#held + 1] = { p.key, frameNo + (p.hold or 6) } end
    for i = #held, 1, -1 do if held[i][2] <= frameNo then gb.setButton(held[i][1], false); table.remove(held, i) end end
    gb.runFrame()
    frameNo = frameNo + 1
  end
  return gb
end

if mode == "golden" then
  local rom = readFile(arg[2])
  local outdir = arg[3]
  local shots = {}
  for f in arg[4]:gmatch("%d+") do shots[tonumber(f)] = true end
  local last = 0
  for f in pairs(shots) do if f > last then last = f end end
  runScript(rom, last, function(f) return shots[f] == true end, function(f, FB, bgp)
    local out = io.open(outdir .. "/" .. f .. ".png", "wb"); out:write(Frame.png(FB, bgp)); out:close()
    out = io.open(outdir .. "/" .. f .. ".bin", "wb"); out:write(Frame.bin(FB, bgp)); out:close()
  end)
  print("golden frames written")
end

if mode == "bench" then
  local rom = readFile(arg[2])
  local N = 6983
  local t0 = os.clock()
  local gb = runScript(rom, N, function() return false end, function() end)
  local cpu = os.clock() - t0
  local st = gb.state()
  local presented, tEnc = 0, 0
  t0 = os.clock()
  runScript(rom, N, function(f) return (f % 2) == 0 end, function(_, FB, bgp)
    local t1 = os.clock(); local s = Frame.bin(FB, bgp); tEnc = tEnc + (os.clock() - t1); presented = presented + 1
  end)
  local withDisp = os.clock() - t0
  local tPng = os.clock()
  local FB = {}
  for k = 1, 5760 do FB[k] = (k * 37) & 255 end
  for _ = 1, 200 do Frame.png(FB, 0xE4) end
  tPng = (os.clock() - tPng) / 200
  print(string.format("CPU only: %.3f ms/frame (%d fps)  bank switches/frame %.1f  DMA loops skipped %d",
    cpu / N * 1000, math.floor(N / cpu), st.bankSwitches / N, st.dmaSkips))
  print(string.format("Presenting every 2nd frame: +%.3f ms per presented frame (render), .bin encode %.3f ms, PNG encode %.3f ms",
    ((withDisp - cpu) - tEnc) / presented * 1000, tEnc / presented * 1000, tPng * 1000))
end

if mode == "state" then
  -- Run to frame 3000, snapshot, then continue the original and a restored copy
  -- in lockstep for 1500 frames with the same inputs; framebuffers must match.
  local rom = readFile(arg[2])
  local snap
  local A = runScript(rom, 3000, function() return false end, function() end)
  snap = A.saveState()
  local hashesA, hashesB = {}, {}
  local function hasher(store) return function(f, FB, bgp) store[#store + 1] = Frame.bin(FB, bgp) end end
  local B = gbcore.create({ romBanks = #rom // 16384, bank = bankHost(rom), bank0 = bank0Of(rom), bank0bytes = function() return { rom:byte(1, 16384) } end,
    beginFrame = function() return true end, frameReady = function(FB, bgp) hashesB[#hashesB + 1] = Frame.bin(FB, bgp) end })
  assert(B.loadState(snap), "loadState failed")
  -- re-create A's presenter by running A with a presenting host is not possible after
  -- creation, so compare via a second snapshot: run both 1500 frames, then compare states.
  for i = 1, 1500 do
    local key = ({ "A", "UP", "RIGHT", "DOWN", "B" })[(i // 37) % 5 + 1]
    local down = (i % 37) < 6
    A.setButton(key, down); B.setButton(key, down)
    if not down then A.releaseAll(); B.releaseAll() end
    A.runFrame(); B.runFrame()
  end
  -- winLine (index 27) is renderer-only bookkeeping (reset every frame); A does not render.
  local fmt = "<c8" .. string.rep("j", 34)
  local hl = string.packsize(fmt)
  local va, vb = { string.unpack(fmt, A.saveState()) }, { string.unpack(fmt, B.saveState()) }
  va[28], vb[28] = 0, 0
  local same = A.saveState():sub(hl + 1) == B.saveState():sub(hl + 1)
  for i = 2, 35 do if va[i] ~= vb[i] then same = false end end
  print("state size", #snap, "bytes; restored run (presenting every frame) identical to original after 1500 frames with input:", same, "frames presented:", #hashesB)
  os.exit(same and 0 or 1)
end
