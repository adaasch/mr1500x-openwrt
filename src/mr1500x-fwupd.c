/*
 * mr1500x-fwupd — sysupgrade back-end for the MR1500X / MR60Xv2 (RTL8197F).
 *
 * usage: mr1500x-fwupd --check <image-r6cr.bin>
 *        mr1500x-fwupd --write <mtd-char-dev> <image-r6cr.bin>
 *
 * WHY THIS EXISTS INSTEAD OF OpenWrt's `mtd write`
 *
 *   1. The rootfs mtd is NOT the rootfs region. mtd2 "rootfs" spans flash
 *      0x400000..0xff0000 and overruns the FACTORY TAIL at 0xfa0000 (MAC,
 *      product-info, radio calibration — unrecoverable) and the persistent
 *      overlay at 0xa00000. Stock `mtd write` erases the whole partition.
 *      This writes only ceil(payload, erasesize) and REFUSES anything that
 *      would reach past ROOTFS_BUDGET (mtd2-relative 0x600000), where the
 *      overlay begins.
 *
 *   2. The bootloader will not boot an unsealed rootfs. check_rootfs_image()
 *      scans 0x400000 in 64K steps and requires, at some offset:
 *          length = BE32(squashfs_sb[8:12]) + 640 + 2
 *          sum16be(flash[off .. off+length]) == 0
 *      A rootfs that fails this drops the box to TFTP-rescue "down mode", and
 *      this board has no UART. Our packer bakes the seal in (uboot_fs_seal.py),
 *      so an upgrade must not re-derive it — it must VERIFY it, before erasing
 *      anything. That is what --check does, replicating the bootloader's own
 *      arithmetic on the file.
 *
 * The image is the r6cr container the build produces:
 *      header(16) = "r6cr" + BE32 startAddr + BE32 burnAddr + BE32 len
 *                   where len = payload + 2
 *      payload    = the SEALED squashfs
 *      trailer(2) = BE16 cvimg checksum, so sum16be(file[16..16+len]) == 0
 * Only the payload is written; the trailing checksum is a container artifact
 * that the boot gate does not read (writing it too is harmless, but the flow
 * proven on this hardware writes the sealed payload alone).
 */
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <mtd/mtd-user.h>

#define SIG            "r6cr"
#define BURN_ADDR      0x400000u
/* mtd2-relative start of rootfs_data. Writing at or past this eats the
 * persistent overlay; see modules/rootfs_data_part.c in this kit. */
#define ROOTFS_BUDGET  0x600000u
#define SQFS_SB        640u      /* SIZE_OF_SQFS_SUPER_BLOCK, per the bootcode */

