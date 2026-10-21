# usage: dis.py <va_hex> [count]  -> disassemble, annotate rip-relative strings
import sys, pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_64

pe = pefile.PE("/bin64/WindroseServer-Win64-Shipping.exe", fast_load=True)
base = pe.OPTIONAL_HEADER.ImageBase
va = int(sys.argv[1], 16)
n = int(sys.argv[2]) if len(sys.argv) > 2 else 120
code = pe.get_data(va - base, n * 15)
md = Cs(CS_ARCH_X86, CS_MODE_64)
md.detail = True


def peek_str(rva):
    try:
        b = pe.get_data(rva, 120)
    except Exception:
        return None
    a = b.split(b"\0")[0]
    if len(a) >= 4 and all(32 <= c < 127 for c in a):
        return a.decode()
    if b[1:2] == b"\0":
        u = b.decode("utf-16-le", "ignore").split("\0")[0]
        if len(u) >= 4 and u.isprintable():
            return "L" + u
    return None


for i, ins in enumerate(md.disasm(code, va)):
    if i >= n:
        break
    note = ""
    if "rip" in ins.op_str:
        for op in ins.operands:
            if op.type == 3 and op.mem.base != 0 and ins.reg_name(op.mem.base) == "rip":
                tgt = ins.address + ins.size + op.mem.disp
                s = peek_str(tgt - base)
                note = "  ; %x %s" % (tgt, repr(s) if s else "")
    print("%x: %-8s %s%s" % (ins.address, ins.mnemonic, ins.op_str, note))
