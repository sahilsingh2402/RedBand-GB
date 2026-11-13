"""Ahead-of-time block compiler for the Lua watchface core (v2.6 fast-path blocks; v2.10 register caching).

Hot code blocks of Pokemon Red (chosen from a profile of entry points) are compiled at build
time into straight-line Lua inside the core, built from the SAME handler bodies the
interpreter uses, but with operands as constants: no opcode/operand fetch from the packed
ROM, no handler lookup, no call per instruction. Exactness rules (as in the verified JS
version):
  * after every instruction: if cyc >= nextEvt then return to the interpreter (events,
    interrupts, timer exactly where the interpreter would handle them);
  * a taken conditional branch returns; JP/JR/CALL/RET/RETI/RST/JP HL end the block;
  * in switchable-bank code, a write that changed the mapped bank returns;
  * HALT, STOP and illegal opcodes are never compiled;
  * enabled only when the cartridge header matches this ROM.
Output: aot_blocks.inc.lua (inserted into gbcore.lua by assemble_lua.py).
"""
import json, os, re, sys

here = os.path.dirname(os.path.abspath(__file__))
BUDGET = int(sys.argv[1]) if len(sys.argv) > 1 else 90_000      # bytes of generated block source
MIN_ENTRIES = 40
MAXLEN = 40

# ---- handler bodies with operands as placeholders -----------------------------------------
src = open(os.path.join(here, 'gen_cpu_lua.py')).read()
def rep(old, new):
    global src
    assert src.count(old) == 1, old[:70]
    src = src.replace(old, new)
rep('''IMM8 = fetch('n', 'pc') + "pc = pc + 1; "''', '''IMM8 = "local n = @B1@; "''')
rep('''IMM16 = (fetch('lo_', 'pc') + "local p1_ = (pc + 1) & 0xFFFF; " + fetch('hi_', 'p1_') +
         "local t = lo_ | (hi_ << 8); pc = pc + 2; ")''', '''IMM16 = "local t = @NN@; "''')
rep('''op(0x18, IMM8 + "pc = (pc + ((n ~ 0x80) - 0x80)) & 0xFFFF; cyc = cyc + 12")''',
    '''op(0x18, "pc = @JRT@; cyc = cyc + 12")''')
rep('''    op(0x20 | (i << 3), f"if {cond} then " + fetch('n', 'pc') + "pc = (pc + 1 + ((n ~ 0x80) - 0x80)) & 0xFFFF; cyc = cyc + 12 "
                        "else pc = pc + 1; cyc = cyc + 8 end")''',
    '''    op(0x20 | (i << 3), f"if {cond} then pc = @JRT@; cyc = cyc + 12 else cyc = cyc + 8 end")''')
rep('''open(os.path.join(here, "cpu_tables.inc.lua"), "w").write(out)''', '''pass''')
rep('''print("ops:", len(ops), "cb:", len(cb), "bytes:", len(out))''', '''pass''')
ns = {'__file__': os.path.join(here, 'gen_cpu_lua.py'), '__name__': 'aot'}
exec(compile(src, 'gen_cpu_lua(aot)', 'exec'), ns)
OPS, CBS = ns['ops'], ns['cb']
for k in list(OPS):
    OPS[k] = OPS[k].replace('pc = pc + 1; ', '').replace('pc = pc + 2; ', '')
    assert 'pc = pc +' not in OPS[k], (hex(k), OPS[k])

# ---- ROM, opcode lengths, profile ---------------------------------------------------------
rom = open(os.path.join(here, '..', 'rom', 'pokemon_red.gb'), 'rb').read()
L = json.load(open(os.path.join(here, 'aot', 'oplen.json')))
prof = json.load(open(os.path.join(here, 'aot', 'profile.json')))
NONCOMP = {0x76, 0x10, 0xD3, 0xDB, 0xDD, 0xE3, 0xE4, 0xEB, 0xEC, 0xED, 0xF4, 0xFC, 0xFD}
TERM = {0x18, 0xC3, 0xE9, 0xCD, 0xC9, 0xD9} | {0xC7 + 8 * i for i in range(8)}
COND = {0x20, 0x28, 0x30, 0x38, 0xC2, 0xCA, 0xD2, 0xDA, 0xC4, 0xCC, 0xD4, 0xDC, 0xC0, 0xC8, 0xD0, 0xD8}


