#!/usr/bin/env python3
"""
extract_stock_rootfs.py — pull sections out of an official Mercusys/TP-Link
firmware upgrade image (the "fwup"/tplink-safeloader container).

Two jobs, both needed by this project:

  1. BUILD INPUT. The 5 GHz RTL8832BR on this board is an eFEM design
     (rfe_type >= 50), so the driver reads its radio register tables from
     /etc/conf/rtl8832bre/RFE50/ at init instead of carrying them in .text.
     Without them the synthesizer never locks and 5 GHz is dead. Those 39 files
     are vendor data: they cannot be compiled from source, and the copies in
     the GPL drop are an OLDER revision with fewer regulatory domains
     (RadioA v003 vs v009, TXPWR_LMT V01 vs V03), so they are not a
     substitute. build_image.sh takes them from the official firmware the user
     downloads, which keeps vendor data out of this repo entirely.

  2. ROLLBACK. `--wrap` re-packages the extracted file-system section as an
     r6cr container, so a user can push themselves back to stock through the
     same down-mode TFTP path they used to install this. The section is
     already sealed for the U-Boot boot gate by the vendor (verified), so
     nothing has to be re-sealed — only wrapped.

CONTAINER LAYOUT (verified against MR1500X v2 1.1.3):
  0x0000  image size                        u32 BE
  0x0004  md5(salt16 || bytes[0x14:])       16 bytes
  0x0014  vendor-info length                u32 BE
  0x0018  vendor info, 0xFF padded          -> 0x1013
  0x1014  fwup-ptn table, 0xFF padded, rows:
              "fwup-ptn <name> base 0x%05x size 0x%05x\\t\\r\\n"
  payload  *** base values are relative to 0x1014, the TABLE start ***

  That last line is the one worth writing down. A natural reading — and an
  older draft in this repo — puts the payload base at 0x1814 (table start plus
  the 0x800 table). It is off by 0x800: with base relative to 0x1014, the
  os-image row (base 0x1000) lands exactly on the `cr6c` signature at 0x2014
  and the file-system row lands exactly on `hsqs`. Both were confirmed by
  searching the file for those magics rather than by trusting the arithmetic.

usage:
  extract_stock_rootfs.py list     <firmware.bin>
  extract_stock_rootfs.py section  <firmware.bin> <name> <out>
  extract_stock_rootfs.py rootfs   <firmware.bin> <out.sqfs> [--wrap <out-r6cr.bin>]
"""
import os
import re
import subprocess
import sys

TABLE_OFF = 0x1014
TABLE_LEN = 0x800
ROW = re.compile(rb"fwup-ptn (\S+) base (0x[0-9a-fA-F]+) size (0x[0-9a-fA-F]+)")


def parse_table(blob: bytes):
    """[(name, file_offset, size)] in table order."""
    if len(blob) < TABLE_OFF + TABLE_LEN:
        sys.exit("not a fwup container: file is too small for a partition table")
    table = blob[TABLE_OFF:TABLE_OFF + TABLE_LEN]
    out = []
    for m in ROW.finditer(table):
        name = m.group(1).decode()
        base = int(m.group(2), 16)
        size = int(m.group(3), 16)
        out.append((name, TABLE_OFF + base, size))
    if not out:
        sys.exit("no fwup-ptn rows at 0x1014 — is this an official upgrade image?")
    return out


def section(blob: bytes, name: str) -> bytes:
    for n, off, size in parse_table(blob):
        if n == name:
            if off + size > len(blob):
                sys.exit("section %s runs past the end of the file" % name)
            return blob[off:off + size]
    sys.exit("no section named %s (try: list)" % name)


def sum16(buf: bytes) -> int:
    s, n = 0, len(buf)
    for i in range(0, (n // 2) * 2, 2):
        s = (s + ((buf[i] << 8) | buf[i + 1])) & 0xFFFF
    if n % 2:
        s = (s + (buf[-1] << 8)) & 0xFFFF
    return s


def check_gate(fs: bytes) -> bool:
    """The bootloader's accept test: sum16be over BE32(sb[8:12]) + 642 bytes."""
    if len(fs) < 12:
        return False
    glen = int.from_bytes(fs[8:12], "big") + 642
    return glen <= len(fs) and sum16(fs[:glen]) == 0


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)
    cmd, path = argv[1], argv[2]
    blob = open(path, "rb").read()

    if cmd == "list":
        for n, off, size in parse_table(blob):
            print("%-16s file-offset 0x%06x  size 0x%06x (%d)" % (n, off, size, size))
        return 0

    if cmd == "section":
        if len(argv) != 5:
            sys.exit(__doc__)
        data = section(blob, argv[3])
        open(argv[4], "wb").write(data)
        print("wrote %s (%d bytes, starts %r)" % (argv[4], len(data), data[:4]))
        return 0

    if cmd == "rootfs":
        if len(argv) < 4:
            sys.exit(__doc__)
        out = argv[3]
        fs = section(blob, "file-system")
        if fs[:4] != b"hsqs":
            sys.exit("file-system section does not start with a squashfs magic "
                     "(got %r) — refusing to hand out something unidentified" % fs[:4])
        open(out, "wb").write(fs)
        print("wrote %s (%d bytes)" % (out, len(fs)))
        print("boot gate: %s" % ("PASS — the bootloader would accept this rootfs"
                                 if check_gate(fs) else
                                 "FAIL — vendor seal missing or damaged"))
        if "--wrap" in argv:
            dest = argv[argv.index("--wrap") + 1]
            if not check_gate(fs):
                sys.exit("refusing to wrap an image that fails the boot gate: "
                         "pushing it would drop the device into TFTP rescue")
            mk = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              "mk_cvimg.py")
            subprocess.check_call([sys.executable, mk, "root", out, dest])
            print("wrapped %s — push with tftp_push.py to return to stock" % dest)
        return 0

    sys.exit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
