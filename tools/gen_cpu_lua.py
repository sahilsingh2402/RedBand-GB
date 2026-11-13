"""Generate SM83 (Game Boy CPU) opcode handlers as Lua 5.4 for the watchface core.

Port of the JS generator that passes Blargg cpu_instrs/instr_timing. Conventions:
  * registers a b c d e h l sp pc are upvalues; flags zr (Z set iff zr == 0), nf, hf, cf in {0,1}
  * Lua treats 0 as TRUE, so every flag/value test is an explicit comparison
  * memory: R0 = ROM bank 0 (keys 1..16384), RX = mapped bank (keys 1..16384),
    RAM = 0x8000..0xFFFF (keys 1..32768, i.e. addr - 0x7FFF)
  * ROM is packed: P0 (bank 0) / PX (mapped bank), 2^WSH bytes per Lua integer; fetches
    decode by address (v2.3 memory-lean layout); RAM is compact (see the template)
"""
import os

R = ["b", "c", "d", "e", "h", "l", None, "a"]


# Bank 0 representation. Packed (False) needs ~270 KB less Lua heap; plain (True) is ~10%
# faster. v2.3 ships packed: the Band 10 watchface heap is the binding constraint.
BANK0_PLAIN = False


def rom_byte(table, idx):
    """Byte `idx` (0-based) of ROM: packed tables (2^WSH bytes per integer), or a plain
    byte table for bank 0 when BANK0_PLAIN."""
    if table == 'P0' and BANK0_PLAIN:
        return f"P0[{idx} + 1]"
    return f"(({table}[({idx} >> WSH) + 1] >> (({idx} & WMA) << 3)) & 255)"


def rd_into(var, addr):
    """Read byte at address expression `addr` (already a local) into local `var`."""
    return (f"local {var}; if {addr} < 0x8000 then if {addr} < 0x4000 then {var} = {rom_byte('P0', addr)} "
            f"else {var} = {rom_byte('PX', '(' + addr + ' - 0x4000)')} end elseif {addr} < 0xE000 then {var} = RAM[{addr} - 0x7FFF] "
            f"else {var} = rd({addr}) end ")


def fetch(var, addr):
    """Instruction/operand fetch: same decode as a data read."""
    return rd_into(var, addr)


def wr_fast(addr, val):
    return (f"if {addr} >= 0xC000 and {addr} < 0xE000 then RAM[{addr} - 0x7FFF] = {val} "
            f"else wr({addr}, {val}) end ")


RD_HL = "local t = (h << 8) | l; " + rd_into("v", "t")
IMM8 = fetch('n', 'pc') + "pc = pc + 1; "
IMM16 = (fetch('lo_', 'pc') + "local p1_ = (pc + 1) & 0xFFFF; " + fetch('hi_', 'p1_') +
         "local t = lo_ | (hi_ << 8); pc = pc + 2; ")
REGION = ""   # v2.3: fetch decodes by address; no per-region fetch table to switch

ops, cb = {}, {}


def op(code, body):
    assert code not in ops, hex(code)
    ops[code] = body


# ---- 8-bit loads ------------------------------------------------------------------
for dst in range(8):
    for src in range(8):
        code = 0x40 | (dst << 3) | src
        if code == 0x76:
            continue
        if dst == 6:
            op(code, "local t = (h << 8) | l; " + wr_fast("t", R[src]) + "cyc = cyc + 8")
        elif src == 6:
            op(code, RD_HL + f"{R[dst]} = v; cyc = cyc + 8")
        elif dst == src:
            op(code, "cyc = cyc + 4")
        else:
            op(code, f"{R[dst]} = {R[src]}; cyc = cyc + 4")