def rom_at(bank, addr):
    return rom[addr if addr < 0x4000 else bank * 0x4000 + addr - 0x4000]


def build_block(bank, start):
    instrs, addr = [], start
    end = 0x4000 if start < 0x4000 else 0x8000
    while len(instrs) < MAXLEN:
        op = rom_at(bank, addr)
        n = L[op]
        if op in NONCOMP or addr + n > end:
            break
        b1 = rom_at(bank, addr + 1) if n > 1 else 0
        b2 = rom_at(bank, addr + 2) if n > 2 else 0
        instrs.append((addr, op, b1, b2, n))
        addr += n
        if op in TERM:
            break
    return instrs


def body_of(addr, op, b1, b2, n):
    if op == 0xCB:
        return CBS[b1]
    b = OPS[op]
    jrt = (addr + 2 + ((b1 ^ 0x80) - 0x80)) & 0xFFFF
    b = b.replace('@B1@', str(b1)).replace('@NN@', str(b1 | (b2 << 8))).replace('@JRT@', str(jrt))
    assert '@' not in b, b
    return b


CYC_RE = re.compile(r'cyc = cyc \+ (\d+)')
RISKY_RE = re.compile(r'\b(rd|wr|ior|iow|haltOp|illegal)\(|nextEvt|CB\[')


REGS = ['a', 'b', 'c', 'd', 'e', 'h', 'l', 'sp', 'zr', 'nf', 'hf', 'cf']
REG_RE = re.compile(r'\b(' + '|'.join(REGS) + r')\b')
WB = '\x00WB\x00'          # placeholder for the register write-back before each exit


REG_CACHE = False   # measured slower (blocks average ~7 instructions; load/store overhead > savings)


def cache_registers(code):
    """v2.10: inside a block the CPU registers live in Lua locals (VM registers) instead of
    upvalues: each use of an upvalue costs an extra VM instruction. Loaded after the entry
    guard, written back before every return. Calls made from ROM blocks (rd/wr/ior/iow) never
    read CPU registers (the only register-changing path, the HRAM DMA shortcut, requires
    pc in HRAM), so no write-back is needed around them."""
    head, rest = code.split('\x01BODY\x01', 1)
    if not REG_CACHE:
        return head + rest.replace(WB, '')
    used = sorted(set(REG_RE.findall(rest)), key=REGS.index)
    if not used:
        return head + rest.replace(WB, '')
    rest = REG_RE.sub(lambda m: 'R_' + m.group(1), rest)
    written = [r for r in used if re.search(r'\bR_' + r + r'\s*=(?!=)', rest)]
    wb = (', '.join(written) + ' = ' + ', '.join('R_' + r for r in written) + ' ') if written else ''
    rest = rest.replace(WB, wb)
    prologue = 'local ' + ', '.join('R_' + r for r in used) + ' = ' + ', '.join(used) + ' '
    return head + prologue + rest


SELF_LOOPS = False   # exact, but no measurable gain and fewer blocks fit the budget


def loop_back(start, maxc):
    """3.2.0: a branch back to the block's own start loops inside the function. If an event
    is due, or could fall inside the next pass, return to the main loop exactly as before
    (pc = start, return true: the main loop handles events first)."""
    return (f'pc = {start} if cyc + {maxc} >= nextEvt then ' + WB + 'return true end goto top')


