# Development

This repository contains the public documentation, non-secret examples, and the initial OpenWrt package skeleton for `luci-app-wrtbak`.

## Repository Structure

```text
.
├── README.md
├── LICENSE
├── Makefile
├── .github/
│   └── workflows/
│       ├── build-package.yml
│       └── lint.yml
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

## Local Lint Workflow

The GitHub Actions lint workflow is intentionally reproducible with local commands.

Check shell syntax:

```sh
sh -n root/usr/bin/wrtbak root/usr/lib/wrtbak/*.sh tests/test_cli_fixture.sh
for script in root/usr/bin/wrtbak root/usr/lib/wrtbak/*.sh tests/test_cli_fixture.sh; do
  sh -n "$script"
done
```

If BusyBox is installed, also check with `ash`:

```sh
if command -v busybox >/dev/null 2>&1; then
  busybox ash -n root/usr/bin/wrtbak root/usr/lib/wrtbak/*.sh tests/test_cli_fixture.sh
  for script in root/usr/bin/wrtbak root/usr/lib/wrtbak/*.sh tests/test_cli_fixture.sh; do
    busybox ash -n "$script"
  done
fi
```

Validate all example manifests:

```sh
for manifest in examples/*/manifest.json; do
  python3 -m json.tool "$manifest" >/dev/null
done
```

Run the fixture test:

```sh
sh tests/test_cli_fixture.sh
```

Scan for sensitive-looking values:

```sh
matches=$(mktemp)
if git grep -nIE \
  -e 'BEGIN[[:space:]]+OPENSSH' \
  -e 'PRIVATE[[:space:]]+KEY' \
  -e '(^|[^[:alnum:]_])hskey-[[:alnum:]_-]{8,}' \
  -e '(^|[^[:alnum:]_])tskey-[[:alnum:]_-]{8,}' \
  -e '(^|[^[:alnum:]_])(token|password)[[:space:]]*=[[:space:]]*[^[:space:];#<>]{4,}' \
  -e 'AAAAC3NzaC1lZDI1NTE5[[:alnum:]+/_=-]{3,}' \
  -- . >"$matches"; then
  cat "$matches" >&2
  exit 1
else
  status=$?
  rm -f "$matches"
  test "$status" -eq 1
fi
```

## GitHub Actions Artifacts

`build-package.yml` currently runs a reliable `package-layout` job rather than pretending to produce installable OpenWrt packages before the SDK target and feed integration are finalized.

The workflow uploads:

- `luci-app-wrtbak-package-source`: a `git archive` source tarball for the package repository.
- `luci-app-wrtbak-logs`: package layout logs, source checksum, and source archive contents.

Future SDK or package-builder work should replace the experimental TODO job with a real build and upload `luci-app-wrtbak-ipk` and/or `luci-app-wrtbak-apk` artifacts.

## Security Notes

Keep this repository free of real backup archives and device secrets. Example files should use placeholder metadata only.