for r in range(8):
    ld_n, inc, dec = 0x06 | (r << 3), 0x04 | (r << 3), 0x05 | (r << 3)
    if r == 6:
        op(ld_n, IMM8 + "local t = (h << 8) | l; " + wr_fast("t", "n") + "cyc = cyc + 12")
        op(inc, RD_HL + "local x = (v + 1) & 255; zr = x; nf = 0; hf = ((x & 15) == 0) and 1 or 0; "
                + wr_fast("t", "x") + "cyc = cyc + 12")
        op(dec, RD_HL + "local x = (v - 1) & 255; zr = x; nf = 1; hf = ((x & 15) == 15) and 1 or 0; "
                + wr_fast("t", "x") + "cyc = cyc + 12")
    else:
        x = R[r]
        op(ld_n, IMM8 + f"{x} = n; cyc = cyc + 8")
        op(inc, f"{x} = ({x} + 1) & 255; zr = {x}; nf = 0; hf = (({x} & 15) == 0) and 1 or 0; cyc = cyc + 4")
        op(dec, f"{x} = ({x} - 1) & 255; zr = {x}; nf = 1; hf = (({x} & 15) == 15) and 1 or 0; cyc = cyc + 4")


# ---- 8-bit ALU --------------------------------------------------------------------
def alu(kind, s):
    if kind == 0:
        return f"local r = a + {s}; hf = ((a & 15) + ({s} & 15)) >> 4; cf = r >> 8; a = r & 255; zr = a; nf = 0; "
    if kind == 1:
        return f"local r = a + {s} + cf; hf = ((a & 15) + ({s} & 15) + cf) >> 4; cf = r >> 8; a = r & 255; zr = a; nf = 0; "
    if kind == 2:
        return f"local r = a - {s}; hf = ((a & 15) < ({s} & 15)) and 1 or 0; cf = (r < 0) and 1 or 0; a = r & 255; zr = a; nf = 1; "
    if kind == 3:
        return (f"local r = a - {s} - cf; hf = (((a & 15) - ({s} & 15) - cf) < 0) and 1 or 0; "
                f"cf = (r < 0) and 1 or 0; a = r & 255; zr = a; nf = 1; ")
    if kind == 4:
        return f"a = a & {s}; zr = a; nf = 0; hf = 1; cf = 0; "
    if kind == 5:
        return f"a = a ~ {s}; zr = a; nf = 0; hf = 0; cf = 0; "
    if kind == 6:
        return f"a = a | {s}; zr = a; nf = 0; hf = 0; cf = 0; "
    if kind == 7:
        return f"local r = a - {s}; hf = ((a & 15) < ({s} & 15)) and 1 or 0; cf = (r < 0) and 1 or 0; zr = r; nf = 1; "


for kind in range(8):
    for src in range(8):
        code = 0x80 | (kind << 3) | src
        if src == 6:
            op(code, RD_HL + alu(kind, "v") + "cyc = cyc + 8")
        elif kind == 5 and R[src] == "a":
            op(code, "a = 0; zr = 0; nf = 0; hf = 0; cf = 0; cyc = cyc + 4")
        else:
            op(code, alu(kind, R[src]) + "cyc = cyc + 4")
    op(0xC6 | (kind << 3), IMM8 + alu(kind, "n") + "cyc = cyc + 8")

# ---- 16-bit -------------------------------------------------------------------------
pairs = [("b", "c"), ("d", "e"), ("h", "l")]
for i, (hi, lo) in enumerate(pairs):
    op(0x01 | (i << 4), IMM16 + f"{lo} = t & 255; {hi} = t >> 8; cyc = cyc + 12")
    op(0x03 | (i << 4), f"{lo} = ({lo} + 1) & 255; if {lo} == 0 then {hi} = ({hi} + 1) & 255 end; cyc = cyc + 8")
    op(0x0B | (i << 4), f"{lo} = ({lo} - 1) & 255; if {lo} == 255 then {hi} = ({hi} - 1) & 255 end; cyc = cyc + 8")
    op(0x09 | (i << 4), f"local hl = (h << 8) | l; local s = ({hi} << 8) | {lo}; local r = hl + s; "
                        "hf = ((hl & 0xFFF) + (s & 0xFFF)) >> 12; cf = r >> 16; h = (r >> 8) & 255; l = r & 255; nf = 0; cyc = cyc + 8")