def compile_block(bank, instrs):
    """v2.6 fast-path block.
    Entry guard: if an event could come due within the block's maximum cycle count, return
    false (the interpreter runs this stretch instead). Otherwise cyc cannot reach nextEvt
    inside the block unless an instruction moves nextEvt or observes cyc, i.e. one that
    calls rd/wr/ior/iow or touches nextEvt ("risky"). So the per-instruction event check is
    kept only after risky instructions, and cycle counts of the other instructions are
    summed and written once, before anything that can observe them or exit."""
    banked = instrs[0][0] >= 0x4000
    bodies = [body_of(*ins) for ins in instrs]
    maxc = sum(max(int(k) for k in CYC_RE.findall(b)) for b in bodies)
    start = instrs[0][0]
    out = ['function()', f'if cyc + {maxc} >= nextEvt then return false end']
    if banked and any('wr(' in b for b in bodies):
        out.append('local PXk = PX')
    out.append('\x01BODY\x01')
    if SELF_LOOPS:
        out.append('::top::')
    pending = 0
    def flush():
        nonlocal pending
        if pending:
            out.append(f'cyc = cyc + {pending}')
            pending = 0
    for (addr, op, b1, b2, n), body in zip(instrs, bodies):
        nxt = (addr + n) & 0xFFFF
        risky = RISKY_RE.search(body) is not None
        cycs = CYC_RE.findall(body)
        tail = re.search(r'cyc = cyc \+ (\d+)\s*$', body)
        pure = (not risky and op not in COND and op not in TERM and len(cycs) == 1 and tail
                and not re.search(r'\bpc\b', body))
        if pure:
            out.append(f'do {body[:tail.start()]} end')
            pending += int(tail.group(1))
            continue
        flush()
        pre = f'pc = {nxt}; ' if re.search(r'\bpc\b', body) else ''
        out.append(f'do {pre}{body} end')
        tgt = None
        if op in (0x18, 0x20, 0x28, 0x30, 0x38):
            tgt = (addr + 2 + ((b1 ^ 0x80) - 0x80)) & 0xFFFF
        elif op in (0xC3, 0xC2, 0xCA, 0xD2, 0xDA):
            tgt = b1 | (b2 << 8)
        selfloop = SELF_LOOPS and tgt == start and (start < 0x4000 or not banked or 'PX ~= PXk' not in ' '.join(out))
        if op in TERM:
            if selfloop and op in (0x18, 0xC3):
                out.append(loop_back(start, maxc) + ' end')
            else:
                out.append(WB + 'return true end')
            return cache_registers(' '.join(out))
        if op in COND:
            if selfloop:
                out.append(f'if pc ~= {nxt} then ' + loop_back(start, maxc) + ' end')
            else:
                out.append(f'if pc ~= {nxt} then ' + WB + 'return true end')
        if risky:
            chk = f'if cyc >= nextEvt then pc = {nxt} ' + WB + 'return true end'
            if banked and 'wr(' in body:
                chk += f' if PX ~= PXk then pc = {nxt} ' + WB + 'return true end'
            out.append(chk)
    flush()
    last = instrs[-1]
    out.append(f'pc = {(last[0] + last[4]) & 0xFFFF} ' + WB + 'return true end')
    return cache_registers(' '.join(out))


# Candidate start points: entry points from the profile, plus (v2.6) the addresses the Lua
# interpreter itself still runs (tools/profile_lua.lua -> aot/lua_interp.json). A block
# starting at any address is used whenever the interpreter reaches that address.
weights = {}
for key, count in prof['entries']:
    if count >= MIN_ENTRIES:
        weights[key] = weights.get(key, 0) + count
lua_prof = os.path.join(here, 'aot', 'lua_interp.json')
if os.path.exists(lua_prof):
    for key, count in json.load(open(lua_prof))['entries']:
        if count >= MIN_ENTRIES:
            weights[key] = max(weights.get(key, 0), count)
cands = []
for key, count in weights.items():
    bank, pc = (key >> 16, key & 0xFFFF) if key > 0xFFFF else (0, key)
    instrs = build_block(bank, pc)
    if instrs:
        cands.append((count * len(instrs), bank, pc, instrs))
        # continuation: a block that stops at HALT/STOP/illegal or at the length limit is
        # followed by sequential code that no jump profile counts: start a block there too
        last = instrs[-1]
        if last[1] not in TERM:
            nxt = last[0] + last[4]
            if rom_at(bank, nxt) in NONCOMP:
                nxt += L[rom_at(bank, nxt)]
            if nxt < (0x4000 if pc < 0x4000 else 0x8000):
                more = build_block(bank, nxt)
                if more:
                    cands.append((count * len(more), bank, nxt, more))
