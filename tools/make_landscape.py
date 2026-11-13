"""RedBand GB landscape: derive main_land_template.lua from main_template.lua.

Everything below the screen layer (emulator, engines, saves, SAFE/FAST, memory and CPU safety,
black box) is the tested portrait code, unchanged. Only the drawing layer is replaced:
  * a logical 520x212 landscape canvas mapped onto the 212x520 panel (shape() places every
    object through L(); gradients run sideways);
  * all text is drawn as small rotated images from a pre-rendered font (fontland.lua), because
    the band's Lua binding cannot rotate labels; messages get a dark strip behind them;
  * the game picture is built upright (BIG: 224x202, exact 7/5 = 1.4x) and turned 90 degrees by
    the graphics chip (image 'angle', no filtering for BIG and 1:1);
  * the clock uses rotated copies of the Poketch images (clkr_*.bin).
  python3 tools/make_landscape.py <orient 1|-1> <out template>
    orient 1: the band's top end on the LEFT (turn the band anticlockwise to play)
    orient -1: the band's top end on the RIGHT (turn it clockwise)"""
import sys, re
ORIENT = int(sys.argv[1]); OUT = sys.argv[2]
s = open('tools/main_template.lua').read()
def rep(a, b, cnt=1):
    global s
    assert a in s, 'missing: ' + a[:100]
    s = s.replace(a, b, cnt)
def cut(start, end_marker, new):
    """replace s[start .. just before end_marker] with new"""
    global s
    i = s.index(start); j = s.index(end_marker, i)
    s = s[:i] + new + s[j:]

s = s.replace('-- RedBand GB 4.6.0 -- Game Boy emulator watchface', '-- RedBand GB 4.6.0 Landscape -- Game Boy emulator watchface (turned sideways)')
rep("local VERSION='4.6.0'", "local VERSION='4.6.0L'")
# settings and saves are shared with the portrait face, but the display probe is per face
rep("'/data/redbandgb_cfg40.txt'", "'/data/redbandgb_cfgL.txt'")

# ---------------------------------------------------------------------------- logical layer
cut('local function shape(parent,x,y,w,h,color,rad)', 'local fonts={}', '''-- ===================================================================================
-- Landscape: every object is placed on a logical 520x212 canvas (the band turned sideways) and
-- mapped onto the 212x520 panel. ORIENT 1 = the band's top end on the left (logical top = the
-- panel's right side), -1 = on the right. Gradients that run top-to-bottom on the logical
-- canvas run sideways on the panel.
-- ===================================================================================
local ORIENT,LW,LH=%d,520,212
local LSIZE=setmetatable({},{__mode='k'})        -- logical size of each object (its frame)
local function L(parent,X,Y,Wd,Ht)
  local s=parent and LSIZE[parent]
  local pw,ph=LW,LH
  if s then pw,ph=s[1],s[2] end
  if ORIENT==1 then return ph-Y-Ht,X,Ht,Wd end
  return Y,pw-X-Wd,Ht,Wd
end
local function Lpoint(X,Y)                      -- a point on the root canvas -> panel
  if ORIENT==1 then return LH-Y,X end
  return Y,LW-X
end
local function grad(o,top,bot)
  if ORIENT==1 then try_set(o,{bg_color=bot,bg_grad_color=top}) else try_set(o,{bg_color=top,bg_grad_color=bot}) end
end
local function shape(parent,x,y,w,h,color,rad)
  local px,py,pw,ph=L(parent,x,y,w,h)
  local o=lvgl.Object(parent,{x=px,y=py,w=pw,h=ph,bg_color=color,bg_opa=lvgl.OPA(100),radius=rad or 0,
    outline_width=0,border_width=0,pad_all=0})
  o:clear_flag(lvgl.FLAG.SCROLLABLE)
  LSIZE[o]={w,h}
  return o
end
local function raised(o,top,bot,edge)
  try_set(o,{bg_grad_dir=2,border_width=1,border_color=edge})
  grad(o,top,bot)
end
local function sunk(o,top,bot)
  grad(o,top,bot)
end
''' % ORIENT)

