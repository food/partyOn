"""Clears the UserMarkers of every PlayerInWorld record in a Windrose world DB (server stopped!).

usage: clear_markers.py <world-db-dir> [--apply] [--ghosts]
Without --apply it only lists what it would change; --ghosts removes only saved live copies. Values are BSON documents; the array is
emptied and _meta.ChangeRevision is bumped so clients drop their cached copy.
"""
import struct
import sys

from rocksdict import AccessType, Options, Rdict


def cstr_end(b, i):
    return b.index(b"\0", i)


def elements(doc):
    """Yields (type, name, value_start, value_end) for each element of a BSON document."""
    i, end = 4, struct.unpack_from("<i", doc)[0] - 1
    while i < end:
        t = doc[i]
        n_end = cstr_end(doc, i + 1)
        name = doc[i + 1:n_end].decode()
        v = n_end + 1
        if t in (0x03, 0x04):                       # document, array
            ln = struct.unpack_from("<i", doc, v)[0]
        elif t == 0x02:                             # string
            ln = 4 + struct.unpack_from("<i", doc, v)[0]
        elif t in (0x01, 0x12, 0x09, 0x11):         # double, int64, datetime, timestamp
            ln = 8
        elif t == 0x10:                             # int32
            ln = 4
        elif t == 0x08:                             # bool
            ln = 1
        elif t == 0x0A:                             # null
            ln = 0
        elif t == 0x05:                             # binary
            ln = 5 + struct.unpack_from("<i", doc, v)[0]
        else:
            raise ValueError("unsupported BSON type 0x%02x at %d" % (t, i))
        yield t, name, v, v + ln
        i = v + ln


def find(doc, name):
    for t, n, s, e in elements(doc):
        if n == name:
            return t, s, e
    return None


def count_array(doc, s, e):
    return sum(1 for _ in elements(doc[s:e]))


def is_ghost(marker):
    """A live copy that the server saved: its class is the Simple marker model."""
    hit = find(marker, "MarkerClass")
    return bool(hit) and hit[0] == 0x02 and b"BP_MarkerModel_Simple" in marker[hit[1]:hit[2]]


def clear(doc, ghosts_only=False):
    """Returns (new_doc, removed_count) or (None, 0) if there is nothing to clear.

    With ghosts_only, keeps real user markers and drops only saved live copies."""
    hit = find(doc, "UserMarkers")
    if not hit or hit[0] != 0x04:
        return None, 0
    _, s, e = hit
    arr = doc[s:e]
    kept = [arr[a:b] for _, _, a, b in elements(arr) if ghosts_only and not is_ghost(arr[a:b])]
    n = count_array(doc, s, e) - len(kept)
    if n == 0:
        return None, 0
    body = b"".join(b"\x03" + str(i).encode() + b"\0" + m for i, m in enumerate(kept))
    new_arr = struct.pack("<i", 4 + len(body) + 1) + body + b"\0"
    new = doc[:s] + new_arr + doc[e:]
    new = struct.pack("<i", len(new)) + new[4:]
    meta = find(new, "_meta")
    if meta and meta[0] == 0x03:
        sub = new[meta[1]:meta[2]]
        rev = find(sub, "ChangeRevision")
        if rev and rev[0] == 0x10:
            off = meta[1] + rev[1]
            val = struct.unpack_from("<i", new, off)[0]
            new = new[:off] + struct.pack("<i", val + 1) + new[off + 4:]
    return new, n


def main():
    path, apply, ghosts = sys.argv[1], "--apply" in sys.argv, "--ghosts" in sys.argv
    cfs = Rdict.list_cf(path)
    opts = Options(raw_mode=True)
    db = Rdict(path, options=opts, access_type=AccessType.read_write() if apply else AccessType.read_only(),
               column_families={cf: Options(raw_mode=True) for cf in cfs})
    total = 0
    for cf_name in cfs:
        cf = db.get_column_family(cf_name)
        changes = []
        for k, v in cf.items():
            if not isinstance(v, (bytes, bytearray)) or b"UserMarkers" not in v:
                continue
            try:
                new, n = clear(bytes(v), ghosts)
            except Exception as exc:  # unknown layout: report, never write
                print("skip %s/%r: %s" % (cf_name, k[:40], exc))
                continue
            if new:
                changes.append((k, new, n))
        for k, new, n in changes:
            print("%s %s/%r: %d marker(s)" % ("clear" if apply else "would clear", cf_name, k[:48], n))
            total += n
            if apply:
                cf.put(k, new)
    if apply:
        db.flush()
    db.close()
    print("%s %d marker(s)" % ("cleared" if apply else "would clear", total))


if __name__ == "__main__":
    main()
