include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for WPCP agent
LUCI_DEPENDS:=+luci-base +rpcd +rpcd-mod-file
LUCI_PKGARCH:=all
PKG_LICENSE:=MIT
PKG_MAINTAINER:=WPCP Contributors

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
$(eval $(call BuildPackage,$(PKG_NAME)))
