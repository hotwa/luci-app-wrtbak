# Development

This repository contains the public documentation and non-secret examples for `luci-app-wrtbak`. Package source will be added as the OpenWrt package skeleton is implemented.

## Repository Structure

```text
.
├── README.md
├── LICENSE
├── docs/
│   ├── BACKUP_FORMAT.md
│   ├── DEVELOPMENT.md
│   ├── OPENWRT_CI_INTEGRATION.md
│   └── ROADMAP.md
└── examples/
    ├── dorm-ax1800/
    │   └── manifest.json
    ├── office-ax6600/
    │   └── manifest.json
    └── test-ax1800/
        └── manifest.json
```

Future package code should follow normal OpenWrt package conventions, including a package `Makefile`, LuCI assets, rpcd/ubus handlers, and shell or Lua helpers as they are implemented. The current docs/examples-only tree is not yet buildable as an OpenWrt package.

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

## Security Notes

Keep this repository free of real backup archives and device secrets. Example files should use placeholder metadata only.
