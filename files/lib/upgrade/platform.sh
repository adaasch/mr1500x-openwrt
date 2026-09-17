#
# MR1500X / MR60Xv2 (RTL8197F) — sysupgrade platform support.
#
# This REPLACES the ramips/mt7621 platform.sh that ships in the userspace we
# repackage. That one is actively dangerous here: it sets PART_NAME=firmware
# (no such partition on this board), calls fw_printenv (no U-Boot env access),
# and its board table falls through to default_do_upgrade, which uses stock
# `mtd write` — and stock mtd erases the WHOLE named partition. mtd2 "rootfs"
# spans flash 0x400000..0xff0000, so that would erase the persistent overlay at
# 0xa00000 AND the factory tail at 0xfa0000 (MAC, product-info, radio
# calibration — unrecoverable).
#
# HOW UPGRADES WORK HERE
#
#   The flashable file is the r6cr container the build produces
#   (`<name>-root-r6cr.bin`). Its payload is ALREADY SEALED for the U-Boot boot
#   gate by uboot_fs_seal.py, so an upgrade must not re-derive the seal — it
#   verifies it, before erasing anything. An unsealed rootfs boots to TFTP
#   rescue, and this board has no UART, so that check is the whole ballgame.
#   All of it lives in /sbin/mr1500x-fwupd (src/mr1500x-fwupd.c in the build
#   kit), which
#   also refuses any payload that would reach past the rootfs budget.
#
#   CONFIG IS PRESERVED BY DOING NOTHING. Unlike a stock squashfs target, the
#   overlay here is its own bounded MTD partition ("rootfs_data", flash
#   0xa00000..0xfa0000) which the rootfs write never touches. So there is no
#   CONF_TAR dance and no `mtd -j`: settings survive because the partition
#   holding them is not part of the upgrade. The flip side is the usual
#   overlayfs caveat — a config file kept in the overlay keeps shadowing the
#   new /rom version, so image defaults that change between versions do not
#   take effect until that file is removed from /overlay/upper.
#
#   `sysupgrade -n` is honoured by erasing rootfs_data after a successful
#   write. That is safe precisely because it is a real partition with a hard
#   end — `mtd erase` cannot run off into the factory tail. Note that the flag
#   does NOT arrive here as $SAVE_CONFIG; see platform_do_upgrade().
#
# Recovery if an upgrade ever does go wrong: TFTP rescue + tftp_push.py,
# exactly as for a first install. See the README in the build kit.

# Our images carry no fwtool metadata trailer; the checks below are stronger
# (they verify the actual boot gate rather than a JSON blob), so do not let
# sysupgrade refuse the image for lacking one.
REQUIRE_IMAGE_METADATA=0

# stage2 runs from a ramfs after the rootfs is unmounted, so the writer has to
# be copied in. It is static, so nothing else needs to come with it.
RAMFS_COPY_BIN='/sbin/mr1500x-fwupd'

FWUPD=/sbin/mr1500x-fwupd

# The vendor's product-info record, at flash 0xfa0400 = mtd2 offset 0xba0400.
# Read-only, inside the factory tail that nothing here ever writes, and the only
# place on this board that states what the hardware actually is.
PRODUCT_OFF=$((0xba0400))
# The models the vendor's own SupportList (flash 0xfe0900) names for this image.
#
# These warn rather than refuse, because "same board" here is not an inference:
# Mercusys publishes the MR1500X v2, MR60X v2 and MR62X v1 firmware as three
# differently-named zips containing one byte-identical upgrade image
# (sha256 511897d3…), built in a tree its own binaries call "MR60Xv2". Refusing
# a board the vendor treats as this board would be theatre.
#
# MR1500X v2 is still the only one it has been RUN on, hence the notices below.
KNOWN_PRODUCTS="MR1500X MR60X MR62X"
# Hardware revisions covered by that firmware. A board outside this set is a
# later revision of the same design — today that means the v2.20 refresh, which
# the vendor serves a separate firmware for, with two of the 39 RF calibration
# files changed (5 GHz TXPWR_ByRate, ther.conf). Still the same kernel, vermagic
# and flash layout, so this is a louder warning and not a refusal.
KNOWN_HW_VERS="1.0.0 2.0.0 3.0.0"

