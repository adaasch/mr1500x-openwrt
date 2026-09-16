#!/bin/sh
# MR1500X / MR60Xv2 — netifd wireless driver: REPORTING ONLY.
#
# *** THIS FILE REPLACES UPSTREAM'S mac80211.sh ON PURPOSE. ***
# It is NOT the OpenWrt mac80211 driver. It deliberately occupies that name.
#
# WHY IT IS CALLED mac80211
#   The radios here cannot be driven by netifd: upstream's mac80211.sh calls
#   `iw phy <phy> interface add`, which HANGS this driver — the box stays
#   pingable, every service dies, and only a POWER CYCLE clears it (a reboot
#   does not). They are driven instead by /etc/init.d/mr1500x-wifi.
#
#   But LuCI keys its entire wireless UI off the radio's `type`. In
#   /www/luci-static/resources/view/network/wireless.js:
#       hwtype = uci.get('wireless', <radio>, 'type')
#       if (hwtype == 'mac80211') { ...the whole crypto_modes list...     }
#       if (hwtype == 'mac80211') { ...channel / htmode / country...      }
#       if (hwtype == 'broadcom') { ...legacy...                          }
#   Any other value matches NEITHER branch, so the encryption dropdown, the
#   passphrase field and the channel selector are simply never built. A driver
#   named anything else gives you a wireless page you cannot set a password on.
#
#   So we take the name and make it safe: this script implements the netifd
#   driver API, reports the already-running netdevs, and touches nothing. The
#   dangerous upstream file is not shipped at all — replacing it is strictly
#   safer than leaving it in place next to a differently-named driver, because
#   then nothing on the box can perform the call that wedges the hardware.
#
# WHAT IT DOES
#   setup() reports which of the pre-created netdevs are up, via
#   wireless_add_vif, so `ubus call network.wireless status` is populated and
#   LuCI can render live state. It never calls `iw`, never creates or destroys
#   an interface, and never starts or stops hostapd/wpa_supplicant.
#   teardown() is empty.
#
#   Consequences, all deliberate:
#     - A vif is reported only when its netdev is IFF_UP, so a radio that failed
#       to come up — or an uplink not configured on this unit — shows as absent
#       instead of as a phantom.
#     - The vifs carry NO `option network`, so netifd never attaches or detaches
#       them from br-lan or wwan. Bridging stays hostapd's job and the uplink
#       stays mr1500x-wwan's. That is what makes a LuCI "Save & Apply" or
#       "Disable" harmless here.
#     - Config changes made in LuCI are applied by /etc/init.d/mr1500x-wifi
#       reload (see WIFI.md §9), NOT by this script.
#
#   netifd runs _wdev_prepare_channel() before drv_*_setup, but that function is
#   pure shell/json (channel/band/hwmode normalisation) and touches no driver.

. /lib/netifd/netifd-wireless.sh

init_wireless_driver "$@"

drv_mac80211_init_device_config() {
	config_add_string phy path country
	config_add_boolean disabled
}

drv_mac80211_init_iface_config() {
	config_add_string ifname
}

drv_mac80211_init_vlan_config() {
	return 0
}

drv_mac80211_init_station_config() {
	return 0
}

drv_mac80211_cleanup() {
	return 0
}

# A netdev counts as live only if it exists and carries IFF_UP (0x1). Reading
# the flags word is cheaper and more reliable here than operstate, which these
# vendor drivers leave at "unknown".
mr1500x_iface_is_up() {
	local flags

	[ -e "/sys/class/net/$1/flags" ] || return 1
	read flags < "/sys/class/net/$1/flags" 2>/dev/null || return 1
	[ $(((flags) & 1)) -eq 1 ]
}

mr1500x_report_vif() {
	local name="$1"
	local ifname

	# for_each_interface leaves the json cursor on the interface object, not
	# on its config.
	json_select config
	json_get_vars ifname
	json_select ..

	[ -n "$ifname" ] || return 0
	mr1500x_iface_is_up "$ifname" || return 0

	wireless_add_vif "$name" "$ifname"
}

drv_mac80211_setup() {
	for_each_interface "ap sta" mr1500x_report_vif

	# Always mark the radio up: the hardware is running under mr1500x-wifi
	# whatever netifd believes, and reporting a failure would only make netifd
	# retry a setup that has no work to do. Truth about individual interfaces
	# is carried by which vifs got reported above.
	wireless_set_up
}

drv_mac80211_teardown() {
	# Deliberately empty — see the header. Anything torn down here would need a
	# power cycle to put back.
	return 0
}

add_driver mac80211
