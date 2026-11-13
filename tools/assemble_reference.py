"""Assemble tests/gbcore_perline_reference.lua: the core with the line-by-line renderer used
up to 3.1.0 (tools/gbcore_template_perline_reference.lua), same CPU tables and compiled blocks.
Used by tests/render_equiv.lua to prove catch-up rendering draws identical frames."""
import os
here = os.path.dirname(os.path.abspath(__file__))
tpl = open(os.path.join(here, 'gbcore_template_perline_reference.lua')).read()
tables = open(os.path.join(here, 'cpu_tables.inc.lua')).read()
aot = open(os.path.join(here, 'aot_blocks.inc.lua')).read()
out = tpl.replace('--@@CPU_TABLES@@', tables).replace('--@@AOT@@', aot)
open(os.path.join(here, '..', 'tests', 'gbcore_perline_reference.lua'), 'w').write(out)
print('reference core assembled')