# Is the hardware underneath us the hardware this image is for?
#
# The image checks below say "this file is a well-formed MR1500X image". They
# say nothing about the board, and a well-formed image written to the wrong
# board is exactly the outcome worth preventing. There is no equivalent check on
# the TFTP recovery path — the bootcode announces no model and its RRQ reads
# back RAM rather than flash — so this is the one place a positive
# identification is possible, and it costs one dd.
platform_identify_device() {
	local mtdnum info name ver known_ver

	mtdnum="$(find_mtd_index rootfs)"
	[ -n "$mtdnum" ] || {
		echo "mr1500x: no MTD partition named \"rootfs\" — this is not the" \
		     "expected flash layout" >&2
		return 1
	}
	info=$(dd if="/dev/mtd$mtdnum" bs=1 skip="$PRODUCT_OFF" count=256 \
	       2>/dev/null | tr -d '\000')
	case "$info" in
		*vendor_name:Mercusys*) ;;
		*)
			echo "mr1500x: no Mercusys product-info record at flash" \
			     "0xfa0400. Either this is not a Mercusys board or its" \
			     "factory data is damaged; in both cases writing a" \
			     "firmware for a different device is the likely next" \
			     "event. Refusing. (sysupgrade -F overrides.)" >&2
			return 1
			;;
	esac
	name=$(echo "$info" | sed -n 's/^product_name:\([A-Za-z0-9_-]*\).*/\1/p' \
	       | head -1)
	case " $KNOWN_PRODUCTS " in
		*" $name "*) ;;
		*)
			echo "mr1500x: this board reports product_name:${name:-<none>}," \
			     "which is not one this image is built for" \
			     "($KNOWN_PRODUCTS). Refusing. (sysupgrade -F overrides.)" >&2
			return 1
			;;
	esac
	[ "$name" = MR1500X ] || echo "mr1500x: board reports $name; this image" \
		"has only been run on MR1500X v2. The vendor ships one byte-identical" \
		"firmware for both, so this should be the same hardware — but you are" \
		"the first. Keep your stock firmware zip." >&2

	# Same record, one field further down: which revision of that board.
	# The empty case is spelled out rather than folded into the glob: an
	# unset $ver inside the pattern would be matched, not compared.
	ver=$(echo "$info" | sed -n 's/^product_ver:\([0-9.]*\).*/\1/p' | head -1)
	known_ver=
	if [ -n "$ver" ]; then
		case " $KNOWN_HW_VERS " in
			*" $ver "*) known_ver=y ;;
		esac
	fi
	case "$known_ver" in
		y) ;;
		*)
			echo "mr1500x: board reports hardware revision ${ver:-<none>}," \
			     "which is not one this image has run on ($KNOWN_HW_VERS)." \
			     "Later revisions of this design exist — the v2.20 refresh" \
			     "— and the vendor gives them their own firmware, with" \
			     "different 5 GHz power tables. Continuing; TFTP rescue is" \
			     "unaffected, but be ready to roll back." >&2
			;;
	esac
	return 0
}

platform_check_image() {
	[ -x "$FWUPD" ] || {
		echo "mr1500x: $FWUPD missing — refusing to flash an unverified image" >&2
		return 1
	}
	# Exit status is the verdict: signature, burn address, container length and
	# checksum, squashfs magic, the U-Boot boot gate, and the rootfs budget.
	"$FWUPD" --check "$1" || {
		echo "mr1500x: this file is not a flashable MR1500X image" >&2
		return 1
	}
	platform_identify_device || return 1
	return 0
}

platform_do_upgrade() {
	local mtdnum

	mtdnum="$(find_mtd_index rootfs)"
	[ -n "$mtdnum" ] || {
		echo "mr1500x: no MTD partition named \"rootfs\" — aborting" >&2
		return 1
	}

	"$FWUPD" --write "/dev/mtd$mtdnum" "$1" || {
		echo "mr1500x: write failed — DO NOT REBOOT; reflash over TFTP rescue" >&2
		return 1
	}

	# -n: drop the persistent config. Bounded partition, so this cannot reach
	# the factory tail; on the next boot mount_root formats it fresh.
	#
	# $SAVE_CONFIG IS NOT VISIBLE HERE, and testing it — which is what this
	# function did until the first bench upgrade of a published image caught
	# it — silently keeps the config every time. /sbin/sysupgrade exports
	# SAVE_CONFIG, but stage 2 does not inherit that environment: sysupgrade
	# hands off through `ubus call system sysupgrade`, procd execs
	# /sbin/upgraded, and upgraded execs /lib/upgrade/stage2 with the image and
	# the command in argv. The only thing procd carries across is
	# UPGRADE_BACKUP, and it sets that only when sysupgrade passed a "backup"
	# path — which it does only when SAVE_CONFIG=1. So an empty UPGRADE_BACKUP
	# is the signal, and it is the same one do_stage2 uses to decide whether to
	# call platform_copy_config.
	#
	# The second test covers failsafe mode, which reaches upgraded by a
	# different route (/tmp/sysupgrade + the failsafe lock) and never sets
	# UPGRADE_BACKUP at all. There the config tarball itself is the evidence:
	# sysupgrade writes it when asked to keep config and deletes it when given
	# -n. Absent both, erasing is what was asked for.
	local conf_tar="${UPGRADE_BACKUP:-/tmp/sysupgrade.tgz}"
	if [ ! -f "$conf_tar" ]; then
		local datanum
		datanum="$(find_mtd_index rootfs_data)"
		if [ -n "$datanum" ]; then
			echo "mr1500x: -n given, erasing rootfs_data (mtd$datanum)"
			mtd erase rootfs_data || echo "mr1500x: rootfs_data erase failed; config kept" >&2
		else
			echo "mr1500x: no rootfs_data partition; nothing to erase" >&2
		fi
	fi

	return 0
}

# Nothing to do: the config never left the overlay, which is a separate
# partition and was not part of the write.
platform_copy_config() {
	return 0
}
