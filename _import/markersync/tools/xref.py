# usage: xref.py <needle> [u]  -> functions (via .pdata) referencing the string containing needle
import sys, pefile, bisect, re

pe = pefile.PE("/bin64/WindroseServer-Win64-Shipping.exe", fast_load=True)
pe.parse_data_directories(directories=[pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_EXCEPTION"]])
data = pe.__data__
base = pe.OPTIONAL_HEADER.ImageBase
wide = len(sys.argv) > 2
needle = sys.argv[1].encode("utf-16-le" if wide else "ascii")
w = 2 if wide else 1

funcs = sorted((e.struct.BeginAddress, e.struct.EndAddress) for e in pe.DIRECTORY_ENTRY_EXCEPTION)
starts = [f[0] for f in funcs]


def func_of(rva):
    i = bisect.bisect_right(starts, rva) - 1
    return funcs[i] if i >= 0 and funcs[i][0] <= rva < funcs[i][1] else None


text = next(s for s in pe.sections if s.Name.startswith(b".text"))
t0, tdata = text.VirtualAddress, text.get_data()
# lea reg, [rip+disp32]
LEA = re.compile(rb"[\x48\x4c]\x8d[\x05\x0d\x15\x1d\x25\x2d\x35\x3d]", re.S)
targets = {}
for m in re.finditer(re.escape(needle), data):
    st = m.start()
    while data[st - w:st] != b"\0" * w:
        st -= w
    srva = pe.get_rva_from_offset(st)
    targets[srva] = data[st:st + 200]
for srva, s in targets.items():
    print("string @rva %x: %r" % (srva, s.split(b"\0\0")[0][:160]))
for mm in LEA.finditer(tdata):
    i = mm.start()
    disp = int.from_bytes(tdata[i + 3:i + 7], "little", signed=True)
    tgt = t0 + i + 7 + disp
    if tgt in targets:
        f = func_of(t0 + i)
        print("  ref to %x @%x in func %s" % (tgt, base + t0 + i, "%x-%x" % (base + f[0], base + f[1]) if f else "?"))
