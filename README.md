# luci-app-wrtbak

`luci-app-wrtbak` is intended to provide a LuCI app for profile-based OpenWrt configuration backup and restore archives.

The project defines a `.wrtbak` archive format for portable, profile-aware backups. A `.wrtbak` file is a gzip-compressed tar archive containing at least:

- `manifest.json`
- `README.txt`
- `rootfs/`

Archives may also be exported as OpenWrt-compatible `.sysupgrade.tar.gz` files for restore flows that use native OpenWrt tooling.

## Security Warning

OpenWrt configuration backups can contain sensitive information, including PPPoE credentials, DDNS tokens, WireGuard private keys, Nikki proxy configuration, Tailscale state, Dropbear keys, Wi-Fi passwords, SSH authorized keys, and other secrets.

Do not store real backups, device-specific secrets, or private restore archives in this public plugin repository. This repository should contain only source code, documentation, and non-secret examples.

## Documentation

- [Backup format](docs/BACKUP_FORMAT.md)
- [OpenWrt CI integration](docs/OPENWRT_CI_INTEGRATION.md)
- [Development notes](docs/DEVELOPMENT.md)
- [Roadmap](docs/ROADMAP.md)
