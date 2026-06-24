# Development

This repository contains the public documentation, non-secret examples, and the initial OpenWrt package skeleton for `luci-app-wrtbak`.

## Repository Structure

```text
.
├── README.md
├── LICENSE
├── Makefile
├── docs/
│   ├── BACKUP_FORMAT.md
│   ├── DEVELOPMENT.md
│   ├── OPENWRT_CI_INTEGRATION.md
│   └── ROADMAP.md
├── root/
│   ├── etc/config/wrtbak
│   └── usr/
│       ├── bin/wrtbak
│       └── lib/wrtbak/
│           ├── backup.sh
│           ├── common.sh
│           ├── manifest.sh
│           ├── pack.sh
│           └── paths.default
├── tests/
│   └── test_cli_fixture.sh
└── examples/
    ├── dorm-ax1800/
    │   └── manifest.json
    ├── office-ax6600/
    │   └── manifest.json
    └── test-ax1800/
        └── manifest.json
```

The current package skeleton provides a shell CLI for archive creation, inspection, and `.sysupgrade.tar.gz` export. LuCI views, rpcd/ubus handlers, and restore flows are intentionally not implemented yet.

## Runtime Assumptions

The CLI currently expects standard OpenWrt/BusyBox tools to be available:

- `tar` with gzip support, or `tar` plus gzip integration used by `tar -czf` and `tar tzf`.
- `sha256sum` for regular file digests.
- `stat -c` for file mode and size metadata.
- `find`, `sort`, `awk`, `sed`, and `grep`.

The package `Makefile` does not add explicit `tar` or `gzip` dependencies because OpenWrt package names vary by build profile and BusyBox configuration. Ensure target images include working tar/gzip support before relying on archive creation or export.

## Basic Checks

Validate example manifests:

```sh
python3 -m json.tool examples/office-ax6600/manifest.json >/dev/null
python3 -m json.tool examples/dorm-ax1800/manifest.json >/dev/null
python3 -m json.tool examples/test-ax1800/manifest.json >/dev/null
```

Confirm required documentation exists:

```sh
ls README.md LICENSE .gitignore docs/BACKUP_FORMAT.md docs/OPENWRT_CI_INTEGRATION.md docs/DEVELOPMENT.md docs/ROADMAP.md
```

Review ignored archive patterns before adding generated files:

```sh
git check-ignore -v example.wrtbak example.sysupgrade.tar.gz package.ipk package.apk
```

Check shell syntax:

```sh
sh -n root/usr/bin/wrtbak root/usr/lib/wrtbak/common.sh root/usr/lib/wrtbak/manifest.sh root/usr/lib/wrtbak/backup.sh root/usr/lib/wrtbak/pack.sh tests/test_cli_fixture.sh
```

Run the local fixture test:

```sh
sh tests/test_cli_fixture.sh
```

## Security Notes

Keep this repository free of real backup archives and device secrets. Example files should use placeholder metadata only.
