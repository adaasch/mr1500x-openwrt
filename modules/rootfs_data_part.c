/*
 * rootfs_data_part - carve a REAL, hard-bounded MTD partition for the OpenWrt
 * overlay on the MR1500X / MR60Xv2 (RTL8197F, vendor kernel 4.4.176).
 *
 *   insmod rootfs_data_part.ko          (defaults below)
 *   insmod rootfs_data_part.ko master=rootfs offset=0x600000 size=0x5a0000
 *
 * WHY THIS EXISTS
 * The vendor mtd map is compiled in (rtkxxpart.c never reads an on-flash table)
 * and has no partition for a writable overlay. The only spare space lives
 * INSIDE mtd2 "rootfs", which spans flash 0x400000..0xff0000 and overruns the
 * factory tail at 0xfa0000 (default-mac, product-info, radio calibration).
 * Those bytes cannot be restored by TFTP rescue, so OpenWrt's stock rootfs_data
 * auto-detection — which claims everything from the end of the squashfs to the
 * end of the partition — must never be let near this device.
 *
 * WHY NOT block2mtd OVER A LOOP DEVICE (the first attempt)
 * A loop device with lo_offset/lo_sizelimit does bound the window safely, and
 * jffs2 mounted and worked on it. But the only block device for the flash is
 * /dev/mtdblock2, and mtdblock keeps the current eraseblock in a RAM cache that
 * is written back on flush/release. block2mtd holds the device open forever, so
 * that cache was never flushed: every setting written survived until reboot and
 * then vanished. Measured exactly that — overlay mounted fine, contents gone.
 *
 * A real MTD partition has none of that: erase/write go straight to the NOR
 * through the vendor SPI driver, which is what jffs2 expects.
 *
 * SAFETY
 * The factory guard is enforced here at compile time (MTD2_SAFE_END), the same
 * constant mtdregion and loopset use. The module refuses to register a
 * partition that would reach it, refuses a non-eraseblock-aligned window, and
 * refuses if the master is smaller than expected. Belt and braces, because a
 * mistake here is not recoverable.
 *
 * Build: as an out-of-tree module against the vendor GPL kernel source with the
 * vendor toolchain, so vermagic matches (4.4.176 mod_unload MIPS32_R2 32BIT).
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/mtd/mtd.h>
#include <linux/mtd/partitions.h>

/* mtd2-relative hard ceiling: flash 0xfa0000 - partition base 0x400000 */
#define MTD2_SAFE_END 0xba0000UL

static char *master = "rootfs";
static ulong offset = 0x600000;		/* flash 0xa00000 */
static ulong size   = 0x5a0000;		/* ends exactly on MTD2_SAFE_END */
static char *name   = "rootfs_data";

module_param(master, charp, 0444);
MODULE_PARM_DESC(master, "name of the MTD to carve from (default: rootfs)");
module_param(offset, ulong, 0444);
MODULE_PARM_DESC(offset, "offset within the master, eraseblock aligned");
module_param(size, ulong, 0444);
MODULE_PARM_DESC(size, "length of the partition");
module_param(name, charp, 0444);
MODULE_PARM_DESC(name, "name of the new partition (default: rootfs_data)");

static struct mtd_info *rd_master;
static int rd_partno = -1;

static int __init rootfs_data_part_init(void)
{
	struct mtd_info *m;
	int ret;

	m = get_mtd_device_nm(master);
	if (IS_ERR(m)) {
		pr_err("rootfs_data_part: no MTD named \"%s\"\n", master);
		return PTR_ERR(m);
	}

	if (size == 0) {
		pr_err("rootfs_data_part: refusing zero size\n");
		ret = -EINVAL;
		goto err_put;
	}
	if (offset + size < offset) {
		pr_err("rootfs_data_part: refusing: offset+size overflows\n");
		ret = -EINVAL;
		goto err_put;
	}
	/* The whole point of this module: never reach the factory tail. */
	if (offset + size > MTD2_SAFE_END) {
		pr_err("rootfs_data_part: REFUSING 0x%lx..0x%lx — crosses the "
		       "factory-data guard at 0x%lx (flash 0xfa0000). That region "
		       "holds the MAC, product-info and radio calibration and is "
		       "NOT recoverable by rescue.\n",
		       offset, offset + size, MTD2_SAFE_END);
		ret = -EINVAL;
		goto err_put;
	}
	if (offset + size > m->size) {
		pr_err("rootfs_data_part: 0x%lx..0x%lx exceeds \"%s\" size 0x%llx\n",
		       offset, offset + size, master,
		       (unsigned long long)m->size);
		ret = -EINVAL;
		goto err_put;
	}
	if (m->erasesize && ((offset % m->erasesize) || (size % m->erasesize))) {
		pr_err("rootfs_data_part: 0x%lx+0x%lx not aligned to erasesize 0x%x\n",
		       offset, size, m->erasesize);
		ret = -EINVAL;
		goto err_put;
	}

	ret = mtd_add_partition(m, name, offset, size);
	if (ret) {
		pr_err("rootfs_data_part: mtd_add_partition failed: %d\n", ret);
		goto err_put;
	}

	rd_master = m;
	pr_info("rootfs_data_part: \"%s\" = %s + 0x%lx, 0x%lx bytes "
		"(flash 0x%lx..0x%lx), guard 0x%lx\n",
		name, master, offset, size,
		0x400000UL + offset, 0x400000UL + offset + size, MTD2_SAFE_END);
	return 0;

err_put:
	put_mtd_device(m);
	return ret;
}

static void __exit rootfs_data_part_exit(void)
{
	/* Partitions are removed by index; we only ever added one. Leaving it in
	 * place on unload would be worse than refusing to unload, so try. */
	if (rd_master) {
		if (rd_partno >= 0)
			mtd_del_partition(rd_master, rd_partno);
		put_mtd_device(rd_master);
		rd_master = NULL;
	}
}

module_init(rootfs_data_part_init);
module_exit(rootfs_data_part_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Bounded rootfs_data MTD partition for MR1500X (guards the factory tail)");
