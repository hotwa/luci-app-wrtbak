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

For private firmware builds that inject R2 credentials, keep firstboot restore
independent from the transparent proxy. `firstboot-candidates` and
`firstboot-prepare` force direct S3/R2 transport so a factory-reset router can
download its `.wrtbak` backup before Nikki or DAE has been restored.

Automatic firstboot restore is opt-in. A private build may enable it with a
UCI defaults migration after the R2 target has been injected:

```text
wrtbak.main.firstboot_auto_enabled=1
wrtbak.main.firstboot_auto_target=s3
wrtbak.main.firstboot_auto_attempts=18
wrtbak.main.firstboot_auto_sleep=10
wrtbak.main.firstboot_auto_reboot=1
```

The init script `wrtbak-firstboot-auto` runs late in boot. It exits without
changing the router when the done marker already exists, when route/DNS/time
is not ready, or when no canonical current-device backup exists. When it does
apply a restore, it writes evidence under `/root/wrtbak/firstboot/` and can
reboot so restored network, SSH, Tailscale, firewall, and proxy configuration
come up together.

If OpenWRT-CI injects site-specific proxy artifact settings, include a
`/etc/uci-defaults` migration that fills missing non-secret options on
keep-config upgrades:

```text
wrtbak.main.site
wrtbak.main.proxy_artifacts_enabled
wrtbak.main.proxy_update_mode
```

The migration must only set missing values. It must not overwrite existing R2
credentials, backup paths, schedules, or user-edited proxy settings. Do not
set `wrtbak.main.proxy_url` to a local transparent proxy for firstboot restore;
leave it empty unless the operator explicitly chooses proxy transport after a
successful whole-device restore. Whole-device recovery should be able to reach
R2 even when Nikki or DAE is missing, disabled, or broken.

Do not publish real `.wrtbak` or `.sysupgrade.tar.gz` backups through OpenWrt-CI logs, artifacts, or this public package repository.
