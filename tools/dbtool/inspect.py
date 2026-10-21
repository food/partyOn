import sys
sys.path.insert(0, "/work")
from clear_markers import find, count_array
from rocksdict import Rdict, Options, AccessType
p = "/db"
cfs = Rdict.list_cf(p)
db = Rdict(p, options=Options(raw_mode=True), access_type=AccessType.read_only(), column_families={c: Options(raw_mode=True) for c in cfs})
for c in cfs:
    cf = db.get_column_family(c)
    n = sum(1 for _ in cf.keys())
    print("CF", c, n)
cf = db.get_column_family("R5BLPlayerInWorld")
for k, v in cf.items():
    v = bytes(v)
    pid = v[v.find(b"PlayerId")+13: v.find(b"PlayerId")+45] if b"PlayerId" in v else b"?"
    h = find(v, "UserMarkers")
    print(k, pid, "markers:", count_array(v, h[1], h[2]) if h else None, "len", len(v))
