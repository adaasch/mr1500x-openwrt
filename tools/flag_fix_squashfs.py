#!/usr/bin/env python3
"""flag_fix_squashfs.py — make a squashfs 4.0 image match the vendor stock flag set.

MR1500X down-mode root cause hunt (r4): our OpenWrt squashfskit4 output carries
flags 0x6c0 (DUPLICATE|EXPORTABLE|NO_XATTR|COMP_OPT) while the stock vendor
rootfs uses 0xe0 (ALWAYS_FRAG|DUPLICATE|EXPORTABLE). The COMP_OPT bit (0x200,
bit10) makes the superblock carry a trailing XZ compressor-options block; stock
never has one. Clear bit10 so the kernel ignores those 4 bytes. NO_XATTR is
kept (our repack drops xattrs; stock has them) — declaring none is mount-safe.

Usage: flag_fix_squashfs.py <in.sqfs> <out.sqfs> [flags-hex]
Default target flags for MR1500X: clear COMP_OPT (0x200) only.
"""
import struct, sys

def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    src, dst = sys.argv[1], sys.argv[2]
    clear = 0x200
    if len(sys.argv) > 3:
        clear = int(sys.argv[3], 0) & 0xFFFF
    buf = bytearray(open(src, 'rb').read())
    magic = bytes(buf[0:4])
    if magic != b'hsqs':
        sys.exit(f'not a little-endian squashfs 4.0 image: {magic!r}')
    (flags,) = struct.unpack_from('<H', buf, 24)
    new = flags & ~clear
    struct.pack_into('<H', buf, 24, new)
    open(dst, 'wb').write(buf)
    print(f'flags 0x{flags:04x} -> 0x{new:04x} (cleared 0x{clear:04x}); '
          f'{len(buf)} bytes written to {dst}')

if __name__ == '__main__':
    main()
