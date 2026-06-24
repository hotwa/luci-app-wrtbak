# OpenWrt CI Integration

Use these integration snippets after this repository contains an OpenWrt package skeleton and the referenced release tag or commit exists. In the current documentation/examples stage, this repository cannot be compiled directly as an OpenWrt package.

After a package skeleton and release tag exist, add the package repository to the OpenWrt-CI package update section:

```sh
UPDATE_PACKAGE "luci-app-wrtbak" "hotwa/luci-app-wrtbak" "v0.1.0"
```

Then enable the package in the OpenWrt build configuration:

```text
CONFIG_PACKAGE_luci-app-wrtbak=y
```

For development images after the package skeleton exists, it is acceptable to track `main` while iterating:

```sh
UPDATE_PACKAGE "luci-app-wrtbak" "hotwa/luci-app-wrtbak" "main"
```

For stable builds, pin a release tag or commit SHA instead of a moving branch. This makes firmware builds reproducible and avoids pulling unreviewed changes into production images. Do not use the `v0.1.0` example until that tag has been created.

Do not publish real `.wrtbak` or `.sysupgrade.tar.gz` backups through OpenWrt-CI logs, artifacts, or this public package repository.
