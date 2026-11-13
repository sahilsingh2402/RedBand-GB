-- RedBand GB Lua core: DMG (original Game Boy) emulator for the Lua 5.4
-- watchface engine of Xiaomi Smart Band 9/10 (Vela). Port of the JS core that
-- passes Blargg cpu_instrs + instr_timing.
--
-- Memory model (v2.3, memory-lean for watchfaces; all keys 1-based):
--   P0  ROM bank 0, PACKED like the switchable banks (host.bank0())
--   PX  mapped ROM bank, packed the same way; a bank switch swaps the PX reference
--       (the host keeps a small LRU of packed banks read 16 KiB at a time from the ROM file)
--   RAM 0x8000-0xDFFF -> RAM[addr - 0x7FFF] (1..24576)
--       0xFE00-0xFFFF -> RAM[addr - 40447]  (24577..25088); echo E000-FDFF maps to C000-DDFF
--   battery RAM: 4 banks kept as 8 KiB strings; the enabled bank lives in the A000-BFFF window
-- No 1 MiB ROM string and no hash-table RAM: v2.2 needed > 3 MB of Lua heap and ran out.
--
-- The scanline renderer writes 2-bit packed pixels (pixel 0 in bits 7-6) into
-- FB (144 rows x 40 bytes); background/window store raw colour numbers and the
-- presenter applies BGP through the image palette.

local M = {}
M.CYCLES_PER_SECOND = 4194304
M.FRAME_CYCLES = 70224

local LINE, MODE3_AT, MODE0_AT, NEVER = 456, 80, 252, 0x3FFFFFFF
local FRAME_CYCLES = 70224
local IO = 24833            -- RAM key of 0xFF00
local OAMK = 24577          -- RAM key of 0xFE00
local IEK = 25088           -- RAM key of 0xFFFF (IE)
local HI = 40447            -- addr - HI = RAM key for 0xFE00-0xFFFF
local RAMSIZE = 25088
-- packed ROM words: 8 bytes per integer on 64-bit Lua, 4 on 32-bit builds
local WSH = (math.maxinteger > 0x7FFFFFFF) and 3 or 2
local WMA = (1 << WSH) - 1
M.WORD_BYTES = 1 << WSH

local SPL, SPH, REV = {}, {}, {}   -- 1-based: value v at [v + 1]
for v = 0, 255 do
  local w, r = 0, 0
  for k = 0, 7 do
    if (v & (1 << k)) ~= 0 then w = w | (1 << (2 * k)); r = r | (1 << (7 - k)) end
  end
  SPL[v + 1] = w; SPH[v + 1] = w << 1; REV[v + 1] = r
end

local SOUND_MASK = {
  0x80, 0x3F, 0x00, 0xFF, 0xBF, 0xFF, 0x3F, 0x00, 0xFF, 0xBF, 0x7F, 0xFF, 0x9F, 0xFF, 0xBF, 0xFF,
  0xFF, 0x00, 0x00, 0xBF, 0x00, 0x00, 0x70, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }
local TIMER_PERIOD = { [0] = 1024, 16, 64, 256 }
M.BUTTON_BITS = { RIGHT = 0x01, LEFT = 0x02, UP = 0x04, DOWN = 0x08, A = 0x10, B = 0x20, SELECT = 0x40, START = 0x80 }