op(0x31, IMM16 + "sp = t; cyc = cyc + 12")
op(0x33, "sp = (sp + 1) & 0xFFFF; cyc = cyc + 8")
op(0x3B, "sp = (sp - 1) & 0xFFFF; cyc = cyc + 8")
op(0x39, "local hl = (h << 8) | l; local r = hl + sp; hf = ((hl & 0xFFF) + (sp & 0xFFF)) >> 12; cf = r >> 16; "
         "h = (r >> 8) & 255; l = r & 255; nf = 0; cyc = cyc + 8")

op(0x02, "wr((b << 8) | c, a); cyc = cyc + 8")
op(0x12, "wr((d << 8) | e, a); cyc = cyc + 8")
op(0x0A, "local t = (b << 8) | c; " + rd_into("v", "t") + "a = v; cyc = cyc + 8")
op(0x1A, "local t = (d << 8) | e; " + rd_into("v", "t") + "a = v; cyc = cyc + 8")
op(0x22, "local t = (h << 8) | l; " + wr_fast("t", "a") + "l = (l + 1) & 255; if l == 0 then h = (h + 1) & 255 end; cyc = cyc + 8")
op(0x32, "local t = (h << 8) | l; " + wr_fast("t", "a") + "l = (l - 1) & 255; if l == 255 then h = (h - 1) & 255 end; cyc = cyc + 8")
op(0x2A, RD_HL + "a = v; l = (l + 1) & 255; if l == 0 then h = (h + 1) & 255 end; cyc = cyc + 8")
op(0x3A, RD_HL + "a = v; l = (l - 1) & 255; if l == 255 then h = (h - 1) & 255 end; cyc = cyc + 8")

op(0x08, IMM16 + "wr(t, sp & 255); wr((t + 1) & 0xFFFF, sp >> 8); cyc = cyc + 20")
op(0xEA, IMM16 + "wr(t, a); cyc = cyc + 16")
op(0xFA, IMM16 + rd_into("v", "t") + "a = v; cyc = cyc + 16")
# compact RAM: 0xFF00 + n -> RAM key n + 24833
op(0xE0, IMM8 + "if n >= 0x80 and n < 0xFF then RAM[n + 24833] = a else wr(0xFF00 | n, a) end; cyc = cyc + 12")
op(0xF0, IMM8 + "if n >= 0x80 then a = RAM[n + 24833] else a = ior(n) end; cyc = cyc + 12")
op(0xE2, "if c >= 0x80 and c < 0xFF then RAM[c + 24833] = a else wr(0xFF00 | c, a) end; cyc = cyc + 8")
op(0xF2, "if c >= 0x80 then a = RAM[c + 24833] else a = ior(c) end; cyc = cyc + 8")
op(0xF9, "sp = (h << 8) | l; cyc = cyc + 8")
op(0xE8, IMM8 + "local s = (n ~ 0x80) - 0x80; hf = ((sp & 15) + (n & 15)) >> 4; cf = ((sp & 255) + n) >> 8; "
         "sp = (sp + s) & 0xFFFF; zr = 1; nf = 0; cyc = cyc + 16")
op(0xF8, IMM8 + "local s = (n ~ 0x80) - 0x80; hf = ((sp & 15) + (n & 15)) >> 4; cf = ((sp & 255) + n) >> 8; "
         "local r = (sp + s) & 0xFFFF; h = r >> 8; l = r & 255; zr = 1; nf = 0; cyc = cyc + 12")


# ---- stack -----------------------------------------------------------------------------
def push(hi, lo):
    return (f"sp = (sp - 2) & 0xFFFF; if sp >= 0xC000 and sp < 0xDFFF then RAM[sp - 0x7FFF] = {lo}; RAM[sp - 0x7FFE] = {hi} "
            f"else wr(sp, {lo}); wr((sp + 1) & 0xFFFF, {hi}) end; ")


