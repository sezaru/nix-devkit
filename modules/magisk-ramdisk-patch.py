#!/usr/bin/env python3
# Pure-host reimplementation of magiskboot's AVD ramdisk patch (Magisk systemless
# root). Reproduces exactly what `magiskboot cpio` does on-device, but with plain
# host tools so it can run in a nix build sandbox (magiskboot itself is a static
# Android binary that hangs on glibc).
#
#   magisk-ramdisk-patch.py <stock-ramdisk.img> <Magisk.apk> <out-ramdisk.img>
#
# Transform (verified byte-identical to a known-good rooted ramdisk):
#   - lz4-legacy decompress the stock ramdisk to its (concatenated) newc cpio
#   - replace /init with magiskinit; back the original up as .backup/init
#   - add overlay.d/sbin/magisk64.xz (xz of libmagisk64.so)
#   - add .backup/.magisk (config) and .backup/.rmlist (restore list)
#   - re-pack a single newc cpio (entries sorted by name, ino from 0x493e0,
#     nlink=1, mtime=0), lz4-legacy recompress
import sys, os, subprocess, hashlib, lzma, io, tempfile

MAGIC = b"070701"
INO_BASE = 0x493E0  # 300000 — magiskboot's inode base


def lz4d(p):
    return subprocess.check_output(["lz4", "-d", "-q", "-c", p])


def parse(raw):
    """Parse concatenated newc cpio -> [[name, mode, uid, gid, data], ...]."""
    i, out, n = 0, [], len(raw)
    while i + 110 <= n:
        if raw[i : i + 6] != MAGIC:
            i += 1
            continue
        f = [int(raw[i + 6 + k * 8 : i + 6 + k * 8 + 8], 16) for k in range(13)]
        ns, fs = f[11], f[6]
        name = raw[i + 110 : i + 110 + ns - 1].decode("latin1")
        hdr = (110 + ns + 3) & ~3
        data = raw[i + hdr : i + hdr + fs]
        i = i + hdr + ((fs + 3) & ~3)
        if name != "TRAILER!!!":
            out.append([name, f[1], f[2], f[3], data])
    return out


def build(entries):
    """Serialize entries (sorted by name) as a single newc cpio + trailer."""
    entries = sorted(entries, key=lambda e: e[0])
    buf = io.BytesIO()

    def w(name, mode, uid, gid, data, ino):
        nm = name.encode("latin1") + b"\0"
        hdr = MAGIC + b"".join(
            b"%08X" % v
            for v in [ino, mode, uid, gid, 1, 0, len(data), 0, 0, 0, 0, len(nm), 0]
        )
        buf.write(hdr)
        buf.write(nm)
        buf.write(b"\0" * ((-(110 + len(nm))) % 4))
        buf.write(data)
        buf.write(b"\0" * ((-len(data)) % 4))

    for idx, (name, mode, uid, gid, data) in enumerate(entries):
        w(name, mode, uid, gid, data, INO_BASE + idx)
    tn = b"TRAILER!!!\0"
    buf.write(MAGIC + b"".join(b"%08X" % v for v in [0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, len(tn), 0]))
    buf.write(tn)
    buf.write(b"\0" * ((-(110 + len(tn))) % 4))
    return buf.getvalue()


def main():
    stock_img, apk, out_img = sys.argv[1], sys.argv[2], sys.argv[3]
    d = {e[0]: e for e in parse(lz4d(stock_img))}

    td = tempfile.mkdtemp()
    subprocess.check_call(["unzip", "-oq", apk, "lib/x86_64/*", "-d", td])
    minit = open(f"{td}/lib/x86_64/libmagiskinit.so", "rb").read()
    m64 = open(f"{td}/lib/x86_64/libmagisk64.so", "rb").read()
    m64xz = lzma.compress(m64, format=lzma.FORMAT_XZ, check=lzma.CHECK_CRC32,
                          preset=9 | lzma.PRESET_EXTREME)

    stock_init = d["init"][4]
    sha1 = hashlib.sha1(open(stock_img, "rb").read()).hexdigest()
    cfg = (f"KEEPVERITY=true\nKEEPFORCEENCRYPT=true\nRECOVERYMODE=false\nSHA1={sha1}\n").encode()
    rml = b"overlay.d\0overlay.d/sbin\0overlay.d/sbin/magisk64.xz\0"

    d["init"] = ["init", 0o100750, 0, 0, minit]
    for e in [
        [".backup", 0o40000, 0, 0, b""],
        [".backup/.magisk", 0o100000, 0, 0, cfg],
        [".backup/.rmlist", 0o100000, 0, 0, rml],
        [".backup/init", 0o100750, 0, 0, stock_init],
        ["overlay.d", 0o40750, 0, 0, b""],
        ["overlay.d/sbin", 0o40750, 0, 0, b""],
        ["overlay.d/sbin/magisk64.xz", 0o100644, 0, 0, m64xz],
    ]:
        d[e[0]] = e

    cpio = build(list(d.values()))
    tf = tempfile.NamedTemporaryFile(suffix=".cpio", delete=False)
    tf.write(cpio)
    tf.close()
    subprocess.check_call(["lz4", "-l", "-9", "-f", tf.name, out_img])
    os.unlink(tf.name)
    print("wrote", out_img, os.path.getsize(out_img), "bytes")


main()
