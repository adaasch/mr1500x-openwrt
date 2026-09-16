#!/bin/bash
#
# build_image.sh — build mr1500x-root-r6cr.bin from source.
#
# WHAT THIS PRODUCES
#   A rootfs-only image for the Mercusys MR1500X v2 (and its MR60X v2/v3 /
#   MR62X siblings): OpenWrt 21.02.7 userspace running on the device's OWN
#   vendor kernel (Linux 4.4.176), wrapped in the `r6cr` container the vendor
#   bootloader burns to flash 0x400000.
#
#   It writes ONLY the rootfs region. The bootloader, the stock kernel and the
#   factory tail at 0xfa0000 (MAC, WPS pin, radio calibration — none of it
#   recoverable) are never touched by the image this builds.
#
# WHAT IT BUILDS FROM SOURCE
#   Everything executable. The OpenWrt userspace and its toolchain, the patched
#   hostapd/wpad, our three kernel modules (with the VENDOR toolchain, which is
#   inside the GPL drop), and our two small C tools. No binary in the output
#   came from this repository.
#
#   The one exception is not executable: 39 RF calibration tables. The 5 GHz
#   RTL8832BR is an eFEM design whose radio register tables are read from the
#   filesystem at init, they cannot be compiled, and the copies in the GPL drop
#   are an older revision that would be a regulatory regression. They are
#   extracted from the official Mercusys firmware YOU download — see --firmware.
#
# USAGE
#   ./build_image.sh
#
#   That is the whole command. From an empty directory it downloads everything
#   it needs — OpenWrt at a pinned commit, the package feeds at pinned
#   revisions, the Mercusys GPL drop (which carries the kernel source AND the
#   vendor toolchain), and the official firmware it takes the RF tables from.
#   Every download is sha256-pinned and cached.
#
#   --workdir DIR     build here (default ./build-mr1500x). NOT mktemp: the
#                     path ends up inside the binaries, and a random one makes
#                     two builds differ. Determinism is a stated goal.
#   --cache DIR       keep downloads here (default <workdir>/downloads), so a
#                     fresh build does not re-fetch half a gigabyte
#   --gpl FILE        use a local GPL drop instead of downloading
#   --firmware FILE   use a local firmware .zip or .bin instead of downloading
#   --jobs N          parallelism (default: nproc)
#   --keep            keep the work tree on success
#   --check-deps      check host dependencies and exit
#   --selftest        run the packaging self-checks and exit
#
# REQUIREMENTS
#   x86-64 Linux, ~15 GB disk, and the usual build packages. Run
#   `./build_image.sh --check-deps` — it lists anything missing and prints the
#   exact install command for your distribution. One requirement is easy to
#   miss: the vendor MSDK toolchain that builds the kernel modules is a 32-bit
#   i386 binary, so a 64-bit host needs the 32-bit loader (libc6:i386).
#   Do not run as root: the OpenWrt build refuses.
#
set -euo pipefail

SELF=$(cd "$(dirname "$0")" && pwd)
JOBS=$(nproc 2>/dev/null || echo 4)
WORK=$PWD/build-mr1500x
CACHE=""
GPL=""; FIRMWARE=""; KEEP=0; SELFTEST=0; DEPS_ONLY=0

# ---------------------------------------------------------------- pins ------
# OpenWrt is taken from git at a pinned COMMIT, not from a release tarball:
# there is no source tarball under downloads.openwrt.org/releases/21.02.7/, and
# GitHub's generated tag archives are not byte-stable over time. A commit hash
# is content-addressed, so this pin cannot rot.
OW_REPO=https://github.com/openwrt/openwrt.git
OW_TAG=v21.02.7
OW_COMMIT=57a6d97ddf8f6541a52e0f8fad8c6f47685a1bc3
# The Mercusys GPL drop: kernel source, kernel config, the gpio-button-hotplug
# package, and the MSDK toolchain. Linked from
# https://www.mercusys.com/en/support/gpl-code/?model=MR60X — the MR60X v2 and
# the MR1500X v2 are the same image family and share one GPL drop.
GPL_URL=https://static.mercusys.com/gpl/MR60Xv2_GPLcode20241202093448.tar.gz
GPL_SHA=97e707d33f1cab78e8dd4056f8be650bfdb7471262bc33549902afb10b235b04

# The official firmware, for its RF calibration tables only — see the note on
# the RF tables at the top of this file. Listed on https://www.mercusys.com/en/download/mr1500x/v2/ —
# this is the 1.1.3 build the image was validated against. A newer firmware may
# carry newer tables; that is a deliberate decision, not a default, so the
# version is pinned and --firmware takes a local file if you want another.
FW_URL=https://static.mercusys.com/software/MR1500X_V2_1.1.3_Build_2025061020250902063658.zip
FW_SHA=b7b2fe9dc738929313f05bb41e2e347557f168d44833e54a193770e195a64d7c
# The vendor toolchain inside it, and the kernel tree it must build.
MSDK_TAR=sdk/toolchain/msdk-6.4.1-mips-EL-4.4-u0.9.33-m32ut-190619.tar.bz2
KERNEL_SRC=sdk/openwrt-21.02/target/linux
# Hard limits from the flash layout. The rootfs must stop before the overlay
# partition, which must stop before the factory tail. See MODULES.md.
ROOTFS_BUDGET=$((0x600000))
# Deterministic timestamps.
export SOURCE_DATE_EPOCH=1700000000

say()  { printf '\n== %s\n' "$*"; }
step() { printf '   %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --gpl)      GPL=$(readlink -f "$2"); shift 2 ;;
        --firmware) FIRMWARE=$(readlink -f "$2"); shift 2 ;;
        --workdir)  WORK=$(readlink -f "$2"); shift 2 ;;
        --cache)    CACHE=$(readlink -f "$2"); shift 2 ;;
        --jobs)     JOBS=$2; shift 2 ;;
        --keep)     KEEP=1; shift ;;
        --selftest) SELFTEST=1; shift ;;
        --check-deps) DEPS_ONLY=1; shift ;;
        -h|--help)  sed -n '2,50p' "$0"; exit 0 ;;
        *)          die "unknown argument: $1" ;;
    esac
done

# ------------------------------------------------------------- selftest -----
if [ "$SELFTEST" = 1 ]; then
    say "selftest: seal + container round trip on a synthetic fixture"
    T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
    head -c 200000 /dev/urandom > "$T/fake.bin"
    printf 'hsqs' | dd of="$T/fake.bin" conv=notrunc status=none
    python3 "$SELF/tools/uboot_fs_seal.py" seal "$T/fake.bin" "$T/sealed.bin"
    python3 "$SELF/tools/uboot_fs_seal.py" verify "$T/sealed.bin"
    python3 "$SELF/tools/mk_cvimg.py" root "$T/sealed.bin" "$T/out.bin"
    python3 - "$T/out.bin" <<'PY'
