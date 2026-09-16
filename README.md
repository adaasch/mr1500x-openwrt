# OpenWrt userspace on the Mercusys MR1500X v2

This turns a Mercusys MR1500X v2 into an OpenWrt 21.02.7 router **without
replacing its kernel**. The device keeps its vendor Linux 4.4.176 — which is
what drives its two Realtek radios, its switch and its hardware NAT — and only
the root filesystem is replaced. You get LuCI, uci, opkg, dropbear, fw3, a
persistent overlay and working 2.4 + 5 GHz Wi-Fi.

It is built entirely from public sources by `build_image.sh`. No binary in the
image comes from this repository.

> **Scope.** Kernel 4.4 has been end-of-life since 2022 and this image cannot
> change that — the vendor kernel is the only thing that can drive this
> hardware. Treat the result as a LAN/lab router, not an internet-facing
> security boundary.

---

## 1. What this is

| | |
|---|---|
| Device | Mercusys MR1500X v2 (same image family as MR60X v2/v3 and MR62X) |
| SoC | Realtek RTL8197F(H), MIPS 24Kc |
| 2.4 GHz | RTL8192FE, in-SoC, driver `rtl8192cd` |
| 5 GHz | RTL8832BR on PCIe, driver `rtk_wifi6` |
| Switch | RTL8367RB-VC |
| Flash | Winbond W25Q128JV, 16 MiB NOR |
| Serial console | **none** — no UART is populated on this board |

The architecture in one paragraph: the vendor bootloader boots the vendor
kernel from `os-image`, the vendor kernel mounts `rootfs` at flash `0x400000`,
and that rootfs is ours — an OpenWrt 21.02.7 mipsel_24kc musl userspace, plus
three kernel modules built against the vendor kernel source, plus one patched
`wpad`. Everything else on the flash is untouched.

### What is on the flash, and what this writes

```
0x000000  fs-uboot        bootloader            NEVER WRITTEN
0x040000  os-image        vendor kernel 4.4.176 NEVER WRITTEN
0x400000  rootfs          <- this image         written  (budget 0x600000)
0xa00000  rootfs_data     overlay, your settings  preserved across upgrades
0xfa0000  factory tail    MAC, WPS pin, radio calibration   NEVER WRITTEN
```

The factory tail is the part worth being careful about: it holds this unit's MAC
address and its radio calibration, neither of which can be regenerated or
downloaded. The image never writes there, the overlay partition is bounded in
the kernel module that creates it, and the sysupgrade path (`/sbin/mr1500x-fwupd`)
refuses any payload that would reach past the rootfs budget.

## 2. First boot

After flashing, wait about 50 seconds, then browse to **http://192.168.1.1**.

| | |
|---|---|
| LAN | 192.168.1.1/24, DHCP server on |
| WAN | `eth1.1`, DHCP client, in the `wan` firewall zone |
| Web UI | LuCI on :80 |
| Root password | **none** — set one on first login |
| SSH | dropbear on :22, but see below |
| **Wi-Fi** | **both radios are OFF** |

Three of those need explaining.

> ### ⚠ Set a root password before you do anything else
>
> The image ships with **no root password**, and until you set one **anyone on
> your LAN can log in as root over SSH, with any password at all**. Not a blank
> one — *any* one. OpenWrt patches dropbear so that root with an empty password
> field is accepted regardless of what is typed
> (`600-allow-blank-root-password.patch`), and this image keeps that upstream
> behaviour.
>
> So: browse to http://192.168.1.1, log in (the password field is empty), go to
> **System → Administration → Router Password**, and set one. LuCI nags you
> until you do. It takes fifteen seconds and it closes the hole.

**Why ship it that way at all?** Because the alternative is worse. An image
cannot keep a secret: a password baked into a public download is the same on
every unit and printed in the release notes, which is not authentication, only
the appearance of it. Upstream OpenWrt makes the same trade, and shipping with
no SSH at all would remove the only recovery path this board has short of TFTP —
there is no serial console. The exposure lasts from first boot until you set a
password, and on the LAN side only — but by the firewall, not by a socket
bind. dropbear listens on `0.0.0.0:22` and fw3's `wan` zone rejects input,
which is upstream OpenWrt's normal arrangement and was verified here from a
host on the WAN subnet (22, 80 and 53 all refused, TCP and UDP). Worth
knowing which mechanism is protecting you: a firewall rule can be edited
away, an interface bind cannot.

**Both radios ship disabled, with no SSID key.** Same reason: a shipped
passphrase is not a passphrase, and an open AP bridged to your LAN is worse.
Go to *Network → Wireless*, edit a radio, set the SSID and an encryption
passphrase, and enable it. The image already knows how to drive these radios;
it just will not put anything on the air that you did not configure.

