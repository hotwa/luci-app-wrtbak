# luci-app-wrtbak

`luci-app-wrtbak` is intended to provide a LuCI app for profile-based OpenWrt configuration backup and restore archives.

The project defines a `.wrtbak` archive format for portable, profile-aware backups. A `.wrtbak` file is a gzip-compressed tar archive containing at least:

- `manifest.json`
- `README.txt`
- `rootfs/`

Archives may also be exported as OpenWrt-compatible `.sysupgrade.tar.gz` files for restore flows that use native OpenWrt tooling.

Current capabilities:

- Detect installed `luci-app-*` packages from `apk` or `opkg`.
- Map known OpenWrt services to backup paths, including network, wireless, Dropbear, DDNS-Go, Nikki, MosDNS, Tailscale, and WireGuard.
- Create selected-item `.wrtbak` archives from the CLI or LuCI.
- Export selected backups as native `.sysupgrade.tar.gz` archives.
- Download generated archives through LuCI's authenticated `cgi-download` flow.
- Emit machine-readable maintenance status, readiness checks, backup dry runs, and restore plans for trusted remote operators.
- Configure WebDAV and S3-compatible remote backup targets from LuCI or UCI.
- Upload, list, prune, and delete remote backups through stable JSON CLI commands.
- Apply cron-based automatic backups using the selected remote target.

## Security Warning

OpenWrt configuration backups can contain sensitive information, including PPPoE credentials, DDNS tokens, WireGuard private keys, Nikki proxy configuration, Tailscale state, Dropbear keys, Wi-Fi passwords, SSH authorized keys, and other secrets.

Do not store real backups, device-specific secrets, or private restore archives in this public plugin repository. This repository should contain only source code, documentation, and non-secret examples.

## Documentation

- [Backup format](docs/BACKUP_FORMAT.md)
- [Agent maintenance runbook](docs/AGENT_MAINTENANCE.md)
- [OpenWrt CI integration](docs/OPENWRT_CI_INTEGRATION.md)
- [Development notes](docs/DEVELOPMENT.md)
- [Roadmap](docs/ROADMAP.md)