import struct, sys
def sum16(b):
    s=0
    for i in range(0,(len(b)//2)*2,2): s=(s+((b[i]<<8)|b[i+1]))&0xffff
    if len(b)%2: s=(s+(b[-1]<<8))&0xffff
    return s
d=open(sys.argv[1],'rb').read()
sig,_,burn,ln=struct.unpack('>4sIII', d[:16])
assert sig==b'r6cr' and burn==0x400000, (sig,hex(burn))
assert ln%2==0, "container length must be even or the burn loop overruns"
assert sum16(d[16:16+ln])==0, "container checksum"
fs=d[16:16+ln-2]
glen=int.from_bytes(fs[8:12],'big')+642
assert sum16(fs[:glen])==0, "boot gate"
print("   container + gate: PASS")
PY
    say "selftest OK"; exit 0
fi

[ "$(id -u)" != 0 ] || die "do not build as root — the OpenWrt build refuses"

# ------------------------------------------------------------ host check ----
# Everything needed to go from an empty directory to a flashable image on a
# stock x86-64 Linux install. Checked UP FRONT and reported all at once, with
# the exact install command: finding out about a missing flex ninety minutes
# into a toolchain build is a poor use of an afternoon.
#
# Each entry is  <test>|<what to test>|<debian pkg>|<fedora pkg>|<arch pkg>
# test: cmd = on $PATH · hdr = header file exists · lib32 = 32-bit loader
DEPS="
cmd|gcc|build-essential|gcc|base-devel
cmd|g++|build-essential|gcc-c++|base-devel
cmd|make|build-essential|make|base-devel
cmd|git|git|git|git
cmd|python3|python3|python3|python
cmd|curl|curl|curl|curl
cmd|unzip|unzip|unzip|unzip
cmd|rsync|rsync|rsync|rsync
cmd|xz|xz-utils|xz|xz
cmd|bc|bc|bc|bc
cmd|gawk|gawk|gawk|gawk
cmd|flex|flex|flex|flex
cmd|bison|bison|bison|bison
cmd|patch|patch|patch|patch
cmd|file|file|file|file
cmd|perl|perl|perl|perl
cmd|msgfmt|gettext|gettext|gettext
cmd|sha256sum|coreutils|coreutils|coreutils
hdr|zlib.h|zlib1g-dev|zlib-devel|zlib
hdr|openssl/ssl.h|libssl-dev|openssl-devel|openssl
hdr|ncurses.h|libncurses-dev|ncurses-devel|ncurses
lib32|/lib/ld-linux.so.2|libc6:i386|glibc.i686|lib32-glibc
"

check_deps() {
    local missing_deb="" missing_rpm="" missing_arch="" missing_human="" line
    local kind what deb rpm arch ok
    local IFS_SAVE=$IFS
    while IFS='|' read -r kind what deb rpm arch; do
        [ -n "${kind:-}" ] || continue
        ok=1
        case "$kind" in
            cmd)   command -v "$what" >/dev/null 2>&1 || ok=0 ;;
            hdr)   ok=0
                   for d in /usr/include /usr/local/include /usr/include/x86_64-linux-gnu; do
                       [ -e "$d/$what" ] && { ok=1; break; }
                   done ;;
            lib32) { [ -e /lib/ld-linux.so.2 ] || [ -e /lib32/ld-linux.so.2 ]; } || ok=0 ;;
        esac
        [ "$ok" = 1 ] && continue
        missing_human="$missing_human $what"
        case " $missing_deb "  in *" $deb "*)  ;; *) missing_deb="$missing_deb $deb"   ;; esac
        case " $missing_rpm "  in *" $rpm "*)  ;; *) missing_rpm="$missing_rpm $rpm"   ;; esac
        case " $missing_arch " in *" $arch "*) ;; *) missing_arch="$missing_arch $arch" ;; esac
    done <<EOF
$DEPS
EOF
    IFS=$IFS_SAVE
    [ -n "$missing_human" ] || return 0

    local id="" like=""
    [ -r /etc/os-release ] && . /etc/os-release && id="${ID:-}" && like="${ID_LIKE:-}"
    printf '\nERROR: this host is missing build dependencies:\n  %s\n\n' \
           "$(echo "$missing_human" | tr -s ' ')" >&2
    case "$id $like" in
        *debian*|*ubuntu*)
            echo "Install them with:" >&2
            case "$missing_deb" in
                *i386*) echo "    sudo dpkg --add-architecture i386 && sudo apt-get update" >&2 ;;
            esac
            echo "    sudo apt-get install -y$missing_deb" >&2 ;;
        *fedora*|*rhel*|*centos*)
            echo "Install them with:" >&2
            echo "    sudo dnf install -y$missing_rpm" >&2 ;;
        *arch*)
            echo "Install them with:" >&2
            echo "    sudo pacman -S --needed$missing_arch" >&2 ;;
        *)
            echo "On Debian/Ubuntu:  sudo apt-get install -y$missing_deb" >&2
            echo "On Fedora/RHEL:    sudo dnf install -y$missing_rpm" >&2
            echo "On Arch:           sudo pacman -S --needed$missing_arch" >&2 ;;
    esac
    case "$missing_human" in
        *ld-linux.so.2*)
            echo >&2
            echo "The 32-bit loader is not optional here: the vendor MSDK toolchain that" >&2
            echo "builds the three kernel modules is an i386 binary, and it is the only" >&2
            echo "compiler known to produce modules this kernel will load." >&2 ;;
    esac
    exit 1
}

say "0. host check"
check_deps
avail=$(df -Pk "$(dirname "$WORK")" | awk 'NR==2{print int($4/1024/1024)}')
[ "${avail:-0}" -ge 15 ] || die \
"need about 15 GB free under $(dirname "$WORK"), found ${avail}G.
   Most of it is the OpenWrt toolchain; --workdir moves the build elsewhere."
step "all build dependencies present, 32-bit loader present"
step "${avail}G free, $JOBS parallel jobs"
[ "$DEPS_ONLY" = 1 ] && { say "dependency check only — nothing built"; exit 0; }

mkdir -p "$WORK"
OW=$WORK/openwrt
GPLDIR=$WORK/gpl
MSDK=$WORK/msdk
OVB=$WORK/ovbuild
OUT=$WORK/out
[ -n "$CACHE" ] || CACHE=$WORK/downloads
mkdir -p "$OUT" "$CACHE"

# fetch <url> <sha256> <dest> <what it is>
# Resumable, verified, and cached: the GPL drop is half a gigabyte and nobody
# should pay for it twice. A file that is present but wrong is moved aside
# rather than deleted — if the vendor has republished something, that file is
# evidence, and silently re-downloading over it would destroy it.
fetch() {
    local url="$1" want="$2" dest="$3" what="$4" have=""
    if [ -f "$dest" ]; then
        have=$(sha256sum "$dest" | cut -d' ' -f1)
        if [ "$have" = "$want" ]; then
            step "$what: cached, sha256 OK"
            return 0
        fi
        mv -f "$dest" "$dest.unexpected"
        step "$what: cached copy had the wrong sha256, moved to $(basename "$dest").unexpected"
    fi
    step "$what: downloading $(basename "$url")"
    # --progress-bar is for a human watching a terminal; into a log file it is
    # thousands of carriage returns. -sS keeps errors, drops the meter.
    local quiet=--progress-bar
    [ -t 1 ] || quiet=-sS
    curl -fL --retry 3 --retry-delay 2 -C - "$quiet" -o "$dest.part" "$url" \
        || die "download failed: $url
   If the vendor has moved it, pass a local copy instead (--gpl / --firmware)."
    mv -f "$dest.part" "$dest"
    have=$(sha256sum "$dest" | cut -d' ' -f1)
    [ "$have" = "$want" ] || die \
"$what sha256 mismatch
   expected $want
   got      $have
   url      $url
   The vendor has republished this file. That may be routine, but it is not
   something to build through silently: the kernel source or the RF tables may
   differ from the ones this image was validated against. Check what changed,
   then update the pin in this script deliberately."
    step "$what: sha256 OK"
}

say "1. inputs"
# Both are public vendor downloads. --gpl / --firmware override with a local
# file (any sha256), for offline builds or for trying a different firmware.
if [ -n "$GPL" ]; then
    [ -f "$GPL" ] || die "no such file: $GPL"
    step "gpl drop: using local $GPL (pin not enforced)"
else
    GPL=$CACHE/$(basename "$GPL_URL")
    fetch "$GPL_URL" "$GPL_SHA" "$GPL" "gpl drop"
