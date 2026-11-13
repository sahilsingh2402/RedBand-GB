"""Build the three engine sizes and their precompiled forms (4.1.0).

  gbcore.lua        S core (compiled-block budget 260 KB), Lua source: the always-working fallback
  gbcore_s.luac     S core, Lua 5.4.0 bytecode, debug info stripped
  gbcore_l.luac     L core (520 KB budget, bank 0 unpacked): ~25% less emulation time walking
  gbcore_xl.luac    XL core (1000 KB budget, bank 0 unpacked): ~35% less emulation time walking

Bytecode is produced by a real Lua 5.4.0 (tests/bandhost32: 32-bit, 64-bit integers, doubles), the
band's exact version; its header (version, format, sizes of Instruction/lua_Integer/lua_Number and
test values) is checked by the band's loader, so a mismatch is refused and main.lua falls back.
Needs: tests/build_hosts.sh run once (bandhost32)."""
import os, shutil, subprocess, sys
here = os.path.dirname(os.path.abspath(__file__))
root = os.path.join(here, '..')
app = os.path.join(root, 'RedBandLuaWatchface', 'app', 'lua')
host = os.path.join(root, 'tests', 'bandhost32')
if not os.path.exists(host):
    subprocess.check_call(['sh', os.path.join(root, 'tests', 'build_hosts.sh')])
dump = os.path.join(here, '_dump.lua')
open(dump, 'w').write("local f = assert(loadfile(arg[1])); local o = io.open(arg[2], 'wb'); o:write(string.dump(f, true)); o:close()\n")
def run(*a): subprocess.check_call(list(a), cwd=here, stdout=subprocess.DEVNULL)
run(sys.executable, 'gen_cpu_lua.py')
keep = open(os.path.join(here, 'aot_blocks.inc.lua')).read() if os.path.exists(os.path.join(here, 'aot_blocks.inc.lua')) else None
for name, budget in (('xl', 1000000), ('l', 520000), ('s', 260000)):
    run(sys.executable, 'gen_aot_lua.py', str(budget))
    run(sys.executable, 'assemble_lua.py')
    src = os.path.join(here, 'gbcore.lua')
    if name in ('l', 'xl'):
        # L/XL: bank 0 (always mapped) as plain bytes, P0B[a+1] instead of a shift/mask per read
        # (+224 KB, ~6% less emulation time); the host supplies host.bank0bytes()
        import re
        code = open(src).read()
        pat = re.compile(r'\(?\(P0\[\((\w+) >> WSH\) \+ 1\] >> \(\(\1 & WMA\) << 3\)\) & 255\)?')
        code, k = pat.subn(lambda m: 'P0B[%s + 1]' % m.group(1), code)
        assert k > 200 and 'P0[' not in code, k
        code = code.replace('  local P0 = host.bank0()\n', '  local P0B = host.bank0bytes()\n')
        assert 'host.bank0bytes' in code
        open(src, 'w').write(code)
    out = os.path.join(app, 'gbcore_%s.luac' % name)
    subprocess.check_call([host, '0', dump, src, out], stdout=subprocess.DEVNULL)
    shutil.copy(src, os.path.join(here, 'gbcore_%s.lua' % name))
    print('gbcore_%s.luac' % name, os.path.getsize(out), 'bytes')
# leave tools/gbcore.lua + app/lua/gbcore.lua = S source (tests and fallback)
shutil.copy(os.path.join(here, 'gbcore_s.lua'), os.path.join(here, 'gbcore.lua'))
shutil.copy(os.path.join(here, 'gbcore.lua'), os.path.join(app, 'gbcore.lua'))
os.remove(dump)