# ---------------------------------------------------------------------------- text as images
cut('local function caption(parent,text,w,h,size,color)', '\nlocal root=lvgl.Object', '''-- Text: rotated images built from fontland.lua (DejaVu Sans Bold 11, 4 alpha levels, already
-- turned for this orientation, 16 px line). A line is the glyphs' row strings joined; lines
-- are interleaved 4 bytes at a time. Written once per (text, colour) to the RAM disk as small
-- I2 images; LVGL keys its cache by the path, so nothing stale can be shown.
local textbox
do
local FONT=nil
pcall(function()
  local f=io.open(asset_dir()..'fontland.lua','rb')
  if not f then return end
  local src=f:read('a') f:close()
  local chunk=load(src,'=fontland','t')
  if chunk then FONT=chunk() end
end)
local textSeq,textCache,textDyn=0,{},{}
local function text_lines(text,maxw)
  local lines={}
  for para in tostring(text):gmatch('[^\\n]+') do
    local cur,curw='',0
    for word in para:gmatch('%S+') do
      local ww=0
      for i=1,#word do ww=ww+(FONT.adv[word:byte(i)] or FONT.adv[63]) end
      local sp=(cur=='' and 0) or FONT.adv[32]
      if maxw and curw+sp+ww>maxw and cur~='' then lines[#lines+1]=cur cur,curw=word,ww
      else cur=(cur=='' and word) or (cur..' '..word) curw=curw+sp+ww end
    end
    lines[#lines+1]=cur
  end
  return lines
end
local function line_rows(t)
  local parts,n={},0
  if ORIENT==1 then
    for i=1,#t do n=n+1 parts[n]=FONT.g[t:byte(i)] or FONT.g[63] end
  else
    for i=#t,1,-1 do n=n+1 parts[n]=FONT.g[t:byte(i)] or FONT.g[63] end
  end
  return table.concat(parts)
end
-- returns path, logical width, logical height
local function text_image(text,color,maxw)
  if not FONT then return nil,0,0 end
  local key=tostring(text)..'|'..color..'|'..tostring(maxw)
  local c=textCache[key]
  if c then return c[1],c[2],c[3] end
  local lines=text_lines(text,maxw)
  local strs,maxlen={},0
  for i,t in ipairs(lines) do strs[i]=line_rows(t) if #strs[i]>maxlen then maxlen=#strs[i] end end
  if maxlen==0 then return nil,0,0 end
  local zero=string.rep('\\0',maxlen)
  for i,st in ipairs(strs) do                    -- centre every line
    local pad=((maxlen-#st)//8)*4
    strs[i]=zero:sub(1,pad)..st..zero:sub(1,maxlen-#st-pad)
  end
  local n=#strs
  local data
  if n==1 then data=strs[1] else
    local order={}
    if ORIENT==1 then for i=n,1,-1 do order[#order+1]=strs[i] end else order=strs end
    local out,k={},0
    for r=1,maxlen,4 do for i=1,n do k=k+1 out[k]=order[i]:sub(r,r+3) end end
    data=table.concat(out)
  end
  local R,G,B=(color>>16)&255,(color>>8)&255,color&255
  local pal=string.char(0,0,0,0, B,G,R,90, B,G,R,170, B,G,R,255)
  textSeq=textSeq+1
  local path='/tmp/rbgbtxt_'..textSeq..'.bin'
  local f=io.open(path,'wb')
  if not f then return nil,0,0 end
  f:write(string.pack('<BBHHHHH',0x19,0x08,0,16*n,maxlen//4,4*n,0),pal,data)
  f:close()
  textCache[key]={path,maxlen//4,16*n}
  -- the button and title texts made while the face is built stay; later texts (messages, file
  -- names) are limited to the 24 most recent, so the RAM disk does not fill up over a session
  if textSeq>40 then
    textDyn[#textDyn+1]=key
    if #textDyn>24 then
      local old=table.remove(textDyn,1)
      local c=textCache[old]
      if c then os.remove(c[1]) textCache[old]=nil end
    end
  end
  return path,maxlen//4,16*n
end
-- a text object: an image centred in a logical box of its parent; :set({text=...}) swaps it
textbox=function(parent,X,Y,Wd,Ht,text,color,maxw)
  local tb={props={text=text},color=color}
  local o=lvgl.Image(parent,{x=0,y=0})
  pcall(function() o:clear_flag(lvgl.FLAG.CLICKABLE) end)
  tb.obj=o tb.flags=o.flags
  function tb:set(p)
    if p.text==nil then return end
    self.props.text=p.text
    local path,tw,th=text_image(p.text,self.color,maxw)
    if not path then pcall(function() o:add_flag(lvgl.FLAG.HIDDEN) end) return end
    local px,py=L(parent,X+(Wd-tw)//2,Y+(Ht-th)//2,tw,th)
    pcall(function() if o.set_src then o:set_src(path) else o:set({src=path}) end end)
    pcall(function() o:set({x=px,y=py}) end)
  end
  function tb:add_flag(f) pcall(function() o:add_flag(f) end) end
  function tb:clear_flag(f) pcall(function() o:clear_flag(f) end) end
  tb:set({text=text})
  return tb
end
end
local function caption(parent,text,w,h,size,color)
  return textbox(parent,0,0,w,h,text,color)
end
''')
open(OUT, 'w').write(s)
print('stage 1 ok')

