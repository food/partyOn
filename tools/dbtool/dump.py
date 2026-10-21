import sys, struct
sys.path.insert(0, "/work")
from clear_markers import find, elements
from rocksdict import Rdict, Options, AccessType
cfs = Rdict.list_cf("/db")
db = Rdict("/db", options=Options(raw_mode=True), access_type=AccessType.read_only(), column_families={c: Options(raw_mode=True) for c in cfs})
def s(m, n):
    h = find(m, n)
    if not h: return None
    t, a, b = h
    if t == 2: return m[a+4:b-1].decode(errors="replace")
    if t == 0x10: return struct.unpack_from("<i", m, a)[0]
    if t == 3: return {k: round(struct.unpack_from("<d", m[a:b], x)[0]) for _, k, x, y in elements(m[a:b])}
    return "?"
for k, v in db.get_column_family("R5BLPlayerInWorld").items():
    v = bytes(v); h = find(v, "UserMarkers"); arr = v[h[1]:h[2]]
    print("==", k.decode(), s(v, "PlayerId"))
    for t, n, a, b in elements(arr):
        m = arr[a:b]
        loc = s(m, "WorldLocation") or {}
        print("  ", s(m, "MarkerId"), repr(s(m, "DisplayText")), "type", s(m, "Type"), "owner", repr(s(m, "OwnerId")), "cls", (s(m, "MarkerClass") or "")[-25:], loc.get("X"), loc.get("Y"))
