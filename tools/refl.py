# usage: refl.py <regex>  -> reflected properties (FPropertyParams) whose name matches, with flags
import sys, re, struct, pefile

pe = pefile.PE("/bin64/WindroseServer-Win64-Shipping.exe", fast_load=True)
data = pe.__data__
base = pe.OPTIONAL_HEADER.ImageBase
pat = re.compile(sys.argv[1].encode(), re.I)


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


# candidate names: standalone NUL-terminated identifiers
names = {}
for m in re.finditer(rb"(?<=\0)[A-Za-z_][A-Za-z0-9_]{2,63}(?=\0)", data):
    if pat.search(m.group()):
        va = va_of(m.start())
        if va:
            names[va] = m.group().decode()

ptr = re.compile(b"|".join(re.escape(struct.pack("<Q", va)) for va in names)) if names else None
CPF = {0x20: "Net", 0x100000000: "RepNotify", 0x80000000: "RepSkip", 0x4: "BPVisible", 0x10: "BPReadOnly",
       0x4000000000000: "Transient"}
seen = set()
for m in ptr.finditer(data) if ptr else []:
    o = m.start()
    if o % 8:
        continue
    name = names[struct.unpack_from("<Q", data, o)[0]]
    rep, flags = struct.unpack_from("<QQ", data, o + 8)
    gen = data[o + 16 + 8]
    if rep and not cstr(rep):
        continue
    if flags > 0x00FFFFFFFFFFFFFF:
        continue
    key = (name, flags)
    if key in seen:
        continue
    seen.add(key)
    tags = [v for k, v in CPF.items() if flags & k]
    print("%-40s gen=%02x flags=%016x %-28s repnotify=%s" % (name, gen, flags, ",".join(tags), cstr(rep) if rep else "-"))
