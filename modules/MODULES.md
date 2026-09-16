# The three kernel modules

The image needs exactly three modules on top of the vendor kernel. All three are
built by `build_image.sh` from source, with the **vendor's own toolchain**
(Realtek MSDK 6.4.1, shipped inside the GPL drop at
`sdk/toolchain/msdk-6.4.1-mips-EL-4.4-u0.9.33-m32ut-190619.tar.bz2`).

| Module | Source | What it is for |
|---|---|---|
| `overlay.ko` | the vendor kernel tree, `fs/overlayfs` | overlayfs is `# CONFIG_OVERLAY_FS is not set` in the vendor config; without it the rootfs is read-only and no setting survives a reboot |
| `rootfs_data_part.ko` | `rootfs_data_part.c`, here | carves the bounded MTD partition the overlay lives in |
| `gpio-button-hotplug.ko` | the GPL drop's own `openwrt/package/gpio-button-hotplug/src/` | the kernel has `CONFIG_INPUT` off, so this is what turns a GPIO press into the uevent procd routes to `/etc/rc.button/reset` |

## Why the vendor toolchain

`CONFIG_MODVERSIONS` is **off** in this kernel. That means there are no symbol
CRCs, and the entire compatibility check is the vermagic string:

```
vermagic=4.4.176 mod_unload MIPS32_R2 32BIT
```

A module that does not match does not load — and on a board with no serial
console, "the overlay module did not load" shows up as "my settings vanished",
hours later.

Using the compiler the kernel was built with removes the question. It is not a
guess: the running kernel's banner says

```
Linux version 4.4.176 (jenkins@...) (gcc version 6.4.1 20180425 (Realtek MSDK-6.4.1 Build 3055))
```

and the modules built this way come out **byte-identical** to the ones that have
been running on the device — verified for `overlay.ko` and `rootfs_data_part.ko`,
and for `gpio-button-hotplug.ko` the `.text`, `.data` and `.rodata` sections
match exactly (the vendor's copy is stripped, ours is not).

The toolchain is an **i386** binary, so a 64-bit build host needs 32-bit runtime
libraries (`libc6:i386`, `zlib1g:i386`). That is the only cost of using it, and
`build_image.sh` checks for the loader before it starts the long build.

## Building them by hand

The BSP reaches out of the kernel tree with relative symlinks
(`arch/mips/bsp -> ../../../target/bsp`), so `linux-4.4` needs its siblings
next to it:

```sh
G=<gpl>/sdk/openwrt-21.02/target/linux
mkdir ovbuild
cp -a $G/linux-4.4 $G/target $G/rtknet ovbuild/
cp <gpl>/build/kernel.config ovbuild/linux-4.4/.config
sed -i 's/^# CONFIG_OVERLAY_FS is not set$/CONFIG_OVERLAY_FS=m/' ovbuild/linux-4.4/.config

CROSS=<msdk>/bin/mipsel-linux-uclibc-
make -C ovbuild/linux-4.4 ARCH=mips CROSS_COMPILE=$CROSS olddefconfig
make -C ovbuild/linux-4.4 ARCH=mips CROSS_COMPILE=$CROSS modules_prepare
make -C ovbuild/linux-4.4 ARCH=mips CROSS_COMPILE=$CROSS SUBDIRS=fs/overlayfs modules
make -C ovbuild/linux-4.4 ARCH=mips CROSS_COMPILE=$CROSS M=$PWD modules   # this dir
```

`modules_prepare` needs `bc`. It builds clean with no patches — the vendor
compiler is contemporary with the vendor kernel, which is the whole point.

Build out-of-tree modules on a **copy** of this directory. Kbuild writes
`.o`/`.ko`/`.cmd`/`.tmp_versions` next to the source, and a stray prebuilt
`.ko` sitting here is exactly the silent fallback that "no prebuilt binaries"
exists to prevent. `build_image.sh` copies before building.

## The flash window `rootfs_data_part.ko` guards

```
mtd2 "rootfs"   flash 0x400000 .. 0xff0000     (the kernel's compiled-in map)
  rootfs           0x400000 .. 0xa00000        squashfs, budget 0x600000
  rootfs_data      0xa00000 .. 0xfa0000        overlay, jffs2
  factory tail     0xfa0000 ..                 MAC, product info, radio cal
```

The vendor partition **overruns the factory tail by 0x50000**. OpenWrt's stock
`rootfs_data` auto-detection claims everything from the end of the squashfs to
the end of the MTD partition, which here would format over the MAC address and
the radio calibration — neither of which can be restored from any download.

That is why the overlay is a real, explicitly bounded partition rather than
auto-detected, why the guard constant is compiled into the module (the build
greps the `.ko` for it), and why stock auto-detection must never be enabled on
this device.
