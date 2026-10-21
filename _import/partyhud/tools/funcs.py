# usage: funcs.py <regex> [server|client|multi]  -> reflected UFunctions (FFunctionParams) whose
# name matches, with function flags and parameter names
import sys, re, struct, pefile

pe = pefile.PE("/bin64/WindroseServer-Win64-Shipping.exe", fast_load=True)
data = pe.__data__
base = pe.OPTIONAL_HEADER.ImageBase
pat = re.compile(sys.argv[1].encode(), re.I)
want = {"server": 0x00200000, "client": 0x01000000, "multi": 0x00004000}.get(sys.argv[2] if len(sys.argv) > 2 else "", 0)


def va_of(off):
    for s in pe.sections:
        if s.PointerToRawData <= off < s.PointerToRawData + s.SizeOfRawData:
            return base + s.VirtualAddress + off - s.PointerToRawData
    return None


def cstr(va):
    try:
        b = pe.get_data(va - base, 128)
    except Exception:
        return None
    a = b.split(b"\0")[0]
    return a.decode("ascii", "replace") if a and all(32 <= c < 127 for c in a) else None


def qword(va):
    try:
        return struct.unpack("<Q", pe.get_data(va - base, 8))[0]
    except Exception:
        return 0


names = {}
for m in re.finditer(rb"(?<=\0)[A-Za-z_][A-Za-z0-9_]{2,80}(?=\0)", data):
    if pat.search(m.group()):
        va = va_of(m.start())
        if va:
            names[va] = m.group().decode()

ptr = re.compile(b"|".join(re.escape(struct.pack("<Q", va)) for va in names)) if names else None
seen = set()
# FFunctionParams: OuterFunc, SuperFunc, NameUTF8, PropertyArray, u16 NumProperties,
# u16 StructureSize, u32 ObjectFlags, u32 FunctionFlags, u16 RPCId, u16 RPCResponseId
for m in ptr.finditer(data) if ptr else []:
    o = m.start() - 16
    if o % 8 or o < 0:
        continue
    outer, sup = struct.unpack_from("<QQ", data, o)
    if not (base < outer < base + 0x20000000):
        continue
    name = names[struct.unpack_from("<Q", data, o + 16)[0]]
    props, nprops, size, oflags, fflags = struct.unpack_from("<QHHII", data, o + 24)
    if nprops > 40 or fflags == 0 or (want and not fflags & want):
        continue
    params = []
    for i in range(nprops):
        p = qword(props + 8 * i) if props else 0
        params.append(cstr(qword(p)) if p else "?")
    key = (name, fflags, tuple(params))
    if key in seen:
        continue
    seen.add(key)
    kind = "SERVER" if fflags & 0x00200000 else "CLIENT" if fflags & 0x01000000 else "MULTI" if fflags & 0x00004000 else ""
    print("%-6s %-50s flags=%08x outer=%x (%s)" % (kind, name, fflags, outer, ", ".join(params)))
