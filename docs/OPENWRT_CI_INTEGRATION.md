# OpenWrt CI Integration

Add the package repository to the OpenWrt-CI package update section:

```sh
UPDATE_PACKAGE "luci-app-wrtbak" "hotwa/luci-app-wrtbak" "v0.1.0"
```

Enable the package in the OpenWrt build configuration:

```text
CONFIG_PACKAGE_luci-app-wrtbak=y
```

For development images, it is acceptable to track `main` while iterating:

```sh
UPDATE_PACKAGE "luci-app-wrtbak" "hotwa/luci-app-wrtbak" "main"
```

For stable builds, pin a release tag or commit SHA instead of a moving branch. This makes firmware builds reproducible and avoids pulling unreviewed changes into production images.

Do not publish real `.wrtbak` or `.sysupgrade.tar.gz` backups through OpenWrt-CI logs, artifacts, or this public package repository.

