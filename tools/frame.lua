-- Frame encoders for the 160x144 2-bit framebuffer produced by gbcore.lua.
-- FB: 5760 bytes (144 rows x 40), 4 pixels per byte, pixel 0 in bits 7-6,
-- values are DMG colour numbers; BGP is applied through the palette.
--
--  * bin(): LVGL 9 image file, colour format I2 (indexed, 4-colour palette).
--           12-byte header + 16-byte BGRA palette + raw rows. No checksums,
--           so it is the cheapest format to produce from Lua.
--  * png(): standard PNG (stored deflate block), byte-identical to the JS app's
--           frames, for firmware whose LVGL lacks the .bin decoder.

local tableToString = require("gbcore").tableToString

local Frame = {}

Frame.DMG_GREEN = { { 224, 248, 208 }, { 136, 192, 112 }, { 52, 104, 86 }, { 8, 24, 32 } }

local function shadeOf(colors, bgp, cn)
  return colors[((bgp >> (cn << 1)) & 3) + 1]
end

-- ------------------------------------------------------------------ LVGL .bin
local BIN_HEADER = string.char(0x19, 0x08, 0, 0, 160, 0, 144, 0, 40, 0, 0, 0)

function Frame.bin(FB, bgp, colors)
  colors = colors or Frame.DMG_GREEN
  local pal = {}
  for cn = 0, 3 do
    local col = shadeOf(colors, bgp, cn)
    pal[cn + 1] = string.char(col[3], col[2], col[1], 255)   -- lv_color32_t = B, G, R, A
  end
  return BIN_HEADER .. table.concat(pal) .. tableToString(FB, 1, 5760)
end

-- LVGL 8 image file (older firmware): 4-byte header cf:5|zero:3|res:2|w:11|h:11,
-- colour format LV_IMG_CF_INDEXED_2BIT (8), then the same palette and rows.
local BIN8_HEADER = string.pack("<I4", 8 | (160 << 10) | (144 << 21))

function Frame.bin8(FB, bgp, colors)
  colors = colors or Frame.DMG_GREEN
  local pal = {}
  for cn = 0, 3 do
    local col = shadeOf(colors, bgp, cn)
    pal[cn + 1] = string.char(col[3], col[2], col[1], 255)
  end
  return BIN8_HEADER .. table.concat(pal) .. tableToString(FB, 1, 5760)
end

-- ------------------------------------------------------------------ PNG
local CRCT = {}
for n = 0, 255 do
  local cr = n
  for _ = 1, 8 do
    if (cr & 1) ~= 0 then cr = 0xEDB88320 ~ (cr >> 1) else cr = cr >> 1 end
  end
  CRCT[n + 1] = cr
end

local function crcString(cr, s)
  for i = 1, #s do cr = CRCT[((cr ~ s:byte(i)) & 255) + 1] ~ (cr >> 8) end
  return cr
end

local function be32(v)
  return string.char((v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255)
end

local function chunk(kind, data)
  return be32(#data) .. kind .. data .. be32(crcString(0xFFFFFFFF, kind .. data) ~ 0xFFFFFFFF)
end

local RAW_BYTES = 144 * 41
local SIG = string.char(137, 80, 78, 71, 13, 10, 26, 10)
local IHDR = chunk("IHDR", be32(160) .. be32(144) .. string.char(2, 3, 0, 0, 0))
local IDAT_PREFIX = string.char(0x78, 0x01, 1, RAW_BYTES & 255, RAW_BYTES >> 8,
  (~RAW_BYTES) & 255, ((~RAW_BYTES) >> 8) & 255)
local IDAT_HEAD = be32(2 + 5 + RAW_BYTES + 4) .. "IDAT"
local IDAT_CRC0 = crcString(0xFFFFFFFF, "IDAT" .. IDAT_PREFIX)
local IEND = chunk("IEND", "")
local plteCache = {}

function Frame.png(FB, bgp, colors)
  colors = colors or Frame.DMG_GREEN
  local plte = plteCache[bgp]
  if not plte or colors ~= Frame.DMG_GREEN then
    local p = {}
    for cn = 0, 3 do
      local col = shadeOf(colors, bgp, cn)
      p[cn + 1] = string.char(col[1], col[2], col[3])
    end
    plte = chunk("PLTE", table.concat(p))
    if colors == Frame.DMG_GREEN then plteCache[bgp] = plte end
  end
  -- raw rows (filter byte 0 + 40 bytes) with Adler-32 and CRC-32 in one pass
  local rows = {}
  local ad, as = 1, 0
  local cr = CRCT[(IDAT_CRC0 & 255) + 1] ~ (IDAT_CRC0 >> 8)   -- filter byte 0 of row 0
  as = as + ad
  for y = 0, 143 do
    local base = y * 40
    if y > 0 then                                              -- filter byte of rows 1..143
      cr = CRCT[(cr & 255) + 1] ~ (cr >> 8)
      as = as + ad
    end
    for k = base + 1, base + 40 do
      local v = FB[k]
      ad = ad + v; as = as + ad
      cr = CRCT[((cr ~ v) & 255) + 1] ~ (cr >> 8)
    end
    rows[y + 1] = "\0" .. tableToString(FB, base + 1, 40)
    ad = ad % 65521; as = as % 65521        -- per row: safe with 32-bit Lua integers
  end
  local adler = string.char(as >> 8, as & 255, ad >> 8, ad & 255)
  cr = crcString(cr, adler) ~ 0xFFFFFFFF
  return SIG .. IHDR .. plte .. IDAT_HEAD .. IDAT_PREFIX .. table.concat(rows) .. adler .. be32(cr) .. IEND
end

return Frame
