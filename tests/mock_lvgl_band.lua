-- Stand-in for the Band 10 `lvgl` module (luavgl on LVGL 9.1 with the VG-Lite GPU), built from the
-- firmware 3.1.33 code paths that RedBand uses:
--  * img:set_src(s) / img:set{src=s}: luavgl passes the Lua string's bytes (lua_tolstring) to
--    lv_image_set_src. First byte < 0x20: an lv_image_dsc_t in memory -> only its ADDRESS is kept
--    (read back with peek() when used, never through a Lua reference); 0x20..0x7F: a file path
--    (copied, like lv_strdup). A get_info failure keeps the old source, like LVGL.
--  * refresh(): what drawing does. Indexed images go through the VG-Lite decoder: descriptor and
--    pixels are read from raw memory, converted, and the result is put in the image cache under the
--    source ADDRESS (or path). A later draw of the same address is served from the cache even if
--    the memory now holds something else -- exactly how a stale frame would appear on the band.
--    Cache: 6 MB, least recently used out first (lv_nuttx_image_cache, 0x600000 in the firmware).
-- Needs the bandhost test host (peek, srcptr).
local L = { objects = {}, timers = {}, images = {}, srcSets = 0, decodes = 0, cacheHits = 0, problems = {} }
L.OPA = function(n) return n end
L.FLAG = { SCROLLABLE = 1, EVENT_BUBBLE = 2, CLICKABLE = 4, GESTURE_BUBBLE = 8, HIDDEN = 16 }
L.EVENT = { PRESSED = 1, PRESSING = 2, RELEASED = 3, PRESS_LOST = 4, CLICKED = 5, SHORT_CLICKED = 6, LONG_PRESSED = 7, ALL = 0 }
L.ALIGN = { CENTER = 9 }
L.IMG_ZOOM_NONE = 256
local PTR = HOST_PTR_BYTES or 8
local DESC = '<BBHHHHHI4' .. (PTR == 4 and 'I4' or 'I8')
local CACHE_MAX = 6 * 1024 * 1024
function L.setCacheMax(n) CACHE_MAX = n end
local cache, cacheBytes, useClock = {}, 0, 0
local function problem(msg) L.problems[#L.problems + 1] = msg end

local function read_desc(addr)
  local raw = peek(addr, string.packsize(DESC))
  local magic, cf, flags, w, h, stride, _, size, data = string.unpack(DESC, raw)
  return { magic = magic, cf = cf, flags = flags, w = w, h = h, stride = stride, size = size, data = data }
end
local function read_file_header(path)
  local f = io.open(path, 'rb'); if not f then return nil end
  local raw = f:read(12); f:close()
  if not raw or #raw < 12 then return nil end
  local magic, cf, flags, w, h, stride = string.unpack('<BBHHHH', raw)
  return { magic = magic, cf = cf, flags = flags, w = w, h = h, stride = stride }
end
local PALN = { [0x08] = 4, [0x0A] = 256 }

local Obj = {}; Obj.__index = Obj
function Obj:set_src(src)
  assert(type(src) == 'string', 'img src must be a string')
  local b = src:byte(1)
  if b < 0x20 then
    local addr = srcptr(src)
    local hd = read_desc(addr)
    if hd.magic ~= 0x19 or not PALN[hd.cf] then problem('bad descriptor') return end
    self.srcType, self.srcKey, self.hd = 'var', addr, hd
  elseif b < 0x80 then
    local hd = read_file_header(src)
    if not hd or hd.magic ~= 0x19 then problem('cannot read image file ' .. src) return end
    self.srcType, self.srcKey, self.hd = 'file', src, hd
  else problem('symbol source') return end
  L.srcSets = L.srcSets + 1
  self.srcCount = (self.srcCount or 0) + 1
end
function Obj:set(p)
  for k, v in pairs(p) do
    if k == 'src' then self:set_src(v) else self.props[k] = v end
  end
end
function Obj:add_flag(f) self.flags[f] = true end
function Obj:clear_flag(f) self.flags[f] = nil end
function Obj:onevent(code, cb) self.handlers[code] = cb end
function Obj:get_img_size()
  if self.srcType == 'var' then local hd = read_desc(self.srcKey) return hd.w, hd.h end
  if self.srcType == 'file' then local hd = read_file_header(self.srcKey) if hd then return hd.w, hd.h end end
  return nil, nil
end
local function make(kind, parent, props)
  local o = setmetatable({ kind = kind, parent = parent, props = {}, flags = {}, handlers = {} }, Obj)
  L.objects[#L.objects + 1] = o
  if kind == 'Image' then L.images[#L.images + 1] = o end
  if props then o:set(props) end
  return o
end
function L.Object(p, props) return make('Object', p, props) end
function L.Label(p, props) return make('Label', p, props) end
function L.Image(p, props) return make('Image', p, props) end
function L.Font(name, size, style) return { name = name, size = size } end
function L.Timer(p)
  local t = { period = p.period, cb = p.cb, paused = false }
  function t:pause() self.paused = true end
  function t:resume() self.paused = false end
  L.timers[#L.timers + 1] = t
  return t
end
L.indev = { get_act = function() return { get_point = function() return L.px or 0, L.py or 0 end } end }
function L.fire(o, code) local h = o.handlers[code]; if h then h(o, code) end end
local function visible(o)
  while o do if o.flags[L.FLAG.HIDDEN] then return false end o = o.parent end
  return true
end

-- decode like the VG-Lite decoder (indexed -> I8 draw buffer, cached under the source key)
local function decode(o)
  local hd, data
  if o.srcType == 'var' then
    hd = read_desc(o.srcKey)                       -- the descriptor is read again from memory
    if hd.magic ~= 0x19 then problem('descriptor memory released or overwritten') return nil end
    data = peek(hd.data, hd.size)
  else
    local f = io.open(o.srcKey, 'rb')
    if not f then problem('image file gone: ' .. o.srcKey) return nil end
    local all = f:read('a'); f:close()
    hd = read_file_header(o.srcKey); data = all:sub(13)
  end
  local pn = PALN[hd.cf]
  if #data < pn * 4 + hd.stride * hd.h then problem('image data too short') return nil end
  if o.srcType == 'var' then       -- frames are opaque: a non-255 alpha means released memory
    for i = 0, 3 do if data:byte(i * 4 + 4) ~= 255 then problem('palette alpha not 255 (released memory?)') break end end
  end
  L.decodes = L.decodes + 1
  local size = 1024 + ((hd.w + 63) & ~63) * hd.h
  return { cf = hd.cf, w = hd.w, h = hd.h, stride = hd.stride, pal = pn * 4, data = data, size = size }
end
local function cache_get(key)
  local e = cache[key]
  if e then useClock = useClock + 1; e.use = useClock end
  return e
end
local function cache_put(key, e)
  while cacheBytes + e.size > CACHE_MAX do
    local victim, old = nil, math.huge
    for k, v in pairs(cache) do if v.use < old then old = v.use victim = k end end
    if not victim then break end
    cacheBytes = cacheBytes - cache[victim].size; cache[victim] = nil
  end
  useClock = useClock + 1; e.use = useClock
  cache[key] = e; cacheBytes = cacheBytes + e.size
end
-- one LVGL refresh of every visible image; returns the image objects drawn
function L.refresh()
  local drawn = {}
  for _, o in ipairs(L.images) do
    if o.srcType and visible(o) then
      local key = o.srcType .. ':' .. tostring(o.srcKey)
      local e = cache_get(key)
      if e then L.cacheHits = L.cacheHits + 1
      else e = decode(o); if e and CACHE_MAX > 0 then cache_put(key, e) end end
      o.shown = e
      drawn[#drawn + 1] = o
    end
  end
  return drawn
end
-- pixel (x, y) of what an image shows: palette entry as B,G,R
function L.pixel(e, x, y)
  local off = e.pal + y * e.stride
  local idx
  if e.cf == 0x08 then idx = (e.data:byte(off + (x >> 2) + 1) >> (6 - 2 * (x & 3))) & 3
  else idx = e.data:byte(off + x + 1) end
  local p = idx * 4
  return e.data:byte(p + 1), e.data:byte(p + 2), e.data:byte(p + 3)
end
function L.cacheStats() local n = 0 for _ in pairs(cache) do n = n + 1 end return n, cacheBytes end
return L
