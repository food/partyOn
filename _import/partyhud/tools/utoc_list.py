# usage: utoc_list.py <file.utoc>...  -> every file path in the IoStore directory index, one per line
#        utoc_list.py --extract <name-part> <out-dir> <file.utoc>...  -> raw chunk of each matching
#        file (only uncompressed containers, which Windrose ships)
# Reads the UE5 TOC header (version 8) and the unencrypted directory index.
import os, struct, sys


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
            fname, nxt, toc_index = fes[f]
            out.append((here + strings[fname], toc_index))
            f = nxt
        c = child
        while c != NONE:
            walk(c, here)
            c = dirs[c][2]

    walk(0, mount)
    return out


def chunk(path, toc_index):
    """Raw bytes of one TOC entry, read from the matching .ucas through the block table."""
    b = open(path, "rb").read()
    (hsize, entries, blocks, block_entry, _, _, block_size, _) = struct.unpack_from("<IIIIIIII", b, 20)
    seeds, = struct.unpack_from("<I", b, 84)
    without, = struct.unpack_from("<I", b, 96)
    ol = hsize + entries * 12 + toc_index * 10
    offset = int.from_bytes(b[ol:ol + 5], "big")
    length = int.from_bytes(b[ol + 5:ol + 10], "big")
    table = hsize + entries * 12 + entries * 10 + seeds * 4 + without * 4
    data = bytearray()
    with open(path[:-5] + ".ucas", "rb") as cas:
        pos = offset
        while len(data) < length:
            e = table + (pos // block_size) * block_entry
            file_off = int.from_bytes(b[e:e + 5], "little")
            comp = int.from_bytes(b[e + 5:e + 8], "little")
            raw = int.from_bytes(b[e + 8:e + 11], "little")
            if comp != raw or b[e + 11] != 0:
                raise SystemExit("compressed block, not supported")
            cas.seek(file_off + pos % block_size)
            take = min(length - len(data), raw - pos % block_size)
            data += cas.read(take)
            pos += take
    return bytes(data)


if sys.argv[1] == "--extract":
    needle, out_dir = sys.argv[2], sys.argv[3]
    os.makedirs(out_dir, exist_ok=True)
    for p in sys.argv[4:]:
        for name, idx in files(p):
            if needle in name:
                target = os.path.join(out_dir, os.path.basename(name))
                open(target, "wb").write(chunk(p, idx))
                print(target)
else:
    for p in sys.argv[1:]:
        for name, _ in files(p):
            print(name)