# ---------------------------------------------------------------------------- body and controls
rep("try_set(root,{bg_grad_color=C.bodyBot,bg_grad_dir=1})", "try_set(root,{bg_grad_dir=2}) grad(root,C.bodyTop,C.bodyBot)")
cut('-- top cap: BROWSE and TURBO side by side; below: POWER, red LED, PAUSE', 'local function control(name,x,y,w,h,rad,top,bot,edge,dtop,dbot,text,tsize,tcolor)', '''-- Landscape layout (logical 520x212): the big screen a little left of centre; on the right the
-- D-pad with PAUSE and POWER above it and the LED low beside the screen; on the left A and B
-- side by side with TURBO and UNSAFE (BROWSE while the game is off) above, START / SELECT below. Every control stays 20 px
-- from the band's long edges and away from its rounded ends (band gestures start there).
local browse_btn=shape(root,66,52,58,24,C.pillTop,12)
raised(browse_btn,C.pillTop,C.pillBot,C.pillEdge)
local browse_text=caption(browse_btn,'BROWSE',58,24,10,C.pillText)
browse_btn:add_flag(lvgl.FLAG.CLICKABLE)
local turbo_btn=shape(root,66,22,58,24,C.pillTop,12)
raised(turbo_btn,C.pillTop,C.pillBot,C.pillEdge)
caption(turbo_btn,'TURBO',58,24,10,C.pillText)
turbo_btn:add_flag(lvgl.FLAG.CLICKABLE)
local pause_btn=shape(root,364,22,58,24,C.pillTop,12)
raised(pause_btn,C.pillTop,C.pillBot,C.pillEdge)
local pause_text=caption(pause_btn,'PAUSE',58,24,10,C.pillText)
pause_btn:add_flag(lvgl.FLAG.CLICKABLE)
local power_btn=shape(root,364,52,58,24,C.pillTop,12)
raised(power_btn,C.pillTop,C.pillBot,C.pillEdge)
caption(power_btn,'POWER',58,24,10,C.pillText)
power_btn:add_flag(lvgl.FLAG.CLICKABLE)
-- LED: low, next to the screen, away from the D-pad; the box around it is the touch area
local led_hit=shape(root,363,163,30,30,C.bodyTop,15)
try_set(led_hit,{bg_opa=0})
led_hit:add_flag(lvgl.FLAG.CLICKABLE)
local led_glow=shape(root,366,166,24,24,C.ledGlow,12)
try_set(led_glow,{bg_opa=lvgl.OPA(30)})
led_glow:add_flag(lvgl.FLAG.HIDDEN)
local led=shape(root,370,170,16,16,C.ledOffTop,8)
try_set(led,{bg_grad_dir=2,border_width=1,border_color=0x140303}) grad(led,C.ledOffTop,C.ledOffBot)

-- screen: 224x202 (the Game Boy picture at exactly 1.4x), 14 px left of centre
local bezel=shape(root,128,1,232,210,C.bezel,8)
local SCREEN_X,SCREEN_Y,SCREEN_W,SCREEN_H=132,5,224,202
local display_bg=shape(root,SCREEN_X,SCREEN_Y,SCREEN_W,SCREEN_H,C.screenOff,0)

''')
cut('-- Controls keep away from the band\'s edges (a touch near a side edge starts a band gesture):', '-- (4.2.0: no diagnostics text on the face', '''-- D-pad on the right: a 120 px cross with 40 px arms, centre (446,106)
local dcenter=shape(root,426,86,40,40,C.padBot,0)
try_set(dcenter,{bg_grad_dir=2}) grad(dcenter,C.padBot,C.padTop)
control('U',426,46,40,40,6,C.padTop,C.padBot,C.padEdge,C.padDownTop,C.padDownBot)
control('D',426,126,40,40,6,C.padTop,C.padBot,C.padEdge,C.padDownTop,C.padDownBot)
control('L',386,86,40,40,6,C.padTop,C.padBot,C.padEdge,C.padDownTop,C.padDownBot)
control('R',466,86,40,40,6,C.padTop,C.padBot,C.padEdge,C.padDownTop,C.padDownBot)
-- A / B: 48 px berry buttons side by side on the left, A nearer the screen
control('B',20,82,48,48,24,C.abTop,C.abBot,C.abEdge,C.abDownTop,C.abDownBot)
control('A',76,82,48,48,24,C.abTop,C.abBot,C.abEdge,C.abDownTop,C.abDownBot)
control('START',66,136,58,24,12,C.pillTop,C.pillBot,C.pillEdge,C.pillDownTop,C.pillDownBot,'START',10,C.pillText)
control('SELECT',66,166,58,24,12,C.pillTop,C.pillBot,C.pillEdge,C.pillDownTop,C.pillDownBot,'SELECT',10,C.pillText)
''')
rep("    try_set(led,{bg_color=C.ledOnTop,bg_grad_color=C.ledOnBot})", "    grad(led,C.ledOnTop,C.ledOnBot)")
rep("    try_set(led,{bg_color=C.ledOffTop,bg_grad_color=C.ledOffBot})", "    grad(led,C.ledOffTop,C.ledOffBot)")

