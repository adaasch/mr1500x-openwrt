#!/usr/bin/env python3
"""
mk_cvimg.py — build Realtek cvimg-wrapped images (r6cr root / cr6c kernel)
exactly like the vendor bootloader expects.

Conventions (validated byte-exact against the stock kernel header by
SESSION_LOG §3.3 / reproduced against factory bytes):
  header  = signature[4] + startAddr(BE32) + burnAddr(BE32) + len(BE32)
            len = payload + 2 (the trailing 2-byte checksum)
  checksum= (- 16-bit big-endian sum of payload) & 0xffff, stored BE
            right after the payload (i.e. payload[st_size])
  total   = header(16) + payload + checksum(2)

usage:
  mk_cvimg.py root  <payload-in>  <out>      # r6cr, RAM 0x80F00000, burn 0x400000
  mk_cvimg.py kernel [--force-kernel] <payload-in> <out>   # cr6c, TRAILING chk; gated (see --force-kernel)
  mk_cvimg.py <signature> <start-addr> <burn-addr> <payload-in> <out>
  mk_cvimg.py --selftest <payload-or-raw> <expected-chk-hex> <payload-offset>
             e.g. --selftest mr60xv2_factory_A.bin 2e0f 0x40000 (stock kernel header offset)
"""
import sys


def sum16(buf: bytes) -> int:
    s = 0
    n = len(buf)
    j = (n // 2) * 2
    for i in range(0, j, 2):
        s = (s + ((buf[i] << 8) | buf[i + 1])) & 0xFFFF
    if n % 2:
        s = (s + (buf[-1] << 8)) & 0xFFFF
    return s


def be32(v: int) -> bytes:
    return v.to_bytes(4, "big")


def build(sig: bytes, start: int, burn: int, payload: bytes) -> bytes:
    if len(sig) != 4:
        sys.exit("signature must be exactly 4 bytes")
    # Header.len MUST be even, and it is payload+2, so the payload must be too.
    # The bootcode checksums with `for (i=0; i < Header.len; i+=2)` reading a
    # 16-bit word each step (eth_tftpd.c), so an odd length makes the last read
    # take one byte from beyond the image — whatever happens to be in the RAM
    # buffer at that address. The checksum then depends on something that is not
    # in the file, and the push passes or fails by luck. sum16() below assumes
    # that byte is 0x00; padding makes the assumption true instead of hoping.
    #
    # This bites the stock rollback image and not ours: our sealed squashfs
    # comes out even, the vendor's file-system section (10,207,235 bytes) does
    # not. Nothing about an extra trailing zero harms either — the boot gate
    # covers only the first BE32(sb[8:12])+642 bytes, and the flash region is
    # erased before the write.
    if len(payload) % 2:
        payload += b"\x00"
    chk = (-sum16(payload)) & 0xFFFF
    be2 = chk.to_bytes(2, "big")
    # r4 fix: uboot IMG_HEADER_T = 16 bytes; checkAutoFlashing with
    # skip_header=1 (r6cr AND cr6c) burns from byte 16 with len = payload+2,
    # checksumming header[16..16+len) which must sum to 0.
    # => BOTH conventions: 16-byte header (sig+start+burn+len), payload,
    #    TRAILING 2-byte checksum. (Old r6cr-with-leading-chk 18-byte header
    #    was wrong for the device; the 18-byte kit is superseded.)
    return sig + be32(start) + be32(burn) + be32(len(payload) + 2) + payload + be2


def main(argv):
    if len(argv) >= 2 and argv[1] == "--selftest":
        if len(argv) != 5:
            sys.exit(__doc__)
        blob = open(argv[2], "rb").read()
        off = int(argv[4], 16)
        exp = int(argv[3], 16)
        # stock kernel header convention: len says payload+2, checksum sits at payload end
        from struct import unpack_from
        sig, start, burn, ln = unpack_from(">4sIII", blob, off)
        pay = blob[off + 16: off + 16 + (ln - 2)]
        got = (-sum16(pay)) & 0xFFFF
        if got != exp:
            print(f"selftest FAIL: computed {got:#06x} expected {exp:#06x}")
            return 1
        # build() must reproduce the stock kernel image byte-exactly (r3 fix:
        # proves the TRAILING-checksum convention end-to-end)
        rebuilt = build(b"cr6c", start, burn, pay)
        if rebuilt != blob[off:off + len(rebuilt)]:
            print("selftest FAIL: build(cr6c) != factory kernel bytes")
            return 1
        print(f"selftest OK: sig={sig.decode()} start={start:#x} burn={burn:#x} "
              f"len={ln:#x} checksum={got:#06x} (build(cr6c) == factory, byte-exact)")
        return 0

    presets = {
        "root":   ("r6cr", 0x80F00000, 0x00400000),
        "kernel": ("cr6c", 0x80F00000, 0x00040000),
    }
    if len(argv) >= 4 and argv[1] == "kernel":
        # gate: rebuilding the kernel is high-risk (brick) and unused today;
        # the preset now emits the stock TRAILING-checksum cr6c convention,
        # but require an explicit --force-kernel to acknowledge it.
        if "--force-kernel" not in argv:
            sys.exit("kernel preset is gated: pass --force-kernel to build a "
                     "cr6c kernel image (trailing-checksum stock convention)")
        argv = [a for a in argv if a != "--force-kernel"]
    if len(argv) == 4 and argv[1] in presets:
        sig, start, burn = presets[argv[1]]
        sig = sig.encode()
        pay_in, out = argv[2], argv[3]
    elif len(argv) == 6:
        sig, start, burn, pay_in, out = (argv[1].encode(), int(argv[2], 0),
                                         int(argv[3], 0), argv[4], argv[5])
    else:
        sys.exit(__doc__)
    payload = open(pay_in, "rb").read()
    open(out, "wb").write(build(sig, start, burn, payload))
    print(f"cvimg {sig.decode(errors='replace')}: payload {len(payload)} B -> {out} "
          f"(checksum {(-sum16(payload)) & 0xFFFF:#06x})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
