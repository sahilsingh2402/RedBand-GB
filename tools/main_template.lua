-- RedBand GB 4.6.0 -- Game Boy emulator watchface for Xiaomi Smart Band 10 (Vela/NuttX, Lua 5.4.0,
-- LVGL 9.1 with the VG-Lite GPU).
--
-- Architecture (4.0.0, from the band's firmware 3.1.33):
--  * Display: no files. Each shown frame is ONE Lua string (palette + pixels) handed to the image
--    widget as an in-memory LVGL image descriptor (luavgl passes a string's bytes straight to
--    lv_image_set_src; a first byte < 0x20 means "lv_image_dsc_t"). The pixels are INDEXED
--    (I2 / I8): LVGL's VG-Lite decoder copies them with the CPU into its own aligned buffer, cleans
--    the cache and the GPU expands the palette. Lua never converts pixels to colours.
--  * Views: BIG = crisp 212x189 (I8, exact 53/40 x 21/16 mapping), SMOOTH = 160x144 I2 scaled by
--    the GPU (bilinear), FAST = 160x144 I2 at 1:1. Long-press the screen to cycle.
--  * Pacing: game frames run on a real-time clock (os.clock = microseconds since boot on NuttX),
--    independent of how fast the screen can be refreshed. Every shown frame advances the game by
--    exactly the same number of frames (2 = 30 shown fps); that number rises only if the band
--    falls behind real time and comes back down when there is room.
--  * Fallback: if the in-memory image cannot be used (or crashed once), frames go through one
--    indexed file per frame in /tmp (tmpfs). Long-press the LED to switch by hand.
local lvgl=require('lvgl')
local Core
local W,H=212,520
local VERSION='4.6.0'
local powered,visible,paused=false,true,false
local emu,errmsg=nil,nil
local down=0
local CONTROL_BITS={R=1,L=2,U=4,D=8,A=16,B=32,SELECT=64,START=128}
local CORE_NAMES={R='RIGHT',L='LEFT',U='UP',D='DOWN',A='A',B='B',SELECT='SELECT',START='START'}
local buttons={}
local clock=os.clock
local function asset_dir()
  local p=rawget(_G,'SCRIPT_PATH') or ''
  if p~='' and p:sub(-1)~='/' then p=p..'/' end
  return p
end

-- ===================================================================================
-- Settings (one small file): view, display path, probe state, diagnostics line
-- ===================================================================================
local CFG_FILES={'/data/redbandgb_cfg40.txt',asset_dir()..'redbandgb_cfg40.txt'}
local cfg={view='big',disp='auto',probe='',hud='0',enginecap='XL',memok='',ver=''}
for _,p in ipairs(CFG_FILES) do
  local f=io.open(p,'r')
  if f then
    for line in f:lines() do local k,v=line:match('^(%w+)=(%w*)$') if k and cfg[k]~=nil then cfg[k]=v end end
    f:close() break
  end
end
if cfg.view~='big' and cfg.view~='smooth' and cfg.view~='fast' then cfg.view='big' end
-- Settings written by an older build may hold a failure state from a crash of that build (the
-- display path stuck on files, a smaller engine): a new build starts clean, only the view stays.
local cfgFresh=false
if cfg.ver~=(VERSION:gsub('%.','')) then
  cfg.disp,cfg.probe,cfg.enginecap,cfg.ver='auto','','XL',(VERSION:gsub('%.',''))
  cfgFresh=true
end
local function save_cfg()
  local s='view='..cfg.view..'\ndisp='..cfg.disp..'\nprobe='..cfg.probe..'\nhud='..cfg.hud..'\nenginecap='..cfg.enginecap..'\nmemok='..cfg.memok..'\nver='..cfg.ver..'\n'
  for _,p in ipairs(CFG_FILES) do
    local f=io.open(p,'w')
    if f then f:write(s) f:close() return true end
  end
  return false
end
if cfgFresh then pcall(save_cfg) end

-- ===================================================================================
-- Look: grey body, dark bezel, 3D controls. No box shadows: this firmware's GPU unit has no
-- shadow support, so every shadow is drawn by the CPU (on each press and LED blink).
-- ===================================================================================
local C={
  bodyTop=0x4B4F55, bodyBot=0x2A2D31,
  grooveDark=0x1D1F22, grooveLight=0x5C6167,
  bezel=0x131517, screenOff=0x131517,
  padTop=0x80868F, padBot=0x5A5F67, padEdge=0xA4AAB2, padDownTop=0x41454B, padDownBot=0x5E636B,
  abTop=0xA3254F, abBot=0x590C2A, abEdge=0xC4466F, abDownTop=0x470A23, abDownBot=0x7C1A3F,
  pillTop=0x3D4147, pillBot=0x212327, pillEdge=0x575C63, pillDownTop=0x18191C, pillDownBot=0x2F3238,
  pillText=0xC2C7CD, hudText=0x9AA1A9,
  ledOnTop=0xFF6A5A, ledOnBot=0xC4100C, ledGlow=0xFF2A2A, ledOffTop=0x481313, ledOffBot=0x1E0505,
  slit=0x1A1C1F, slitBot=0x0D0E10,
  lcd=0x70B470, lcdEdge=0x508450, lcdInk=0x385030, panel=0x1B1D20, panelRow=0x2A2D32, warn=0xC4302B,
}
local function try_set(o,props)
  for k,v in pairs(props) do pcall(function() o:set({[k]=v}) end) end
end
local function shape(parent,x,y,w,h,color,rad)
  local o=lvgl.Object(parent,{x=x,y=y,w=w,h=h,bg_color=color,bg_opa=lvgl.OPA(100),radius=rad or 0,
    outline_width=0,border_width=0,pad_all=0})
  o:clear_flag(lvgl.FLAG.SCROLLABLE)
  return o
end
local function raised(o,top,bot,edge)
  try_set(o,{bg_grad_color=bot,bg_grad_dir=1,border_width=1,border_color=edge})
  try_set(o,{bg_color=top})
end
local function sunk(o,top,bot)
  try_set(o,{bg_color=top,bg_grad_color=bot})
end
local fonts={}
local function F(size)
  if fonts[size]==nil then
    local ok,f=pcall(lvgl.Font,'MiSans-Regular, montserrat',size,'normal')
    if not ok or not f then ok,f=pcall(lvgl.Font,'montserrat',size,'normal') end
    fonts[size]=(ok and f) or false
  end
  return fonts[size] or nil
end
local function caption(parent,text,w,h,size,color)
  local props={x=0,y=math.floor((h-size)/2)-1,w=w,h=size+4,text=text,text_color=color,bg_opa=0,border_width=0}
  local f=F(size)
  if f then props.text_font=f end
  local l=lvgl.Label(parent,props)
  try_set(l,{text_align=2})
  if lvgl.LABEL_CONST and lvgl.LABEL_CONST.LONG_CLIP then try_set(l,{long_mode=lvgl.LABEL_CONST.LONG_CLIP}) end
  return l
end

local root=lvgl.Object(nil,{x=0,y=0,w=W,h=H,bg_color=C.bodyTop,bg_opa=lvgl.OPA(100),border_width=0,pad_all=0})
root:clear_flag(lvgl.FLAG.SCROLLABLE)
root:add_flag(lvgl.FLAG.EVENT_BUBBLE)
try_set(root,{bg_grad_color=C.bodyBot,bg_grad_dir=1})

-- top cap: BROWSE and TURBO side by side; below: POWER, red LED, PAUSE
local browse_btn=shape(root,38,30,68,26,C.pillTop,13)
raised(browse_btn,C.pillTop,C.pillBot,C.pillEdge)
local browse_text=caption(browse_btn,'BROWSE',68,26,12,C.pillText)
browse_btn:add_flag(lvgl.FLAG.CLICKABLE)
local turbo_btn=shape(root,112,30,62,26,C.pillTop,13)
raised(turbo_btn,C.pillTop,C.pillBot,C.pillEdge)
caption(turbo_btn,'TURBO',62,26,12,C.pillText)
turbo_btn:add_flag(lvgl.FLAG.CLICKABLE)
local power_btn=shape(root,22,62,66,30,C.pillTop,15)
raised(power_btn,C.pillTop,C.pillBot,C.pillEdge)
caption(power_btn,'POWER',66,30,12,C.pillText)
power_btn:add_flag(lvgl.FLAG.CLICKABLE)
-- LED: a GPU-drawn glow disc behind it instead of a blurred shadow; the box around it is the
-- touch area (tap: diagnostics line on/off; long-press: display path auto/file)
local led_hit=shape(root,91,62,30,30,C.bodyTop,15)
try_set(led_hit,{bg_opa=0})
led_hit:add_flag(lvgl.FLAG.CLICKABLE)
local led_glow=shape(root,91,62,30,30,C.ledGlow,15)
try_set(led_glow,{bg_opa=lvgl.OPA(30)})
led_glow:add_flag(lvgl.FLAG.HIDDEN)
local led=shape(root,96,67,20,20,C.ledOffTop,10)
try_set(led,{bg_grad_color=C.ledOffBot,bg_grad_dir=1,border_width=1,border_color=0x140303})
local pause_btn=shape(root,124,62,66,30,C.pillTop,15)
raised(pause_btn,C.pillTop,C.pillBot,C.pillEdge)
local pause_text=caption(pause_btn,'PAUSE',66,30,12,C.pillText)
pause_btn:add_flag(lvgl.FLAG.CLICKABLE)

-- screen: the full watch width (212 px); dark bezel bands above and below
local bezel=shape(root,0,104,212,202,C.bezel,6)
local SCREEN_X,SCREEN_Y,SCREEN_W,SCREEN_H=0,110,212,189
local display_bg=shape(root,SCREEN_X,SCREEN_Y,SCREEN_W,SCREEN_H,C.screenOff,0)

local function control(name,x,y,w,h,rad,top,bot,edge,dtop,dbot,text,tsize,tcolor)
  local o=shape(root,x,y,w,h,top,rad)
  raised(o,top,bot,edge)
  o:add_flag(lvgl.FLAG.CLICKABLE)
  if text then caption(o,text,w,h,tsize,tcolor) end
  buttons[name]=o
  local bit=CONTROL_BITS[name] or 0
  o:onevent(lvgl.EVENT.PRESSED,function()
    pcall(function()
      down=down|bit
      if emu and not paused then emu.setButton(CORE_NAMES[name],true) end
      sunk(o,dtop,dbot)
    end)
  end)
  local function release()
    pcall(function()
      down=down&(~bit)
      if emu then emu.setButton(CORE_NAMES[name],false) end
      sunk(o,top,bot)
    end)
  end
  o:onevent(lvgl.EVENT.RELEASED,release)
  o:onevent(lvgl.EVENT.PRESS_LOST,release)
  return o
end
-- Controls keep away from the band's edges (a touch near a side edge starts a band gesture):
-- the D-pad is centred (a light-grey 3D cross, 116 px across, arms 42 px, centre (106,383)),
-- B sits top-left and A top-right of it, 20 px in from the sides, beside the up arm
local dcenter=shape(root,85,362,42,42,C.padBot,0)
try_set(dcenter,{bg_grad_color=C.padTop,bg_grad_dir=1})
control('U',85,325,42,37,8,C.padTop,C.padBot,C.padEdge,C.padDownTop,C.padDownBot)
control('D',85,404,42,37,8,C.padTop,C.padBot,C.padEdge,C.padDownTop,C.padDownBot)
control('L',48,362,37,42,8,C.padTop,C.padBot,C.padEdge,C.padDownTop,C.padDownBot)
control('R',127,362,37,42,8,C.padTop,C.padBot,C.padEdge,C.padDownTop,C.padDownBot)
-- A / B: 44 px berry buttons, no letters
control('B',20,312,44,44,22,C.abTop,C.abBot,C.abEdge,C.abDownTop,C.abDownBot)
control('A',148,312,44,44,22,C.abTop,C.abBot,C.abEdge,C.abDownTop,C.abDownBot)
control('SELECT',36,452,66,28,14,C.pillTop,C.pillBot,C.pillEdge,C.pillDownTop,C.pillDownBot,'SELECT',12,C.pillText)
control('START',110,452,66,28,14,C.pillTop,C.pillBot,C.pillEdge,C.pillDownTop,C.pillDownBot,'START',12,C.pillText)
local slits={}
for i=0,5 do
  local sl=shape(root,82+i*9,490,5,16,C.slit,2)
  try_set(sl,{bg_grad_color=C.slitBot,bg_grad_dir=1})
  slits[#slits+1]=sl
end
-- (4.2.0: no diagnostics text on the face; the numbers stay in RBGB40.stats for testing)
local hudOn=false
local function hud_show(on) end

-- LED: blinks while the game runs, fast in TURBO, glows while paused, dark when off
local ledOn=false
local function led_set(on)
  if on==ledOn then return end
  ledOn=on
  if on then
    try_set(led,{bg_color=C.ledOnTop,bg_grad_color=C.ledOnBot})
    pcall(function() led_glow:clear_flag(lvgl.FLAG.HIDDEN) end)
  else
    try_set(led,{bg_color=C.ledOffTop,bg_grad_color=C.ledOffBot})
    pcall(function() led_glow:add_flag(lvgl.FLAG.HIDDEN) end)
  end
end
local turbo=false
local ledPhase=0
local ledTimer=lvgl.Timer({period=250,cb=function()
  pcall(function()
    ledPhase=ledPhase+1
    if powered and not paused then
      if turbo or ledPhase%2==0 then led_set(not ledOn) end
    elseif powered and paused then led_set(true)
    else led_set(false) end
  end)
end})

-- ===================================================================================
-- Emulator core: gbcore.lua next to main.lua, loaded only at POWER
-- ===================================================================================
-- System memory (NuttX /proc/meminfo; the watchface's Lua heap is the shared user heap "Umem"):
-- returns free and largest free block in KB, or nil if it cannot be read
local MEMINFO=rawget(_G,'RBGB_MEMINFO') or '/proc/meminfo'
local function meminfo()
  local f=io.open(MEMINFO,'r')
  if not f then return nil end
  local txt=f:read('a') f:close()
  if not txt then return nil end
  local head,best
  for line in txt:gmatch('[^\n]+') do
    local words={}
    for w in line:gmatch('%S+') do words[#words+1]=w end
    if not head and line:find('free') and not line:find('%d') then head=words
    elseif head then
      local nums,name={},nil
      for _,w in ipairs(words) do local n=tonumber(w) if n then nums[#nums+1]=n else name=w:gsub(':','') end end
      if #nums>=3 then
        local row={name=name}
        for i,h in ipairs(head) do row[h]=nums[i] end
        if row.free and (name=='Umem' or (not best and name~='Kmem')) then best=row end
      end
    end
  end
  if not best then return nil end
  return best.free//1024,(best.maxfree or best.largest or best.free)//1024
end

-- Emulation engine: three sizes, the larger ones compile more of the game into Lua functions
-- (walking: L -21%, XL -30% emulation time) and need more memory. Precompiled 5.4.0 bytecode
-- loads ~10x faster and uses ~20% less memory than source; source is the fallback.
-- SAFE (the default, every POWER): XL from 6 MB free, L from 4 MB. FAST ("UNSAFE" button while
-- playing): XL from 3 MB, L from 1.8 MB, like 4.4.0-4.5.0 which moved fastest.
local CORES={{tier='XL',file='gbcore_xl.luac',needKB=6144,fastKB=3072},{tier='L',file='gbcore_l.luac',needKB=4096,fastKB=1800},
  {tier='S',file='gbcore_s.luac',needKB=0,fastKB=0},{tier='S',file='gbcore.lua',needKB=0,fastKB=0}}
local coreTier,coreForm='?',''
local fastMode=false
local function load_chunk(path)
  local chunk
  if loadfile then chunk=loadfile(path) end
  if not chunk then
    local f=io.open(path,'rb')
    if not f then return nil end
    local src=f:read('a') f:close()
    chunk=load(src,'=gbcore')
  end
  return chunk
end
local function load_tier(tier)
  for _,c in ipairs(CORES) do
    if c.tier==tier then
      local chunk=load_chunk(asset_dir()..c.file)
      if chunk then
        local ok,M=pcall(chunk)
        if ok and type(M)=='table' and M.create then
          coreTier=c.tier coreForm=c.file:match('%.luac$') and 'b' or 's'
          return M
        end
      end
    end
  end
  return nil
end
-- the engine size this mode wants with this much free memory (free KB counted with the
-- current engine already loaded: it is given back when the engine changes)
local function tier_for(free,fast)
  for _,c in ipairs(CORES) do
    if (free or 0)>=(fast and c.fastKB or c.needKB) then return c.tier end
  end
  return 'S'
end
local function create_core_module()
  local free=meminfo()
  local forced=rawget(_G,'RBGB_CORE')
  -- only after the band really ran out of memory (3 times in a minute) is a smaller engine
  -- remembered for the next POWER
  local capRank=({XL=1,L=2,S=3})[cfg.enginecap or 'XL'] or 1
  for rank,c in ipairs(CORES) do
    local allowed=(rank>=capRank) or c.tier=='S'
    if (forced and c.tier==forced) or (not forced and allowed and (free or 0)>=c.needKB) or c.needKB==0 then
      local chunk=load_chunk(asset_dir()..c.file)
      if chunk then
        local ok,M=pcall(chunk)
        if ok and type(M)=='table' and M.create then
          coreTier=c.tier coreForm=c.file:match('%.luac$') and 'b' or 's'
          return M
        end
      end
    end
  end
  error('gbcore missing')
end
-- ===================================================================================
-- Presenter
-- ===================================================================================
local Pr,VIEWS,VIEW_ORDER
do
local char,unpack,concat=string.char,table.unpack,table.concat
-- the original screen colours, lightest..darkest, as B,G,R
local SHADE={{0xD0,0xF8,0xE0},{0x70,0xC0,0x88},{0x56,0x68,0x34},{0x20,0x18,0x08}}
local CF_I2,CF_I8=0x08,0x0A
VIEWS={
  big   ={x=0, y=110,w=212,h=189,zoom=256,cf=CF_I8,stride=212,tag='8'},
  smooth={x=26,y=133,w=160,h=144,zoom=338,cf=CF_I2,stride=40, tag='2z'},
  fast  ={x=26,y=132,w=160,h=144,zoom=256,cf=CF_I2,stride=40, tag='2'},
}
VIEW_ORDER={big='smooth',smooth='fast',fast='big'}
Pr={mode=nil,view=cfg.view,shown=0,rowsBuilt=0,rowsReused=0,why='',bytes=0}
local img
-- the pixel string on screen is always referenced (LVGL reads it when it draws, after this
-- callback); an older one is never read again, its decoded copy lives in LVGL's cache
local curData=nil
-- descriptors: LVGL caches each decoded frame under the descriptor's address (6 MB cache, at
-- most ~220 of our frames). Keeping the last 2048 descriptors alive means an address can only be
-- reused long after its cache entry is gone, so a stale frame can never be shown.
local RING_N=2048
local ring,ringI={},0
local HDR,DFMT=nil,nil
local PAD48=string.rep('\0',48)
local lastData,lastBgp,force=nil,-1,true
local fileCur,fileSeq=nil,0
local session=tostring((os.time and os.time() or 0)%100000)..'_'..tostring(math.random(1000,9999))
local FRAME_DIR='/tmp/'

-- offset of a long string's bytes from its address (Lua 5.4 TString), measured from the exact
-- heap byte counter: one concatenation allocates exactly one string object
local function string_header()
  if not pcall(string.format,'%p','x') then return nil,'no %p' end
  local ptr=string.packsize('T')
  if ptr~=4 and ptr~=8 then return nil,'size_t '..ptr end
  local a,b=string.rep('a',600),string.rep('b',700)
  local suf={}
  for i=1,6 do suf[i]=string.rep(char(64+i),50) end
  local running=collectgarbage('isrunning')
  collectgarbage('stop')
  local res,keep={},{}
  for i=1,6 do
    local c0=collectgarbage('count')
    local s=a..suf[i]..b
    local c1=collectgarbage('count')
    res[i]=math.floor((c1-c0)*1024+0.5)-(#s+1)
    keep[i]=s
  end
  if running then collectgarbage('restart') end
  local cnt,best,bn={},nil,0
  for i=1,6 do cnt[res[i]]=(cnt[res[i]] or 0)+1 end
  for v,n in pairs(cnt) do if n>bn then best,bn=v,n end end
  if bn<4 or best~=8+2*ptr then return nil,'header '..tostring(best) end
  return best,ptr
end
local function addr_of(s)
  local p=string.format('%p',s)
  local hex=p:match('^%s*0[xX](%x+)%s*$') or p:match('^%s*(%x+)%s*$')
  return hex and tonumber(hex,16) or nil
end
local function descriptor(cf,w,h,stride,addr,size)
  local d=string.pack(DFMT,0x19,cf,0,w,h,stride,0,size,addr)
  return d..PAD48:sub(1,48-#d)   -- 48 bytes: a long string, never shared with another
end

-- palettes: I2 = 4 entries, I8 = 256 entries (only 0..3 used); entry = B,G,R,A
local palCache,palOrder={},{}
local function palette(bgp)
  local p=palCache[bgp]
  if p then return p end
  if #palOrder>=4 then palCache[table.remove(palOrder,1)]=nil end
  local n={}
  for cn=0,3 do
    local c=SHADE[((bgp>>(cn*2))&3)+1]
    n[#n+1]=c[1] n[#n+1]=c[2] n[#n+1]=c[3] n[#n+1]=255
  end
  local s4=char(unpack(n))
  p={n=n,i8=s4..string.rep('\0',1008)}
  palCache[bgp]=p palOrder[#palOrder+1]=bgp
  return p
end

-- I2 160x144: palette + the core's packed framebuffer bytes, as they are (pixel 0 = bits 7-6)
local function data_i2(fb,pal)
  local n=pal.n
  return char(n[1],n[2],n[3],n[4],n[5],n[6],n[7],n[8],n[9],n[10],n[11],n[12],n[13],n[14],n[15],n[16],
    unpack(fb,1,5760))
end

-- I8 212x189 (crisp BIG): every framebuffer byte (4 pixels) becomes a run of 5 or 6 index
-- bytes; 10 bytes -> 53 pixels (53/40), rows repeated 21/16. Rows are cached by content: while
-- walking ~80% of rows are rows seen before (same place or scrolled).
local RUNS={{0,0,1,2,3,3},{0,1,2,2,3},{0,1,1,2,3},{0,0,1,2,3}}
local TB={}
for r=1,4 do
  TB[r]={}
  for b=0,255 do
    local t={}
    for j,q in ipairs(RUNS[r]) do t[j]=char((b>>(6-2*q))&3) end
    TB[r][b+1]=concat(t)
  end
end
local T1,T2,T3,T4=TB[1],TB[2],TB[3],TB[4]
local PC={}
local function build_row(fb,i)
  for o=0,30,10 do
    PC[o+1]=T1[fb[i]+1] PC[o+2]=T2[fb[i+1]+1] PC[o+3]=T3[fb[i+2]+1]
    PC[o+4]=T1[fb[i+3]+1] PC[o+5]=T2[fb[i+4]+1] PC[o+6]=T3[fb[i+5]+1]
    PC[o+7]=T1[fb[i+6]+1] PC[o+8]=T2[fb[i+7]+1] PC[o+9]=T3[fb[i+8]+1]
    PC[o+10]=T4[fb[i+9]+1]
    i=i+10
  end
  return concat(PC,'',1,40)
end
local RC_CAP=96
local rcNew,rcOld,rcN={},{},0
local KEYS,ROWS,PARTS={},{},{}
local YMAP={}
for r=0,188 do YMAP[r+1]=(r*16)//21+1 end
local function data_i8(fb,pal,bgp)
  local changed=force or bgp~=lastBgp
  for y=1,144 do
    local i=y*40-39
    local k=char(unpack(fb,i,i+39))
    if k~=KEYS[y] then
      KEYS[y]=k
      local v=rcNew[k]
      if not v then
        v=rcOld[k]
        if v then Pr.rowsReused=Pr.rowsReused+1 else v=build_row(fb,i) Pr.rowsBuilt=Pr.rowsBuilt+1 end
        rcNew[k]=v rcN=rcN+1
        if rcN>=RC_CAP then rcOld=rcNew rcNew={} rcN=0 end
      else Pr.rowsReused=Pr.rowsReused+1 end
      ROWS[y]=v
      changed=true
    end
  end
  if not changed then return nil end
  PARTS[1]=pal.i8
  for r=1,189 do PARTS[r+1]=ROWS[YMAP[r]] end
  return concat(PARTS,'',1,190)
end

local function img_set_src(src)
  if img.set_src then img:set_src(src) else img:set({src=src}) end
end
local function apply_geometry()
  if not img then return end
  local v=VIEWS[Pr.view]
  if Pr.mode=='file' and v.cf==CF_I8 then v=VIEWS.smooth end
  pcall(function() img:set({x=v.x,y=v.y,w=v.w,h=v.h}) end)
  pcall(function() img:set({zoom=v.zoom}) end)
end
function Pr.ensure_image()
  if img then return end
  local v=VIEWS[Pr.view]
  img=lvgl.Image(root,{x=v.x,y=v.y,w=v.w,h=v.h,pad_all=0})
  img:add_flag(lvgl.FLAG.HIDDEN)
  img:clear_flag(lvgl.FLAG.CLICKABLE)
  apply_geometry()
end
local shownOnce=false
function Pr.hide(h)
  if not img then return end
  pcall(function() if h then img:add_flag(lvgl.FLAG.HIDDEN) else img:clear_flag(lvgl.FLAG.HIDDEN) end end)
end
function Pr.setView(v)
  if not VIEWS[v] then return end
  Pr.view=v force=true lastData=nil
  for y=1,144 do KEYS[y]=nil end
  apply_geometry()
end
function Pr.invalidate() force=true end
-- choose the display path; returns the path name
function Pr.init()
  Pr.ensure_image()
  local why
  -- the memory path is left only by hand (LED long-press), or if three sessions in a row ended
  -- abruptly during their first frames on a band where it never worked (memok)
  local abrupt=tonumber((cfg.probe or ''):match('^p(%d)$') or '0')
  if cfg.probe=='pending' then abrupt=1 end
  if cfg.disp=='file' or Pr.forceFile then Pr.mode='file' why='set to file'
  elseif cfg.memok~='1' and (abrupt>=3 or cfg.probe=='failed') then
    Pr.mode='file' why='memory path stopped 3 times'
  else
    -- the string layout never changes while the watchface runs: measure once, reuse after
    local hdr,ptr=HDR,(DFMT and (DFMT:sub(-1)=='4' and 4 or 8)) or nil
    if not hdr then
      collectgarbage('collect')
      hdr,ptr=string_header()
      if not hdr then collectgarbage('collect') hdr,ptr=string_header() end
    end
    if hdr and not addr_of(PAD48..PAD48) then hdr,ptr=nil,'pointer format '..string.format('%p',PAD48) end
    if not hdr then Pr.mode='file' why=ptr
    else
      HDR=hdr
      DFMT='<BBHHHHHI4'..((ptr==4) and 'I4' or 'I8')
      -- the binding must hand LVGL the string itself: check that LVGL reads our header
      local data=char(255,255,255,255,0,0,0,255,255,255,255,255,0,0,0,255)..string.rep('\27',32)   -- 16x8, long string
      local d=descriptor(CF_I2,16,8,4,addr_of(data)+HDR,#data)
      local ok,w,h=pcall(function() img_set_src(d) if img.get_img_size then return img:get_img_size() end return 16,8 end)
      ringI=ringI%RING_N+1 ring[ringI]=d curData=data   -- same ring: no descriptor is dropped early
      if ok and w==16 and h==8 then
        Pr.mode='direct' why='ok'
        if cfg.probe~='ok' then cfg.probe='p'..(abrupt+1) save_cfg() end
      else Pr.mode='file' why='image size '..tostring(w)..'x'..tostring(h) end
    end
  end
  Pr.why=why or ''
  apply_geometry()
  force=true lastData=nil shownOnce=false
  for y=1,144 do KEYS[y]=nil end
  return Pr.mode
end
-- the first drawn frames prove the memory path (a fault would happen at the first draw)
local confirmAt=20
-- show one frame; returns true if the screen was given a new picture
function Pr.present(fb,bgp)
  local v=VIEWS[Pr.view]
  if Pr.mode=='file' and v.cf==CF_I8 then v=VIEWS.smooth end
  local pal=palette(bgp)
  local data
  if v.cf==CF_I8 then
    data=data_i8(fb,pal,bgp)
    if not data then return false end
  else
    data=data_i2(fb,pal)
    if not force and data==lastData then return false end
  end
  force=false lastData=data lastBgp=bgp
  if Pr.mode=='direct' then
    local d=descriptor(v.cf,v.w,v.h,v.stride,addr_of(data)+HDR,#data)
    ringI=ringI%RING_N+1
    ring[ringI]=d
    -- the image gets the new frame first; only then does the old one stop being referenced
    -- (if handing it over failed, the image still shows the old frame, which is still alive)
    img_set_src(d)
    curData=data
  else
    fileSeq=fileSeq+1
    local path=FRAME_DIR..'rbgb_'..session..'_'..fileSeq..'.bin'
    local f=io.open(path,'wb')
    if not f then error('cannot write '..path) end
    local ok=f:write(string.pack('<BBHHHHH',0x19,v.cf,0,v.w,v.h,v.stride,0),data)
    f:close()
    if not ok then os.remove(path) error('cannot write '..path) end
    img_set_src(path)
    curData=data
    if fileCur then os.remove(fileCur) end
    fileCur=path
  end
  Pr.bytes=#data
  if not shownOnce then shownOnce=true Pr.hide(false) end
  Pr.shown=Pr.shown+1
  if Pr.mode=='direct' and cfg.probe~='ok' then
    confirmAt=confirmAt-1
    if confirmAt<=0 then cfg.probe='ok' cfg.memok='1' save_cfg() end
  end
  return true
end
-- power off: hide first (a hidden image is never drawn), then let the pixels go
function Pr.release()
  Pr.hide(true)
  shownOnce=false
  if fileCur then os.remove(fileCur) fileCur=nil end
  curData,lastData=nil,nil
  rcNew,rcOld,rcN={},{},0
  for y=1,144 do KEYS[y]=nil ROWS[y]=nil end
  for r=1,190 do PARTS[r]=nil end
end
function Pr.shrink()
  RC_CAP=math.max(16,RC_CAP//2)
  rcNew,rcOld,rcN={},{},0
  force=true
end
function Pr.tag()
  return ((Pr.mode=='direct') and 'M' or 'F')..VIEWS[Pr.view].tag
end
function Pr.image() return img end
function Pr.current() return curData end
function Pr.ringInfo() return ring,ringI,RING_N end
function Pr.setRcCap(n) RC_CAP=n end
end

-- ===================================================================================
-- ROM: 64 files gbank00.dat .. gbank63.dat (on the band's NAND), packed banks in an LRU.
-- Battles use many banks (35 distinct in a play session); with 12 slots the cache thrashed
-- (~700 loads during 8 battles, each a NAND read plus a new 32 KB table: tens of MB of garbage
-- that made the Lua heap balloon). 4.4.0: 14 / 24 / 32 slots for the S / L / XL engine
-- (32: 19 loads in the same battles), and an evicted bank's table is refilled in place, so a
-- bank load makes no garbage at all.
-- ===================================================================================
local BANK_CACHE=14
local bankCache,bankAge,bankCount,ageClock={},{},0,0
local bankLoads=0
local spare=nil
local romf
local function bank_file(n) return asset_dir()..string.format('gbank%02d.dat',n) end
local function read_bank_string(n)
  local f=io.open(bank_file(n),'rb')
  if f then local s=f:read('a') f:close() return s end
  if not romf then return nil end
  romf:seek('set',n*16384)
  return romf:read(16384)
end
local function open_rom()
  local s=read_bank_string(0)
  if not s then
    for _,name in ipairs({asset_dir()..'pokemon_red.gb',asset_dir()..'pokemon_red.rom'}) do
      romf=io.open(name,'rb') if romf then break end
    end
    s=read_bank_string(0)
  end
  return s and #s==16384 and s:sub(0x135,0x13F)=='POKEMON RED'
end
local function evict_oldest()
  local victim,oldest=nil,math.huge
  for k,age in pairs(bankAge) do if age<oldest then oldest=age victim=k end end
  if victim then spare=bankCache[victim] bankCache[victim]=nil bankAge[victim]=nil bankCount=bankCount-1 end
end
local function evict_all_but(keep)
  for k in pairs(bankCache) do if k~=keep then bankCache[k]=nil bankAge[k]=nil end end
  bankCount=bankCache[keep] and 1 or 0
  spare=nil
end
-- the core's packed format: 8 ROM bytes per integer with 64-bit Lua integers (4 with 32-bit);
-- written straight into an existing table, 8 words per string.unpack, no temporary tables
local WIDE=math.maxinteger>0x7FFFFFFF
local WFMT=WIDE and '<i8i8i8i8i8i8i8i8' or '<i4i4i4i4i4i4i4i4'
local WSTEP=WIDE and 64 or 32
local packInPlace=true                    -- checked against Core.packBank at POWER
local function pack_into(t,s)
  if #s<16384 then s=s..string.rep('\255',16384-#s) end
  local up,k=string.unpack,1
  for pos=1,16384,WSTEP do
    t[k],t[k+1],t[k+2],t[k+3],t[k+4],t[k+5],t[k+6],t[k+7]=up(WFMT,s,pos)
    k=k+8
  end
  return t
end
local function load_bank(n)
  local s=read_bank_string(n)
  if not s or #s~=16384 then error('ROM bank '..n..' unreadable') end
  if packInPlace then
    local t=spare or {}
    spare=nil
    return pack_into(t,s)
  end
  return Core.packBank(s)
end
-- a bank load is the one allocation inside a game frame: if memory is short, everything else
-- in the bank cache goes and the load is retried, so the core never sees the failure
local function get_bank(n)
  ageClock=ageClock+1
  local t=bankCache[n]
  if t then bankAge[n]=ageClock return t end
  if n~=0 and bankCount>=BANK_CACHE then evict_oldest() end
  local ok,res=pcall(load_bank,n)
  if not ok then
    evict_all_but(-1)
    collectgarbage('collect')
    res=load_bank(n)
  end
  t=res
  bankLoads=bankLoads+1
  if n~=0 then
    bankCache[n]=t bankAge[n]=ageClock bankCount=bankCount+1
  end
  return t
end

-- ===================================================================================
-- Battery save. Pokemon writes its save over several frames and its checksum last ("SAVING...
-- Don't turn off the power"). Up to 4.3.0 the file was written as soon as the first byte
-- changed, i.e. often in the middle of that save, and with 'wb' (the old file is gone the
-- moment it is opened): a crash before the next write left "The file data is destroyed!".
-- 4.4.0:
--  * a save is written only when the game's own checksum is valid and the battery RAM has not
--    changed for 1 s (the game's save has finished);
--  * written to <name>.tmp, read back and compared, then the old save becomes <name>.bak and
--    the new one takes its place (rename): a crash at any point leaves a good file;
--  * loading takes the newest file with a valid checksum: save, then .tmp, then .bak.
-- ===================================================================================
local SAVE_CANDIDATES={'/data/redbandgb_red.sav',asset_dir()..'pokemon_red.sav'}
-- Pokemon Red: main data A598-B522 in SRAM bank 1 (file 0x2598-0x3522), checksum at B523 =
-- complement of the 8-bit sum
local function sav_valid(s)
  if type(s)~='string' or #s~=32768 then return false end
  local sum,byte=0,string.byte
  for i=0x2599,0x3523,64 do
    local j=i+63 if j>0x3523 then j=0x3523 end
    local t={byte(s,i,j)}
    for k=1,#t do sum=sum+t[k] end
  end
  return ((~sum)&255)==byte(s,0x3524)
end
local function read_file(p)
  local f=io.open(p,'rb')
  if not f then return nil end
  local s=f:read('a') f:close()
  return s
end
local savedFrom=nil
local diskSram=nil                         -- what the save file holds now
local function load_sram()
  local fallback=nil
  for _,p in ipairs(SAVE_CANDIDATES) do
    for _,q in ipairs({p,p..'.tmp',p..'.bak'}) do
      local s=read_file(q)
      if sav_valid(s) then savedFrom=q diskSram=s return s end
      if not fallback and s and #s==32768 and q==p then fallback=s end
    end
  end
  savedFrom=fallback and 'raw' or nil
  return fallback                         -- a save the game never finished (or a new game)
end
local function write_atomic(p,data)
  local tmp=p..'.tmp'
  local f=io.open(tmp,'wb')
  if not f then return false end
  local ok=f:write(data)
  f:close()
  if not ok or read_file(tmp)~=data then os.remove(tmp) return false end
  local cur=read_file(p)
  if cur and sav_valid(cur) then os.remove(p..'.bak') os.rename(p,p..'.bak') end
  if not os.rename(tmp,p) then os.remove(p) if not os.rename(tmp,p) then return false end end
  return true
end
local lastSram,lastSramAt=nil,0
local saveWrites=0
-- final: on pause / screen off / power off (no waiting, but still only a finished save)
local function save_ram(final)
  if not emu or not emu.sramDirty() then return true end
  local data=emu.getSRAM()
  assert(#data==32768,'battery save must be 32 KB')
  -- Pokemon also uses its battery RAM as scratch space: every battle / menu sprite is
  -- decompressed into SRAM bank 0 (file bytes 0x0000-0x0597). That is not a save. Only the
  -- save itself (from 0x0598: Hall of Fame, main data, boxes) decides whether there is
  -- anything to write, so the file is written only after the player saves in the game.
  if diskSram and data:sub(0x599)==diskSram:sub(0x599) then emu.markSRAMSaved() lastSram=nil return true end
  local now=clock()
  local settled=final or (data==lastSram and now-lastSramAt>=1)
  if data~=lastSram then lastSram,lastSramAt=data,now end
  if not settled then return false end
  -- only a finished game save is ever written (an unfinished or never-made save is not a save)
  if not sav_valid(data) then return false end
  for _,p in ipairs(SAVE_CANDIDATES) do
    if write_atomic(p,data) then emu.markSRAMSaved() lastSram=nil diskSram=data saveWrites=saveWrites+1 return true end
  end
  return false
end

-- ===================================================================================
-- Memory safety without a budget. Normal play is never limited: the collector gets the same
-- room as in 4.1.0 (pause up to 200% when the band has memory to spare). Safety is reactive:
--  * an allocation that really fails (Lua has already run an emergency collection by then) is
--    caught: the frame is skipped, the row cache and two ROM banks go, one full collection runs,
--    and play continues;
--  * a ROM bank load that fails empties the bank cache and retries;
--  * the band's own free memory (/proc/meminfo) is looked at only when the Lua heap has grown by
--    1 MB since the last look, or once a minute; if the band is really short (< 1 MB free), one
--    full collection runs and the collector is set to 110% until there is room again.
-- ===================================================================================
local snapshot,snapAt=nil,0
-- FAST mode falls back to SAFE by itself when memory gets short (done at the next callback)
local pendingSafe,set_mode,plan_caches,mode_button,coreSwaps=false,nil,nil,nil,0
local recoverPending,restore=false,nil       -- see recover()
local gcPause,sysFree,sysLargest=110,nil,nil
local MEM={events=0,lastLow=-100,lowNow=false,checkKB=0,checkAt=0,emergencies=0}
local lowMem=0
local function set_gc_pause()
  local ok,f,l=pcall(meminfo)
  if ok then sysFree,sysLargest=f,l end
  local p=110
  if sysFree then
    -- the heap may grow by at most 1.5 MB (and never into the last 4 MB the band has free);
    -- the collector overshoots its target by ~15% while a cycle runs
    local live=collectgarbage('count')
    local allow=fastMode and math.min(sysFree-3072,2560,live) or math.min(sysFree-4096,1536,live)
    p=100+math.floor(allow*100/math.max(live*1.15,1))
    if p<110 then p=110 elseif p>200 then p=200 end
  end
  gcPause=p
  pcall(collectgarbage,'incremental',p,200)
end
local low_memory
low_memory=function(now)
  now=now or clock()
  lowMem=lowMem+1
  if fastMode then pendingSafe=true end
  Pr.shrink()
  if BANK_CACHE>6 then BANK_CACHE=BANK_CACHE-2 end
  while bankCount>BANK_CACHE do evict_oldest() end
  snapshot=nil
  collectgarbage('collect')
  if now-MEM.lastLow<60 then
    MEM.events=MEM.events+1
    if MEM.events>=3 and coreTier~='S' then
      local smaller=(coreTier=='XL') and 'L' or 'S'
      if cfg.enginecap~=smaller then cfg.enginecap=smaller pcall(save_cfg) end
    end
  else MEM.events=1 end
  MEM.lastLow=now
end
-- called once per second: one counter read; the band's figures only now and then
local function check_memory(now)
  local kb=collectgarbage('count')
  if kb<MEM.checkKB+512 and now<MEM.checkAt then return end
  MEM.checkKB=kb MEM.checkAt=now+30
  local ok,f,l=pcall(meminfo)
  if not ok or not f then return end
  sysFree,sysLargest=f,l
  if sysFree<2560 and fastMode then pendingSafe=true end
  if sysFree<2560 and now-MEM.lastLow>10 then
    -- the band is getting short: give back the bank cache and the row cache first
    if BANK_CACHE>8 then BANK_CACHE=8 end
    while bankCount>BANK_CACHE do evict_oldest() end
    spare=nil
    Pr.shrink()
    MEM.lastLow=now
  end
  if sysFree<1536 and not MEM.lowNow then
    MEM.lowNow=true MEM.emergencies=MEM.emergencies+1
    pcall(collectgarbage,'incremental',110,200)
    collectgarbage('collect')
    MEM.checkKB=collectgarbage('count')
  elseif MEM.lowNow and sysFree>3072 then
    MEM.lowNow=false
    pcall(collectgarbage,'incremental',gcPause,200)
  end
end

-- ===================================================================================
-- Scheduler
-- ===================================================================================
local GB_FPS=59.7275
local TIMER_PERIOD=8
local MAX_OWED,MAX_BATCH,BUDGET=3,3,0.034         -- backlog kept, frames per callback, seconds
local TURBO_SPEED,TURBO_OWED,TURBO_BATCH,TURBO_BUDGET,TURBO_P=4,8,6,0.060,8
local PMIN,PMAX=2,6                                -- shown frame every 2..6 game frames
local presentEvery=2
local owed,lastT,lastEnd,lastShown=0,nil,nil,false
local frameNo=0
local renderWanted=false
local pendingFB,pendingBGP=nil,nil
local lastFB,lastBGP=nil,nil
local estE=0.004
local clean,blockLowerUntil,trialUntil=0,0,0
local presentFails=0
-- Breathing room for the band. The game loop must never keep the UI thread busy all the time:
-- the band's own services (and its hardware watchdog feeder) need CPU too. The share of time
-- spent in this loop plus LVGL drawing is followed (time-weighted, ~0.25 s); above 80% a
-- callback runs no frames and just returns, so the thread sleeps until the next one. In calm
-- scenes the limit is never reached; in the heaviest scenes the game runs a little slower
-- instead of starving the band.
local UTIL_MAX=0.80                          -- SAFE; FAST uses 0.85
local util,cycleStart,lastBusy,breaths=0,nil,0,0
local win={}
local function win_reset(t) win.t0=t win.frames=0 win.shown=0 win.dropped=0 win.busy=0 win.emu=0 win.pres=0 win.missed=0 win.slots=0 win.breaths=0
  win.gapS=0 win.nS=0 win.gapN=0 win.nN=0 win.banks=bankLoads end
win_reset(clock())
local stats={gfps=0,sfps=0,E=0,R=0,L=0,kb=0}
-- Black box: every 10 s of play one short line goes to /data/redbandgb_last.txt (game speed,
-- busy share, Lua heap, free memory, engine, bank cache, game map). If a session ends without
-- POWER off (a crash), the next POWER shows that line for 8 s, so it can be reported.
local BLACKBOX='/data/redbandgb_last.txt'
local boxAt=0
local function box_line(clean)
  local e=emu
  local map=(e and e._ram) and e._ram[0xD35E-0x7FFF] or -1
  return string.format('%s fps %.0f busy %.0f%% lua %.1fM free %s %s%s b%d map %d',clean and 'ok' or 'run',
    stats.gfps or 0,(util or 0)*100,collectgarbage('count')/1024,sysFree and string.format('%.1fM',sysFree/1024) or '?',
    coreTier or '?',fastMode and ' FAST' or '',BANK_CACHE or 0,map or -1)
end
local function box_write(clean)
  pcall(function()
    local f=io.open(BLACKBOX,'w')
    if f then f:write(box_line(clean)) f:close() end
  end)
end
local function box_read()
  local ok,s=pcall(function() local f=io.open(BLACKBOX,'r') if not f then return nil end local t=f:read('a') f:close() return t end)
  return ok and s or nil
end
local lastSave=clock()
local timer

local curHost=nil
local function load_core()
  -- the game ROM first: without it there is nothing to load an engine for
  if not open_rom() then return nil,'rom' end
  if not Core then
    local ok,result=pcall(create_core_module)
    if not ok then return nil,tostring(result) end
    Core=result
  end
  local host={
    romBanks=64,
    bank=get_bank,
    bank0=function() return Core.packBank(read_bank_string(0)) end,
    -- L and XL engines read bank 0 as plain bytes (no shift/mask per read; +224 KB)
    bank0bytes=function() return {string.byte(read_bank_string(0),1,16384)} end,
    beginFrame=function(dirty) return dirty and renderWanted end,
    frameReady=function(fb,bgp) pendingFB,pendingBGP=fb,bgp lastFB,lastBGP=fb,bgp end,
  }
  -- the in-place bank packer must produce exactly what the core's own packBank does
  do
    local s1=read_bank_string(1)
    local a,b=Core.packBank(s1),pack_into({},s1)
    packInPlace=(#a==#b)
    if packInPlace then for i=1,#a do if a[i]~=b[i] then packInPlace=false break end end end
  end
  curHost=host
  local ok,instance=pcall(Core.create,host)
  if not ok then return nil,tostring(instance) end
  local s=load_sram()
  if s then instance.loadSRAM(s) end
  return instance,nil
end

local function window(now)
  local w=now-win.t0
  if w<=0 then w=0.001 end
  stats.gfps=win.frames/w
  stats.sfps=win.shown/w
  stats.E=(win.frames>0) and (win.emu/win.frames*1000) or 0
  stats.R=(win.shown>0) and (win.pres/win.shown*1000) or 0
  if win.nS>0 and win.nN>0 then stats.L=math.max(0,(win.gapS/win.nS-win.gapN/win.nN)*1000) end
  if not turbo then
    local behind=win.dropped/(w*GB_FPS)
    local missed=(win.slots>0) and (win.missed/win.slots) or 0
    local breathing=(win.breaths or 0)>0
    if behind>0.02 or missed>0.10 or (breathing and behind>0.005) then
      if presentEvery<PMAX then presentEvery=presentEvery+1 end
      clean=0
      if now<trialUntil then blockLowerUntil=now+20 end
    else
      clean=clean+1
      -- show more often only with clear room left (also below the breathing limit), so P does
      -- not see-saw between two values
      if clean>=3 and presentEvery>PMIN and now>=blockLowerUntil and win.busy/w<0.6 and util<UTIL_MAX-0.15 then
        presentEvery=presentEvery-1 clean=0 trialUntil=now+3
      end
    end
  end
  stats.kb=collectgarbage('count')
  check_memory(now)
  if now>=boxAt then boxAt=now+10 box_write(false) end
  win_reset(now)
end

local function tick()
  if not powered or not visible or paused or not emu then return end
  local t0=clock()
  if pendingSafe then
    pendingSafe=false
    pcall(set_mode,false,'memory')
    return
  end
  if recoverPending then
    collectgarbage('collect')
    if restore() then recoverPending=false show_msg('recovered',3) end
    return
  end
  if cycleStart then
    local cyc=t0-cycleStart
    if cyc>0 and cyc<1 then
      local b=lastBusy+(lastShown and math.max(stats.L/1000,0.002) or 0)
      local share=b/cyc if share>1 then share=1 end
      local w=cyc/0.25 if w>1 then w=1 end
      util=util+(share-util)*w
    end
  end
  cycleStart=t0
  if util>UTIL_MAX and not rawget(_G,'TEST_UNTHROTTLED') then
    breaths=breaths+1 win.breaths=(win.breaths or 0)+1
    lastShown=false
    lastBusy=clock()-t0
    return
  end
  if lastEnd then
    local gap=t0-lastEnd
    if gap>=0 and gap<1 then
      if lastShown then win.gapS=win.gapS+gap win.nS=win.nS+1 else win.gapN=win.gapN+gap win.nN=win.nN+1 end
    end
  end
  lastShown=false
  local dt=lastT and (t0-lastT) or 0
  lastT=t0
  if dt<0 or dt>0.5 then dt=TIMER_PERIOD/1000 end
  owed=owed+dt*GB_FPS*(turbo and TURBO_SPEED or 1)
  local cap=turbo and TURBO_OWED or MAX_OWED
  if owed>cap then win.dropped=win.dropped+(owed-cap) owed=cap end
  if rawget(_G,'TEST_UNTHROTTLED') then owed=cap end
  local n=math.floor(owed)
  if n>=1 then
    local maxB=turbo and TURBO_BATCH or MAX_BATCH
    if n>maxB then n=maxB end
    -- frames that fit the time budget (decided up front, so the frame to draw is known)
    local budget=turbo and TURBO_BUDGET or BUDGET
    local fit=math.floor(budget/estE)
    if fit<1 then fit=1 end
    if n>fit then n=fit end
    -- frame-locked showing: only game frames numbered k*P are drawn, so every shown frame is
    -- exactly P game frames after the one before (smooth motion)
    local Pc=turbo and TURBO_P or presentEvery
    local last=frameNo+n
    local target=last-(last%Pc)
    if target<=frameNo then target=-1 else
      local passed=(target-frameNo-1)//Pc
      win.missed=win.missed+passed win.slots=win.slots+passed+1
    end
    pendingFB=nil
    for i=1,n do
      frameNo=frameNo+1
      renderWanted=(frameNo==target)
      emu.runFrame()
    end
    renderWanted=false
    owed=owed-n
    local t1=clock()
    estE=estE+((t1-t0)/n-estE)*0.2
    win.frames=win.frames+n win.emu=win.emu+(t1-t0)
    if pendingFB then
      assert(#pendingFB==5760,'framebuffer must be 5760 bytes')
      local ok,res=pcall(Pr.present,pendingFB,pendingBGP)
      if not ok then
        if tostring(res):find('memory') then low_memory(t1)
        else
          -- a display problem never stops the game: memory path -> files -> keep playing
          presentFails=presentFails+1
          if Pr.mode=='direct' and presentFails>=3 then Pr.forceFile=true pcall(Pr.init) end
        end
      elseif res then
        lastShown=true win.shown=win.shown+1 presentFails=0
      end
      win.pres=win.pres+(clock()-t1)
    end
    if t1>=snapAt and not turbo and not pendingFB then
      -- a recovery point every 30 s, between frames, on a callback that showed nothing
      local ok,st=pcall(emu.saveState)
      snapshot=ok and st or nil
      snapAt=t1+30
    end
  else
    -- nothing due yet: let the garbage collector use the slack
    collectgarbage('step',0)
  end
  local now=clock()
  if now-win.t0>=1.0 then window(now) end
  if emu.sramDirty() and now-lastSave>=1 then pcall(save_ram,false) lastSave=clock() end
  lastEnd=clock()
  lastBusy=lastEnd-t0
  win.busy=win.busy+(lastEnd-t0)
end

-- ===================================================================================
-- Messages on the screen area (only when something went wrong)
-- ===================================================================================
local msg_label
local msgUntil=0
local function show_msg(text,secs)
  if not msg_label then return end
  pcall(function()
    msg_label:set({text=tostring(text):sub(1,64)})
    msg_label:clear_flag(lvgl.FLAG.HIDDEN)
  end)
  msgUntil=clock()+(secs or 4)
end
local function hide_msg_if_due()
  if msg_label and msgUntil>0 and clock()>=msgUntil then
    msgUntil=0 pcall(function() msg_label:add_flag(lvgl.FLAG.HIDDEN) end)
  end
end

local function set_paused(p)
  paused=p
  pcall(function() pause_text:set({text=p and 'PLAY' or 'PAUSE'}) end)
end
local function reset_pacing()
  owed,lastT,lastEnd,lastShown=0,nil,nil,false
  util,cycleStart,lastBusy=0,nil,0
  clean,blockLowerUntil,trialUntil=0,0,0
  win_reset(clock())
end

-- ===================================================================================
-- Clock (Poketch style) in the screen area while the game is off: Red on the left, hours over
-- minutes on the right, weekday and date below. Time comes from the band's dataman service;
-- os.date is the fallback.
-- ===================================================================================
local clock_show,clock_panel,ck,clockTimer
(function()
Pr.ensure_image()                       -- the game image sits under the clock and the browser
clock_panel=shape(root,4,113,204,184,C.lcd,10)
try_set(clock_panel,{border_width=3,border_color=C.lcdEdge})
local function asset_img(parent,x,y,file)
  local o=lvgl.Image(parent,{x=x,y=y,src=asset_dir()..file})
  pcall(function() o:clear_flag(lvgl.FLAG.CLICKABLE) end)
  return o
end
asset_img(clock_panel,10,11,'clk_red.bin')
ck={
  h1=asset_img(clock_panel,118,8,'clk_b1.bin'), h2=asset_img(clock_panel,146,8,'clk_b0.bin'),
  m1=asset_img(clock_panel,118,74,'clk_b0.bin'), m2=asset_img(clock_panel,146,74,'clk_b9.bin'),
  wd=asset_img(clock_panel,128,143,'clk_w0.bin'),
  o1=asset_img(clock_panel,120,163,'clk_s0.bin'), o2=asset_img(clock_panel,131,163,'clk_s1.bin'),
  dot=asset_img(clock_panel,142,163,'clk_dot.bin'),
  d1=asset_img(clock_panel,149,163,'clk_s0.bin'), d2=asset_img(clock_panel,160,163,'clk_s1.bin'),
}
local ckState={}
local function ck_set(key,file)
  if ckState[key]==file then return end
  ckState[key]=file
  pcall(function() local o=ck[key] if o.set_src then o:set_src(asset_dir()..file) else o:set({src=asset_dir()..file}) end end)
end
local function ck_digit(key,v,big)
  v=math.floor(tonumber(v) or 0)%10
  ck_set(key,(big and 'clk_b' or 'clk_s')..v..'.bin')
end
local function ck_week(v)                 -- 0 or 7 = Sunday, 1..6 = Monday..Saturday
  v=math.floor(tonumber(v) or 1)%7
  ck_set('wd','clk_w'..((v+6)%7)..'.bin')  -- files: 0 = MON .. 6 = SUN
end
local function ck_from_os()
  local ok,t=pcall(os.date,'*t')
  if not ok or type(t)~='table' then return end
  ck_digit('h1',t.hour//10,true) ck_digit('h2',t.hour%10,true)
  ck_digit('m1',t.min//10,true) ck_digit('m2',t.min%10,true)
  ck_digit('o1',t.month//10) ck_digit('o2',t.month%10)
  ck_digit('d1',t.day//10) ck_digit('d2',t.day%10)
  ck_week((t.wday or 2)-1)
end
local useDataman=false
pcall(function()
  local ok,dm=pcall(require,'dataman')
  if not ok or type(dm)~='table' or not dm.subscribe then return end
  local function sub(name,obj,fn)
    dm.subscribe(name,obj,function(_,value) pcall(fn,(tonumber(value) or 0)//256) end)
  end
  sub('timeHourHigh',ck.h1,function(v) ck_digit('h1',v,true) end)
  sub('timeHourLow',ck.h2,function(v) ck_digit('h2',v,true) end)
  sub('timeMinuteHigh',ck.m1,function(v) ck_digit('m1',v,true) end)
  sub('timeMinuteLow',ck.m2,function(v) ck_digit('m2',v,true) end)
  sub('dateMonth',ck.o1,function(v) ck_digit('o1',v//10) ck_digit('o2',v%10) end)
  sub('dateDay',ck.d1,function(v) ck_digit('d1',v//10) ck_digit('d2',v%10) end)
  sub('dateWeek',ck.wd,function(v) ck_week(v) end)
  useDataman=true
end)
ck_from_os()
clockTimer=lvgl.Timer({period=1000,cb=function()
  pcall(function()
    hide_msg_if_due()
    if not useDataman and not powered then ck_from_os() end
  end)
end})
clock_show=function(on)
  pcall(function() if on then clock_panel:clear_flag(lvgl.FLAG.HIDDEN) else clock_panel:add_flag(lvgl.FLAG.HIDDEN) end end)
  if on and not useDataman then ck_from_os() end
end
msg_label=lvgl.Label(root,{x=8,y=116,w=196,h=30,text='',text_color=C.pillText,bg_opa=0,border_width=0})
do local f=F(11) if f then try_set(msg_label,{text_font=f}) end end
try_set(msg_label,{text_align=2})
msg_label:add_flag(lvgl.FLAG.HIDDEN)

end)()

-- ===================================================================================
-- Power, recovery
-- ===================================================================================
local function power_off(skipSave)
  timer:pause()
  box_write(true)
  fastMode=false UTIL_MAX=0.80 pendingSafe=false
  if not skipSave then pcall(save_ram,true) end
  if cfg.probe~='ok' and Pr.mode=='direct' and Pr.shown>0 then cfg.probe='ok' cfg.memok='1' pcall(save_cfg) end
  emu=nil pendingFB=nil lastFB=nil Core=nil snapshot=nil
  Pr.release()
  if romf then pcall(function() romf:close() end) romf=nil end
  bankCache,bankAge,bankCount={},{},0
  turbo=false
  sunk(turbo_btn,C.pillTop,C.pillBot)
  powered=false
  set_paused(false)
  collectgarbage('collect')
  down=0
  led_set(false)
  sunk(power_btn,C.pillTop,C.pillBot)
  clock_show(true)
  mode_button()
end
local function power_on()
  powered=true
  set_paused(false)
  led_set(true)
  sunk(power_btn,C.pillDownTop,C.pillDownBot)
  if not emu then
    collectgarbage('collect')
    local call_ok,instance,message=pcall(load_core)
    if not call_ok or not instance then
      -- one more try after a full collection (a short memory squeeze must not stop POWER)
      Core=nil collectgarbage('collect')
      call_ok,instance,message=pcall(load_core)
    end
    if call_ok then emu,errmsg=instance,message else emu=nil errmsg=tostring(instance) end
    if not emu then
      powered=false Core=nil
      led_set(false)
      sunk(power_btn,C.pillTop,C.pillBot)
      show_msg((errmsg=='rom') and 'no game ROM in this watchface' or ('cannot start: '..tostring(errmsg)),6)
      return
    end
    collectgarbage('collect')
    set_gc_pause()
    MEM.checkKB=collectgarbage('count') MEM.checkAt=clock()+60 MEM.lowNow=false
  end
  errmsg=nil
  clock_show(false)
  -- the last session ended without POWER off: show what the black box saw last
  local last=box_read()
  if last and last:sub(1,3)=='run' then show_msg('last run: '..last:sub(5),8) end
  boxAt=0
  Pr.init()
  fastMode=false UTIL_MAX=0.80 pendingSafe=false
  plan_caches()
  mode_button()
  presentEvery=2
  snapshot=nil snapAt=clock()+20
  reset_pacing()
  if visible then timer:resume() end
end
-- ===================================================================================
-- SAFE / FAST. Every POWER starts in SAFE (the build that never crashed). While playing, the
-- top-left button reads UNSAFE: tapping it switches to FAST (the 4.4.0-4.5.0 feel: largest
-- engine from 3 MB free, more ROM banks cached, a roomier collector, the UI thread may be busy
-- up to 85%) and back. FAST keeps every safety net, and drops back to SAFE by itself as soon as
-- memory gets short. A different engine size takes over the running game through a save
-- state, so nothing is lost.
-- ===================================================================================
do
local ENGINE_KB={XL=1200,L=700,S=450}
plan_caches=function()
  Pr.setRcCap((coreTier=='XL') and 256 or ((coreTier=='L') and 160 or 96))
  local want=(coreTier=='XL') and 32 or ((coreTier=='L') and 24 or 14)
  -- each cached bank is ~33 KB: never into the last 3 MB the band has free (2 MB in FAST)
  if sysFree then
    local fit=math.floor((sysFree-(fastMode and 2048 or 3072))/40)
    if fit<want then want=math.max(8,fit) end
  end
  BANK_CACHE=want
  while bankCount>BANK_CACHE do evict_oldest() end
end
mode_button=function()
  pcall(function()
    if powered then
      browse_text:set({text='UNSAFE'})
      if fastMode then sunk(browse_btn,C.abDownTop,C.abDownBot) else sunk(browse_btn,C.pillTop,C.pillBot) end
    else
      browse_text:set({text='BROWSE'})
      sunk(browse_btn,C.pillTop,C.pillBot)
    end
  end)
end
local function swap_engine(tier)
  pcall(save_ram,true)                     -- a finished game save goes to the file first
  local ok,st=pcall(emu.saveState)
  if not ok then return false end
  local oldEmu,oldCore,oldTier,oldForm=emu,Core,coreTier,coreForm
  local M=load_tier(tier)
  if M then
    local ok2,inst=pcall(M.create,curHost)
    if ok2 and inst and pcall(inst.loadState,st) then
      Core=M emu=inst
      emu.releaseAll() down=0
      Pr.invalidate()
      snapshot=nil snapAt=clock()+5
      coreSwaps=coreSwaps+1
      oldEmu,oldCore=nil,nil
      collectgarbage('collect')
      return true
    end
  end
  emu,Core,coreTier,coreForm=oldEmu,oldCore,oldTier,oldForm
  return false
end
set_mode=function(fast,why)
  if not powered or not emu or fast==fastMode then return end
  fastMode=fast
  UTIL_MAX=fast and 0.85 or 0.80
  local ok,free=pcall(meminfo)
  free=ok and free or nil
  if free and not rawget(_G,'RBGB_CORE') then
    local want=tier_for(free+(ENGINE_KB[coreTier] or 0),fast)
    if want~=coreTier then swap_engine(want) end
  end
  set_gc_pause()
  plan_caches()
  mode_button()
  reset_pacing()
  show_msg(fast and 'UNSAFE: fastest, less margin' or ('SAFE'..(why and (' again: '..why) or '')),3)
end
end

local function toggle_power()
  if powered then power_off(false) else power_on() end
end
-- an error inside a game frame: go back to the last recovery point (or restart the engine from
-- the battery save); after three failures within a minute the game is stopped cleanly
local rescues,rescueWin,memFaults=0,-100,0
restore=function()
  local ok=false
  if snapshot then ok=pcall(emu.loadState,snapshot) end
  if not ok then
    local c_ok,inst=pcall(load_core)
    if c_ok and inst then emu=inst ok=true end
  end
  if ok then
    emu.releaseAll()
    Pr.invalidate()
    reset_pacing()
  end
  return ok
end
local function recover(why)
  local now=clock()
  if now-rescueWin>60 then rescues=0 rescueWin=now end
  errmsg=tostring(why)
  local memFault=errmsg:find('memory')~=nil
  -- running out of memory is not a bug: free memory and carry on (it never counts toward
  -- stopping); other faults stop the game after 3 within a minute
  if memFault then pcall(low_memory,now) memFaults=memFaults+1 else rescues=rescues+1 end
  if (memFault or rescues<=3) and emu then
    if restore() then show_msg('recovered',3) return end
    if memFault then
      -- not even the recovery point fits right now: the game waits (no frames) and tries
      -- again on every callback until memory is back
      recoverPending=true
      show_msg('low memory - waiting',3)
      return
    end
  end
  power_off(false)
  show_msg('stopped: '..errmsg,8)
end
timer=lvgl.Timer({period=TIMER_PERIOD,cb=function()
  local ok,why=pcall(tick)
  if not ok then
    local ok2=pcall(recover,why)
    if not ok2 then pcall(function() timer:pause() end) end
  end
end})
timer:pause()

-- every touch handler runs protected: a failing handler can never take the watchface down
local function safe(fn)
  return function(...)
    local ok,e=pcall(fn,...)
    if not ok then pcall(show_msg,'error: '..tostring(e),5) end
  end
end
power_btn:onevent(lvgl.EVENT.CLICKED,safe(toggle_power))
local function toggle_pause()
  if not powered or not emu then return end
  if not paused then
    set_paused(true)
    timer:pause()
    down=0
    emu.releaseAll()
    pcall(save_ram,true)
    sunk(pause_btn,C.pillDownTop,C.pillDownBot)
  else
    set_paused(false)
    sunk(pause_btn,C.pillTop,C.pillBot)
    reset_pacing()
    if visible then timer:resume() end
  end
end
local function toggle_turbo()
  if not powered or not emu then return end
  turbo=not turbo
  if turbo then sunk(turbo_btn,C.pillDownTop,C.pillDownBot) else sunk(turbo_btn,C.pillTop,C.pillBot) end
  owed=0
end
pause_btn:onevent(lvgl.EVENT.CLICKED,safe(toggle_pause))
turbo_btn:onevent(lvgl.EVENT.CLICKED,safe(toggle_turbo))

-- view: BIG (crisp 212x189) -> SMOOTH (GPU-scaled) -> FAST (160x144); long-press the screen
local function show_again()
  if powered and emu and lastFB then pcall(Pr.present,lastFB,lastBGP) end
end
local function toggle_view()
  cfg.view=VIEW_ORDER[cfg.view] or 'big'
  pcall(save_cfg)
  Pr.setView(cfg.view)
  show_again()
end
pcall(function()
  display_bg:add_flag(lvgl.FLAG.CLICKABLE)
  if lvgl.EVENT.LONG_PRESSED then
    display_bg:onevent(lvgl.EVENT.LONG_PRESSED,safe(toggle_view))
  else
    local lastTap=-1
    display_bg:onevent(lvgl.EVENT.CLICKED,safe(function()
      local now=clock()
      if now-lastTap<0.5 then lastTap=-1 toggle_view() else lastTap=now end
    end))
  end
end)
-- LED long-press: display path automatic <-> files (troubleshooting)
local function toggle_disp()
  cfg.disp=(cfg.disp=='file') and 'auto' or 'file'
  cfg.probe=''
  Pr.forceFile=false
  pcall(save_cfg)
  if powered and emu then
    Pr.init()
    show_again()
  end
  show_msg((cfg.disp=='file') and 'display: files' or 'display: memory',2)
end
pcall(function()
  if lvgl.EVENT.LONG_PRESSED then led_hit:onevent(lvgl.EVENT.LONG_PRESSED,safe(toggle_disp)) end
  -- tap: the live figures (game fps, busy share, Lua heap, free memory, engine, banks, map)
  led_hit:onevent(lvgl.EVENT.SHORT_CLICKED or lvgl.EVENT.CLICKED,safe(function()
    local ok,f=pcall(meminfo) if ok and f then sysFree=f end
    show_msg(box_line(true):sub(4),6)
  end))
end)

-- ===================================================================================
-- BROWSE: the save files on the band, each with DELETE (tap twice to confirm)
-- ===================================================================================
local browser,rows,close_btn,browseFiles_get
(function()
local KNOWN_FILES={
  {'/data/redbandgb_red.sav','GAME SAVE',true},
  {'/data/redbandgb_red.sav.bak','SAVE BACKUP',true},
  {'/data/redbandgb_red.sav.tmp','SAVE TEMP',true},
  {asset_dir()..'pokemon_red.sav','GAME SAVE 2',true},
  {asset_dir()..'pokemon_red.sav.bak','SAVE BACKUP 2',true},
  {'/data/redbandgb_cfg40.txt','SETTINGS',false},
  {asset_dir()..'redbandgb_cfg40.txt','SETTINGS 2',false},
  {'/data/redbandgb_view31.txt','OLD SETTINGS',false},
}
local function file_size(path)
  local f=io.open(path,'rb')
  if not f then return nil end
  local n=f:seek('end') f:close()
  return n or 0
end
local function scan_dir(dir,seen,out)
  if not (lvgl.fs and lvgl.fs.open_dir) then return end
  local ok,d=pcall(lvgl.fs.open_dir,dir)
  if not ok or not d then return end
  for _=1,200 do
    local ok2,name=pcall(d.read,d)
    if not ok2 or type(name)~='string' or name=='' then break end
    if name:sub(1,1)~='/' and (name:find('^redbandgb') or name:find('%.sav$')) then
      local path=dir..((dir:sub(-1)=='/') and '' or '/')..name
      if not seen[path] then
        local sz=file_size(path)
        if sz then seen[path]=true out[#out+1]={path=path,label=name:upper():sub(1,14),save=name:find('%.sav$')~=nil,size=sz} end
      end
    end
  end
  pcall(d.close,d)
end
local function list_files()
  local out,seen={},{}
  for _,k in ipairs(KNOWN_FILES) do
    local sz=file_size(k[1])
    if sz and not seen[k[1]] then seen[k[1]]=true out[#out+1]={path=k[1],label=k[2],save=k[3],size=sz} end
  end
  scan_dir('/data',seen,out)
  local ad=asset_dir()
  if ad~='' then scan_dir(ad:sub(1,-2),seen,out) end
  return out
end
browser=shape(root,0,104,212,202,C.panel,6)
browser:add_flag(lvgl.FLAG.HIDDEN)
browser:add_flag(lvgl.FLAG.CLICKABLE)
do
  local t=lvgl.Label(browser,{x=0,y=6,w=212,h=18,text='SAVE FILES',text_color=C.pillText,bg_opa=0,border_width=0})
  local f=F(13) if f then try_set(t,{text_font=f}) end
  try_set(t,{text_align=2})
end
rows={}
local empty_label=lvgl.Label(browser,{x=0,y=80,w=212,h=18,text='NO SAVE FILES',text_color=C.hudText,bg_opa=0,border_width=0})
do local f=F(12) if f then try_set(empty_label,{text_font=f}) end try_set(empty_label,{text_align=2}) end
local browseFiles,armed,armedAt={},nil,0
local wasRunning=false
local refresh_browser
local function delete_file(i)
  local e=browseFiles[i]
  if not e then return end
  if armed~=i or clock()-armedAt>4 then
    armed,armedAt=i,clock()
    pcall(function() rows[i].btext:set({text='SURE?'}) end)
    sunk(rows[i].btn,C.warn,C.abDownTop)
    return
  end
  armed=nil
  -- deleting the game's save while it runs: stop it first without saving, or it would be
  -- written straight back
  if e.save and powered then power_off(true) wasRunning=false end
  local ok=os.remove(e.path)
  -- a game save goes with its backup and temp copies, or the backup would bring it back
  if e.path:find('%.sav$') then os.remove(e.path..'.bak') os.remove(e.path..'.tmp') end
  show_msg(ok and ('deleted '..e.label) or 'could not delete',3)
  refresh_browser()
end
for i=1,4 do
  local r=shape(browser,8,28+(i-1)*36,196,32,C.panelRow,8)
  local name=lvgl.Label(r,{x=8,y=8,w=122,h=16,text='',text_color=C.pillText,bg_opa=0,border_width=0})
  local f=F(11) if f then try_set(name,{text_font=f}) end
  local btn=shape(r,134,3,58,26,C.pillTop,13)
  raised(btn,C.pillTop,C.pillBot,C.pillEdge)
  btn:add_flag(lvgl.FLAG.CLICKABLE)
  local btext=caption(btn,'DELETE',58,26,10,C.pillText)
  btn:onevent(lvgl.EVENT.CLICKED,safe(function() delete_file(i) end))
  r:add_flag(lvgl.FLAG.HIDDEN)
  rows[i]={row=r,name=name,btn=btn,btext=btext}
end
close_btn=shape(browser,66,172,80,24,C.pillTop,12)
raised(close_btn,C.pillTop,C.pillBot,C.pillEdge)
caption(close_btn,'CLOSE',80,24,11,C.pillText)
close_btn:add_flag(lvgl.FLAG.CLICKABLE)
refresh_browser=function()
  browseFiles=list_files()
  for i=1,4 do
    local e=browseFiles[i]
    local r=rows[i]
    pcall(function()
      if e then
        r.name:set({text=string.format('%s %dK',e.label,math.max(1,(e.size+1023)//1024))})
        r.btext:set({text='DELETE'})
        sunk(r.btn,C.pillTop,C.pillBot)
        r.row:clear_flag(lvgl.FLAG.HIDDEN)
      else r.row:add_flag(lvgl.FLAG.HIDDEN) end
    end)
  end
  pcall(function() if #browseFiles==0 then empty_label:clear_flag(lvgl.FLAG.HIDDEN) else empty_label:add_flag(lvgl.FLAG.HIDDEN) end end)
end
local browsing=false
local function open_browser()
  if browsing then return end
  browsing=true
  wasRunning=powered and emu and not paused
  if wasRunning then toggle_pause() end
  armed=nil
  refresh_browser()
  browser:clear_flag(lvgl.FLAG.HIDDEN)
  sunk(browse_btn,C.pillDownTop,C.pillDownBot)
end
local function close_browser()
  if not browsing then return end
  browsing=false
  browser:add_flag(lvgl.FLAG.HIDDEN)
  sunk(browse_btn,C.pillTop,C.pillBot)
  if wasRunning and powered and emu and paused then toggle_pause() end
  wasRunning=false
end
browse_btn:onevent(lvgl.EVENT.CLICKED,safe(function()
  if powered and emu and not browsing then set_mode(not fastMode) return end
  if browsing then close_browser() else open_browser() end
end))
close_btn:onevent(lvgl.EVENT.CLICKED,safe(close_browser))
browseFiles_get=function() return browseFiles end
end)()

pageOnPause=function()
  pcall(function()
    visible=false timer:pause()
    pcall(save_ram,true)
    if emu then emu.releaseAll() end
  end)
end
pageOnResume=function()
  pcall(function()
    visible=true
    reset_pacing()
    if powered and emu and not paused then timer:resume() end
  end)
end
function ScreenStateChangedCB(pre,now,reason)
  pcall(function()
    visible=(now=='ON')
    if not visible then
      timer:pause()
      pcall(save_ram,true)
      if emu then emu.releaseAll() end
    else
      reset_pacing()
      if powered and emu and not paused then timer:resume() end
    end
  end)
end

-- desktop test harness only (not defined on the watch)
if rawget(_G,'RBGB_TEST') then
  RBGB40={timer=function() return timer end,emu=function() return emu end,power=power_btn,pause=pause_btn,
    buttons=buttons,presenter=Pr,image=function() return Pr.image() end,shown=function() return Pr.shown end,
    toggleView=toggle_view,setView=function(v) cfg.view=v Pr.setView(v) end,view=function() return Pr.view end,
    displayBg=display_bg,led=led,ledHit=led_hit,ledOn=function() return ledOn end,ledTimer=ledTimer,
    root=root,version=VERSION,turbo=function() return turbo end,toggleTurbo=toggle_turbo,turboBtn=turbo_btn,
    presentEvery=function() return presentEvery end,stats=stats,hudOn=function() return hudOn end,
    cfg=cfg,ring=function() return Pr.ringInfo() end,bankLoads=function() return bankLoads end,
    current=function() return Pr.current() end,errmsg=function() return errmsg end,
    core=function() return coreTier,coreForm end,gcPause=function() return gcPause end,meminfo=meminfo,
    browse=browse_btn,browser=browser,rows=rows,closeBtn=close_btn,browseFiles=browseFiles_get,
    clockPanel=clock_panel,clockImgs=ck,clockTimer=clockTimer,msg=function() return msg_label end,showMsg=function(t,secs) show_msg(t,secs) end,
    mem=MEM,lowMem=function() return lowMem end,snapshot=function() return snapshot end,
    recover=recover,memFaults=function() return memFaults end,rescues=function() return rescues end,saveSlots=SAVE_CANDIDATES,savValid=sav_valid,saveRam=function(f) return save_ram(f) end,
    savedFrom=function() return savedFrom end,fast=function() return fastMode end,setMode=function(f) set_mode(f) end,coreSwaps=function() return coreSwaps end,utilMax=function() return UTIL_MAX end,browseText=function() return browse_text end,boxRead=box_read,saveWrites=function() return saveWrites end,util=function() return util,breaths end,bankCache=function() return BANK_CACHE,bankCount end,packInPlace=function() return packInPlace end}
end
