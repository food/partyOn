"""Rebuilds a Windrose world backup zip (RocksDB BackupEngine checkpoint) with all user markers removed.

usage: patch_backup.py <in.zip> <out.zip> [workdir] [--ghosts]

The server restores <world>_<version>_Latest.zip over the world DB at every start, so clearing
the DB alone does not stick. This extracts the checkpoint, rebuilds the DB from it, clears the
UserMarkers (see clear_markers.py), and packs a new checkpoint in the same layout: meta/1 lists
every file with its crc32c, SST files live in shared_checksum/ named <num>_s<session>_<size>.sst.
The game runs RocksDB 10.x and reads the older SST format this writer produces; compression is
forced off because the game's build may lack Snappy.
"""
import os
import shutil
import sys
import time
import zipfile

from rocksdict import AccessType, DBCompressionType, Options, Rdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from clear_markers import clear  # noqa: E402


def crc32c(data):
    poly, crc = 0x82F63B78, 0xFFFFFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ (poly & -(crc & 1))
    return crc ^ 0xFFFFFFFF


def file_crc(path):
    with open(path, "rb") as f:
        return crc32c(f.read())


def rebuild_db(checkpoint, db_dir):
    """Turns a checkpoint (private/1 + shared_checksum) into a plain DB directory."""
    os.makedirs(db_dir)
    priv = os.path.join(checkpoint, "private", "1")
    for name in os.listdir(priv):
        shutil.copy(os.path.join(priv, name), db_dir)
    shared = os.path.join(checkpoint, "shared_checksum")
    for name in os.listdir(shared):
        num, ext = name.split("_", 1)[0], name.rsplit(".", 1)[1]
        shutil.copy(os.path.join(shared, name), os.path.join(db_dir, "%s.%s" % (num, ext)))


def db_options():
    o = Options(raw_mode=True)
    o.set_compression_type(DBCompressionType.none())
    o.set_disable_auto_compactions(True)  # keep the file set predictable until close
    return o


def open_db(db_dir, write):
    cfs = Rdict.list_cf(db_dir)
    access = AccessType.read_write() if write else AccessType.read_only()
    return Rdict(db_dir, options=db_options(), access_type=access,
                 column_families={cf: db_options() for cf in cfs}), cfs


def clear_db(db_dir, ghosts):
    db, cfs = open_db(db_dir, True)
    total = 0
    for cf_name in cfs:
        cf = db.get_column_family(cf_name)
        changes = []
        for k, v in cf.items():
            if isinstance(v, (bytes, bytearray)) and b"UserMarkers" in v:
                new, n = clear(bytes(v), ghosts)
                if new:
                    changes.append((k, new, n))
        for k, new, n in changes:
            cf.put(k, new)
            total += n
    db.flush()
    seq = db.latest_sequence_number()
    db.close()  # obsolete files are gone after this; the directory is the live set
    return total, seq


def count_markers(db_dir, ghosts=False):
    db, cfs = open_db(db_dir, False)
    n = 0
    for cf_name in cfs:
        for k, v in db.get_column_family(cf_name).items():
            if isinstance(v, (bytes, bytearray)) and b"UserMarkers" in v:
                _, removed = clear(bytes(v), ghosts)
                n += removed
    db.close()
    return n


def pack(db_dir, seq, old_names, session, extra_files, out_zip):
    """Writes the new checkpoint zip. old_names maps sst number -> original shared name."""
    entries = []  # (zip path, local path)
    for name in sorted(os.listdir(db_dir)):
        local = os.path.join(db_dir, name)
        num, ext = name.rsplit(".", 1)[0], name.rsplit(".", 1)[1] if "." in name else ""
        if ext == "sst":
            crc = file_crc(local)
            shared = old_names.get(num)
            if shared and old_names[num + ".crc"] == crc:
                entries.append(("shared_checksum/" + shared, local, crc))
            else:
                entries.append(("shared_checksum/%s_s%s_%d.sst" % (num, session, os.path.getsize(local)), local, crc))
        elif ext == "blob":
            crc = file_crc(local)
            entries.append(("shared_checksum/%s_%d_%d.blob" % (num, crc, os.path.getsize(local)), local, crc))
        elif name == "CURRENT" or name.startswith("MANIFEST-") or name.startswith("OPTIONS-") or ext == "log":
            entries.append(("private/1/" + name, local, file_crc(local)))
        elif name in ("LOCK", "IDENTITY", "LOG", "rocksdict-config.json") or name.startswith("LOG.old"):
            continue
        else:
            raise SystemExit("unexpected file in db dir: " + name)
    manifests = [e for e in entries if "/MANIFEST-" in e[0]]
    options = [e for e in entries if "/OPTIONS-" in e[0]]
    if len(manifests) != 1 or len(options) < 1:
        raise SystemExit("expected one MANIFEST, got %r" % [e[0] for e in manifests])
    if len(options) > 1:  # keep the newest OPTIONS file only
        options.sort(key=lambda e: int(e[0].rsplit("-", 1)[1]))
        entries = [e for e in entries if e not in options[:-1]]
    meta = "%d\n%d\n%d\n" % (int(time.time()), seq, len(entries))
    meta += "".join("%s crc32 %d\n" % (zp, crc) for zp, _, crc in entries)
    with zipfile.ZipFile(out_zip, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("Checkpoint/meta/1", meta)
        for zp, local, _ in entries:
            z.write(local, "Checkpoint/" + zp)
        for zp, data in extra_files:
            z.writestr(zp, data)
    return meta


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    ghosts = "--ghosts" in sys.argv
    in_zip, out_zip = args[0], args[1]
    work = args[2] if len(args) > 2 else "/tmp/patch_backup"
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work, exist_ok=True)
    src = os.path.join(work, "src")
    with zipfile.ZipFile(in_zip) as z:
        z.extractall(src)
        extra = [(i.filename, z.read(i.filename)) for i in z.infolist()
                 if not i.filename.startswith("Checkpoint/") and not i.is_dir()]
    old_names, session = {}, None
    for name in os.listdir(os.path.join(src, "Checkpoint", "shared_checksum")):
        if name.endswith(".sst"):
            num = name.split("_", 1)[0]
            old_names[num] = name
            old_names[num + ".crc"] = file_crc(os.path.join(src, "Checkpoint", "shared_checksum", name))
            session = name.split("_")[1][1:]  # any session id works for the restore, borrow one
    db_dir = os.path.join(work, "db")
    rebuild_db(os.path.join(src, "Checkpoint"), db_dir)
    before = count_markers(db_dir, ghosts)
    removed, seq = clear_db(db_dir, ghosts)
    meta = pack(db_dir, seq, old_names, session, extra, out_zip)
    print("markers before: %d, removed: %d" % (before, removed))
    print(meta)
    # read back: rebuild from the new zip and count again
    check = os.path.join(work, "check")
    with zipfile.ZipFile(out_zip) as z:
        z.extractall(check)
    check_db = os.path.join(work, "check_db")
    rebuild_db(os.path.join(check, "Checkpoint"), check_db)
    after = count_markers(check_db, ghosts)
    print("%s left in new zip: %d, user markers kept: %d" % ("ghosts" if ghosts else "markers", after, count_markers(check_db) - after))
    if after != 0:
        raise SystemExit("new zip still has markers")


if __name__ == "__main__":
    main()
