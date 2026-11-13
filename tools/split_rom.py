"""Write the cartridge as 64 bank files (app/lua/gbankNN.dat, 16 KiB each) from rom/pokemon_red.gb.
The watchface reads each bank file whole: no seeking inside one large embedded asset."""
import hashlib, os
here = os.path.dirname(os.path.abspath(__file__))
src = os.path.join(here, '..', 'rom', 'pokemon_red.gb')
dst = os.path.join(here, '..', 'RedBandLuaWatchface', 'app', 'lua')
rom = open(src, 'rb').read()
assert hashlib.sha256(rom).hexdigest() == '5ca7ba01642a3b27b0cc0b5349b52792795b62d3ed977e98a09390659af96b7b', 'unexpected ROM'
for name in os.listdir(dst):
    if name.startswith('gbank') or name in ('pokemon_red.gb', 'pokemon_red.rom'):
        os.remove(os.path.join(dst, name))
for n in range(64):
    open(os.path.join(dst, 'gbank%02d.dat' % n), 'wb').write(rom[n * 16384:(n + 1) * 16384])
print('64 bank files written to app/lua')
