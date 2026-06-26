# Agent Maintenance Runbook

This document describes the read-only commands that a trusted remote operator, such as Codex, can use before creating or restoring OpenWrt backups.

These commands are designed to be safe over SSH because they print metadata and plans only. They do not print configuration file contents, and `restore-plan` never writes files to the router root filesystem.

## Health Snapshot

Use `status` first to identify the router, package manager, detected backup items, and recent generated archives:

```sh
ssh root@192.168.11.234 'wrtbak status --json'
```

Useful fields:

- `device.hostname`
- `device.management_ip`
- `firmware.target`
- `package_manager`
- `counts.detected_items`
- `counts.installed_items`
- `recent_backups`

## Readiness Check

Use `doctor` before asking the router to create an archive:

```sh
ssh root@192.168.11.234 'wrtbak doctor --json'
```

The command checks whether wrtbak libraries, the path catalog, output directory, package manager, and required archive tools are available. A maintenance agent should stop and report the failed `checks[]` entry when `ok` is false.

## Backup Dry Run

Use `plan` before creating a backup:

```sh
ssh root@192.168.11.234 \
  'wrtbak plan --profile test-ax1800 --items core-system,network,wireless,dropbear,mosdns,nikki,tailscale,wireguard --format wrtbak --json'
```

For the router's default selected backup set, use `--items all`:

```sh
ssh root@192.168.11.234 \
  'wrtbak plan --profile test-ax1800 --items all --format wrtbak --json'
```

The plan reports:

- requested backup items
- paths that would be scanned
- missing paths that will be skipped
- sensitive items that may contain credentials, private keys, tokens, or runtime identity state
- restart service hints

The plan intentionally does not include file contents.

## Create Downloadable Archive

After reviewing the plan, create an archive for browser download or SCP collection:

```sh
ssh root@192.168.11.234 \
  'wrtbak create-download --profile test-ax1800 --items core-system,network,wireless,dropbear,mosdns,nikki,tailscale,wireguard --format wrtbak'
```

For native OpenWrt restore flows, request a sysupgrade-compatible archive:

```sh
ssh root@192.168.11.234 \
  'wrtbak create-download --profile test-ax1800 --items core-system,network,wireless,dropbear,mosdns,nikki,tailscale,wireguard --format sysupgrade'
```

The JSON response includes `path`, `filename`, `format`, and `size`.

## Restore Review

Before any restore, inspect the archive:

```sh
ssh root@192.168.11.234 'wrtbak restore-plan --input /tmp/wrtbak/test-ax1800-20260625T000000Z.wrtbak --json'
```

The restore plan reports the manifest identity, file counts, total bytes, restart services, reboot recommendation, confirmation requirement, and every target path in the archive.

This command is read-only. It extracts into a temporary directory, validates tar member safety, reads `manifest.json`, and deletes temporary files when it exits.

## Confirmed Restore Flow

Remote restore is intentionally gated. A maintenance agent must not apply a restore until the operator has approved the target archive, reviewed the plan, created a fresh pre-restore backup, and confirmed the exact token `RESTORE`.

Download a remote archive into the restore cache:

```sh
ssh root@192.168.11.234 \
  'wrtbak remote-download --target webdav --path REMOTE_PATH --json'
```

Review the local archive:

```sh
ssh root@192.168.11.234 \
  'wrtbak restore-prepare --input /tmp/wrtbak/restore-cache/CACHED.wrtbak --json'
```

Create the mandatory local rollback point:

```sh
ssh root@192.168.11.234 \
  'wrtbak restore-prebackup --profile pre-restore --items all --format wrtbak --json'
```

Apply a `.wrtbak` archive only after approval:

```sh
ssh root@192.168.11.234 \
  'wrtbak restore-apply --input /tmp/wrtbak/restore-cache/CACHED.wrtbak --mode selected --items core-system --prebackup /tmp/wrtbak/pre-restore-YYYYMMDDTHHMMSSZ.wrtbak --confirm RESTORE --restart-services 0 --json'
```

For native sysupgrade archives, run a preflight first:

```sh
ssh root@192.168.11.234 \
  'wrtbak restore-sysupgrade --input /tmp/wrtbak/restore-cache/CACHED.sysupgrade.tar.gz --prebackup /tmp/wrtbak/pre-restore-YYYYMMDDTHHMMSSZ.wrtbak --confirm RESTORE --execute 0 --json'
```

Only after the preflight is accepted, execute native restore:

```sh
ssh root@192.168.11.234 \
  'wrtbak restore-sysupgrade --input /tmp/wrtbak/restore-cache/CACHED.sysupgrade.tar.gz --prebackup /tmp/wrtbak/pre-restore-YYYYMMDDTHHMMSSZ.wrtbak --confirm RESTORE --execute 1 --json'
```

`restore-sysupgrade --execute 1` invokes `sysupgrade -r` and can interrupt the management connection before JSON returns. Treat a dropped SSH/LuCI session as an unknown handoff state until the router is reachable again.

After restoring network, wireless, Dropbear, Tailscale, WireGuard, DNS, or proxy configuration, prefer a full reboot unless the operator explicitly asks for a service-only restart. Network-related restores can interrupt SSH, LuCI, and tailnet connectivity.

## Agent Rules

- Run `doctor --json` before creating archives.
- Run `plan --json` before `create` or `create-download`.
- Run `restore-prepare --json` before any restore apply.
- Always create `restore-prebackup --json` immediately before `restore-apply` or `restore-sysupgrade`.
- Treat `sensitive_item` warnings as expected for network, Dropbear, proxy, VPN, Tailscale, and DDNS backups.
- Do not copy real `.wrtbak` or `.sysupgrade.tar.gz` files into a public repository.
- Do not run `restore-apply`, `restore-sysupgrade --execute 1`, or raw `sysupgrade -r` without explicit human confirmation.
- Ask before restoring high-risk network, firewall, SSH, Tailscale, WireGuard, Nikki, MosDNS, DDNS, or proxy configuration.