**Check the country code before you transmit.** `/etc/config/mr1500x-wifi`
ships `option country 'DE'` as a placeholder, not a recommendation. The 5 GHz
RF tables carry per-region power limits (FCC / ETSI / MKK / IC / KCC / ACMA /
…) and the driver selects by this value, so a wrong country means transmitting
outside your local rules. Change it on both radio sections:

```sh
uci set mr1500x-wifi.radio2g.country=US     # your ISO 3166-1 code
uci set mr1500x-wifi.radio5g.country=US
uci commit mr1500x-wifi && /etc/init.d/mr1500x-wifi restart
```

Deleting the option does not mean "no country" — `mr1500x-wifi` falls back to
`DE` internally, so the only effect is that the value stops being visible.
Setting it in LuCI works too, but *clearing* the field there does not clear it
here; set the code you want rather than blanking it. The vendor driver also
ignores the cfg80211 regulatory domain, so `iw reg get` is not a second opinion
— this option is the whole control.

## 3. Building

```sh
./build_image.sh --gpl MR60Xv2_GPLcode20241202093448.tar.gz \
                 --firmware MR1500X_V2_1.1.3_Build_2025061020250902063658.zip
```

Two inputs are downloads you fetch yourself, because both should come from the
vendor rather than from a stranger:

- **the GPL drop** — Mercusys MR60X v2 product page → *GPL Code*. It carries the
  kernel source, the kernel config, the `gpio-button-hotplug` source and the
  Realtek MSDK toolchain. Its sha256 is pinned in the script.
- **the official firmware image** — the MR1500X v2 download page. Only 39 files
  are taken from it: the 5 GHz RF calibration tables (see §5).

Everything else is fetched by the script: OpenWrt at a pinned commit
(`v21.02.7`, `57a6d97…`) and the package feeds at pinned revisions.

**Requirements:** ~15 GB disk, a normal build host (`gcc`, `make`, `python3`,
`xz`, `bc`, `git`), and **32-bit runtime libraries**, because the vendor
toolchain that builds the kernel modules is an i386 binary:

```sh
sudo dpkg --add-architecture i386 && sudo apt update
sudo apt install libc6:i386 zlib1g:i386
```

The script checks for this before it starts the long part. Do not build as
root. Output lands in `<workdir>/out/`:

```
mr1500x-root-r6cr.bin   the flashable image
manifest.txt            toolchain versions, source revisions, per-file sha256
sha256sums.txt
```

A build of this kit on the machine it was validated on produces:

```
38be3f5385c94693b53d2695ce88a02562c85eff33edcf9f9e423c9d9c207733  mr1500x-root-r6cr.bin   (2953236 bytes)
```

Two builds in different directories on one machine agree on 895 of the 896
files in the image. The one that differs is `usr/lib/libelf-0.180.so`, and it
differs only in its 20-byte GNU build-id: that hash is taken over the link, and
the objects libelf links carry musl's own build path, which `REPRODUCIBLE_DEBUG_INFO`
does not reach because the toolchain is built before it applies. Two `kmod-mt76-*`
opkg metadata files can also differ by a byte of `Installed-Size`. Nothing
executable differs. A build on a *different* machine is not claimed to match.

Before it seals anything, the build unpacks the image it has just packed and
sha256-compares every file against the tree it was built from. That is not
ceremony: squashfs carries no per-file integrity data and the bootloader
checksums only the first 642 bytes, so a single flipped bit anywhere else would
otherwise be flashed, mounted and executed with nothing noticing. One build here
did exactly that — one bit, in one instruction, in `dropbear`.

`./build_image.sh --selftest` runs the packaging checks (seal, boot gate,
container arithmetic) in a couple of seconds without building anything.

## 4. Flashing

The image is pushed to the bootloader's own TFTP recovery ("down mode"). This
is the same path the vendor's own recovery uses, and it writes only the rootfs
region.

1. **Set your PC to a static `192.168.1.x/24`** (not .1) on the LAN port.
2. **Enter down mode:** power the router off, hold the reset button, power it
   on, keep holding ~10 seconds. The device answers on `192.168.1.1` — TFTP on
   :69 and a small HTTP page on :80.