fi

if [ -n "$FIRMWARE" ]; then
    [ -f "$FIRMWARE" ] || die "no such file: $FIRMWARE"
    step "firmware: using local $FIRMWARE (pin not enforced)"
else
    FIRMWARE=$CACHE/$(basename "$FW_URL")
    fetch "$FW_URL" "$FW_SHA" "$FIRMWARE" "firmware"
fi

# The vendor ships firmware as a zip (upgrade .bin + two PDFs). Accept either.
case "$FIRMWARE" in
    *.zip)
        rm -rf "$WORK/fwzip"; mkdir -p "$WORK/fwzip"
        unzip -q -o -j "$FIRMWARE" '*.bin' -d "$WORK/fwzip" \
            || die "no .bin inside $FIRMWARE"
        FIRMWARE=$(find "$WORK/fwzip" -maxdepth 1 -name '*.bin' | head -1)
        [ -n "$FIRMWARE" ] || die "no .bin inside the firmware zip"
        step "firmware: unpacked $(basename "$FIRMWARE")"
        ;;
esac
python3 "$SELF/tools/extract_stock_rootfs.py" list "$FIRMWARE" >/dev/null \
    || die "that firmware file is not an official Mercusys upgrade image"
step "firmware container parses"

say "2. OpenWrt $OW_TAG source"
if [ ! -d "$OW/.git" ]; then
    git clone -q --branch "$OW_TAG" "$OW_REPO" "$OW"
fi
got=$(git -C "$OW" rev-parse HEAD)
[ "$got" = "$OW_COMMIT" ] || die "OpenWrt checkout is $got, expected $OW_COMMIT"
step "commit $OW_COMMIT"

say "3. feeds (pinned) + config"
cp "$SELF/config/feeds.conf" "$OW/feeds.conf"
( cd "$OW"
  ./scripts/feeds update -a >/dev/null
  ./scripts/feeds install -a -p luci >/dev/null
  ./scripts/feeds install cgi-io liblucihttp liblucihttp-lua >/dev/null )
cp "$SELF/config/mr1500x.diffconfig" "$OW/.config"
make -C "$OW" defconfig >/dev/null
# `make defconfig` DROPS symbols it does not recognise, silently. If the feeds
# were not installed first, this is where the web UI quietly disappears.
for sym in CONFIG_PACKAGE_luci-base=y CONFIG_PACKAGE_wpad-basic-wolfssl=y \
           CONFIG_PACKAGE_wireless-tools=y CONFIG_PACKAGE_dropbear=y; do
    grep -q "^$sym" "$OW/.config" || die \
"$sym did not survive 'make defconfig' — the feeds were not installed, and the
   image would come out without it. Delete $OW and re-run."
done
# The reproducibility symbols, same treatment: defconfig resolves them against
# each other, so asserting the seed was written is not the same as asserting the
# result. ALL_NONSHARED in particular is what BUILDBOT would otherwise turn on,
# and it would pull in every target package.
for sym in CONFIG_BUILDBOT=y CONFIG_REPRODUCIBLE_DEBUG_INFO=y \
           '# CONFIG_ALL_NONSHARED is not set' '# CONFIG_ALL_KMODS is not set' \
           '# CONFIG_COLLECT_KERNEL_DEBUG is not set' \
           CONFIG_PACKAGE_kmod-mac80211=y CONFIG_PACKAGE_kmod-cfg80211=y; do
    grep -qx "$sym" "$OW/.config" || die \
"'$sym' did not survive 'make defconfig'. Two clean builds in different
   directories would not come out byte-identical. Delete $OW and re-run."
done
step "config seeded; luci/wpad/dropbear and the reproducibility symbols verified"

say "4. the hostapd association patch"
# WITHOUT THIS PATCH NO CLIENT CAN ASSOCIATE ON 2.4 GHz AT ALL.
# The vendor rtl8192cd is built with REPLY_ASSOC_BY_HAPD, so it never answers
# association requests itself — it waits for hostapd to hand the response back
# down. It also sets WIPHY_FLAG_HAVE_AP_SME, so hostapd takes the device-AP-SME
# path and assumes the device answers. Upstream driver_nl80211.c has no
# .sta_assoc op, so hostapd_sta_assoc() returns 0 having done nothing, and with
# WPA2 it looks like a dead 4-way handshake: M1 sent to a station that never
# associated.
cp "$SELF/patches/900-rtl8192cd-sta-assoc-reply.patch" \
   "$OW/package/network/services/hostapd/patches/"
step "patch staged"

say "5. build the userspace (this is the long one)"
make -C "$OW" -j"$JOBS" tools/compile toolchain/compile > "$WORK/toolchain.log" 2>&1 \
    || { tail -30 "$WORK/toolchain.log"; die "toolchain build failed (log: $WORK/toolchain.log)"; }
# Do not take "exit 0" for an answer. A clean build here has come back
# successful, with .toolchain_compile stamped, and no bin/ directory under
# staging_dir at all — the whole cross compiler silently missing. Left alone it
# surfaces ten minutes later as "target/linux failed to build", whose real
# message is buried: "compiler 'mipsel-openwrt-linux-musl-gcc' not found". The
# stamp is the thing that lies, so the recovery is to remove it and let make do
# the work again.
toolchain_cc() { echo "$OW"/staging_dir/toolchain-*/bin/mipsel-openwrt-linux-musl-gcc; }
if [ ! -x "$(toolchain_cc)" ]; then
    step "toolchain/compile claimed success but installed no compiler; retrying once"
    rm -f "$OW"/staging_dir/toolchain-*/stamp/.toolchain_compile
    make -C "$OW" -j"$JOBS" toolchain/compile >> "$WORK/toolchain.log" 2>&1 || true
    [ -x "$(toolchain_cc)" ] || die \
"the toolchain still has no mipsel-openwrt-linux-musl-gcc after a retry
   (log: $WORK/toolchain.log). Nothing downstream can build. Delete $OW and
   start again; if it recurs, build with a smaller --jobs."
fi
step "toolchain built"
# One retry, and only for a single named package. Some upstream packages have
# parallel-make races — binutils' ld/ loses .deps/*.Po under -j often enough to
# fail roughly one clean build in two on a 24-core host — and a race is by
# definition not reproducible, so failing the whole run is the wrong response to
# it. The retry is deliberately narrow: it acts only on the package OpenWrt
# names in its own "ERROR: … failed to build" line, cleans that package first
# (a half-built tree fails the same way forever otherwise), and happens once.
# A second failure, or a failure with no package named, is a real build error
# and stops the build.
if ! make -C "$OW" -j"$JOBS" > "$WORK/userspace.log" 2>&1; then
    FAILED=$(sed -n 's/^[[:space:]]*ERROR: \(package\/[^ ]*\) failed to build\..*/\1/p' \
             "$WORK/userspace.log" | head -1)
    [ -n "$FAILED" ] || { tail -30 "$WORK/userspace.log"; die \
        "userspace build failed (log: $WORK/userspace.log)"; }
    step "$FAILED failed; cleaning it and retrying once"
    # A separate log for the retry, so the failure reported below is the one
    # that just happened. Appending to the first log and parsing it again reads
    # back the ORIGINAL failure and names the wrong package.
    make -C "$OW" "$FAILED/clean" > "$WORK/userspace-retry.log" 2>&1 || true
    make -C "$OW" -j"$JOBS" >> "$WORK/userspace-retry.log" 2>&1 || {
        AGAIN=$(sed -n 's/^[[:space:]]*ERROR: \(package\/[^ ]*\) failed to build\..*/\1/p' \
                "$WORK/userspace-retry.log" | head -1)
        tail -30 "$WORK/userspace-retry.log"
        die "the userspace build failed again, in ${AGAIN:-an unnamed package}
   (log: $WORK/userspace-retry.log; the first attempt is in userspace.log).
   If the two failures are in DIFFERENT packages and both look like a missing
   file rather than a compiler error, this is parallelism, not your source:
   several packages in this tree have make races that only bite on a loaded
   machine. Re-run with --jobs 8. A compiler crash or a corrupt archive would
   be a different story and would be worth memtesting the host over."
    }
    step "retry succeeded"
