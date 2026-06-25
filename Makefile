include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-wrtbak
PKG_VERSION:=0.1.0
PKG_RELEASE:=13

LUCI_TITLE:=LuCI app and CLI for profile-based OpenWrt backups
LUCI_DEPENDS:=+luci-base +rpcd +jsonfilter +curl +rclone
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