3. **Push the image:**
   ```sh
   python3 tools/tftp_push.py 192.168.1.1 out/mr1500x-root-r6cr.bin
   ```
   The device decides what to do from the payload *signature*, not the
   filename: `r6cr` means "burn to 0x400000". The client refuses the two magic
   filenames (`boot.img`, `nfjrom`) that would make the bootloader execute your
   upload instead of flashing it.

   It also stops two ways of flashing the wrong thing, both before a single
   byte of payload leaves your PC. **The file must be one of this device's
   containers** — signature, matching burn address, and a length field that
   matches the file exactly, so a vendor `.bin`, another project's image or a
   half-finished download is refused here rather than handed to the bootcode.
   **And the thing answering must be this bootcode**: `eth_tftpd.c` replies
   from UDP port 2098, where RFC 1350 says an ordinary TFTP server picks a
   random port per transfer, so a different vendor's bootloader or a `tftpd` on
   a machine that has taken `192.168.1.1` is caught at the first ACK. `--force`
   skips both. Neither can tell you the *model* — the bootcode announces none,
   and its read-back serves RAM rather than flash — so that check lives on the
   `sysupgrade` path instead, where there is a Linux to read the product-info
   record with.
4. **Wait for the burn to finish before powering off.** After the last block is
   acknowledged, the device is erasing and writing flash. Re-probe TFTP: when
   it answers again, the write is done. **Never power-cycle mid-write.**
5. **Power-cycle normally** (no reset held).

Optional, and cheap: before step 3, push a *no-burn twin* — the same file with
its signature changed from `r6cr` to `X6cr`. An unknown signature is stored in
RAM and never burned, and you can read it back out with a TFTP GET and compare
byte for byte. That proves the delivery path before you touch flash.

### Later upgrades