# POP fast path only inside RAM: Pokemon streams data out of banked ROM with `ld sp,hl / pop`.
POP = ("local lo, hi; if sp >= 0x8000 and sp < 0xDFFF then lo = RAM[sp - 0x7FFF]; hi = RAM[sp - 0x7FFE] "
       "else lo = rd(sp); hi = rd((sp + 1) & 0xFFFF) end; sp = (sp + 2) & 0xFFFF; ")
for i, (hi, lo) in enumerate(pairs):
    op(0xC5 | (i << 4), push(hi, lo) + "cyc = cyc + 16")
    op(0xC1 | (i << 4), POP + f"{hi} = hi; {lo} = lo; cyc = cyc + 12")
op(0xF5, "local fl = ((zr == 0) and 0x80 or 0) | (nf << 6) | (hf << 5) | (cf << 4); " + push("a", "fl") + "cyc = cyc + 16")
op(0xF1, POP + "a = hi; zr = ((lo & 0x80) ~= 0) and 0 or 1; nf = (lo >> 6) & 1; hf = (lo >> 5) & 1; cf = (lo >> 4) & 1; cyc = cyc + 12")

# ---- jumps / calls --------------------------------------------------------------------------
conds = {"nz": "zr ~= 0", "z": "zr == 0", "nc": "cf == 0", "c": "cf ~= 0"}
op(0x18, IMM8 + "pc = (pc + ((n ~ 0x80) - 0x80)) & 0xFFFF; cyc = cyc + 12")
for i, cc in enumerate(["nz", "z", "nc", "c"]):
    cond = conds[cc]
    op(0x20 | (i << 3), f"if {cond} then " + fetch('n', 'pc') + "pc = (pc + 1 + ((n ~ 0x80) - 0x80)) & 0xFFFF; cyc = cyc + 12 "
                        "else pc = pc + 1; cyc = cyc + 8 end")
    op(0xC2 | (i << 3), f"if {cond} then " + IMM16 + "pc = t; cyc = cyc + 16 "
                        "else pc = pc + 2; cyc = cyc + 12 end")
    op(0xC4 | (i << 3), f"if {cond} then " + IMM16 + push("pc >> 8", "pc & 255") + "pc = t; " + REGION +
                        "cyc = cyc + 24 else pc = pc + 2; cyc = cyc + 12 end")
    op(0xC0 | (i << 3), f"if {cond} then " + POP + "pc = lo | (hi << 8); " + REGION + "cyc = cyc + 20 else cyc = cyc + 8 end")
op(0xC3, IMM16 + "pc = t; cyc = cyc + 16")
op(0xE9, "pc = (h << 8) | l; " + REGION + "cyc = cyc + 4")
op(0xCD, IMM16 + push("pc >> 8", "pc & 255") + "pc = t; " + REGION + "cyc = cyc + 24")
op(0xC9, POP + "pc = lo | (hi << 8); " + REGION + "cyc = cyc + 16")
op(0xD9, POP + "pc = lo | (hi << 8); " + REGION + "ime = 1; imeDelay = 0; nextEvt = cyc; cyc = cyc + 16")
for i in range(8):
    op(0xC7 | (i << 3), push("pc >> 8", "pc & 255") + f"pc = {i * 8}; cyc = cyc + 16")

# ---- misc ---------------------------------------------------------------------------------------
op(0x00, "cyc = cyc + 4")
op(0x10, "pc = pc + 1; cyc = cyc + 4")
op(0x76, "cyc = cyc + 4; haltOp()")
op(0xF3, "ime = 0; imeDelay = 0; cyc = cyc + 4")
op(0xFB, "if ime == 0 then imeDelay = 1; nextEvt = cyc + 4 end; cyc = cyc + 4")
op(0x07, "cf = a >> 7; a = ((a << 1) | cf) & 255; zr = 1; nf = 0; hf = 0; cyc = cyc + 4")
op(0x0F, "cf = a & 1; a = (a >> 1) | (cf << 7); zr = 1; nf = 0; hf = 0; cyc = cyc + 4")
op(0x17, "local r = (a << 1) | cf; cf = r >> 8; a = r & 255; zr = 1; nf = 0; hf = 0; cyc = cyc + 4")
op(0x1F, "local o = a & 1; a = (a >> 1) | (cf << 7); cf = o; zr = 1; nf = 0; hf = 0; cyc = cyc + 4")
op(0x27, "if nf == 0 then if cf ~= 0 or a > 0x99 then a = a + 0x60; cf = 1 end; if hf ~= 0 or (a & 15) > 9 then a = a + 6 end "
         "else if cf ~= 0 then a = a - 0x60 end; if hf ~= 0 then a = a - 6 end end; a = a & 255; zr = a; hf = 0; cyc = cyc + 4")
