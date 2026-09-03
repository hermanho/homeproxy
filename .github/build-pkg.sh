#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2023 Tianling Shen <cnsztl@immortalwrt.org>

set -o errexit
set -o pipefail
set -o nounset

PKG_MGR="${1:-apk}"

if [ "$PKG_MGR" != "apk" ] && [ "$PKG_MGR" != "ipk" ]; then
	echo "error: expected package format 'apk' or 'ipk', got '$PKG_MGR'" >&2
	exit 1
fi

BASE_DIR="$(cd "$(dirname $0)"; pwd)"
PKG_DIR="$BASE_DIR/.."

function get_mk_value() {
	awk -F "$1:=" '{print $2}' "$PKG_DIR/Makefile" | xargs
}

function get_source_revision() {
	local commit_info commit_epoch commit_hash year_day seconds

	# CI passes the exact triggering commit. For local builds, use the
	# current checkout's HEAD rather than searching backwards by path.
	commit_info="$(git -C "$PKG_DIR" show -s \
		--format='%ct %h' \
		--abbrev=7 \
		"${SOURCE_COMMIT:-${GITHUB_SHA:-HEAD}}")"
	commit_epoch="${commit_info%% *}"
	commit_hash="${commit_info##* }"

	if ! [[ "$commit_epoch" =~ ^[0-9]+$ ]] || ! [[ "$commit_hash" =~ ^[0-9a-f]{7}$ ]]; then
		echo "error: unable to determine source revision from git" >&2
		exit 1
	fi

	seconds="$((commit_epoch % 86400))"
	if year_day="$(date --utc --date="@$commit_epoch" '+%y.%j' 2>/dev/null)"; then
		:
	else
		year_day="$(date -u -r "$commit_epoch" '+%y.%j')"
	fi

	printf '%s.%05d~%s' "$year_day" "$seconds" "$commit_hash"
}

PKG_NAME="$(get_mk_value "PKG_NAME")"
SING_BOX_MIN_VERSION="$(get_mk_value "SING_BOX_MIN_VERSION")"
PKG_VERSION="$(get_source_revision)"
PKG_SOURCE_DATE_EPOCH="$(git -C "$PKG_DIR" show -s --format='%ct' \
	"${SOURCE_COMMIT:-${GITHUB_SHA:-HEAD}}")"
export PKG_SOURCE_DATE_EPOCH
export SOURCE_DATE_EPOCH="$PKG_SOURCE_DATE_EPOCH"

echo "Building $PKG_NAME $PKG_VERSION"

TEMP_DIR="$(mktemp -d -p "$BASE_DIR")"
trap 'rm -rf "$TEMP_DIR"' EXIT
TEMP_PKG_DIR="$TEMP_DIR/$PKG_NAME"
mkdir -p "$TEMP_PKG_DIR/lib/upgrade/keep.d/"
mkdir -p "$TEMP_PKG_DIR/usr/lib/lua/luci/i18n/"
mkdir -p "$TEMP_PKG_DIR/www/"
if [ "$PKG_MGR" == "apk" ]; then
	mkdir -p "$TEMP_PKG_DIR/lib/apk/packages/"
else
	mkdir -p "$TEMP_PKG_DIR/CONTROL/"
fi

