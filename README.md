# luci-app-wrtbak

`luci-app-wrtbak` is intended to provide a LuCI app for profile-based OpenWrt configuration backup and restore archives.

The project defines a `.wrtbak` archive format for portable, profile-aware backups. A `.wrtbak` file is a gzip-compressed tar archive containing at least:

- `manifest.json`
- `README.txt`
- `rootfs/`

Archives may also be exported as OpenWrt-compatible `.sysupgrade.tar.gz` files for restore flows that use native OpenWrt tooling.

Current capabilities:

- Detect installed `luci-app-*` packages from `apk` or `opkg`.
- Map known OpenWrt services to backup paths, including network, firewall extras, wireless, Dropbear, DDNS-Go, Nikki, MosDNS, Tailscale, and WireGuard.
- Create selected-item `.wrtbak` archives from the CLI or LuCI.
- Export selected backups as native `.sysupgrade.tar.gz` archives.
- Download generated archives through LuCI's authenticated `cgi-download` flow.
- Emit machine-readable maintenance status, readiness checks, backup dry runs, and restore plans for trusted remote operators.
- Configure WebDAV and S3-compatible remote backup targets from LuCI or UCI.
- Upload, list, prune, and delete remote backups through stable JSON CLI commands.
- Apply cron-based automatic backups using the selected remote target.
- Download remote backups into a local restore cache, review restore plans, create mandatory pre-restore backups, and apply confirmed `.wrtbak` restores.
- Preflight or execute native `.sysupgrade.tar.gz` restores through OpenWrt `sysupgrade -r` after confirmation.
- On first boot after a factory reset, list and download R2 restore candidates without using the local transparent proxy. This keeps cloud restore usable before Nikki/DAE has been restored.
- Run an opt-in firstboot auto-restore orchestrator that waits for route, DNS, and time readiness, selects the latest current-device R2 `.wrtbak`, creates a pre-restore backup, applies the restore, writes a done marker, and optionally reboots.
- Review, apply, health-check, and roll back cloud-published Nikki/DAE proxy artifacts such as `final.yaml` and `final.dae`.

## Security Warning

OpenWrt configuration backups can contain sensitive information, including PPPoE credentials, firewall scripts and nftables snippets, DDNS tokens, WireGuard private keys, Nikki proxy configuration, Tailscale state, Dropbear keys, Wi-Fi passwords, SSH authorized keys, and other secrets.

Do not store real backups, device-specific secrets, or private restore archives in this public plugin repository. This repository should contain only source code, documentation, and non-secret examples.

## Documentation

- [Backup format](docs/BACKUP_FORMAT.md)
- [Agent maintenance runbook](docs/AGENT_MAINTENANCE.md)
- [OpenWrt CI integration](docs/OPENWRT_CI_INTEGRATION.md)
- [Development notes](docs/DEVELOPMENT.md)
- [Roadmap](docs/ROADMAP.md)