op(0x2F, "a = a ~ 255; nf = 1; hf = 1; cyc = cyc + 4")
op(0x37, "nf = 0; hf = 0; cf = 1; cyc = cyc + 4")
op(0x3F, "nf = 0; hf = 0; cf = cf ~ 1; cyc = cyc + 4")
op(0xCB, IMM8 + "CB[n]()")
for bad in [0xD3, 0xDB, 0xDD, 0xE3, 0xE4, 0xEB, 0xEC, 0xED, 0xF4, 0xFC, 0xFD]:
    op(bad, "illegal(pc - 1)")
assert len(ops) == 256, len(ops)


# ---- CB-prefixed ------------------------------------------------------------------------------
def cb_shift(kind, x):
    return {
        0: f"cf = {x} >> 7; {x} = (({x} << 1) | cf) & 255; ",
        1: f"cf = {x} & 1; {x} = ({x} >> 1) | (cf << 7); ",
        2: f"local r = ({x} << 1) | cf; cf = r >> 8; {x} = r & 255; ",
        3: f"local o = {x} & 1; {x} = ({x} >> 1) | (cf << 7); cf = o; ",
        4: f"cf = {x} >> 7; {x} = ({x} << 1) & 255; ",
        5: f"cf = {x} & 1; {x} = ({x} >> 1) | ({x} & 0x80); ",
        6: f"{x} = (({x} << 4) | ({x} >> 4)) & 255; cf = 0; ",
        7: f"cf = {x} & 1; {x} = {x} >> 1; ",
    }[kind] + f"zr = {x}; nf = 0; hf = 0; "


for code in range(256):
    grp, y, r = code >> 6, (code >> 3) & 7, code & 7
    if r == 6:
        if grp == 0:
            body = "local t = (h << 8) | l; " + rd_into("v", "t") + cb_shift(y, "v") + "wr(t, v); cyc = cyc + 16"
        elif grp == 1:
            body = RD_HL + f"zr = v & {1 << y}; nf = 0; hf = 1; cyc = cyc + 12"
        elif grp == 2:
            body = RD_HL + f"wr(t, v & {255 ^ (1 << y)}); cyc = cyc + 16"
        else:
            body = RD_HL + f"wr(t, v | {1 << y}); cyc = cyc + 16"
    else:
        x = R[r]
        if grp == 0:
            body = cb_shift(y, x) + "cyc = cyc + 8"
        elif grp == 1:
            body = f"zr = {x} & {1 << y}; nf = 0; hf = 1; cyc = cyc + 8"
        elif grp == 2:
            body = f"{x} = {x} & {255 ^ (1 << y)}; cyc = cyc + 8"
        else:
            body = f"{x} = {x} | {1 << y}; cyc = cyc + 8"
    cb[code] = body


def emit(name, table):
    lines = [f"  {name} = {{"]
    for code in range(256):
        key = f"[{code}]" if code == 0 else ""
        prefix = f"[0] = " if code == 0 else ""
        lines.append(f"    {prefix}function() {table[code]} end, -- {code:02X}")
    lines.append("  }")
    return "\n".join(lines)


out = "  -- AUTO-GENERATED by tools/gen_cpu_lua.py. Do not edit by hand.\n"
out += emit("OP", ops) + "\n" + emit("CB", cb) + "\n"
here = os.path.dirname(os.path.abspath(__file__))
open(os.path.join(here, "cpu_tables.inc.lua"), "w").write(out)
print("ops:", len(ops), "cb:", len(cb), "bytes:", len(out))