cands.sort(key=lambda c: -c[0])

blocks, size, seen = [], 0, set()
for w, bank, pc, instrs in cands:
    if (bank if pc >= 0x4000 else 0, pc) in seen:
        continue
    seen.add((bank if pc >= 0x4000 else 0, pc))
    code = compile_block(bank, instrs)
    if size + len(code) > BUDGET:
        continue
    blocks.append((bank, pc, code))
    size += len(code)

sig = list(rom[0x134:0x150])
lines = ['  -- AUTO-GENERATED by tools/gen_aot_lua.py (%d compiled blocks). Do not edit by hand.' % len(blocks),
         '  AOT_SIG = {%s}' % ','.join(map(str, sig))]
for bank, pc, code in blocks:
    if pc < 0x4000:
        lines.append(f'  B0[{pc}] = {code}')
    else:
        lines.append(f'  AOT_BANKS[{bank}] = AOT_BANKS[{bank}] or {{}}; AOT_BANKS[{bank}][{pc}] = {code}')
# ---- high-level replacement of the joypad routine (v2.10) -----------------------------------
# Pokemon Red polls `Joypad` (home 0x019A -> bank 3 `_Joypad`) ~23x per frame while text waits
# for a button: ~20% of all instructions. On its common path (no soft-reset combo, input not
# discarded, no ignored buttons) its complete effect is reproduced here: HRAM joypad bytes,
# B/D/E, A and flags as left by `pop af`, the stack bytes written by `push af` and `call`, the
# final ROM-bank register write and exactly 352 cycles. Anything else -> normal execution.
lines.append('''  do
    local fallback = B0[0x019A]          -- compiled block, used when the common path does not apply
    B0[0x019A] = function()
      if cyc + 352 >= nextEvt then if fallback then return fallback() end return false end
      local S = sp
      local input = RAM[0xF8 + 24833]
      if S < 0xC004 or S > 0xDFFE or input == 0x0F or (RAM[0xD730 - 0x7FFF] & 0x20) ~= 0 or RAM[0xCD6B - 0x7FFF] ~= 0 then
        if fallback then return fallback() end
        return false
      end
      local old, last = RAM[0xB8 + 24833], RAM[0xB1 + 24833]
      local fl = ((zr == 0) and 0x80 or 0) | (nf << 6) | (hf << 5) | (cf << 4)
      RAM[S - 2 - 0x7FFF] = fl RAM[S - 1 - 0x7FFF] = old          -- push af
      RAM[S - 4 - 0x7FFF] = 0xA7 RAM[S - 3 - 0x7FFF] = 0x01       -- call _Joypad (returns to 0x01A7)
      local x = last ~ input
      RAM[0xB2 + 24833] = x & last                                  -- hJoyReleased
      RAM[0xB3 + 24833] = x & input                                 -- hJoyPressed
      RAM[0xB1 + 24833] = input                                     -- hJoyLast
      RAM[0xB4 + 24833] = input                                     -- hJoyHeld
      b = input d = x e = last a = old
      zr = ((fl & 0x80) ~= 0) and 0 or 1 nf = (fl >> 6) & 1 hf = (fl >> 5) & 1 cf = (fl >> 4) & 1
      cyc = cyc + 352
      wr(0x2000, old)                                               -- ld [MBC1RomBank],a
      pc = RAM[S - 0x7FFF] | (RAM[S + 1 - 0x7FFF] << 8)            -- ret
      sp = (S + 2) & 0xFFFF
      return true
    end
  end
  -- Busy-wait loop at 0x38F6: call Joypad, leave if A or B is held, loop while the frame
  -- counter (changed only by the VBlank interrupt) is non-zero. Once the input has been
  -- processed (hJoyLast == hJoyInput) every pass is identical: same registers, the same
  -- bytes at the same stack addresses, 456 cycles. So all whole passes that finish before
  -- the next event are applied at once, exactly. The first pass, an exiting pass or any
  -- other path runs normally.
  do
    local fallback = B0[0x38F6]
    B0[0x38F6] = function()
      local S = sp
      local input, counter = RAM[0xF8 + 24833], RAM[0xD5 + 24833]
      if S < 0xC006 or S > 0xDFFE or input == 0x0F or (input & 3) ~= 0 or counter == 0
         or RAM[0xB1 + 24833] ~= input or (RAM[0xD730 - 0x7FFF] & 0x20) ~= 0 or RAM[0xCD6B - 0x7FFF] ~= 0 then
        if fallback then return fallback() end
        return false
      end
      local k = (nextEvt - cyc - 1) // 456                         -- whole passes before the next event
      if k < 1 then if fallback then return fallback() end return false end
      local old = RAM[0xB8 + 24833]
      local fl = ((zr == 0) and 0x80 or 0) | (nf << 6) | (hf << 5) | (cf << 4)
      if k >= 2 then fl = 0x20 end                                  -- flags at the loop head after a pass
      RAM[S - 1 - 0x7FFF] = 0x38 RAM[S - 2 - 0x7FFF] = 0xF9       -- call Joypad (returns to 0x38F9)
      RAM[S - 3 - 0x7FFF] = old RAM[S - 4 - 0x7FFF] = fl          -- push af in Joypad
      RAM[S - 5 - 0x7FFF] = 0x01 RAM[S - 6 - 0x7FFF] = 0xA7       -- call _Joypad (returns to 0x01A7)
      RAM[0xB2 + 24833] = 0 RAM[0xB3 + 24833] = 0                  -- nothing released / pressed
      RAM[0xB1 + 24833] = input RAM[0xB4 + 24833] = input
      a = counter b = input d = 0 e = input
      zr = counter nf = 0 hf = 1 cf = 0                             -- and a
      cyc = cyc + k * 456
      wr(0x2000, old)
      pc = 0x38F6
      return true
    end
  end''')
