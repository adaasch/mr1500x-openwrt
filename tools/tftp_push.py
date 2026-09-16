#!/usr/bin/env python3
"""
tftp_push.py — push a firmware file to the MR1500X/MR60Xv2 bootcode
TFTP recovery (RFC1350 write request to UDP 69; the bootcode ACKs from
its own port, 2098 upwards in server/down mode — see guard 2 below).

usage: tftp_push.py <device-ip> <file> [--force]

Notes decoded from package/uboot/realtek/generic/boot/init/eth_tftpd.c:
- the device treats incoming WRQ by PAYLOAD SIGNATURE (sign_tbl), so the
  file NAME on the PC side is arbitrary; AVOID the magic names
  'boot.img' (RAM-boot) and 'nfjrom' (NFBI test).
  r6cr = root filesystem, burns bare (skip_header) using header.burnAddr.
  cr6c/cs6c = kernel, burns with header at its position, reboots.
- device IP is its configured LAN IP (factory 192.168.1.1); the PC should
  be set to a static 192.168.1.x/24 with a different last octet.

TWO GUARDS AGAINST FLASHING THE WRONG THING, both free and both before a
single byte of payload leaves the PC:

1. The file must BE one of our containers. The bootcode burns by payload
   signature, and it will happily accept 3 MB of something else and do
   whatever its own table says about the first four bytes. So the header is
   parsed here first: signature, the burn address that goes with it, and a
   length that matches the file exactly. A vendor .bin, a different
   project's image or a truncated download is refused on the PC.

2. The device must BE a down-mode bootcode. `eth_tftpd.c` sets
   `SERVER_port = 2098` when the recovery server starts and does
   `SERVER_port++` at the end of each COMPLETED transfer, answering with
   `udp->src = htons(SERVER_port)`. So the first push of a session is
   acked from 2098, the second from 2099, and so on. RFC 1350 says a normal
   TFTP server picks an ephemeral TID per transfer, and on Linux that comes
   from 32768-60999 — nowhere near here. Checking for a small window above
   2098 therefore still tells a recovery bootcode apart from another
   vendor's bootloader, a running tftpd, or a PC that has taken the address.

   This started life as an equality test against 2098, which passed the
   first live push and refused the second — on the install path, with a
   message claiming the board was wrong. Hardware found it; reading the
   source again explained it. A guard that blocks the thing it is meant to
   protect is worse than no guard.

Neither identifies the MODEL: the bootcode announces nothing, and its
RRQ reads back RAM rather than flash, so there is no way to interrogate
the product-info partition from down mode. The model check lives on the
sysupgrade path, where there is a Linux to read it with. Consequently
these two guards catch "wrong image" and "not a Mercusys recovery
server", not "right family, wrong board". --force skips both.
"""
import os
import socket
import struct
import sys
import time

BLK = 512
OP_RRQ, OP_WRQ, OP_DATA, OP_ACK, OP_ERR = 1, 2, 3, 4, 5
MAGIC_NAMES = ("boot.img", "nfjrom")

# signature -> (what it is, the burn address the bootcode will use for it)
SIGS = {
    b"r6cr": ("root filesystem", 0x400000),
    b"cr6c": ("kernel", 0x40000),
    b"cs6c": ("kernel", 0x40000),
}
HDR = 16
# First transfer of a down-mode session; it increments per completed
# transfer, so accept a session-sized window rather than one value.
DOWN_MODE_PORT = 2098
DOWN_MODE_PORT_SPAN = 32


def check_container(data, path):
    """Return a one-line description, or a reason to refuse."""
    if len(data) < HDR:
        return None, f"{path} is {len(data)} bytes — not a firmware container"
    sig = data[:4]
    if sig not in SIGS:
        pretty = sig.decode("ascii", "replace")
        return None, (
            f"{path} starts with {pretty!r}, which is not a signature this "
            f"device burns ({', '.join(s.decode() for s in SIGS)}).\n"
            "   Pushing it would hand the bootcode a payload it will "
            "interpret by its own table. Refusing.")
    what, want_burn = SIGS[sig]
    start, burn, ln = struct.unpack(">III", data[4:HDR])
    if ln != len(data) - HDR:
        return None, (
            f"{path}: header says {ln} payload bytes, file has "
            f"{len(data) - HDR}. Truncated or not the file it claims to be.")
    if ln % 2:
        return None, f"{path}: payload length {ln} is odd; the bootcode " \
                     "requires an even length."
    if burn != want_burn:
        return None, (
            f"{path}: {sig.decode()} should burn to 0x{want_burn:x}, header "
            f"says 0x{burn:x}. That is not where this image belongs.")
    return (f"{sig.decode()} — {what}, {ln} bytes, burns at 0x{burn:x}, "
            f"entry 0x{start:08x}"), None