cp -fpR "$PKG_DIR/htdocs"/* "$TEMP_PKG_DIR/www/"
cp -fpR "$PKG_DIR/root"/* "$TEMP_PKG_DIR/"

cat > "$TEMP_PKG_DIR/lib/upgrade/keep.d/$PKG_NAME" <<-EOF
/etc/homeproxy/certs/
/etc/homeproxy/ruleset/
/etc/homeproxy/resources/direct_list.txt
/etc/homeproxy/resources/proxy_list.txt
EOF

po2lmo "$PKG_DIR/po/zh_Hans/homeproxy.po" "$TEMP_PKG_DIR/usr/lib/lua/luci/i18n/homeproxy.zh-cn.lmo"

if [ "$PKG_MGR" == "apk" ]; then
	find "$TEMP_PKG_DIR" -type f,l -printf '/%P\n' | sort > "$TEMP_DIR/$PKG_NAME.list"
	mv "$TEMP_DIR/$PKG_NAME.list" "$TEMP_PKG_DIR/lib/apk/packages/$PKG_NAME.list"
	echo "/etc/config/homeproxy" >> "$TEMP_PKG_DIR/lib/apk/packages/$PKG_NAME.conffiles"
	while IFS= read -r file; do
		[ -f "$TEMP_PKG_DIR/$file" ] || continue
		csum="$(sha256sum "$TEMP_PKG_DIR/$file" | awk '{print $1}')"
		echo "$file $csum" >> "$TEMP_PKG_DIR/lib/apk/packages/$PKG_NAME.conffiles_static"
	done < "$TEMP_PKG_DIR/lib/apk/packages/$PKG_NAME.conffiles"

	echo -e '#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="'"$PKG_NAME"'"
add_group_and_user
default_postinst
[ -n "${IPKG_INSTROOT}" ] || { rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	killall -HUP rpcd 2>/dev/null
	exit 0
}' > "$TEMP_DIR/post-install"

	echo -e '#!/bin/sh
export PKG_UPGRADE=1
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="'"$PKG_NAME"'"
add_group_and_user
default_postinst
[ -n "${IPKG_INSTROOT}" ] || { rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	killall -HUP rpcd 2>/dev/null
	exit 0
}' > "$TEMP_DIR/post-upgrade"

	echo -e '#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="'"$PKG_NAME"'"
default_prerm' > "$TEMP_DIR/pre-deinstall"

	apk mkpkg \
		--info "name:$PKG_NAME" \
		--info "version:$PKG_VERSION" \
		--info "description:The modern ImmortalWrt proxy platform for ARM64/AMD64" \
		--info "arch:noarch" \
		--info "origin:https://github.com/immortalwrt/homeproxy" \
		--info "url:" \
		--info "maintainer:Tianling Shen <cnsztl@immortalwrt.org>" \
		--info "provides:" \
		--script "post-install:$TEMP_DIR/post-install" \
		--script "post-upgrade:$TEMP_DIR/post-upgrade" \
		--script "pre-deinstall:$TEMP_DIR/pre-deinstall" \
		--info "depends:libc sing-box>=$SING_BOX_MIN_VERSION firewall4 kmod-nft-tproxy ucode-mod-digest" \
		--files "$TEMP_PKG_DIR" \
		--output "$TEMP_DIR/${PKG_NAME}-${PKG_VERSION}.apk"

	mv "$TEMP_DIR/${PKG_NAME}-${PKG_VERSION}.apk" "$BASE_DIR/${PKG_NAME}-${PKG_VERSION}.apk"
else
	mkdir -p "$TEMP_PKG_DIR/CONTROL/"

	cat > "$TEMP_PKG_DIR/CONTROL/control" <<-EOF
		Package: $PKG_NAME
		Version: $PKG_VERSION
		Depends: libc, sing-box (>= $SING_BOX_MIN_VERSION), firewall4, kmod-nft-tproxy, ucode-mod-digest
		Source: https://github.com/immortalwrt/homeproxy
		SourceName: $PKG_NAME
		Section: luci
		SourceDateEpoch: $PKG_SOURCE_DATE_EPOCH
		Maintainer: Tianling Shen <cnsztl@immortalwrt.org>
		Architecture: all
		Installed-Size: TO-BE-FILLED-BY-IPKG-BUILD
		Description:  The modern ImmortalWrt proxy platform for ARM64/AMD64
	EOF
	chmod 0644 "$TEMP_PKG_DIR/CONTROL/control"

	echo -e "/etc/config/homeproxy" > "$TEMP_PKG_DIR/CONTROL/conffiles"

	echo -e '#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_postinst $0 $@' > "$TEMP_PKG_DIR/CONTROL/postinst"
	chmod 0755 "$TEMP_PKG_DIR/CONTROL/postinst"

	echo -e "[ -n "\${IPKG_INSTROOT}" ] || {
	(. /etc/uci-defaults/$PKG_NAME) && rm -f /etc/uci-defaults/$PKG_NAME
	rm -f /tmp/luci-indexcache
	rm -rf /tmp/luci-modulecache/
	exit 0
}" > "$TEMP_PKG_DIR/CONTROL/postinst-pkg"
	chmod 0755 "$TEMP_PKG_DIR/CONTROL/postinst-pkg"

	echo -e '#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_prerm $0 $@' > "$TEMP_PKG_DIR/CONTROL/prerm"
	chmod 0755 "$TEMP_PKG_DIR/CONTROL/prerm"

	ipkg-build -m "" "$TEMP_PKG_DIR" "$TEMP_DIR"

	mv "$TEMP_DIR/${PKG_NAME}_${PKG_VERSION}_all.ipk" "$BASE_DIR/${PKG_NAME}_${PKG_VERSION}_all.ipk"
fi