fi
SQIN=$OW/build_dir/target-mipsel_24kc_musl/linux-ramips_mt7621/root.squashfs
[ -f "$SQIN" ] || die "no root.squashfs at $SQIN"
step "rootfs: $(stat -c%s "$SQIN") bytes"

WPAD=$(ls "$OW"/bin/packages/mipsel_24kc/base/wpad-basic-wolfssl_*.ipk 2>/dev/null | head -1)
[ -n "$WPAD" ] || die "no wpad-basic-wolfssl package was built"
rm -rf "$WORK/.wpad"; mkdir -p "$WORK/.wpad"
( cd "$WORK/.wpad" && tar xzf "$WPAD" && tar xzf data.tar.gz ) >/dev/null 2>&1
grep -aq "nl80211: sta_assoc " "$WORK/.wpad/usr/sbin/wpad" || die \
"the built wpad does NOT carry 900-rtl8192cd-sta-assoc-reply.patch.
   Refusing to package an image whose Wi-Fi cannot associate a client."
# Ask the binary what it understands, not the config what we asked for.
# /etc/init.d/mr1500x-wifi writes ieee80211ac and vht_oper_chwidth for band a,
# and hostapd only parses them when it was built with CONFIG_IEEE80211AC —
# which is gated on @DRIVER_11AC_SUPPORT, which no symbol here sets directly:
# it comes in through whichever Wi-Fi driver packages are selected. Deselecting
# the MediaTek packages as dead weight therefore produced a wpad that rejected
# the 5 GHz config outright ("unknown configuration item 'ieee80211ac'") while
# 2.4 GHz came up fine and every config assertion passed. Checking the strings
# is the only test that actually tracks the capability.
# NB: `grep -x`, never `grep -qx`, downstream of a pipe. This script runs under
# `set -o pipefail`, and -q makes grep exit the moment it matches, which kills
# the upstream `strings` with SIGPIPE — so the pipeline reports failure on a
# SUCCESSFUL match. That cost an afternoon here: the assertion below fired
# against a wpad that did contain both strings. Without -q, grep drains its
# input and the exit status means what it looks like.
for opt in ieee80211ac vht_oper_chwidth; do
    strings -a "$WORK/.wpad/usr/sbin/wpad" | grep -x "$opt" >/dev/null || die \
"the built wpad does not understand '$opt', so 5 GHz cannot start.
   hostapd lost CONFIG_IEEE80211AC, which means @DRIVER_11AC_SUPPORT is off,
   which means the Wi-Fi driver packages that pull it in were deselected.
   See the MediaTek note in config/mr1500x.diffconfig.
   If you just changed the config in an EXISTING --workdir, the package may
   simply be stale — 'make -C $OW package/network/services/hostapd/clean'
   and re-run. A build in an empty directory cannot hit that."
done
step "wpad carries the sta_assoc patch and understands VHT"

say "6. unpack the GPL drop"
if [ ! -d "$GPLDIR/MR60Xv2_GPLcode" ]; then
    mkdir -p "$GPLDIR"
    tar -C "$GPLDIR" -xzf "$GPL"
fi
G=$GPLDIR/MR60Xv2_GPLcode
[ -d "$G/$KERNEL_SRC/linux-4.4" ] || die "no kernel tree at $KERNEL_SRC/linux-4.4"
if [ ! -d "$MSDK" ]; then
    mkdir -p "$MSDK"
    tar -C "$MSDK" -xjf "$G/$MSDK_TAR"
fi
# Resolve the extracted directory, THEN build the prefix. Globbing on the
# prefix itself ("$MSDK"/*/bin/mipsel-linux-uclibc-) matches nothing — it is a
# filename prefix, not a file — so the pattern survives literally and every
# later use fails with an unexpanded '*' in the path.
MSDKDIR=$(ls -d "$MSDK"/msdk-*/ 2>/dev/null | head -1)
[ -n "$MSDKDIR" ] || die "the MSDK toolchain did not extract into $MSDK"
CROSS=${MSDKDIR}bin/mipsel-linux-uclibc-
"${CROSS}gcc" --version >/dev/null 2>&1 || die \
"the vendor MSDK compiler will not run. It is an i386 binary; install the
   32-bit runtime (libc6:i386 zlib1g:i386) and try again."
step "vendor toolchain: $("${CROSS}gcc" --version | head -1)"

say "7. kernel modules against the vendor kernel"
# The BSP reaches out of the kernel tree with RELATIVE symlinks
# (arch/mips/bsp -> ../../../target/bsp), so linux-4.4 needs its siblings.
if [ ! -d "$OVB/linux-4.4" ]; then
    mkdir -p "$OVB"
    cp -a "$G/$KERNEL_SRC/linux-4.4" "$OVB/linux-4.4"
    cp -a "$G/$KERNEL_SRC/target"    "$OVB/target"
    cp -a "$G/$KERNEL_SRC/rtknet"    "$OVB/rtknet"
    cp "$G/build/kernel.config" "$OVB/linux-4.4/.config"
    # The vendor kernel ships overlayfs OFF; the overlay is what makes settings
    # survive a reboot here, so turn it on as a module.
    sed -i 's/^# CONFIG_OVERLAY_FS is not set$/CONFIG_OVERLAY_FS=m/' "$OVB/linux-4.4/.config"
    grep -q '^CONFIG_OVERLAY_FS=m' "$OVB/linux-4.4/.config" || die "could not enable overlayfs"
fi
KMAKE="make -C $OVB/linux-4.4 ARCH=mips CROSS_COMPILE=$CROSS"
$KMAKE olddefconfig    > "$WORK/kernel.log" 2>&1 || { tail -20 "$WORK/kernel.log"; die "olddefconfig"; }
$KMAKE -j"$JOBS" modules_prepare >> "$WORK/kernel.log" 2>&1 || { tail -20 "$WORK/kernel.log"; die "modules_prepare"; }
step "kernel headers prepared"

$KMAKE -j"$JOBS" SUBDIRS=fs/overlayfs modules >> "$WORK/kernel.log" 2>&1 || die "overlay.ko"
# Out-of-tree builds are done on a COPY. Kbuild writes .o/.ko/.cmd/.tmp_versions
# next to the source, and the kit must stay source-only — a stray prebuilt .ko
# in publish/modules/ is exactly the silent fallback D2 exists to prevent.
#
# The copy goes INSIDE the kernel tree and M= is given RELATIVE to it. That
# looks like a detail and is not: `M=` lands verbatim in the compiler command
# line, so an absolute M= puts the absolute path of this build directory into
# __FILE__ — and gpio-button-hotplug.c has a WARN(), which expands __FILE__
# into .rodata. The result is a .ko whose bytes depend on where it was built.
# It cannot be mapped away either: the vendor MSDK compiler is gcc 6.4.1 and
# -ffile-prefix-map arrived in gcc 8. A relative M= makes the recorded name
# "gpio-button-hotplug/gpio-button-hotplug.c" wherever the build runs.
KSRC=$OVB/linux-4.4
RDP=$KSRC/rootfs_data_part
rm -rf "$RDP"; mkdir -p "$RDP"
cp "$SELF/modules/rootfs_data_part.c" "$SELF/modules/Makefile" "$RDP/"
$KMAKE M=rootfs_data_part modules >> "$WORK/kernel.log" 2>&1 || die "rootfs_data_part.ko"
GBH=$KSRC/gpio-button-hotplug
rm -rf "$GBH"; mkdir -p "$GBH"
# From the GPL drop's own copy, which is the source the vendor's shipped module
# was built from — not OpenWrt 21.02's, which targets kernel 5.4.
cp "$G/openwrt/package/gpio-button-hotplug/src/"* "$GBH/"
$KMAKE M=gpio-button-hotplug modules >> "$WORK/kernel.log" 2>&1 || die "gpio-button-hotplug.ko"