Once this image is running you do not need TFTP again: `sysupgrade` takes the
same `mr1500x-root-r6cr.bin`. It verifies the boot gate *before* erasing
anything, and it also checks the board: the vendor's product-info record at
flash `0xfa0400` says `vendor_name:Mercusys` and `product_name:MR1500X`, and an
upgrade refuses to proceed unless it finds a Mercusys record naming a model this
image is built for (`MR1500X`, or `MR60X`/`MR62X` with a warning — the same
board and image per the vendor's own SupportList, but untested here).
`sysupgrade -F` overrides that, for a unit whose factory data has been damaged.
It writes only the rootfs region, and leaves your settings alone —
the overlay is its own partition, so there is no config backup/restore dance.
`sysupgrade -n` wipes settings by erasing that partition explicitly.

**Know which one you want, because "keep my settings" is stronger here than on
a normal OpenWrt device.** Elsewhere the overlay lives inside the partition
being rewritten, so a plain upgrade tars your config up and restores it. Here
the overlay is never touched by the write at all, which means any file you have
ever edited keeps shadowing the new `/rom` copy indefinitely — including
defaults that changed between versions. If an upgrade seems not to have taken
effect, that is why. `sysupgrade -n` is the "give me this image's own defaults"
button; it erases `rootfs_data` and nothing else, and it cannot reach the
factory data.

## 5. Backup and rollback

**You cannot take a backup over TFTP.** The bootloader's TFTP GET serves the
buffer of the last file you *pushed*, not the flash; the command channel that
could dump memory is compiled out of the shipping bootloader; and the monitor
commands that remain need the serial console this board does not have. Anyone
telling you to "just read it back over TFTP" has not tried it on this device.

What you do have:

- **Rollback to stock, over the network.** The kit extracts the official
  firmware's own filesystem and wraps it for the same TFTP path:
  ```sh
  python3 tools/extract_stock_rootfs.py rootfs \
          MR1500X_V2_1.1.3_Build_2025061020250902063658.zip \
          stock.sqfs --wrap stock-root-r6cr.bin
  python3 tools/tftp_push.py 192.168.1.1 stock-root-r6cr.bin
  ```
  The vendor's filesystem section is already sealed for the boot gate, so it is
  wrapped, not modified. This restores every region this image ever wrote. (It
  also overwrites the overlay, so your settings are gone — that is the point.)
- **A full-chip backup needs a programmer.** A CH341A with an SOP-8 clip, off
  board, before your first flash. Many CH341A clones drive 5 V on the data
  lines and will damage a 3.3 V part — check yours before connecting it.
- **Once this image runs you can back up most of it from inside, but not all.**
  `dd if=/dev/mtd0 of=…` over each partition gets you the bootloader, the whole
  rootfs region and the factory tail — everything this image writes, and
  everything that is unrecoverable if lost. It does **not** get you the vendor
  kernel, and it is worth knowing why, because the reason is a trap:

  ```
  mtd0 uboot   offset 0x000000  size 0x040000
  mtd1 uImage  offset 0x400000  size 0x3c0000   <- offset is wrong
  mtd2 rootfs  offset 0x400000  size 0xbf0000
  mtd3 ART     offset 0xff0000  size 0x010000
  ```

  `uImage` is *sized* as the kernel partition (`0x400000 - 0x040000`) but
  *offset* to the start of the rootfs. The vendor's own partition table does
  this — `rtkxxpart.c` in the GPL drop sets `offset: CONFIG_RTL_ROOT_IMAGE_OFFSET`
  where it means `CONFIG_RTL_LINUX_IMAGE_OFFSET` — so it ships this way on the
  stock firmware too. Two consequences:

  **Never write to `/dev/mtd1`.** It is not the kernel. It is a 3.75 MiB window
  onto the beginning of your rootfs, and any generic "flash the kernel to mtd1"
  advice will destroy the filesystem you are running from.

  **Flash `0x040000`–`0x400000` is reachable by no partition at all**, so the
  running kernel cannot read or write its own image. Concatenating every `mtd`
  device does not give you a 16 MiB chip image: it gives you the rootfs head
  twice and no kernel. If you want a true full-chip backup, that is what the
  CH341A above is for.

## 6. What works, and what does not

**Works:** both radios (WPA2-PSK, WPA3-SAE, SAE mixed mode, OWE, 802.11r fast
transition between the box's own two BSSes); Wi-Fi client uplink; the switch
and VLANs; hardware NAT (toggleable); LEDs; the reset button, configurable
through a device-specific LuCI page; sysupgrade; a persistent overlay; per-unit
SSH host keys generated on first boot; per-unit radio MACs derived from the
factory tail.

**Does not, and why:**

| Limit | Reason |
|---|---|
| 29 of LuCI's 85 wireless options are wired up | the rest are rendered but inert. The ones that work are the ones `/etc/init.d/mr1500x-wifi` writes into the generated hostapd config — read `write_conf()` and the `SEED_OPTS`/`FLAG_OPTS`/`DEV_OPTS` lists in that file for the exact set, which is authoritative in a way a separate document could only go stale against |
| `htmode` up to HT40; no VHT/HE | not wired to the vendor driver |
| No ACS (automatic channel selection) | pick a channel |
| One SSID per radio; no mesh/ad-hoc/monitor/WDS | the driver is not netifd-driven here |
| No WPA-Enterprise (EAP/RADIUS) | unwired; the stock firmware has the branch, so it is possible, not impossible |
| `txpower` is not adjustable | it needs a driver call that can hang this driver until a power cycle |
| opkg installs userspace packages only | the `openwrt_core` feed ships kernel modules built for kernel 5.4 — they can never load here, so that feed is deliberately absent. `base` and `packages` work normally. |
| No `/sbin/shd` | the bench image had an unauthenticated root shell on :23 for bring-up work. It is not in a published image. |

## 7. Troubleshooting

**The box does not come up after flashing.** It is almost certainly back in
down mode, which is recoverable: re-enter down mode and push again. The
bootloader will not boot a rootfs that fails its checksum gate, which is why
`build_image.sh` simulates that gate before it emits an image, and why
`sysupgrade` verifies it before erasing. You can check any image yourself:

```sh
python3 tools/uboot_fs_seal.py verify <rootfs.sealed>
```

**Is it in down mode?** It answers TFTP on 192.168.1.1:69 and serves a small
upload page on :80. Nothing else answers.

**It answers ARP but every TCP connection fails.** Usually a stale ARP entry on
the host. Pin it: `ip neigh replace 192.168.1.1 lladdr <mac> dev <if> nud permanent`.

**Power-cycling.** A hung radio driver survives a reboot and only clears on a
real power cycle; when that happens, cut power for ≥10 seconds so the capacitors
discharge.

## 8. Licensing and provenance

Everything in the image is built from source by `build_image.sh`:

| Component | Source | License |
|---|---|---|
| OpenWrt userspace, toolchain | github.com/openwrt/openwrt @ `57a6d97` (v21.02.7) | GPL-2.0 and others, per package |
| LuCI | github.com/openwrt/luci @ `e4c46338` | Apache-2.0 |
| Package feed | git.openwrt.org/feed/packages @ `48242ee7` | per package |
| `wpad` association patch | `patches/900-rtl8192cd-sta-assoc-reply.patch` | BSD-3-Clause (hostapd's license) |
| Kernel modules (`overlay`, `rootfs_data_part`, `gpio-button-hotplug`) | Mercusys GPL drop + `modules/rootfs_data_part.c` | GPL-2.0 |
| `mr1500x-fwupd`, `hapcli`, init scripts, LuCI page | `src/`, `files/` in this kit | GPL-2.0 |
| RF calibration tables (39 files) | the vendor's own firmware image, extracted at build time | proprietary vendor data, not redistributed here |

The kernel itself is not modified and not redistributed here: the modules are
built against Mercusys' published GPL source, which is where the corresponding
source for the kernel that runs on your device comes from.

This project is not affiliated with Mercusys or TP-Link. Flashing it will void
your warranty, and it is on you to comply with the radio regulations where you
operate it.