static uint32_t be32(const unsigned char *p)
{
	return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
	       ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

/* 16-bit big-endian word sum, exactly as the bootcode computes it */
static uint16_t sum16be(const unsigned char *b, size_t n)
{
	uint32_t s = 0;
	size_t i;
	for (i = 0; i < n; i += 2)
		s += ((uint32_t)b[i] << 8) | (i + 1 < n ? b[i + 1] : 0);
	return (uint16_t)(s & 0xffff);
}

struct img {
	unsigned char *buf;
	size_t         size;
	size_t         payload_off;   /* 16 */
	size_t         payload_len;   /* len field - 2 */
	size_t         burn_len;      /* len field: payload + checksum */
};

static int load_and_validate(const char *path, struct img *im)
{
	struct stat st;
	int fd = open(path, O_RDONLY);
	if (fd < 0) { fprintf(stderr, "FAIL: open %s: %s\n", path, strerror(errno)); return 1; }
	if (fstat(fd, &st) != 0) { fprintf(stderr, "FAIL: stat: %s\n", strerror(errno)); close(fd); return 1; }

	if ((size_t)st.st_size < 16 + SQFS_SB + 2) {
		fprintf(stderr, "FAIL: too small to be a firmware image (%lld bytes)\n",
		        (long long)st.st_size);
		close(fd);
		return 1;
	}
	im->size = (size_t)st.st_size;
	im->buf  = malloc(im->size);
	if (!im->buf) { fprintf(stderr, "FAIL: out of memory for %lu bytes\n",
	                        (unsigned long)im->size); close(fd); return 1; }
	if (read(fd, im->buf, im->size) != (ssize_t)im->size) {
		fprintf(stderr, "FAIL: short read on %s\n", path);
		close(fd);
		return 1;
	}
	close(fd);

	if (memcmp(im->buf, SIG, 4) != 0) {
		fprintf(stderr, "FAIL: not an r6cr image (signature is \"%.4s\")\n"
		        "      this tool only accepts the container the MR1500X build produces\n",
		        im->buf);
		return 1;
	}

	uint32_t burn = be32(im->buf + 8);
	uint32_t len  = be32(im->buf + 12);
	if (burn != BURN_ADDR) {
		fprintf(stderr, "FAIL: burn address is 0x%x, expected 0x%x\n", burn, BURN_ADDR);
		return 1;
	}
	if (len != im->size - 16) {
		fprintf(stderr, "FAIL: header length 0x%x does not match file (0x%lx)\n",
		        len, (unsigned long)(im->size - 16));
		return 1;
	}
	/* the device's burn loop steps i += 2 and would read one byte past an
	 * odd-length image */
	if (len & 1) {
		fprintf(stderr, "FAIL: header length 0x%x is odd\n", len);
		return 1;
	}

	if (sum16be(im->buf + 16, len) != 0) {
		fprintf(stderr, "FAIL: container checksum is wrong (image corrupt or truncated)\n");
		return 1;
	}

	im->payload_off = 16;
	im->burn_len    = len;
	im->payload_len = len - 2;

	unsigned char *pl = im->buf + im->payload_off;
	if (memcmp(pl, "hsqs", 4) != 0) {
		fprintf(stderr, "FAIL: payload is not a little-endian squashfs "
		        "(magic %02x%02x%02x%02x)\n", pl[0], pl[1], pl[2], pl[3]);
		return 1;
	}

	/* THE BOOT GATE — the same arithmetic check_rootfs_image() performs.
	 * If this does not hold, flashing this image bricks the box into TFTP
	 * rescue, so it is checked before a single sector is erased. */
	uint32_t field = be32(pl + 8);
	uint64_t glen  = (uint64_t)field + SQFS_SB + 2;
	if (glen > im->burn_len) {
		fprintf(stderr, "FAIL: boot gate length 0x%llx exceeds the image (0x%lx) — "
		        "image is not sealed\n", (unsigned long long)glen,
		        (unsigned long)im->burn_len);
		return 1;
	}
	uint16_t gsum = sum16be(pl, (size_t)glen);
	if (gsum != 0) {
		fprintf(stderr, "FAIL: boot gate checksum is 0x%04x, must be 0 — "
		        "image is not sealed (would boot to rescue)\n", gsum);
		return 1;
	}

	if (im->payload_len > ROOTFS_BUDGET) {
		fprintf(stderr, "FAIL: payload 0x%lx exceeds the rootfs budget 0x%x — "
		        "writing it would destroy the overlay\n",
		        (unsigned long)im->payload_len, ROOTFS_BUDGET);
		return 1;
	}

	printf("image ok: payload 0x%lx bytes, boot gate 0x%llx sums to zero, "
	       "fits budget 0x%x\n", (unsigned long)im->payload_len,
	       (unsigned long long)glen, ROOTFS_BUDGET);
	return 0;
}

static int do_write(const char *dev, struct img *im)
{
	struct mtd_info_user mi;
	int fd = open(dev, O_RDWR);
	if (fd < 0) { fprintf(stderr, "FAIL: open %s: %s\n", dev, strerror(errno)); return 1; }
	if (ioctl(fd, MEMGETINFO, &mi) != 0) { fprintf(stderr, "FAIL: MEMGETINFO: %s\n", strerror(errno)); return 1; }
	if (mi.type != MTD_NORFLASH) { fprintf(stderr, "FAIL: %s is not NOR flash\n", dev); return 1; }
	printf("mtd: size=0x%x erasesize=0x%x\n", mi.size, mi.erasesize);

	size_t aligned = ((im->payload_len + mi.erasesize - 1) / mi.erasesize) * mi.erasesize;
	if (aligned > ROOTFS_BUDGET) {
		fprintf(stderr, "FAIL: erase span 0x%lx would reach the overlay at 0x%x\n",
		        (unsigned long)aligned, ROOTFS_BUDGET);
		return 1;
	}
	if (aligned > mi.size) {
		fprintf(stderr, "FAIL: image too big for %s\n", dev);
		return 1;
	}

	unsigned char *buf = malloc(aligned);
	if (!buf) { fprintf(stderr, "FAIL: out of memory\n"); return 1; }
	memset(buf, 0xff, aligned);
	memcpy(buf, im->buf + im->payload_off, im->payload_len);

	unsigned char *vbuf = malloc(mi.erasesize);
	if (!vbuf) { fprintf(stderr, "FAIL: out of memory\n"); return 1; }

	printf("writing 0x%lx bytes to %s (erase span 0x%lx)\n",
	       (unsigned long)im->payload_len, dev, (unsigned long)aligned);

	size_t off;
	for (off = 0; off < aligned; off += mi.erasesize) {
		struct erase_info_user ei;
		ei.start = off; ei.length = mi.erasesize;
		/* MEMUNLOCK is advisory here: this vendor MTD returns EOPNOTSUPP
		 * because sectors are not locked. A genuinely locked sector fails
		 * the MEMERASE below, which is fatal. */
		if (ioctl(fd, MEMUNLOCK, &ei) != 0 && off == 0)
			fprintf(stderr, "note: MEMUNLOCK unsupported (%s); continuing\n",
			        strerror(errno));
		if (ioctl(fd, MEMERASE, &ei) != 0) { fprintf(stderr, "FAIL: MEMERASE at 0x%lx: %s\n", (unsigned long)off, strerror(errno)); return 1; }
		if (lseek(fd, off, SEEK_SET) < 0) { fprintf(stderr, "FAIL: lseek: %s\n", strerror(errno)); return 1; }
		if (write(fd, buf + off, mi.erasesize) != (ssize_t)mi.erasesize) { fprintf(stderr, "FAIL: write at 0x%lx: %s\n", (unsigned long)off, strerror(errno)); return 1; }
		if (lseek(fd, off, SEEK_SET) < 0) { fprintf(stderr, "FAIL: lseek2: %s\n", strerror(errno)); return 1; }
		if (read(fd, vbuf, mi.erasesize) != (ssize_t)mi.erasesize) { fprintf(stderr, "FAIL: readback at 0x%lx: %s\n", (unsigned long)off, strerror(errno)); return 1; }
		if (memcmp(vbuf, buf + off, mi.erasesize) != 0) {
			fprintf(stderr, "FAIL: verify mismatch at 0x%lx — DO NOT REBOOT, reflash\n",
			        (unsigned long)off);
			return 1;
		}
		printf("block 0x%06lx ok\n", (unsigned long)off);
	}
	if (fsync(fd) != 0 && errno != EINVAL)
		fprintf(stderr, "note: fsync: %s\n", strerror(errno));
	close(fd);
	printf("done: wrote and verified 0x%lx bytes\n", (unsigned long)aligned);
	return 0;
}

int main(int argc, char **argv)
{
	struct img im;
	memset(&im, 0, sizeof(im));

	if (argc == 3 && strcmp(argv[1], "--check") == 0)
		return load_and_validate(argv[2], &im);

	if (argc == 4 && strcmp(argv[1], "--write") == 0) {
		if (load_and_validate(argv[3], &im) != 0) {
			fprintf(stderr, "refusing to write — nothing has been erased\n");
			return 1;
		}
		return do_write(argv[2], &im);
	}

	fprintf(stderr,
	        "usage: mr1500x-fwupd --check <image-r6cr.bin>\n"
	        "       mr1500x-fwupd --write <mtd-char-dev> <image-r6cr.bin>\n");
	return 2;
}