local function bytesToTable(s, t, offset)
  -- copy string bytes into table t starting at key offset+1, in chunks (C stack friendly)
  local n = #s
  local i = 1
  while i <= n do
    local j = i + 1023
    if j > n then j = n end
    local chunk = { string.byte(s, i, j) }
    table.move(chunk, 1, #chunk, offset + i, t)
    i = j + 1
  end
  return t
end
M.bytesToTable = bytesToTable

--- Array of n copies of v with an exactly-sized array part (filling one element at a
--- time grows the array by doubling: 25088 entries would take 32768 slots).
local function newArray(n, v)
  local ok, t = pcall(function()
    return load("return {" .. string.rep(tostring(v) .. ",", n) .. "}")()
  end)
  if ok and type(t) == "table" and #t == n then return t end
  t = {}
  for i = 1, n do t[i] = v end
  return t
end
M.newArray = newArray

--- Bank 0 as a plain, exactly-sized byte table.
function M.unpackBank0(s)
  local ok, t = pcall(function() return { string.byte(s, 1, 16384) } end)
  if ok and #t == 16384 then return t end
  t = {}
  for i = 1, 16384 do t[i] = string.byte(s, i) end
  return t
end

--- Pack a 16 KiB ROM bank string into 16384 >> WSH little-endian integers.
function M.packBank(s)
  if #s < 16384 then s = s .. string.rep("\255", 16384 - #s) end
  local fmt = "<" .. string.rep(WSH == 3 and "i8" or "i4", 256)
  local step = 256 << WSH
  local t, k = {}, 1
  for pos = 1, 16384, step do
    local vals = { string.unpack(fmt, s, pos) }
    table.move(vals, 1, 256, k, t)
    k = k + 256
  end
  return t
end

local function tableToString(t, first, count)
  local parts, i, last = {}, first, first + count - 1
  while i <= last do
    local j = i + 999
    if j > last then j = last end
    parts[#parts + 1] = string.char(table.unpack(t, i, j))
    i = j + 1
  end
  return table.concat(parts)
end
M.tableToString = tableToString

--- host = { bank(n) -> table (1..16384), romBanks = 64,
---          beginFrame(dirty) -> bool, frameReady(FB, bgp), serialOut(byte)? }
function M.create(host)
  local romBanks = host.romBanks or 64
  local RAM, FB, TW = newArray(RAMSIZE, 0), newArray(5760, 0), newArray(3072, 0)
  local ZERO8K = string.rep("\0", 8192)
  local ERAMS = { ZERO8K, ZERO8K, ZERO8K, ZERO8K }   -- battery RAM banks as strings
  local ramWinDirty = false
  local BGC, WW, LN, LB, LSP = {}, {}, {}, {}, {}
  for k = 1, 48 do BGC[k] = 0 end
  for k = 1, 24 do WW[k] = 0 end
  for k = 1, 144 do LN[k] = 0 end
  for k = 1, 1440 do LB[k] = 0 end
  for k = 1, 10 do LSP[k] = 0 end
  local INV, SO0, SO1 = { 0, 1, 2, 3 }, {}, {}
  for k = 1, 256 do SO0[k] = 0; SO1[k] = 0 end

  local P0 = host.bank0()
  -- compiled blocks (v2.5): B0 = bank-0 blocks by address, AOT_BANKS[bank] = blocks of a
  -- switchable bank, BX = blocks of the mapped bank (filled by aot_blocks.inc.lua)
  local NOBLK = {}
  local B0, BX, AOT_BANKS, AOT_SIG = {}, NOBLK, {}, nil
  local PX = host.bank(1)

  -- CPU state
  local a, b, c, d, e, h, l = 0x01, 0x00, 0x13, 0x00, 0xD8, 0x01, 0x4D
  local sp, pc = 0xFFFE, 0x0100
  local zr, nf, hf, cf = 0, 0, 1, 1
  local ime, imeDelay, halted = 0, 0, 0
  local cyc, nextEvt = 0, 0

  -- peripherals
  local romBank, ramOn, ramBank, sramDirty = 1, false, 0, false
  local lcdOn, ly, lineStart, ppuEvt, ppuPhase, winLine = true, 0, 0, 0, 0, 0
  local skipLines = 1           -- lines until the next PPU event (lazy scanlines)
  local offEvt = NEVER
  local frameDone, rendering, nSpr, oamDirty, bucketTall = false, false, 0, false, 8
  local divStart, timerEvt, timaRef, serialEvt = 0, NEVER, 0, NEVER
  local buttons = 0
  local videoDirty = true
  local lastFrameCycles = FRAME_CYCLES
  local bankSwitches, dmaSkips = 0, 0

  local rd, wr, ior, iow, haltOp, illegal, mbcWrite, selectRomBank
  local syncRamOut, mapRam, buildInv, buildObj, timerSync, scheduleTimer
  local lcdEnable, lcdDisable, startLine, ppuEvent, events, nextLineEvent, curLine, ppuResync
  local beginFrameRender, scanOam, blankFrame, renderLine, renderWindow, renderSprites
  local OP, CB

  illegal = function(at) error(string.format("Illegal opcode at %04X", at)) end

  -- ================= memory =================
  rd = function(t)
    if t < 0x4000 then return (P0[(t >> WSH) + 1] >> ((t & WMA) << 3)) & 255 end
    if t < 0x8000 then return (PX[((t - 0x4000) >> WSH) + 1] >> ((t & WMA) << 3)) & 255 end
    if t < 0xE000 then return RAM[t - 0x7FFF] end
    if t < 0xFE00 then return RAM[t - 0x9FFF] end
    if t < 0xFF00 then
      if t < 0xFEA0 then return RAM[t - HI] end
      return 0xFF
    end
    if t >= 0xFF80 then return RAM[t - HI] end
    return ior(t & 0x7F)
  end

  wr = function(t, v)
    if t < 0x8000 then mbcWrite(t, v) return end
    if t < 0xA000 then
      local k = t - 0x7FFF
      if RAM[k] ~= v then
        RAM[k] = v; videoDirty = true
        if t < 0x9800 then
          local q = t & 0xFFFE
          TW[((q - 0x8000) >> 1) + 1] = SPL[RAM[q - 0x7FFF] + 1] | SPH[RAM[q - 0x7FFE] + 1]
        end
      end
      return
    end
    if t < 0xC000 then
      if ramOn and ramBank < 4 then
        local k = t - 0x7FFF
        if RAM[k] ~= v then RAM[k] = v; sramDirty = true; ramWinDirty = true end
      end
      return
    end
    if t < 0xE000 then RAM[t - 0x7FFF] = v return end
    if t < 0xFE00 then RAM[t - 0x9FFF] = v return end
    if t < 0xFF00 then
      if t < 0xFEA0 then
        local k = t - HI
        if RAM[k] ~= v then RAM[k] = v; videoDirty = true; oamDirty = true end
      end
      return
    end
    if t >= 0xFF80 then
      RAM[t - HI] = v
      if t == 0xFFFF then nextEvt = cyc end
      return
    end
    iow(t & 0x7F, v)
  end

  -- ---- MBC3 ----
  mbcWrite = function(t, v)
    if t < 0x2000 then
      local on = (v & 0x0F) == 0x0A
      if on ~= ramOn then syncRamOut(); ramOn = on; mapRam() end
    elseif t < 0x4000 then
      local n = v & 0x7F
      if n == 0 then n = 1 end
      selectRomBank(n % romBanks)
    elseif t < 0x6000 then
      local n = v & 0x0F
      if n ~= ramBank then syncRamOut(); ramBank = n; mapRam() end
    end
  end

  selectRomBank = function(n)
    if n == romBank then return end
    PX = host.bank(n)
    BX = AOT_BANKS[n] or NOBLK
    romBank = n
    bankSwitches = bankSwitches + 1
  end

  syncRamOut = function()
    if ramOn and ramBank < 4 and ramWinDirty then ERAMS[ramBank + 1] = tableToString(RAM, 0x2001, 8192) end
    ramWinDirty = false
  end

  mapRam = function()
    if ramOn and ramBank < 4 then
      bytesToTable(ERAMS[ramBank + 1], RAM, 0x2000)
    else
      for k = 0x2001, 0x4000 do RAM[k] = 0xFF end
    end
  end

  -- ---- I/O registers ----
  ior = function(n)
    if n == 0x00 then
      local sel = RAM[IO] & 0x30
      local v = 0x0F
      if (sel & 0x10) == 0 then v = v & (~buttons) & 0x0F end
      if (sel & 0x20) == 0 then v = v & (~(buttons >> 4)) & 0x0F end
      return 0xC0 | sel | v
    elseif n == 0x02 then return RAM[IO + 2] | 0x7E
    elseif n == 0x04 then return ((cyc - divStart) >> 8) & 255
    elseif n == 0x05 then timerSync(); return RAM[IO + 5]
    elseif n == 0x07 then return RAM[IO + 7] | 0xF8
    elseif n == 0x0F then return RAM[IO + 0x0F] | 0xE0
    elseif n == 0x41 then
      local mode
      local L = lcdOn and curLine() or 0
      if not lcdOn then mode = 0
      elseif L >= 144 then mode = 1
      else
        local t = cyc - lineStart - (L - ly) * LINE
        if t < MODE3_AT then mode = 2 elseif t < MODE0_AT then mode = 3 else mode = 0 end
      end
      return 0x80 | (RAM[IO + 0x41] & 0x78) | ((L == RAM[IO + 0x45] and lcdOn) and 4 or 0) | mode
    elseif n == 0x44 then return lcdOn and curLine() or 0
    end
    if n >= 0x10 and n < 0x40 then return RAM[IO + n] | SOUND_MASK[n - 0x0F] end
    if n >= 0x4C then return 0xFF end
    if n == 0x03 or (n >= 0x08 and n < 0x0F) then return 0xFF end
    return RAM[IO + n]
  end

  iow = function(n, v)
    if n == 0x00 then RAM[IO] = v & 0x30
    elseif n == 0x02 then
      RAM[IO + 2] = v
      if (v & 0x81) == 0x81 then
        serialEvt = cyc + 4096
        if serialEvt < nextEvt then nextEvt = serialEvt end
      end
      if host.serialOut and (v & 0x80) ~= 0 then host.serialOut(RAM[IO + 1]) end
    elseif n == 0x04 then timerSync(); divStart = cyc; timaRef = cyc; scheduleTimer()
    elseif n == 0x05 then timerSync(); RAM[IO + 5] = v; scheduleTimer()
    elseif n == 0x06 then RAM[IO + 6] = v
    elseif n == 0x07 then timerSync(); RAM[IO + 7] = v & 7; scheduleTimer()
    elseif n == 0x0F then RAM[IO + 0x0F] = v & 0x1F; nextEvt = cyc
    elseif n == 0x40 then
      if RAM[IO + 0x40] ~= v then videoDirty = true end
      RAM[IO + 0x40] = v
      if (v & 0x80) ~= 0 and not lcdOn then lcdEnable()
      elseif (v & 0x80) == 0 and lcdOn then lcdDisable() end
    elseif n == 0x41 then RAM[IO + 0x41] = v & 0x78; ppuResync()
    elseif n == 0x44 then -- LY is read-only
    elseif n == 0x45 then RAM[IO + 0x45] = v; ppuResync()
    elseif n == 0x46 then
      local src = v << 8
      for i = 0, 159 do
        local x = rd(src + i)
        local k = OAMK + i
        if RAM[k] ~= x then RAM[k] = x; videoDirty = true; oamDirty = true end
      end
      RAM[IO + 0x46] = v
      -- Standard HRAM DMA wait loop `ld a,n / dec a / jr nz,-3`: apply its exact
      -- result (A=0, Z=1, N=1, H=0, same cycle count); our DMA is instant.
      if pc >= 0xFF80 and pc < 0xFFF9 then
        local k = pc - HI
        if RAM[k] == 0x3E and RAM[k + 2] == 0x3D and RAM[k + 3] == 0x20 and RAM[k + 4] == 0xFD then
          local cnt = RAM[k + 1]
          if cnt > 0 then
            a = 0; zr = 0; nf = 1; hf = 0
            pc = pc + 5
            cyc = cyc + 8 + cnt * 4 + (cnt - 1) * 12 + 8
            dmaSkips = dmaSkips + 1
          end
        end
      end
    elseif n == 0x47 then if RAM[IO + 0x47] ~= v then RAM[IO + 0x47] = v; buildInv(); videoDirty = true end
    elseif n == 0x48 then if RAM[IO + 0x48] ~= v then RAM[IO + 0x48] = v; buildObj(SO0, v); videoDirty = true end
    elseif n == 0x49 then if RAM[IO + 0x49] ~= v then RAM[IO + 0x49] = v; buildObj(SO1, v); videoDirty = true end
    elseif n == 0x42 or n == 0x43 or n == 0x4A or n == 0x4B then
      if RAM[IO + n] ~= v then RAM[IO + n] = v; videoDirty = true end
    else
      RAM[IO + n] = v
    end
  end

  -- INV[shade+1] = BG colour number whose BGP shade is closest to `shade`.
  buildInv = function()
    local p = RAM[IO + 0x47]
    local changed = false
    for shd = 0, 3 do
      local best, bd = 0, 9
      for cn = 0, 3 do
        local dlt = ((p >> (cn << 1)) & 3) - shd
        if dlt < 0 then dlt = -dlt end
        if dlt < bd then bd = dlt; best = cn end
      end
      if INV[shd + 1] ~= best then INV[shd + 1] = best; changed = true end
    end
    if changed then buildObj(SO0, RAM[IO + 0x48]); buildObj(SO1, RAM[IO + 0x49]) end
  end

  -- Sprite byte table: four packed OBJ colour numbers -> four packed image indices.
  buildObj = function(T, p)
    for v = 0, 255 do
      T[v + 1] = INV[((p >> ((v & 3) << 1)) & 3) + 1]
        | (INV[((p >> (((v >> 2) & 3) << 1)) & 3) + 1] << 2)
        | (INV[((p >> (((v >> 4) & 3) << 1)) & 3) + 1] << 4)
        | (INV[((p >> ((v >> 6) << 1)) & 3) + 1] << 6)
    end
  end

  -- ================= timer =================
  timerSync = function()
    local tac = RAM[IO + 7]
    if (tac & 4) == 0 then timaRef = cyc; return end
    local per = TIMER_PERIOD[tac & 3]
    local ticks = (cyc - divStart) // per - (timaRef - divStart) // per
    timaRef = cyc
    if ticks <= 0 then return end
    local t = RAM[IO + 5] + ticks
    if t > 255 then
      local tma = RAM[IO + 6]
      local span = 256 - tma
      t = tma + ((t - 256) % span)
      RAM[IO + 0x0F] = RAM[IO + 0x0F] | 4
      nextEvt = cyc
    end
    RAM[IO + 5] = t
  end

  scheduleTimer = function()
    local tac = RAM[IO + 7]
    if (tac & 4) == 0 then timerEvt = NEVER; return end
    local per = TIMER_PERIOD[tac & 3]
    local phase = (cyc - divStart) % per
    local nextTick = cyc + (per - phase)
    timerEvt = nextTick + (255 - RAM[IO + 5]) * per
    if timerEvt < nextEvt then nextEvt = timerEvt end
  end

  -- ================= PPU timing =================
  lcdEnable = function()
    lcdOn = true; ly = 0; lineStart = cyc; winLine = 0
    offEvt = NEVER
    startLine()
  end

  lcdDisable = function()
    lcdOn = false; ly = 0; ppuEvt = NEVER
    offEvt = (cyc < FRAME_CYCLES) and FRAME_CYCLES or (cyc + LINE)
    if offEvt < nextEvt then nextEvt = offEvt end
  end

  startLine = function()
    local st = RAM[IO + 0x41]
    local irq = 0
    if ly == 144 then
      irq = irq | 1
      if (st & 0x10) ~= 0 then irq = irq | 2 end
      frameDone = true
    elseif ly < 144 and (st & 0x20) ~= 0 then irq = irq | 2 end
    if ly == RAM[IO + 0x45] and (st & 0x40) ~= 0 then irq = irq | 2 end
    if irq ~= 0 then RAM[IO + 0x0F] = RAM[IO + 0x0F] | irq end
    if ly == 0 then beginFrameRender() end
    if ly < 144 and rendering then ppuPhase = 1; ppuEvt = lineStart + MODE3_AT
    elseif ly < 144 and (st & 0x08) ~= 0 then ppuPhase = 2; ppuEvt = lineStart + MODE0_AT
    else nextLineEvent(st) end
  end

  -- Lazy scanlines (ported from the verified JS core): lines on which nothing happens
  -- are skipped. The next PPU event is the next line that matters: line 0, VBlank (144)
  -- and the LYC line; every line only while a frame is drawn or per-line STAT interrupts
  -- are on. LY/STAT reads derive the line from the cycle counter; STAT/LYC writes re-plan.
  -- Pokemon idles in HALT most of each frame: it now sleeps straight to VBlank instead of
  -- waking on all 154 lines.
  nextLineEvent = function(st)
    ppuPhase = 0
    local target = (ly < 144) and 144 or 154
    if ly < 144 and (st & 0x20) ~= 0 then target = ly + 1 end
    if (st & 0x40) ~= 0 then
      local lyc = RAM[IO + 0x45]
      if lyc > ly and lyc < target then target = lyc end
    end
    skipLines = target - ly
    ppuEvt = lineStart + skipLines * LINE
  end
  curLine = function() return ly + (cyc - lineStart) // LINE end
  ppuResync = function()
    if not lcdOn or ppuPhase ~= 0 then return end
    local dl = (cyc - lineStart) // LINE
    if dl > 0 then ly = ly + dl; lineStart = lineStart + dl * LINE end
    nextLineEvent(RAM[IO + 0x41])
    if ppuEvt < nextEvt then nextEvt = ppuEvt end
  end

  ppuEvent = function()
    if ppuPhase == 1 then
      renderLine(ly)
      if (RAM[IO + 0x41] & 0x08) ~= 0 then ppuPhase = 2; ppuEvt = lineStart + MODE0_AT
      else ppuPhase = 0; skipLines = 1; ppuEvt = lineStart + LINE end
    elseif ppuPhase == 2 then
      RAM[IO + 0x0F] = RAM[IO + 0x0F] | 2
      ppuPhase = 0; skipLines = 1; ppuEvt = lineStart + LINE
    else
      lineStart = lineStart + skipLines * LINE
      ly = ly + skipLines
      if ly >= 154 then ly = ly - 154 end
      startLine()
    end
  end

  -- ================= events, interrupts, HALT =================
  events = function()
    while true do
      while cyc >= ppuEvt do ppuEvent() end
      if cyc >= timerEvt then timerSync(); scheduleTimer() end
      if cyc >= serialEvt then
        serialEvt = NEVER
        RAM[IO + 1] = 0xFF; RAM[IO + 2] = RAM[IO + 2] & 0x7F; RAM[IO + 0x0F] = RAM[IO + 0x0F] | 8
      end
      if cyc >= offEvt then
        offEvt = offEvt + FRAME_CYCLES
        frameDone = true
        if not rendering and videoDirty and host.beginFrame and host.beginFrame(true) then
          rendering = true; videoDirty = false
        end
        if rendering then blankFrame() end
      end
      local ne = ppuEvt
      if timerEvt < ne then ne = timerEvt end
      if serialEvt < ne then ne = serialEvt end
      if offEvt < ne then ne = offEvt end
      if imeDelay ~= 0 then
        imeDelay = 0; ime = 1
        nextEvt = (cyc + 1 < ne) and (cyc + 1) or ne
        return frameDone
      end
      local pend = RAM[IEK] & RAM[IO + 0x0F] & 0x1F
      local serviced = false
      if pend ~= 0 then
        halted = 0
        if ime ~= 0 then
          local bit = pend & (-pend)
          RAM[IO + 0x0F] = RAM[IO + 0x0F] & (~bit)
          ime = 0
          sp = (sp - 2) & 0xFFFF
          wr(sp, pc & 255); wr((sp + 1) & 0xFFFF, pc >> 8)
          if bit == 1 then pc = 0x40 elseif bit == 2 then pc = 0x48 elseif bit == 4 then pc = 0x50
          elseif bit == 8 then pc = 0x58 else pc = 0x60 end
          cyc = cyc + 20
          serviced = true
        end
      end
      if not serviced then
        nextEvt = ne
        if frameDone then return true end
        if halted == 0 then return false end
        cyc = ne
      end
    end
  end

  haltOp = function()
    if ime ~= 0 or (RAM[IEK] & RAM[IO + 0x0F] & 0x1F) == 0 then halted = 1; nextEvt = cyc end
  end

  -- ================= rendering =================
  beginFrameRender = function()
    winLine = 0
    rendering = (host.beginFrame ~= nil) and host.beginFrame(videoDirty) or false
    if rendering then videoDirty = false; scanOam() end
  end

  scanOam = function()
    oamDirty = false
    bucketTall = ((RAM[IO + 0x40] & 4) ~= 0) and 16 or 8
    for k = 1, 144 do LN[k] = 0 end
    nSpr = 0
    for i = 0, 39 do
      local sy = RAM[OAMK + (i << 2)] - 16
      local y0 = (sy < 0) and 0 or sy
      local y1 = sy + bucketTall
      if y1 > 144 then y1 = 144 end
      if y0 < y1 then
        nSpr = nSpr + 1
        for y = y0, y1 - 1 do
          local cnt = LN[y + 1]
          if cnt < 10 then LB[y * 10 + cnt + 1] = i; LN[y + 1] = cnt + 1 end
        end
      end
    end
  end

  blankFrame = function()
    local z = INV[1] * 0x55
    for k = 1, 5760 do FB[k] = z end
  end

  renderLine = function(y)
    local row = y * 40 + 1
    local lcdc = RAM[IO + 0x40]
    if (lcdc & 1) ~= 0 then
      local sy = (y + RAM[IO + 0x42]) & 255
      local sx = RAM[IO + 0x43]
      local mapk = (((lcdc & 8) ~= 0) and 0x9C00 or 0x9800) + ((sy >> 3) << 5) - 0x7FFF
      local unsigned = (lcdc & 0x10) ~= 0
      local tx = unsigned and 0 or 0x80
      local tb = (unsigned and 0 or 1024) + (sy & 7) + 1
      local fine = sx & 7
      local col = sx >> 3
      local k = row
      if fine == 0 then
        for _ = 1, 20 do
          local w = TW[((RAM[mapk + col] ~ tx) << 3) + tb]
          FB[k] = w >> 8; FB[k + 1] = w & 255; k = k + 2
          col = (col + 1) & 31
        end
      else
        local sh = 16 - (fine << 1)
        local prev = TW[((RAM[mapk + col] ~ tx) << 3) + tb]
        for _ = 1, 20 do
          col = (col + 1) & 31
          local cur = TW[((RAM[mapk + col] ~ tx) << 3) + tb]
          local v = ((prev << 16) | cur) >> sh
          FB[k] = (v >> 8) & 255; FB[k + 1] = v & 255; k = k + 2
          prev = cur
        end
      end
      local wx = RAM[IO + 0x4B]
      if (lcdc & 0x20) ~= 0 and y >= RAM[IO + 0x4A] and wx < 167 then renderWindow(row, lcdc, wx - 7) end
    else
      local z = INV[1] * 0x55
      for k = row, row + 39 do FB[k] = z end
    end
    if (lcdc & 2) ~= 0 then
      if oamDirty or bucketTall ~= (((lcdc & 4) ~= 0) and 16 or 8) then scanOam() end
      if nSpr > 0 and LN[y + 1] > 0 then renderSprites(row, lcdc, y) end
    end
  end

  renderWindow = function(row, lcdc, x0)
    local wl = winLine
    winLine = winLine + 1
    local mapk = (((lcdc & 0x40) ~= 0) and 0x9C00 or 0x9800) + ((wl >> 3) << 5) - 0x7FFF
    local unsigned = (lcdc & 0x10) ~= 0
    local tx = unsigned and 0 or 0x80
    local tb = (unsigned and 0 or 1024) + (wl & 7) + 1
    if x0 >= 0 and (x0 & 7) == 0 then
      local k, i = row + (x0 >> 2), 0
      local stop = row + 40
      while k < stop do
        local w = TW[((RAM[mapk + i] ~ tx) << 3) + tb]
        FB[k] = w >> 8; FB[k + 1] = w & 255; k = k + 2; i = i + 1
      end
      return
    end
    local ntiles = ((159 - x0) >> 3) + 1
    if ntiles > 22 then ntiles = 22 end
    for i = 0, ntiles - 1 do WW[i + 1] = TW[((RAM[mapk + (i & 31)] ~ tx) << 3) + tb] end
    WW[ntiles + 1] = 0
    local first = (x0 < 0) and 0 or x0
    for j = first >> 2, 39 do
      local q = (j << 2) - x0
      if q >= 0 then
        local kk = q >> 3
        FB[row + j] = (((WW[kk + 1] << 16) | WW[kk + 2]) >> (24 - ((q & 7) << 1))) & 255
      else
        local cn = (WW[1] >> 8) >> ((-q) << 1)
        local mask = 0xFF >> ((-q) << 1)
        FB[row + j] = (FB[row + j] & (~mask) & 255) | (cn & mask)
      end
    end
  end

  renderSprites = function(row, lcdc, y)
    local tall = ((lcdc & 4) ~= 0) and 16 or 8
    local n = LN[y + 1]
    local lb = y * 10
    local behind = 0
    for k = 1, n do
      local i = LB[lb + k]
      LSP[k] = i
      behind = behind | RAM[OAMK + (i << 2) + 3]
    end
    if (behind & 0x80) ~= 0 then for k = 0, 39 do BGC[k + 1] = FB[row + k] end end
    -- draw lowest priority first: larger X first; equal X -> larger OAM index first
    for i = 2, n do
      local v = LSP[i]
      local vx = RAM[OAMK + (v << 2) + 1]
      local j = i - 1
      while j >= 1 do
        local u = LSP[j]
        local ux = RAM[OAMK + (u << 2) + 1]
        if ux > vx or (ux == vx and u > v) then break end
        LSP[j + 1] = u; j = j - 1
      end
      LSP[j + 1] = v
    end
    for s = 1, n do
      local base = OAMK + (LSP[s] << 2)
      local sy = RAM[base] - 16
      local x = RAM[base + 1] - 8
      local attr = RAM[base + 3]
      if x > -8 and x < 160 then
        local line = y - sy
        if (attr & 0x40) ~= 0 then line = tall - 1 - line end
        local tile = RAM[base + 2]
        if tall == 16 then tile = tile & 0xFE end
        local w
        if (attr & 0x20) ~= 0 then
          local ad = (tile << 4) + (line << 1) + 1     -- RAM key of 0x8000 + tile*16 + line*2
          w = SPL[REV[RAM[ad] + 1] + 1] | SPH[REV[RAM[ad + 1] + 1] + 1]
        else
          w = TW[(tile << 3) + line + 1]
        end
        if w ~= 0 then
          local m = (w | (w >> 1)) & 0x5555
          m = m | (m << 1)
          local P = ((attr & 0x10) ~= 0) and SO1 or SO0
          local px = (P[(w >> 8) + 1] << 8) | P[(w & 255) + 1]
          local bi, s2
          if x < 0 then
            local cut = (-x) << 1
            m = (m << cut) & 0xFFFF; px = (px << cut) & 0xFFFF
            bi = 0; s2 = 0
          else
            bi = x >> 2; s2 = (x & 3) << 1
          end
          if (attr & 0x80) ~= 0 then
            local bw = (((BGC[bi + 1] << 16) | (BGC[bi + 2] << 8) | BGC[bi + 3]) >> (8 - s2)) & 0xFFFF
            local bm = (bw | (bw >> 1)) & 0x5555
            bm = bm | (bm << 1)
            m = m & (~bm) & 0xFFFF
          end
          if m ~= 0 then
            local sh = 8 - s2
            local pm, pv = m << sh, px << sh
            local mk = (pm >> 16) & 255
            if mk ~= 0 then local o = row + bi; FB[o] = (FB[o] & (~mk) & 255) | ((pv >> 16) & mk) end
            mk = (pm >> 8) & 255
            if mk ~= 0 and bi + 1 < 40 then local o = row + bi + 1; FB[o] = (FB[o] & (~mk) & 255) | ((pv >> 8) & mk) end
            mk = pm & 255
            if mk ~= 0 and bi + 2 < 40 then local o = row + bi + 2; FB[o] = (FB[o] & (~mk) & 255) | (pv & mk) end
          end
        end
      end
    end
  end

  -- ================= CPU instruction tables (generated) =================
--@@CPU_TABLES@@
--@@AOT@@
  -- compiled blocks only for the ROM they were built from (other ROMs: interpreter only)
  do
    local ok = AOT_SIG ~= nil
    if ok then for i = 1, #AOT_SIG do if rd(0x133 + i) ~= AOT_SIG[i] then ok = false break end end end
    if not ok then B0 = {} AOT_BANKS = {} end
    BX = AOT_BANKS[romBank] or NOBLK
  end
  local function aotCount() local n = 0 for _ in pairs(B0) do n = n + 1 end for _, t in pairs(AOT_BANKS) do for _ in pairs(t) do n = n + 1 end end return n end

  -- ================= main loop =================
  local function runFrame()
    if halted ~= 0 and not frameDone then cyc = nextEvt end
    if not frameDone and not (cyc >= nextEvt and events()) then
      local ops = OP
      while true do
        local blk
        if pc < 0x4000 then blk = B0[pc] elseif pc < 0x8000 then blk = BX[pc] end
        if not (blk and blk()) then              -- compiled block (false: event due soon)
          local op
          if pc < 0x4000 then op = (P0[(pc >> WSH) + 1] >> ((pc & WMA) << 3)) & 255
          elseif pc < 0x8000 then op = (PX[((pc - 0x4000) >> WSH) + 1] >> ((pc & WMA) << 3)) & 255
          elseif pc < 0xE000 then op = RAM[pc - 0x7FFF]
          else op = rd(pc) end
          pc = pc + 1
          ops[op]()
        end
        if cyc >= nextEvt and events() then break end
      end
    end
    frameDone = false
    local base = lcdOn and lineStart or (offEvt - FRAME_CYCLES)
    if rendering then
      rendering = false
      if host.frameReady then host.frameReady(FB, RAM[IO + 0x47]) end
    end
    cyc = cyc - base; nextEvt = nextEvt - base; lineStart = lineStart - base
    divStart = divStart - base; timaRef = timaRef - base
    if ppuEvt ~= NEVER then ppuEvt = ppuEvt - base end
    if timerEvt ~= NEVER then timerEvt = timerEvt - base end
    if serialEvt ~= NEVER then serialEvt = serialEvt - base end
    if offEvt ~= NEVER then offEvt = offEvt - base end
    while divStart < -65536 do divStart = divStart + 65536 end
    lastFrameCycles = base
    return base
  end

  local function rebuildTiles()
    for r = 0, 3071 do
      local q = 0x8000 + (r << 1)
      TW[r + 1] = SPL[RAM[q - 0x7FFF] + 1] | SPH[RAM[q - 0x7FFE] + 1]
    end
  end

  -- ================= save states (taken between frames) =================
  local STATE_TAG = "RBGBST03"
  local function saveState()
    syncRamOut()
    local head = string.pack("<c8" .. string.rep("j", 35), STATE_TAG,
      a, b, c, d, e, h, l, sp, pc, zr, nf, hf, cf, ime, imeDelay, halted, cyc, nextEvt,
      romBank, ramOn and 1 or 0, ramBank, lcdOn and 1 or 0, ly, lineStart, ppuEvt, ppuPhase, winLine,
      offEvt, divStart, timerEvt, timaRef, serialEvt, lastFrameCycles, buttons, skipLines)
    return head .. tableToString(RAM, 1, RAMSIZE) .. table.concat(ERAMS)
  end

  local function loadState(s)
    local headLen = string.packsize("<c8" .. string.rep("j", 35))
    if type(s) ~= "string" or #s ~= headLen + RAMSIZE + 32768 or s:sub(1, 8) ~= STATE_TAG then return false end
    local v = { string.unpack("<c8" .. string.rep("j", 35), s) }
    a, b, c, d, e, h, l, sp, pc = v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9], v[10]
    zr, nf, hf, cf, ime, imeDelay, halted = v[11], v[12], v[13], v[14], v[15], v[16], v[17]
    cyc, nextEvt, romBank = v[18], v[19], v[20]
    ramOn, ramBank, lcdOn = v[21] == 1, v[22], v[23] == 1
    ly, lineStart, ppuEvt, ppuPhase, winLine = v[24], v[25], v[26], v[27], v[28]
    offEvt, divStart, timerEvt, timaRef, serialEvt, lastFrameCycles = v[29], v[30], v[31], v[32], v[33], v[34]
    buttons = 0
    skipLines = v[36]
    bytesToTable(s:sub(headLen + 1, headLen + RAMSIZE), RAM, 0)
    local e0 = headLen + RAMSIZE
    for i = 1, 4 do ERAMS[i] = s:sub(e0 + (i - 1) * 8192 + 1, e0 + i * 8192) end
    ramWinDirty = false
    PX = host.bank(romBank)
    BX = AOT_BANKS[romBank] or NOBLK
    rebuildTiles()
    INV[1], INV[2], INV[3], INV[4] = 9, 9, 9, 9
    buildInv(); buildObj(SO0, RAM[IO + 0x48]); buildObj(SO1, RAM[IO + 0x49])
    frameDone, rendering, oamDirty, videoDirty, sramDirty = false, false, true, true, false
    return true
  end

  -- ================= init (DMG post-boot state) =================
  local IO_INIT = {
    [0x00] = 0x30, [0x05] = 0x00, [0x06] = 0x00, [0x07] = 0x00, [0x0F] = 0x01,
    [0x10] = 0x80, [0x11] = 0xBF, [0x12] = 0xF3, [0x14] = 0xBF, [0x16] = 0x3F, [0x17] = 0x00, [0x19] = 0xBF,
    [0x1A] = 0x7F, [0x1B] = 0xFF, [0x1C] = 0x9F, [0x1E] = 0xBF, [0x20] = 0xFF, [0x21] = 0x00, [0x22] = 0x00,
    [0x23] = 0xBF, [0x24] = 0x77, [0x25] = 0xF3, [0x26] = 0xF1, [0x40] = 0x91, [0x41] = 0x00, [0x42] = 0x00,
    [0x43] = 0x00, [0x45] = 0x00, [0x47] = 0xFC, [0x48] = 0xFF, [0x49] = 0xFF, [0x4A] = 0x00, [0x4B] = 0x00 }
  for k, v in pairs(IO_INIT) do RAM[IO + k] = v end
  RAM[IEK] = 0
  INV[1], INV[2], INV[3], INV[4] = 9, 9, 9, 9
  buildInv(); buildObj(SO0, RAM[IO + 0x48]); buildObj(SO1, RAM[IO + 0x49])
  mapRam()
  divStart = -0xABCC
  lineStart = 0; ly = 0; startLine()
  nextEvt = ppuEvt

  local core = {}
  core.runFrame = runFrame
  core.frameCycles = function() return lastFrameCycles end
  core.setButton = function(name, down)
    local bit = M.BUTTON_BITS[name]
    if not bit then return end
    if down then
      if (buttons & bit) == 0 then
        buttons = buttons | bit
        RAM[IO + 0x0F] = RAM[IO + 0x0F] | 0x10
        nextEvt = cyc
      end
    else
      buttons = buttons & (~bit)
    end
  end
  core.releaseAll = function() buttons = 0 end
  core.loadSRAM = function(s)
    if type(s) == "string" and #s == 32768 then
      for i = 1, 4 do ERAMS[i] = s:sub((i - 1) * 8192 + 1, i * 8192) end
      ramWinDirty = false; mapRam(); return true
    end
    return false
  end
  core.getSRAM = function() syncRamOut(); return table.concat(ERAMS) end
  core.sramDirty = function() return sramDirty end
  core.markSRAMSaved = function() sramDirty = false end
  core.markVideoDirty = function() videoDirty = true end
  core.saveState = saveState
  core.loadState = loadState
  core.bgp = function() return RAM[IO + 0x47] end
  core.aotBlocks = aotCount
  core.state = function()
    return { pc = pc, sp = sp, a = a, b = b, c = c, d = d, e = e, h = h, l = l, ly = ly,
             romBank = romBank, bankSwitches = bankSwitches, dmaSkips = dmaSkips }
  end
  core._ram = RAM
  return core
end

return M
