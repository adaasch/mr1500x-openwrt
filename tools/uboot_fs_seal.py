#!/usr/bin/env python3
"""uboot_fs_seal.py — U-Boot rootfs boot gate sealer for MR1500X/MR60Xv2 (RTL8197F).

GROUND TRUTH (from the shipping bootcode binary, verified byte-exact against the
factory dump): doBooting -> check_system_image(0x40000) sees cr6c = FW_SIGNATURE_
WITH_ROOT (ret=2) -> check_rootfs_image() scans 0x400000..0xfa0000 step 0x10000
and requires at some 64k-aligned offset:

    length = BE32( squashfs_superblock[8:12] ) + 640 + 2   # 640 = SIZE_OF_SQFS_SUPER_BLOCK
    sum16be( flash[off : off+length] ) == 0                # 16-bit BE word sum

The vendor stores, instead of the squashfs4 mkfs_time (field is informational,
mounts fine with it), a big-endian "P - 640" where P = squashfs length padded
with 0x00 to a 4096-byte boundary, and appends BE16( -sum16be(payload[:P]) ).

Verified: applying this recipe to the factory file-system section reproduces the
vendor bytes exactly, including checksum 0x3b01 (P = 0x9bc000, field 0x009bbd80).

Modes:
  seal <in.sqfs> <out> [--body]   emit P+2 bytes (patched sb + zero pad + BE16 chk);
                                  --body emits only the P bytes (mk_cvimg root appends
                                  the same BE16 chk itself, so the burned region is
                                  exactly the sealed image)
  verify <regionfile> [off]       simulate the bootloader gate over a region image
                                  (the whole 16 MiB chip dump also works w/ default off
                                  0x400000); exits 0 iff a gate hit is found
  selftest <factorydump>          reseal factory[0x400000:0x400000+0x9bc002] from the
                                  raw payload and require byte-identity incl. 0x3b01
"""
import sys, struct

def sum16(b: bytes) -> int:
    s = 0
    for i in range(0, len(b), 2):
        s += (b[i] << 8) | (b[i + 1] if i + 1 < len(b) else 0)
    return s & 0xffff

def seal(sqfs: bytes, body_only: bool = False) -> bytes:
    P = (len(sqfs) + 4095) // 4096 * 4096
    assert P >= len(sqfs)
    payload = bytearray(sqfs)
    payload[8:12] = struct.pack('>I', P - 640)          # replaces mkfs_time (informational)
    payload += b'\x00' * (P - len(sqfs))
    out = bytes(payload)
    if not body_only:
        out += struct.pack('>H', (-sum16(out)) & 0xffff)
    return out

def gate_hit(flash: bytes, start: int, end: int, step: int = 0x10000) -> int | None:
    """Exact port of check_rootfs_image scanning: returns the offset of the hit.
    A row whose gate length runs past the image end cannot be a hit (bootcode:
    'SPI flash read fail'); random data yields huge random fields, so skipping
    those keeps the scan near-instant over multi-MB regions."""
    for off in range(start, end, step):
        if off + 12 > len(flash):
            break
        field = struct.unpack_from('>I', flash, off + 8)[0]
        length = field + 640 + 2
        if off + length > len(flash):
            continue
        s = sum16(flash[off:off + length])
        if s == 0:
            return off
        print(f'  @0x{off:06x} length 0x{length:x} sum 0x{s:04x}', flush=True)
    return None

def cmd_seal(argv):
    body = '--body' in argv
    args = [a for a in argv if a != '--body']
    sq = open(args[0], 'rb').read()
    len_sq = len(sq)
    out = seal(sq, body)
    open(args[1], 'wb').write(out)
    nbytes = len(sq)
    print(f'seal: in {nbytes} (0x{nbytes:x}) -> P 0x{((nbytes+4095)//4096*4096):x}, '
          f'out {len(out)} (0x{len(out):x}) "{args[1]}" chk='
          f'{out[-2:].hex() if not body else "(cvimg will append)"}')

def cmd_verify(argv):
    data = open(argv[0], 'rb').read()
    if len(argv) > 1:
        off = int(argv[1], 0)
    else:
        # full chip dump (16 MiB) -> real partition offset; anything smaller
        # (standalone rootfs or region image) starts at 0
        off = 0x400000 if len(data) >= 0x1000000 else 0
    hit = gate_hit(data, off, min(off + 0xba0000, len(data)))
    if hit is None:
        print('GATE MISS — this image will NOT pass check_rootfs_image (down mode)')
        return 1
    print(f'GATE HIT @0x{hit:06x} — bootloader will accept the rootfs')
    return 0

def cmd_selftest(argv):
    factory = open(argv[0], 'rb').read()
    N = 0x9bc002
    reg = factory[0x400000:0x400000 + N]
    # unseal: keep payload, ignore field+chk, reseal
    raw = reg[:0x9bc000]            # padded payload (field inside gets rewritten)
    resealed = seal(raw)
    if bytes(resealed) == reg:
        print(f'selftest PASS: reseal of factory payload is byte-identical '
              f'(chk 0x{sum16(reg[:0x9bc000]) ^ 0xffff and 0 or struct.unpack(">H", reg[-2:])[0]:04x} maches)')
        return 0
    # locate first divergence for a useful diagnostic
    for i, (a, b) in enumerate(zip(resealed, reg)):
        if a != b:
            print(f'selftest FAIL: first difference @0x{i:x}: got {a:02x} want {b:02x}')
            return 1
    print('selftest FAIL: length mismatch')
    return 1

if __name__ == '__main__':
    mode = sys.argv[1] if len(sys.argv) > 1 else ''
    if mode == 'seal': cmd_seal(sys.argv[2:])
    elif mode == 'verify': sys.exit(cmd_verify(sys.argv[2:]))
    elif mode == 'selftest': sys.exit(cmd_selftest(sys.argv[2:]))
    else:
        print(__doc__)
        sys.exit(2)