# ---------------------------------------------------------------------------- the game picture
rep("""  big   ={x=0, y=110,w=212,h=189,zoom=256,cf=CF_I8,stride=212,tag='8'},
  smooth={x=26,y=133,w=160,h=144,zoom=338,cf=CF_I2,stride=40, tag='2z'},
  fast  ={x=26,y=132,w=160,h=144,zoom=256,cf=CF_I2,stride=40, tag='2'},""","""  big   ={w=224,h=202,zoom=256,cf=CF_I8,stride=224,tag='8', aa=false},
  smooth={w=160,h=144,zoom=358,cf=CF_I2,stride=40, tag='2z',aa=true},
  fast  ={w=160,h=144,zoom=256,cf=CF_I2,stride=40, tag='2', aa=false},""")
rep("""local RUNS={{0,0,1,2,3,3},{0,1,2,2,3},{0,1,1,2,3},{0,0,1,2,3}}
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
end""","""-- landscape BIG: 160 -> 224 = exactly 7/5: every 5 framebuffer bytes (20 pixels) become 28
-- pixels; output pixel o shows source pixel (o*5)//7, so the 5 bytes of a group give runs of
-- 6, 6, 5, 6 and 5 pixels
local TB={}
for j=0,4 do
  TB[j+1]={}
  local q={}
  for o=0,27 do local sp=(o*5)//7 if sp//4==j then q[#q+1]=sp%4 end end
  for b=0,255 do
    local t={}
    for k,qq in ipairs(q) do t[k]=char((b>>(6-2*qq))&3) end
    TB[j+1][b+1]=concat(t)
  end
end
local T1,T2,T3,T4,T5=TB[1],TB[2],TB[3],TB[4],TB[5]
local PC={}
local function build_row(fb,i)
  for o=0,35,5 do
    PC[o+1]=T1[fb[i]+1] PC[o+2]=T2[fb[i+1]+1] PC[o+3]=T3[fb[i+2]+1] PC[o+4]=T4[fb[i+3]+1] PC[o+5]=T5[fb[i+4]+1]
    i=i+5
  end
  return concat(PC,'',1,40)
end""")
rep("for r=0,188 do YMAP[r+1]=(r*16)//21+1 end", "for r=0,201 do YMAP[r+1]=(r*144)//202+1 end")
rep("""  for r=1,189 do PARTS[r+1]=ROWS[YMAP[r]] end
  return concat(PARTS,'',1,190)""", """  for r=1,202 do PARTS[r+1]=ROWS[YMAP[r]] end
  return concat(PARTS,'',1,203)""")
rep("""  pcall(function() img:set({x=v.x,y=v.y,w=v.w,h=v.h}) end)
  pcall(function() img:set({zoom=v.zoom}) end)
end""","""  -- built upright, turned 90 degrees by the graphics chip around its centre, which lands on
  -- the centre of the screen area
  local cx,cy=Lpoint(SCREEN_X+SCREEN_W/2,SCREEN_Y+SCREEN_H/2)
  pcall(function() img:set({x=math.floor(cx-v.w/2),y=math.floor(cy-v.h/2),w=v.w,h=v.h}) end)
  pcall(function() img:set({zoom=v.zoom}) end)
  pcall(function() img:set({angle=(ORIENT==1) and 900 or 2700}) end)
  pcall(function() img:set({antialias=v.aa}) end)
end""")
rep("""  img=lvgl.Image(root,{x=v.x,y=v.y,w=v.w,h=v.h,pad_all=0})""", """  img=lvgl.Image(root,{x=0,y=0,w=v.w,h=v.h,pad_all=0})""")