def peer_mac(ip):
    """Best effort, for the operator's eyes only. Never fails the push."""
    try:
        for line in open("/proc/net/arp"):
            f = line.split()
            if len(f) >= 4 and f[0] == ip and f[3] != "00:00:00:00:00:00":
                return f[3]
    except OSError:
        pass
    return None


def main(dev, path, force=False):
    name = os.path.basename(path)
    if name in MAGIC_NAMES:
        print(f"refusing magic filename {name}")
        return 2
    try:
        data = open(path, "rb").read()
    except OSError as e:
        print(f"cannot read {path}: {e}")
        return 2
    if not data:
        print("empty file")
        return 2

    desc, why = check_container(data, path)
    if why:
        if not force:
            print(f"refusing to push: {why}")
            return 2
        print(f"WARNING (--force): {why}")
    else:
        print(f"image: {desc}")
    # RFC1350 termination: the LAST data block must be shorter than 512.
    if len(data) % BLK == 0:
        data += b"\x00"
        print("note: appended one 0x00 byte to make final block short")

    nblk = -(-len(data) // BLK)  # ceil: last block is short by construction
    print(f"pushing {path} — {len(data)} bytes in {nblk} blocks to {dev}")

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(3.0)
    target = (dev, 69)          # WRQ goes to bootcode's accept port 69
    wrq = bytes([0, OP_WRQ]) + name.encode() + b"\0octet\0"

    def send_block(block, payload):
        """send one DATA block, wait its ACK; retry transfer through WRQ"""
        pkt = bytes([0, OP_DATA, block >> 8, block & 0xFF]) + payload
        for _ in range(6):
            s.sendto(pkt, target)
            try:
                reply, peer = s.recvfrom(600)
            except socket.timeout:
                continue
            op = int.from_bytes(reply[:2], "big")
            if op == OP_ERR:
                code = int.from_bytes(reply[2:4], "big")
                msg = reply[4:].split(b"\0")[0].decode(errors="replace")
                print(f"device ERROR {code}: {msg} for block {block}")
                raise ConnectionError("device refused the transfer")
            if op == OP_ACK and int.from_bytes(reply[2:4], "big") == block:
                return True
        return False

    try:
        # ---- WRQ handshake (block 0 ACK) ----
        for _ in range(5):
            s.sendto(wrq, target)
            try:
                reply, peer = s.recvfrom(600)
            except socket.timeout:
                continue
            op = int.from_bytes(reply[:2], "big")
            if op == OP_ERR:
                code = int.from_bytes(reply[2:4], "big")
                msg = reply[4:].split(b"\0")[0].decode(errors="replace")
                print(f"device ERROR {code}: {msg} on WRQ")
                return 1
            if op == OP_ACK and int.from_bytes(reply[2:4], "big") == 0:
                mac = peer_mac(dev)
                print(f"device answered from {peer[0]}:{peer[1]}"
                      + (f", MAC {mac}" if mac else ""))
                # The last exit before anything is written. eth_tftpd.c
                # replies from SERVER_port = 2098; a stock TFTP server would
                # have picked an ephemeral TID here.
                lo = DOWN_MODE_PORT
                hi = DOWN_MODE_PORT + DOWN_MODE_PORT_SPAN - 1
                if not (lo <= peer[1] <= hi) and not force:
                    print(
                        f"refusing to push: the ACK came from port {peer[1]}, "
                        f"outside {lo}-{hi}.\n"
                        "   This board's recovery server answers from "
                        f"{DOWN_MODE_PORT} upwards, so whatever is on {dev}:69 is "
                        "probably\n"
                        "   not an MR1500X in down mode — another vendor's "
                        "bootloader, or a TFTP\n"
                        "   daemon on a machine that has taken the address. "
                        "Nothing has been written.\n"
                        "   Use --force only if you know what is listening.")
                    return 1
                if not (lo <= peer[1] <= hi):
                    print(f"WARNING (--force): port {peer[1]} is outside "
                          f"{lo}-{hi}; this may not be an MR1500X")
                target = peer              # data channel uses the ACK port
                break
        else:
            print("no ACK(0) from device — is it in down-mode (reset-held)?")
            return 1

        # ---- data loop ----
        sent = 0
        for b in range(nblk):
            block = b + 1
            lo, hi = b * BLK, min((b + 1) * BLK, len(data))
            if not send_block(block, data[lo:hi]):
                print(f"stuck at block {block} — aborting (nothing burned "
                      f"beyond what blocks the device already ACKed)")
                return 1
            sent += 1
            if sent % 128 == 0:
                print(f"  {sent}/{nblk} blocks acked")

        print(f"transfer complete: {nblk} blocks, all ACKed")
        return 0
    except ConnectionError as e:
        print(str(e))
        return 1


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--force"]
    if len(args) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(args[0], args[1], force="--force" in sys.argv[1:]))
