#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2022-2023 ImmortalWrt.org

NAME="homeproxy"

# Keep this in UCI so it can be changed from LuCI.  Fall back to the default
# for upgrades from older configurations or if uci is temporarily unavailable.
log_max_size="$(uci -q get homeproxy.config.log_max_size 2>/dev/null || true)"
case "$log_max_size" in
	''|*[!0-9]*) log_max_size="50" ;;
esac
main_log_file="/var/run/$NAME/$NAME.log"
singc_log_file="/var/run/$NAME/sing-box-c.log"
sings_log_file="/var/run/$NAME/sing-box-s.log"

while true; do
	sleep 180
	for i in "$main_log_file" "$singc_log_file" "$sings_log_file"; do
		[ -s "$i" ] || continue
		[ "$(( $(ls -l "$i" | awk -F ' ' '{print $5}') / 1024 >= log_max_size))" -eq "0" ] || echo "" > "$i"
	done
done