KO_OVERLAY=$OVB/linux-4.4/fs/overlayfs/overlay.ko
KO_PART=$RDP/rootfs_data_part.ko
KO_BTN=$GBH/gpio-button-hotplug.ko
# CONFIG_MODVERSIONS is off on this kernel, so vermagic IS the compatibility
# contract. A module with the wrong string does not load, and on a box with no
# UART that means the overlay silently never mounts.
for ko in "$KO_OVERLAY" "$KO_PART" "$KO_BTN"; do
    [ -s "$ko" ] || die "module not built: $ko"
    strings "$ko" | grep -x "vermagic=4.4.176 mod_unload MIPS32_R2 32BIT " >/dev/null \
        || die "$(basename "$ko") has the wrong vermagic — it cannot load"
done
grep -aq "crosses the factory-data guard" "$KO_PART" \
    || die "rootfs_data_part.ko lost its factory guard — refusing to build"
step "overlay.ko, rootfs_data_part.ko, gpio-button-hotplug.ko — vermagic verified"

say "8. RF calibration tables from the official firmware"
python3 "$SELF/tools/extract_stock_rootfs.py" rootfs "$FIRMWARE" "$WORK/stock.sqfs" >/dev/null
UNSQ=$OW/staging_dir/host/bin/unsquashfs4
rm -rf "$WORK/stockfs"
"$UNSQ" -d "$WORK/stockfs" "$WORK/stock.sqfs" > "$WORK/unsq.log" 2>&1 \
    || die "could not unpack the official firmware rootfs"
[ -d "$WORK/stockfs/etc/conf/rtl8832bre/RFE50" ] \
    || die "no RF tables in the official firmware — wrong image for this device?"
step "$(find "$WORK/stockfs/etc/conf" -type f | wc -l) files"

