#!/bin/sh
# MR1500X — factory MAC address derivation.
#
# WHY THIS IS A SHARED LIB AND NOT A CONSTANT IN /etc/config
#
# The Wi-Fi netdevs come up at 00:00:00:00:00:00 / 0a:.. / 0e:.. because nothing
# in the vendor kernel reads the factory data, so someone has to set them. The
# obvious shortcut — a literal `option macaddr` in /etc/config/mr1500x-wifi —
# works on exactly ONE unit: the one the value was read from. In a published
# image it puts the build machine's radio MACs on every device that flashes it
# (duplicate MACs on the air, and a `nas_identifier` that is no longer unique
# per AP). It also leaks the build unit's address to everyone who downloads it.
#
# So: derive at runtime, from this unit's own factory tail. An explicit
# `option macaddr` still wins, for anyone who needs to override.
#
# WHERE THE MAC LIVES
#   flash 0xfa0000 = mtd2 offset 0xba0000    (mtd2 "rootfs" starts at 0x400000)
#   layout: u32 BE length (=6) | 4 zero bytes | 6 MAC bytes | 0xff padding
#   so the MAC itself is at mtd2 offset 0xba0008.
# READ ONLY. Writing anywhere near 0xba0000 destroys the MAC, product-info and
# the radio calibration, none of which can be recovered (see mtdregion.c).
#
# DERIVATION (observed on the stock firmware, verified against this unit)
#   eth0 / br-lan = base
#   eth1 / WAN    = base + 1
#   wlan0         = base - 1
#   wlan1         = base with the locally-administered bit set
#
# /etc/init.d/vendor-mac caches the results in /var/run/factory_mac* at S25;
# mr1500x_wifi_mac() prefers that cache and falls back to reading mtd2 itself,
# so it is also correct when called from a shell before vendor-mac has run.

MR1500X_MAC_MTD=/dev/mtd2
MR1500X_MAC_OFF=$((0xba0008))

mr1500x_read_factory_mac() {
	dd if="$MR1500X_MAC_MTD" bs=1 skip="$MR1500X_MAC_OFF" count=6 2>/dev/null | \
		hexdump -v -e '5/1 "%02x:" 1/1 "%02x"' 2>/dev/null
}

# usable_mac <mac> — reject the empty/blank/broadcast readings
mr1500x_mac_usable() {
	case "$1" in
		"" | "00:00:00:00:00:00" | "ff:ff:ff:ff:ff:ff") return 1 ;;
	esac
	return 0
}

# add $2 to the last octet of MAC $1 (handles the small offsets we need)
mr1500x_mac_offset() {
	local mac="$1" delta="$2" head tail newtail
	head="${mac%:*}"
	tail="${mac##*:}"
	newtail=$(printf '%02x' $(( (0x$tail + delta) & 0xff )))
	echo "$head:$newtail"
}

# set the locally-administered bit in the first octet
mr1500x_mac_local() {
	local mac="$1" first rest
	first="${mac%%:*}"
	rest="${mac#*:}"
	printf '%02x:%s\n' $(( 0x$first | 0x02 )) "$rest"
}

# mr1500x_wifi_mac <ifname> -> the address that netdev should carry, or nothing
# if this unit has no readable factory MAC (callers must treat empty as "leave
# the interface alone" — a wrong MAC is worse than the driver's default).
mr1500x_wifi_mac() {
	local ifname="$1" cached base

	cached=$(cat "/var/run/factory_mac_$ifname" 2>/dev/null)
	mr1500x_mac_usable "$cached" && { echo "$cached"; return 0; }

	base=$(mr1500x_read_factory_mac)
	mr1500x_mac_usable "$base" || return 1

	case "$ifname" in
		wlan0) mr1500x_mac_offset "$base" -1 ;;
		wlan1) mr1500x_mac_local  "$base"    ;;
		*)     return 1 ;;
	esac
}
