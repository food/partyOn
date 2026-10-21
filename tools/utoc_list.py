# usage: utoc_list.py <file.utoc>...  -> every file path in the IoStore directory index, one per line
# Reads the UE5 TOC header (version 8) and the unencrypted directory index; no asset contents.
import struct, sys


def fstring(b, o):
    n = struct.unpack_from("<i", b, o)[0]
    o += 4
    if n == 0:
        return "", o
    if n < 0:
        s = b[o:o - n * 2].decode("utf-16-le").rstrip("\0")
        return s, o - n * 2
    return b[o:o + n].decode("latin-1").rstrip("\0"), o + n


def files(path):
    b = open(path, "rb").read()
    assert b[:16] == b"-==--==--==--==-", "not a utoc"
    (hsize, entries, blocks, block_entry, methods, method_len, _, index_size) = struct.unpack_from("<IIIIIIII", b, 20)
    flags = b[80]
    if index_size == 0:  # global.utoc has no directory index
        return []
    seeds, = struct.unpack_from("<I", b, 84)
    without, = struct.unpack_from("<I", b, 96)
    if flags & 2:
        raise SystemExit(path + ": directory index is encrypted")
    o = hsize + entries * 12 + entries * 10 + seeds * 4 + without * 4 + blocks * block_entry + methods * method_len
    if flags & 4:  # signed: two hash tables + block hashes
        hash_size, = struct.unpack_from("<i", b, o)
        o += 4 + hash_size * 2 + blocks * 20
    end = o + index_size
    mount, o = fstring(b, o)
    nd, = struct.unpack_from("<i", b, o); o += 4
    dirs = [struct.unpack_from("<IIII", b, o + i * 16) for i in range(nd)]; o += nd * 16
    nf, = struct.unpack_from("<i", b, o); o += 4
    fes = [struct.unpack_from("<III", b, o + i * 12) for i in range(nf)]; o += nf * 12
    ns, = struct.unpack_from("<i", b, o); o += 4
    strings = []
    for _ in range(ns):
        s, o = fstring(b, o)
        strings.append(s)
    assert o <= end, "index overrun"
    NONE = 0xFFFFFFFF
    out = []

    def walk(d, prefix):
        name, child, sibling, first_file = dirs[d]
        here = prefix + (strings[name] + "/" if name != NONE else "")
        f = first_file
        while f != NONE:
            fname, nxt, _ = fes[f]
            out.append(here + strings[fname])
            f = nxt
        c = child
        while c != NONE:
            walk(c, here)
            c = dirs[c][2]

    walk(0, mount)
    return out


for p in sys.argv[1:]:
    for line in files(p):
        print(line)
