# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2022-2023 ImmortalWrt.org

include $(TOPDIR)/rules.mk

LUCI_TITLE:=The modern ImmortalWrt proxy platform for ARM64/AMD64
LUCI_PKGARCH:=all
SING_BOX_MIN_VERSION:=1.14.0
LUCI_DEPENDS:= \
	+sing-box (>= $(SING_BOX_MIN_VERSION)) \
	+firewall4 \
	+kmod-nft-tproxy \
	+ucode-mod-digest

PKG_NAME:=luci-app-homeproxy

define Package/luci-app-homeproxy/conffiles
/etc/config/homeproxy
/etc/homeproxy/certs/
/etc/homeproxy/ruleset/
/etc/homeproxy/resources/direct_list.txt
/etc/homeproxy/resources/proxy_list.txt
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
