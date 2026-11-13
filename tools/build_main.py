"""Write the watchface Lua files: app/lua/main.lua (UI, display, loop) from main_template.lua
and app/lua/gbcore.lua (emulator core + compiled blocks, loaded at POWER) from gbcore.lua."""
import os, shutil
here = os.path.dirname(os.path.abspath(__file__))
app = os.path.join(here, '..', 'RedBandLuaWatchface', 'app', 'lua')
tpl = open(os.path.join(here, 'main_template.lua')).read()
assert '--@@CORE@@' not in tpl
open(os.path.join(app, 'main.lua'), 'w').write(tpl)
core = open(os.path.join(here, 'gbcore.lua')).read()
assert core.rstrip().endswith('return M')
shutil.copy(os.path.join(here, 'gbcore.lua'), os.path.join(app, 'gbcore.lua'))
print('main.lua', len(tpl), 'bytes; gbcore.lua', len(core), 'bytes')
