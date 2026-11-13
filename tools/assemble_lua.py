"""Assemble app/lua/gbcore.lua from the template and the generated CPU tables."""
import os
here = os.path.dirname(os.path.abspath(__file__))
tpl = open(os.path.join(here, 'gbcore_template.lua')).read()
tables = open(os.path.join(here, 'cpu_tables.inc.lua')).read()
assert tpl.count('--@@CPU_TABLES@@') == 1 and tpl.count('--@@AOT@@') == 1
aot_path = os.path.join(here, 'aot_blocks.inc.lua')
aot = open(aot_path).read() if os.path.exists(aot_path) else '  -- (no compiled blocks)\n'
out = tpl.replace('--@@CPU_TABLES@@', tables).replace('--@@AOT@@', aot)
dst = os.path.join(here, 'gbcore.lua')   # test/dev copy; the watchface embeds it in main.lua
open(dst, 'w').write(out)
print('gbcore.lua', len(out), 'bytes')
