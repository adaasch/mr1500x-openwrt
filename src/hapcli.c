/*
 * hapcli - minimal hostapd/wpa_supplicant control-interface client.
 *
 *   hapcli <ctrl-socket> <command...>
 *   hapcli /var/run/hostapd/global "ADD bss_config=phy0:/tmp/bss.conf"
 *
 * WHY THIS EXISTS
 * The OpenWrt image ships wpad (hostapd+wpa_supplicant in one binary) but NOT
 * hostapd_cli — that lives in the separate hostapd-utils package. The vendor
 * rootfs has a hostapd_cli, but it is linked against uClibc (libc.so.0) and this
 * rootfs is musl, so it cannot be reused.
 *
 * We need the control interface because this board's Realtek driver only works
 * the way the vendor firmware drives it: a single GLOBAL hostapd daemon with
 * each BSS registered against a phy, i.e.
 *   hostapd_cli -p /var/run/hostapd -i global raw ADD bss_config=<phy>:<conf>
 * (stock lib/wifi/hostapd.sh). Running a standalone hostapd per interface
 * instead gets you an AP that beacons and accepts association but never
 * completes the WPA2 4-way handshake.
 *
 * The protocol is trivial: a UNIX DGRAM socket; the client binds its own path,
 * sends the command as plain text and reads the reply ("OK"/"FAIL"/data).
 *
 * Build (static, like mtdfsw/mtdregion/shd/loopset):
 *   mipsel-openwrt-linux-musl-gcc -static -Os -s hapcli.c -o hapcli
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/time.h>

int main(int argc, char **argv)
{
	struct sockaddr_un local, dest;
	char cmd[4096], buf[8192];
	char localpath[128];
	struct timeval tv = { .tv_sec = 10, .tv_usec = 0 };
	int fd, i, n;

	if (argc < 3) {
		fprintf(stderr, "usage: hapcli <ctrl-socket> <command...>\n");
		return 2;
	}

	/* join argv[2..] with spaces so the command can be given unquoted */
	cmd[0] = '\0';
	for (i = 2; i < argc; i++) {
		if (i > 2)
			strncat(cmd, " ", sizeof(cmd) - strlen(cmd) - 1);
		strncat(cmd, argv[i], sizeof(cmd) - strlen(cmd) - 1);
	}

	fd = socket(AF_UNIX, SOCK_DGRAM, 0);
	if (fd < 0) { perror("socket"); return 1; }

	/* hostapd replies to the client's bound address, so we must have one */
	snprintf(localpath, sizeof(localpath), "/tmp/hapcli-%d", (int)getpid());
	memset(&local, 0, sizeof(local));
	local.sun_family = AF_UNIX;
	strncpy(local.sun_path, localpath, sizeof(local.sun_path) - 1);
	unlink(localpath);
	if (bind(fd, (struct sockaddr *)&local, sizeof(local)) < 0) {
		perror("bind"); close(fd); return 1;
	}

	memset(&dest, 0, sizeof(dest));
	dest.sun_family = AF_UNIX;
	strncpy(dest.sun_path, argv[1], sizeof(dest.sun_path) - 1);
	if (connect(fd, (struct sockaddr *)&dest, sizeof(dest)) < 0) {
		perror("connect"); goto err;
	}

	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

	if (send(fd, cmd, strlen(cmd), 0) < 0) { perror("send"); goto err; }

	n = recv(fd, buf, sizeof(buf) - 1, 0);
	if (n < 0) { perror("recv (timeout?)"); goto err; }
	buf[n] = '\0';
	fputs(buf, stdout);
	if (n == 0 || buf[n - 1] != '\n')
		fputc('\n', stdout);

	unlink(localpath);
	close(fd);
	/* hostapd answers "FAIL" on error; make that a non-zero exit */
	return strncmp(buf, "FAIL", 4) == 0 ? 1 : 0;

err:
	unlink(localpath);
	close(fd);
	return 1;
}