say "9. assemble the rootfs"
TREE=$WORK/tree
rm -rf "$TREE"; mkdir -p "$TREE"
# unsquashfs runs unprivileged and cannot recreate device nodes; without
# /dev/console procd's askconsole fails and userspace never comes up. Capture
# the node list and re-declare it to mksquashfs with -pf, which needs no root.
"$UNSQ" -ll "$SQIN" 2>/dev/null | python3 -c '
import sys, re
out=[]
for ln in sys.stdin:
    if not ln or ln[0] not in "bc": continue
    m=re.match(r"([bc])(\S{9})\s+\S+\s+(\d+),\s*(\d+)\s+\S+\s+\S+\s+(\S+)", ln)
    if not m: continue
    typ,perm,maj,minor,path=m.groups()
    bits=0
    for i,ch in enumerate(perm):
        if ch!="-": bits|=(4,2,1)[i%3]<<(3*(2-i//3))
    path=re.sub(r"^squashfs-root","",path)
    if path: out.append("%s %s %o root root %s %s"%(path,typ,bits,maj,minor))
print("\n".join(out))' > "$WORK/devnodes.pf"
[ -s "$WORK/devnodes.pf" ] || die "no device nodes captured — /dev/console would be missing"
"$UNSQ" -f -d "$TREE" "$SQIN" >/dev/null 2>&1 || true
step "base rootfs unpacked, $(wc -l < "$WORK/devnodes.pf") device nodes captured"

# Kernel modules and firmware from the mt7621 target can never load on 4.4.176.
rm -rf "$TREE/lib/modules" "$TREE/etc/modules.d" "$TREE/lib/firmware"
# modules-boot.d is a directory of symlinks INTO modules.d, so deleting one and
# not the other leaves dangling links that kmodloader reports as user.err on
# every boot ("failed to open /etc/modules-boot.d/30-gpio-button-hotplug").
# Harmless, because nothing here is loaded by kmodloader in the first place:
# /etc/init.d/mr1500x-hw insmods gpio-button-hotplug.ko and
# /lib/preinit/79_mr1500x_rootfs_data does overlay.ko and rootfs_data_part.ko,
# both by explicit path. But it is two error lines on every boot of a device
# with no console, where the boot log is the only diagnostic anyone has.
if [ -d "$TREE/etc/modules-boot.d" ]; then
    find "$TREE/etc/modules-boot.d" -type l ! -exec test -e {} \; -delete
    rmdir "$TREE/etc/modules-boot.d" 2>/dev/null || true
fi
mkdir -p "$TREE/lib/modules/4.4.176"
install -m 644 "$KO_OVERLAY" "$KO_PART" "$KO_BTN" "$TREE/lib/modules/4.4.176/"
install -m 755 "$WORK/.wpad/usr/sbin/wpad" "$TREE/usr/sbin/wpad"

WT=$(ls "$OW"/bin/packages/mipsel_24kc/base/wireless-tools_*.ipk | head -1)
rm -rf "$WORK/.wt"; mkdir -p "$WORK/.wt"
( cd "$WORK/.wt" && tar xzf "$WT" && tar xzf data.tar.gz ) >/dev/null 2>&1
# iwpriv is how func_off gets cleared; while it is 1 the 2.4 GHz driver drops
# every data frame with no counter and no printk. wireless-tools is multi-call.
install -m 755 "$WORK/.wt/usr/sbin/iwconfig" "$TREE/usr/sbin/iwconfig"
ln -sf iwconfig "$TREE/usr/sbin/iwpriv"
ln -sf iwconfig "$TREE/usr/sbin/iwlist"

cp -a "$SELF/files/." "$TREE/"
cp -a "$WORK/stockfs/etc/conf" "$TREE/etc/"
step "overlay + RF tables installed"

say "10. build our tools"
TCC=$(echo "$OW"/staging_dir/toolchain-mipsel_24kc_*/bin/mipsel-openwrt-linux-musl-gcc)
[ -x "$TCC" ] || die "no target compiler at $TCC"
# The OpenWrt gcc wrapper resolves its sysroot from STAGING_DIR and warns on
# every invocation without it.
export STAGING_DIR=$OW/staging_dir
for src in mr1500x-fwupd hapcli; do
    # -s: strip at link time. Not cosmetic. Static linking drags in libgcc's
    # debug info, which carries the absolute path of the directory the
    # toolchain was built in — so an unstripped binary is ~85 KB larger AND
    # different for every build directory, on a board with 6 MB of rootfs
    # budget. Nothing here is ever debugged on-target.
    "$TCC" -Os -static -s -o "$TREE/sbin/$src" "$SELF/src/$src.c" \
        || die "failed to build $src"
    chmod 755 "$TREE/sbin/$src"
done
# hapcli talks to hostapd's global control socket; it lives on $PATH as well
ln -sf ../../sbin/hapcli "$TREE/usr/sbin/hapcli"
step "mr1500x-fwupd, hapcli"

say "11. wire up init"
( cd "$TREE"
  ln -sf ../init.d/vendor-vlan      etc/rc.d/S15vendor-vlan
  ln -sf ../init.d/vendor-mac       etc/rc.d/S25vendor-mac
  ln -sf ../init.d/lan-failsafe     etc/rc.d/S99lan-failsafe
  ln -sf ../init.d/mr1500x-hw       etc/rc.d/S12mr1500x-hw
  ln -sf ../init.d/mr1500x-hwnat    etc/rc.d/S21mr1500x-hwnat
  ln -sf ../init.d/mr1500x-wifi     etc/rc.d/S35mr1500x-wifi
  ln -sf ../init.d/mr1500x-wwan     etc/rc.d/S36mr1500x-wwan
  ln -sf ../init.d/mr1500x-wwan     etc/rc.d/K16mr1500x-wwan
  chmod 755 etc/init.d/vendor-vlan etc/init.d/vendor-mac etc/init.d/lan-failsafe \
            etc/init.d/mr1500x-hw etc/init.d/mr1500x-hwnat etc/init.d/mr1500x-wifi \
            etc/init.d/mr1500x-wwan etc/init.d/led etc/rc.button/reset sbin/netup
  chmod 755 lib/netifd/wireless/mac80211.sh
  # a mt7621 switch config would make swconfig/netifd fight the vendor driver
  rm -f etc/config/switch
  # /etc/hotplug.d/ieee80211/10-wifi-detect runs `wifi config` on a new phy and
  # appends upstream-style mac80211 radios whose Enable button wedges the box
  # until a power cycle. Neither file can ever be correct here.
  rm -f etc/hotplug.d/ieee80211/10-wifi-detect lib/wifi/mac80211.sh
  # keys are generated per unit on first boot; an image-wide key is no key
  rm -f etc/dropbear/dropbear_*_host_key
  mkdir -p etc/dropbear && chmod 700 etc/dropbear )

# LuCI's Save & Apply on the wireless page must reach our bring-up script, or
# edits land in /etc/config/wireless and never touch the radios.
grep -q "option init mr1500x-wifi" "$TREE/etc/config/ucitrack" || \
    sed -i "s|^config wireless\$|config wireless\n\toption init mr1500x-wifi|" \
        "$TREE/etc/config/ucitrack"
grep -q "option init mr1500x-wifi" "$TREE/etc/config/ucitrack" \
    || die "could not register mr1500x-wifi in ucitrack — LuCI apply would do nothing"

# /sbin/netup asserts the vendor link once at boot. It is respawned because it
# is what keeps the LAN reachable; it is NOT a shell.
python3 - "$TREE/etc/inittab" <<'PY'
import sys
p=sys.argv[1]
lines=[l for l in open(p).read().splitlines() if '/sbin/netup' not in l and '/sbin/shd' not in l]
out=[]
for l in lines:
    out.append(l)
    if l.startswith('::sysinit:'):
        out.append('::respawn:/sbin/netup')
if not any('/sbin/netup' in l for l in out):
    out.append('::respawn:/sbin/netup')
open(p,'w').write("\n".join(out)+"\n")
PY
# An image with no identity is unsupportable: the first question about any
# report is "which build is that?", and there is no other way to answer it.
cat > "$TREE/etc/mr1500x-version" <<EOF
MR1500X_IMAGE="openwrt-21.02.7 on vendor kernel 4.4.176"
MR1500X_OPENWRT="$OW_COMMIT"
MR1500X_LUCI="$(grep -oE 'luci\.git\^[0-9a-f]{40}' "$SELF/config/feeds.conf" | cut -d^ -f2)"
MR1500X_GPL_SHA="$GPL_SHA"
MR1500X_FIRMWARE_SHA="$(sha256sum "$FIRMWARE" | cut -d' ' -f1)"
MR1500X_BUILT="$(date -u -d "@$SOURCE_DATE_EPOCH" +%FT%TZ)"
EOF
step "rc.d links, ucitrack hook, inittab, /etc/mr1500x-version"

# Point ABI-versioned dependencies at the package that is actually installed.
#
# OpenWrt renames a dependency on an ABI-versioned library to carry the ABI
# suffix — libc depends on "libgcc1", not "libgcc" — using an .abiversion file
# that the providing package writes when it is built. In a COLD build the two
# happen in the wrong order often enough to matter: libc gets packaged before
# libgcc has registered its ABI, and the dependency is recorded unsuffixed,
# naming a package that does not exist. Warm rebuilds of the same tree get it
# right, which is why this never showed up until two clean builds were compared
# side by side. The visible symptom is opkg refusing work with "Cannot satisfy
# the following dependencies for libc: libgcc".
#
# So this is a correctness fix that happens to also remove a source of
# build-to-build variation. It is deliberately conservative: a dependency is
# only rewritten when the unsuffixed name is NOT installed and exactly one
# installed package provides it under an ABI suffix. Anything else is left
# alone, so a genuinely missing dependency stays visible.
python3 - "$TREE" <<'PY'
import os, re, sys
info = os.path.join(sys.argv[1], "usr/lib/opkg/info")
stat = os.path.join(sys.argv[1], "usr/lib/opkg/status")
if os.path.isdir(info):
    installed, abi = set(), {}
    for blk in open(stat).read().split("\n\n") if os.path.isfile(stat) else []:
        m = re.search(r"^Package:\s*(\S+)", blk, re.M)
        if not m:
            continue
        installed.add(m.group(1))
        v = re.search(r"^ABIVersion:\s*(\S+)", blk, re.M)
        if v and m.group(1).endswith(v.group(1)):
            abi.setdefault(m.group(1)[: -len(v.group(1))], []).append(m.group(1))

    def fix(line):
        head, _, rest = line.partition(":")
        deps, out = [d.strip() for d in rest.split(",")], []
        for d in deps:
            n = d.split()[0] if d else d
            if n and n not in installed and len(abi.get(n, [])) == 1:
                d = d.replace(n, abi[n][0], 1)
            out.append(d)
        return "%s: %s" % (head, ", ".join(out))

    n = 0
    for p in [stat] + [os.path.join(info, f) for f in os.listdir(info)
                       if f.endswith(".control")]:
        if not os.path.isfile(p):
            continue
        src = open(p).read()
        dst = "\n".join(fix(l) if l.startswith("Depends:") else l
                        for l in src.split("\n"))
        if dst != src:
            open(p, "w").write(dst)
            n += 1
    print("   %d opkg metadata file(s) had a dependency renamed to its "
          "ABI-versioned package" % n)
PY

say "12. image assertions"
bad=0
chk() { if eval "$2"; then printf '   ok   %s\n' "$1"; else printf '   FAIL %s\n' "$1"; bad=1; fi; }

# --- the ones that decide whether it boots at all ---
chk "preinit is the stock one (no ramfs chroot)" \
    'grep -q "boot_hook_init preinit_essential" "$TREE/etc/preinit" &&
     ! grep -qE "mount -t ramfs|chroot" "$TREE/etc/preinit"'
chk "overlay preinit hook present and sorts before 80_mount_root" \
    '[ -s "$TREE/lib/preinit/79_mr1500x_rootfs_data" ]'
chk "sysupgrade writer is ours, not the ramips one" \
    'grep -q "mr1500x-fwupd" "$TREE/lib/upgrade/platform.sh" &&
     ! grep -vE "^[[:space:]]*#" "$TREE/lib/upgrade/platform.sh" | grep "PART_NAME=firmware" >/dev/null'
chk "lan bridge keeps the vendor CPU-trunk vlan netdev" \
    'grep -q "eth0.2" "$TREE/etc/config/network"'
chk "vendor-mac runs at S25, after netifd made br-lan" \
    '[ -e "$TREE/etc/rc.d/S25vendor-mac" ] && [ ! -e "$TREE/etc/rc.d/S14vendor-mac" ]'

# --- the ones that decide whether Wi-Fi works ---
chk "netifd wireless driver is our reporting-only one" \
    'grep -q "REPORTING ONLY" "$TREE/lib/netifd/wireless/mac80211.sh"'
chk "that driver never calls iw (it wedges this hardware)" \
    '! grep -vE "^[[:space:]]*#" "$TREE/lib/netifd/wireless/mac80211.sh" | grep -E "(^|[^-a-z_])iw[[:space:]]" >/dev/null'
chk "radios declare type mac80211 so LuCI builds the crypto form" \
    'grep -q "option type[[:space:]]*.mac80211." "$TREE/etc/config/wireless"'
chk "5 GHz RF tables present" \
    '[ -s "$TREE/etc/conf/rtl8832bre/RFE50/RadioA.txt" ] &&
     [ -s "$TREE/etc/conf/rtl8832bre/RFE50/PHY_REG.txt" ] &&
     [ -s "$TREE/etc/conf/rtl8832bre/RFE50/TXPWR_LMT.txt" ]'
chk "wpad carries the association patch" \
    'grep -aq "nl80211: sta_assoc " "$TREE/usr/sbin/wpad"'
chk "iwpriv present" '[ -e "$TREE/usr/sbin/iwpriv" ]'

# --- the ones that decide whether it is safe to publish ---
chk "no root shell service in the image" \
    '[ ! -e "$TREE/sbin/shd" ] && ! grep -q "/sbin/shd" "$TREE/etc/inittab"'
chk "netup still respawns (it is what keeps the LAN up)" \
    'grep -q "::respawn:/sbin/netup" "$TREE/etc/inittab"'
chk "no dropbear host key in the image" \
    '[ -z "$(ls "$TREE"/etc/dropbear/dropbear_*_host_key 2>/dev/null)" ]'
# Parse the VALUE rather than pattern-matching the line: the uplink ships
# `option ssid ''` and `option key ''` on purpose (empty means "the operator
# switched it off", absent means "never seeded" — the init script distinguishes
# them), and a regex like `option key .\S` matches the two quotes of an empty
# value and fails a tree that is actually correct.
chk "no wireless passphrase anywhere" \
    'python3 - "$TREE" <<"PY"
import os, re, sys
bad = []
for f in ("etc/config/mr1500x-wifi", "etc/config/wireless"):
    p = os.path.join(sys.argv[1], f)
    for n, line in enumerate(open(p), 1):
        m = re.match(r"\s*option\s+key\s+(.*)", line)
        if not m:
            continue
        v = m.group(1).strip().strip("\x27\x22")
        if v:
            bad.append("%s:%d" % (f, n))
assert not bad, "a passphrase is present at " + ", ".join(bad)
PY'
chk "both radios ship disabled" \
    '[ "$(grep -c "option disabled[[:space:]]*.1." "$TREE/etc/config/wireless")" -ge 2 ]'
chk "uplink ships off and credential-free" \
    'python3 - "$TREE" <<"PY"
import re, sys, os
t = sys.argv[1]
w = open(os.path.join(t, "etc/config/mr1500x-wifi")).read()
m = re.search(r"(?ms)^config\s+wwan\b.*?(?=^config |\Z)", w)
assert m, "no wwan section"
blk = m.group(0)
assert re.search(r"option\s+enabled\s+.0.", blk), "uplink not disabled"
for opt in ("ssid", "key"):
    v = re.search(r"option\s+%s\s+(.*)" % opt, blk)
    # empty is correct and meaningful here; only a real value is a leak
    assert not (v and v.group(1).strip().strip("\x27\x22")), \
        "uplink ships a %s" % opt
PY'
chk "no unit-specific MAC constant" \
    'python3 - "$TREE" <<"PY"
import os,re,sys
A=re.compile(r"^(00:00:00:00:00:00|ff:ff:ff:ff:ff:ff|00:12:34:56:78:90|00:11:22:33:44:[0-9a-f]{2}|0[ae]:00:00:00:00:00)$",re.I)
M=re.compile(r"\b(?:[0-9a-fA-F]{2}:){2,}[0-9a-fA-F]{2}\b")
bad=[]
for r,_,fs in os.walk(os.path.join(sys.argv[1],"etc/config")):
    for f in fs:
        p=os.path.join(r,f)
        for m in M.findall(open(p,errors="ignore").read()):
            if not A.match(m): bad.append(p+": "+m)
assert not bad, bad
PY'
# Two reproducibility guards. Neither changes what the image does; both exist
# because the only way to notice you have lost byte-for-byte reproducibility is
# to build twice in two directories and diff, and nobody does that per commit.
chk "no build path baked into the image" \
    'python3 - "$TREE" "$WORK" <<"PY"
import os, sys
tree, work = sys.argv[1], sys.argv[2].encode()
bad = []
for r, _, fs in os.walk(tree):
    for f in fs:
        p = os.path.join(r, f)
        if os.path.islink(p) or not os.path.isfile(p):
            continue
        if work in open(p, "rb").read():
            bad.append(os.path.relpath(p, tree))
assert not bad, ("these carry the absolute build directory, so a build "
                 "elsewhere produces different bytes: " + ", ".join(bad))
PY'
chk "no per-build package signing key shipped" \
    'python3 - "$TREE" "$OW" <<"PY"
import os, sys
keys = os.path.join(sys.argv[1], "etc/opkg/keys")
pub  = os.path.join(sys.argv[2], "key-build.pub")
if os.path.isdir(keys) and os.path.isfile(pub):
    want = open(pub, "rb").read()
    bad = [f for f in os.listdir(keys)
           if open(os.path.join(keys, f), "rb").read() == want]
    assert not bad, ("this buildroot\x27s own usign key is in the image as "
                     + ", ".join(bad) + " — its name and bytes are random per "
                     "clean build, and it verifies nothing anyone publishes. "
                     "CONFIG_BUILDBOT should have kept it out.")
PY'
# Deliberately scoped to modules-boot.d rather than the whole tree: a rootfs is
# full of symlinks that are correctly dangling at build time because their
# target is created at runtime (/etc/resolv.conf -> /tmp/resolv.conf is the
# obvious one). These, by contrast, can only ever point at /etc/modules.d,
# which this build removes.
chk "no dangling module-load symlinks" \
    'python3 - "$TREE" <<"PY"
import os, sys
d = os.path.join(sys.argv[1], "etc/modules-boot.d")
bad = [n for n in (os.path.isdir(d) and os.listdir(d) or [])
       if not os.path.exists(os.path.join(d, n))]
assert not bad, ("kmodloader will log a user.err for each of these on every "
                 "boot: " + ", ".join(sorted(bad)))
PY'
chk "image carries its identity" \
    'grep -q "^MR1500X_OPENWRT=" "$TREE/etc/mr1500x-version"'
chk "radio MACs are derived at runtime" \
    '[ -s "$TREE/lib/functions/mr1500x-mac.sh" ] &&
     grep -q "mr1500x_wifi_mac" "$TREE/etc/init.d/mr1500x-wifi"'
chk "opkg feeds are the two userspace ones (no wrong-kernel kmods)" \
    'grep -q "openwrt_base" "$TREE/etc/opkg/distfeeds.conf" &&
     ! grep -qE "^[[:space:]]*src(/gz)?[[:space:]]+openwrt_core" "$TREE/etc/opkg/distfeeds.conf"'
chk "uci configs parse" \
    'python3 - "$TREE" <<"PY"
import glob,sys,os
bad=[]
for p in sorted(glob.glob(os.path.join(sys.argv[1],"etc/config/*"))):
    for n,l in enumerate(open(p,errors="replace"),1):
        s=l.strip()
        if s and not s.startswith("#") and s.split()[0] not in ("config","option","list"):
            bad.append("%s:%d"%(p,n))
assert not bad, bad
PY'
[ "$bad" = 0 ] || die "image assertions failed — refusing to emit an image"

say "13. pack, seal, wrap"
# Deterministic: fixed timestamps, and the device-node list re-declared rather
# than recreated (we are not root).
find "$TREE" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
MKSQ=$OW/staging_dir/host/bin/mksquashfs4
"$MKSQ" "$TREE" "$OUT/rootfs.sqfs" -comp xz -b 262144 -noappend -no-progress \
        -root-owned -pf "$WORK/devnodes.pf" > "$WORK/mksquashfs.log" 2>&1
# Superblock flags must come out 0x04c0 — DUPLICATE|EXPORTABLE|NO_XATTR|COMP_OPT.
# That is what every image validated on this hardware carries, including the one
# running now. COMP_OPT (the trailing xz options block) was once suspected of
# causing down-mode drops and tools/flag_fix_squashfs.py exists to clear it; it
# turned out to be innocent, and the seal was the real story. So this asserts the
# proven value rather than "fixing" it — if a future mksquashfs changes the flag
# set, that is something to find out here, not on a device with no serial port.
python3 - "$OUT/rootfs.sqfs" <<'PY'
import struct, sys
f = struct.unpack_from('<H', open(sys.argv[1], 'rb').read(32), 24)[0]
if f != 0x04c0:
    raise SystemExit("squashfs flags 0x%04x, expected 0x04c0 (the value proven "
                     "to mount on the vendor kernel). tools/flag_fix_squashfs.py "
                     "can adjust them, but understand the change first." % f)
print("   squashfs flags 0x%04x — matches every validated image" % f)
PY
# *** UNPACK WHAT WE JUST PACKED AND COMPARE IT, FILE BY FILE ***
# This is not paranoia about mksquashfs's correctness in general. On 2026-09-14,
# on this build host, one run produced an image whose /usr/sbin/dropbear differed
# from the file on disk by a SINGLE BIT (0x83 -> 0x82 at offset 0xd505, inside a
# `lw $t9, imm($gp)`). The source file was never rewritten — its mtime predates
# all four runs — and the runs on either side were byte-identical. So either a
# transient memory error or a race in the compressor wrote one wrong bit into
# the image.
#
# squashfs has no per-file integrity data, the vendor boot gate only checksums
# the first 642 bytes, and this board has no serial console. A silently
# corrupted binary would therefore be flashed, mounted and run with nothing
# anywhere noticing. Unpacking costs a few seconds and turns that into a
# build-time failure.
rm -rf "$WORK/verify"
"$UNSQ" -d "$WORK/verify" "$OUT/rootfs.sqfs" > "$WORK/verify.log" 2>&1 || true
python3 - "$TREE" "$WORK/verify" <<'PY'
import hashlib, os, sys, stat
src, back = sys.argv[1], sys.argv[2]
def digest(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()
bad, n = [], 0
for root, dirs, files in os.walk(src):
    for fn in files:
        a = os.path.join(root, fn)
        b = os.path.join(back, os.path.relpath(a, src))
        st = os.lstat(a)
        if stat.S_ISLNK(st.st_mode):
            if not os.path.islink(b) or os.readlink(a) != os.readlink(b):
                bad.append("symlink %s" % os.path.relpath(a, src))
            continue
        if not stat.S_ISREG(st.st_mode):
            continue            # device nodes come from the -pf list, not here
        n += 1
        if not os.path.exists(b):
            bad.append("missing %s" % os.path.relpath(a, src)); continue
        if digest(a) != digest(b):
            bad.append("CONTENT %s" % os.path.relpath(a, src))
if bad:
    print("the packed image does not match the tree it was built from:", file=sys.stderr)
    for x in bad[:20]:
        print("   " + x, file=sys.stderr)
    print("   Re-run the build. If it recurs on the same file, suspect the\n"
          "   compressor; if it moves around, suspect the host's memory.",
          file=sys.stderr)
    sys.exit(1)
print("   round trip: %d files unpacked and sha256-matched against the tree" % n)
PY
python3 "$SELF/tools/uboot_fs_seal.py" seal "$OUT/rootfs.sqfs" "$OUT/rootfs.sealed"
python3 "$SELF/tools/uboot_fs_seal.py" verify "$OUT/rootfs.sealed"
SZ=$(stat -c%s "$OUT/rootfs.sealed")
[ "$SZ" -le "$ROOTFS_BUDGET" ] || die \
"sealed rootfs is $SZ bytes, budget is $ROOTFS_BUDGET.
   Anything past the budget grows into the overlay partition, and past that
   into the factory tail. Remove packages."
step "sealed $SZ bytes, $((ROOTFS_BUDGET - SZ)) spare"
python3 "$SELF/tools/mk_cvimg.py" root "$OUT/rootfs.sealed" "$OUT/mr1500x-root-r6cr.bin"

say "14. verify the container the way the bootloader does"
python3 - "$OUT/mr1500x-root-r6cr.bin" <<'PY'
import struct, sys
def sum16(b):
    s=0
    for i in range(0,(len(b)//2)*2,2): s=(s+((b[i]<<8)|b[i+1]))&0xffff
    if len(b)%2: s=(s+(b[-1]<<8))&0xffff
    return s
d=open(sys.argv[1],'rb').read()
sig,start,burn,ln=struct.unpack('>4sIII',d[:16])
fs=d[16:16+ln-2]
glen=int.from_bytes(fs[8:12],'big')+642
ok = (sig==b'r6cr' and burn==0x400000 and ln%2==0
      and sum16(d[16:16+ln])==0 and glen<=len(fs) and sum16(fs[:glen])==0)
print("   sig=%s burn=0x%x len=0x%x even=%s" % (sig.decode(), burn, ln, ln%2==0))
print("   container checksum : %s" % ("PASS" if sum16(d[16:16+ln])==0 else "FAIL"))
print("   boot gate over %d B: %s" % (glen, "PASS (accept & boot)" if sum16(fs[:glen])==0 else "FAIL"))
sys.exit(0 if ok else 1)
PY

say "15. manifest"
{
  echo "# mr1500x image manifest"
  echo "built           $(date -u -d "@$SOURCE_DATE_EPOCH" +%FT%TZ) (SOURCE_DATE_EPOCH)"
  echo "openwrt         $OW_TAG $OW_COMMIT"
  echo "feeds           $(grep -oE '\^[0-9a-f]{40}' "$SELF/config/feeds.conf" | tr -d '^' | tr '\n' ' ')"
  echo "gpl drop        $GPL_SHA"
  echo "firmware        $(sha256sum "$FIRMWARE" | cut -d' ' -f1)"
  echo "module cc       $("${CROSS}gcc" --version | head -1)"
  echo "userspace cc    $("$TCC" --version | head -1)"
  echo "rootfs sealed   $SZ bytes (budget $ROOTFS_BUDGET)"
  echo
  ( cd "$OUT" && sha256sum mr1500x-root-r6cr.bin rootfs.sealed )
  echo
  echo "# rootfs contents"
  ( cd "$TREE" && find . -type f -exec sha256sum {} + | sort -k2 )
} > "$OUT/manifest.txt"
( cd "$OUT" && sha256sum mr1500x-root-r6cr.bin > sha256sums.txt )

say "done"
echo "   image:    $OUT/mr1500x-root-r6cr.bin"
echo "   manifest: $OUT/manifest.txt"
echo
echo "   flash it:  python3 $SELF/tools/tftp_push.py 192.168.1.1 $OUT/mr1500x-root-r6cr.bin"
echo "   (device in down mode: power off, hold reset, power on, hold ~10 s)"
[ "$KEEP" = 1 ] || echo "   work tree kept at $WORK (nothing is deleted automatically)"
