include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-wrtbak
PKG_VERSION:=0.3.8
PKG_RELEASE:=1

LUCI_TITLE:=LuCI app and CLI for profile-based OpenWrt backups
LUCI_DEPENDS:=+luci-base +rpcd +jsonfilter +curl +rclone +qrencode
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
