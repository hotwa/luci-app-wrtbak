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
│   ├── AGENT_MAINTENANCE.md
│   ├── DEVELOPMENT.md
│   ├── OPENWRT_CI_INTEGRATION.md
│   ├── superpowers/plans/
│   └── ROADMAP.md
├── root/
│   ├── etc/config/wrtbak
│   ├── share/luci/menu.d/luci-app-wrtbak.json
│   ├── share/rpcd/acl.d/luci-app-wrtbak.json
│   └── usr/
│       ├── bin/wrtbak
│       └── lib/wrtbak/
│           ├── backup.sh
│           ├── agent.sh
│           ├── common.sh
│           ├── items.sh
│           ├── manifest.sh
│           ├── pack.sh
│           ├── web.sh
│           └── paths.default
├── htdocs/
│   └── luci-static/resources/view/wrtbak/index.js
├── tests/
│   ├── test_cli_fixture.sh
│   ├── test_detect_fixture.sh
│   ├── test_agent_plan_fixture.sh
│   ├── test_agent_status_fixture.sh
│   ├── test_restore_plan_fixture.sh
│   ├── test_luci_layout.sh
│   └── test_web_create_fixture.sh
└── examples/
    ├── dorm-ax1800/
    │   └── manifest.json
    ├── office-ax6600/
    │   └── manifest.json
    └── test-ax1800/
        └── manifest.json
```

The current package provides a shell CLI for archive creation, inspection, installed package detection, selected-item archive generation, LuCI-triggered downloads, `.sysupgrade.tar.gz` export, and read-only agent maintenance planning. Restore planning exists, but automatic restore writes are intentionally not implemented yet.

## Runtime Assumptions

The CLI currently expects standard OpenWrt/BusyBox tools to be available:

- `tar` with gzip support, or `tar` plus gzip integration used by `tar -czf` and `tar tzf`.
- `sha256sum` for regular file digests.
- `stat -c` for file mode and size metadata.
- `find`, `sort`, `awk`, `sed`, and `grep`.
- `jsonfilter` for OpenWrt metadata lookup and strict `restore-plan` manifest validation.

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
sh -n root/usr/bin/wrtbak root/usr/lib/wrtbak/*.sh tests/*.sh
```

Run the local fixture test:

```sh
for test_script in tests/*.sh; do
  sh "$test_script"
done
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
for test_script in tests/*.sh; do
  sh "$test_script"
done
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

`build-package.yml` always runs a reliable `package-layout` job. On manual `workflow_dispatch`, it also runs an OpenWrt SDK build through the official `openwrt/gh-action-sdk` action.

The layout job uploads:

- `luci-app-wrtbak-package-source`: a `git archive` source tarball for the package repository.
- `luci-app-wrtbak-logs`: package layout logs, source checksum, and source archive contents.

The SDK job is manual so normal documentation pushes stay cheap. Default inputs are:

- `arch`: `aarch64_cortex-a53`
- `packages`: `luci-app-wrtbak`
- `container`: `openwrt/sdk`

The package repository keeps its OpenWrt `Makefile` at the repository root so `hotwa/OpenWRT-CI` can clone it directly into `wrt/package/luci-app-wrtbak`. The SDK workflow stages a temporary feed at `.sdk-feed/luci-app-wrtbak/` before invoking `openwrt/gh-action-sdk`, because OpenWrt feeds expect packages in subdirectories.

The SDK job uploads:

- `luci-app-wrtbak-sdk-<arch>`: installable `luci-app-wrtbak` `.ipk` and/or `.apk` packages plus generated indexes from the `wrtbak` feed.
- `luci-app-wrtbak-sdk-logs-<arch>`: SDK build logs and package feed metadata.

## Security Notes

Keep this repository free of real backup archives and device secrets. Example files should use placeholder metadata only.
