# Out-of-tree build of rootfs_data_part.ko against the vendor kernel.
#
#   make -C <ovbuild>/linux-4.4 M=$(PWD) ARCH=mips \
#        CROSS_COMPILE=<msdk>/bin/mipsel-linux-uclibc- modules
#
# It MUST be the vendor kernel source and a toolchain that produces
# `vermagic=4.4.176 mod_unload MIPS32_R2 32BIT`, or the module cannot load:
# CONFIG_MODVERSIONS is off on this kernel, so vermagic is the entire
# compatibility check. build_image.sh asserts it.
obj-m := rootfs_data_part.o