# ---------------------------------------------------------------------------- clock
rep("clock_panel=shape(root,4,113,204,184,C.lcd,10)", "clock_panel=shape(root,142,14,204,184,C.lcd,10)")
rep("""local function asset_img(parent,x,y,file)
  local o=lvgl.Image(parent,{x=x,y=y,src=asset_dir()..file})""", """-- rotated copies of the clock images (clkr_*.bin); placed by their upright size
local ASZ={clk_red={78,162},clk_b={26,62},clk_s={10,16},clk_w={34,16},clk_dot={6,16}}
local function rfile(file) return (file:gsub('^clk_','clkr_')) end
local function asset_img(parent,x,y,file)
  local base=file:match('^(clk_%a+)') if base=='clk_dot' or base=='clk_red' then else base=file:match('^(clk_%a)') end
  local sz=ASZ[base] or {10,16}
  local px,py=L(parent,x,y,sz[1],sz[2])
  local o=lvgl.Image(parent,{x=px,y=py,src=asset_dir()..rfile(file)})""")
rep("""  pcall(function() local o=ck[key] if o.set_src then o:set_src(asset_dir()..file) else o:set({src=asset_dir()..file}) end end)""",
    """  pcall(function() local o=ck[key] if o.set_src then o:set_src(asset_dir()..rfile(file)) else o:set({src=asset_dir()..rfile(file)}) end end)""")

# ---------------------------------------------------------------------------- messages
rep("""msg_label=lvgl.Label(root,{x=8,y=116,w=196,h=30,text='',text_color=C.pillText,bg_opa=0,border_width=0})
do local f=F(11) if f then try_set(msg_label,{text_font=f}) end end
try_set(msg_label,{text_align=2})
msg_label:add_flag(lvgl.FLAG.HIDDEN)""", """-- messages on a dark strip across the top of the screen, readable over any game scene
do
  local strip=shape(root,138,9,212,52,C.panel,6)
  try_set(strip,{bg_opa=lvgl.OPA(88)})
  pcall(function() strip:clear_flag(lvgl.FLAG.CLICKABLE) end)
  local txt=textbox(strip,0,0,212,52,'',0xE6E9EC,200)
  msg_label={props=txt.props,flags=strip.flags}
  function msg_label:set(p) txt:set(p) end
  function msg_label:add_flag(f) pcall(function() strip:add_flag(f) end) end
  function msg_label:clear_flag(f) pcall(function() strip:clear_flag(f) end) end
  msg_label:add_flag(lvgl.FLAG.HIDDEN)
end""")

# ---------------------------------------------------------------------------- save browser
rep("browser=shape(root,0,104,212,202,C.panel,6)", "browser=shape(root,132,5,224,202,C.panel,6)")
rep("""  local t=lvgl.Label(browser,{x=0,y=6,w=212,h=18,text='SAVE FILES',text_color=C.pillText,bg_opa=0,border_width=0})
  local f=F(13) if f then try_set(t,{text_font=f}) end
  try_set(t,{text_align=2})""", """  textbox(browser,0,4,224,20,'SAVE FILES',C.pillText)""")
rep("""local empty_label=lvgl.Label(browser,{x=0,y=80,w=212,h=18,text='NO SAVE FILES',text_color=C.hudText,bg_opa=0,border_width=0})
do local f=F(12) if f then try_set(empty_label,{text_font=f}) end try_set(empty_label,{text_align=2}) end""",
    """local empty_label=textbox(browser,0,80,224,20,'NO SAVE FILES',C.hudText)""")
rep("""  local r=shape(browser,8,28+(i-1)*36,196,32,C.panelRow,8)
  local name=lvgl.Label(r,{x=8,y=8,w=122,h=16,text='',text_color=C.pillText,bg_opa=0,border_width=0})
  local f=F(11) if f then try_set(name,{text_font=f}) end""", """  local r=shape(browser,8,26+(i-1)*36,208,32,C.panelRow,8)
  local name=textbox(r,4,0,134,32,'',C.pillText)""")
rep("""  local btn=shape(r,134,3,58,26,C.pillTop,13)""", """  local btn=shape(r,144,3,58,26,C.pillTop,13)""")
rep("""close_btn=shape(browser,66,172,80,24,C.pillTop,12)""", """close_btn=shape(browser,72,172,80,24,C.pillTop,12)""")
open(OUT, 'w').write(s)
print('landscape template written:', OUT, len(s), 'bytes')