# ---- sprite-slot clearing loop at 01:4BCB (3.1.0) ---------------------------------------------
# `cp l / ret z / ld [hl],b / add hl,de / jr -6`: PrepareOAMData fills the unused sprite slots
# every frame; ~11% of all instructions while walking. Exact effect: B written every DE bytes
# from HL until the low byte of HL equals A, flags as after `cp l` with equal values, 40 cycles
# per pass + 24 for the final compare and return. Writes outside work RAM, more than 256
# passes, an event inside the span or an unusual stack -> the compiled block runs instead.
lines.append('''  do
    local banks = AOT_BANKS[1] or {}
    AOT_BANKS[1] = banks
    local fallback = banks[0x4BCB]
    banks[0x4BCB] = function()
      local S = sp
      local t = (h << 8) | l
      local de = (d << 8) | e
      if S < 0x8000 or S >= 0xDFFF then if fallback then return fallback() end return false end
      local k, u = 0, t
      while (u & 255) ~= a do
        if u < 0xC000 or u >= 0xE000 or k >= 256 then if fallback then return fallback() end return false end
        u = (u + de) & 0xFFFF
        k = k + 1
      end
      local total = k * 40 + 24
      if cyc + total >= nextEvt then if fallback then return fallback() end return false end
      u = t
      for _ = 1, k do RAM[u - 0x7FFF] = b u = (u + de) & 0xFFFF end
      h = (u >> 8) & 255 l = u & 255
      zr = 0 nf = 1 hf = 0 cf = 0                                   -- cp l, A == L
      cyc = cyc + total
      pc = RAM[S - 0x7FFF] | (RAM[S - 0x7FFE] << 8)                -- ret z
      sp = (S + 2) & 0xFFFF
      return true
    end
  end''')
open(os.path.join(here, 'aot_blocks.inc.lua'), 'w').write('\n'.join(lines) + '\n')
print(f'{len(blocks)} blocks compiled, {size // 1024} KB of Lua source (budget {BUDGET // 1024} KB)')
