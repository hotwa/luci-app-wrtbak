# Backup Format

This document defines the archive formats used by `luci-app-wrtbak`.

## `.wrtbak`

A `.wrtbak` file is a gzip-compressed tar archive.

Required top-level entries:

- `manifest.json`: machine-readable metadata for the backup.
- `README.txt`: human-readable restore notes and safety warnings.
- `rootfs/`: directory containing root filesystem paths captured by the backup.

Files below `rootfs/` map to absolute OpenWrt filesystem paths during restore. For example, `rootfs/etc/config/network` represents `/etc/config/network` on the target device.

### Tar Entry Rules

All `.wrtbak` tar member names MUST be relative, normalized POSIX paths.

The archive MUST NOT contain:

- Absolute paths, including paths beginning with `/`.
- Parent directory traversal, including any `..` path segment.
- Symlinks.
- Hardlinks.
- Character or block device nodes.
- FIFOs.
- Sockets.

Only regular files and directories are valid backup content. Restore implementations should reject archives that violate these rules before writing any file to disk.

## `manifest.json`

`manifest.json` describes the backup profile, source device, firmware, restore behavior, and file inventory. The current manifest schema is `wrtbak/v1`.

### `wrtbak/v1` Manifest Schema

The manifest MUST be valid JSON encoded as UTF-8.

Required top-level fields:

| Field | Type | Description |
| --- | --- | --- |
| `schema` | string | MUST be `wrtbak/v1`. |
| `profile` | string | Stable profile identifier, such as `office-ax6600`. |
| `backup_id` | string | Unique backup identifier. A timestamped, profile-prefixed value is recommended. |
| `created_at` | string | Backup creation time in RFC 3339 / ISO 8601 UTC form, such as `2026-06-24T00:00:00Z`. |
| `tool_version` | string | Version of the wrtbak tool that created the manifest. |
| `device` | object | Source device metadata. See required device fields below. |
| `firmware` | object | Source firmware metadata. |
| `restore` | object | Restore policy hints. See required restore fields below. |
| `files` | array | File inventory for content under `rootfs/`. |

Required `device` fields:

| Field | Type | Description |
| --- | --- | --- |
| `label` | string | Human-readable device label. |
| `hostname` | string | Source device hostname. |
| `management_ip` | string | Example or source management IP address. Public examples should use documentation ranges, not private deployment details. |
| `market_model` | string | Retail or market-facing model name. |
| `board_model` | string | OpenWrt board model string when known. |
| `board_name` | string | OpenWrt board name, such as `xiaomi,ax1800`. |
| `target` | string | OpenWrt target/subtarget, such as `qualcommax/ipq60xx`. |
| `arch` | string | OpenWrt package architecture, such as `aarch64_cortex-a53`. |

Required `firmware` fields:

| Field | Type | Description |
| --- | --- | --- |
| `distribution` | string | Firmware distribution name, usually `OpenWrt`. |
| `version` | string | Firmware version. |
| `revision` | string | Build revision or placeholder value for examples. |
| `kernel` | string | Kernel major/minor version or full kernel release if known. |

Required `restore` fields:

| Field | Type | Description |
| --- | --- | --- |
| `default_mode` | string | Suggested restore mode, such as `review-required`. |
| `restart_services` | array of strings | Services that should be restarted after restore when a reboot is not performed. |
| `reboot_recommended` | boolean | Whether a reboot is recommended after restore. |
| `requires_confirmation` | boolean | Whether tooling must require explicit user confirmation before restore. |

`files[]` entries describe archive content stored below `rootfs/`. Each entry MUST be an object.

Required fields for every `files[]` entry:

| Field | Type | Description |
| --- | --- | --- |
| `path` | string | Absolute target path on the router, such as `/etc/config/network`. |
| `archive_path` | string | Relative path inside the `.wrtbak` archive. It MUST begin with `rootfs/`, such as `rootfs/etc/config/network`. |
| `type` | string | Entry type. For v1 backup content this MUST be `file` or `directory`. |
| `mode` | string | Octal permission string, such as `0600` or `0755`. |

Additional required fields for regular file entries:

| Field | Type | Description |
| --- | --- | --- |
| `size` | integer | File size in bytes. |
| `sha256` | string | SHA-256 digest of the file content. |

Optional fields for `files[]` entries:

| Field | Type | Description |
| --- | --- | --- |
| `service_hints` | array of strings | Optional services affected by this file. |

Optional top-level fields MAY be added for non-security-critical metadata, such as `notes`, `tags`, or UI display hints. Restore implementations MUST NOT require unknown optional fields to be present.

An empty `files` array is only valid for public examples or draft archives that do not contain backup content. Real backups SHOULD list every regular file captured under `rootfs/`, and SHOULD include size, mode, and SHA-256 metadata for each regular file.

### Version Evolution

Manifest schemas use the `wrtbak/vN` string form. Backward-incompatible schema changes MUST increment `N`, for example from `wrtbak/v1` to `wrtbak/v2`.

Within `wrtbak/v1`, producers MAY add optional fields, but MUST keep existing required fields and their types stable. Consumers SHOULD ignore unknown optional fields, MUST reject manifests with unsupported `schema` values, and SHOULD reject manifests missing required fields before restore.

## `.sysupgrade.tar.gz`

A `.sysupgrade.tar.gz` export is a gzip-compressed tar archive compatible with OpenWrt's native backup restore layout. Paths are root-relative and are not nested under `rootfs/`.

For example, a sysupgrade archive may contain:

- `etc/config/network`
- `etc/config/system`
- `etc/backup/wrtbak-manifest.json`

The optional `etc/backup/wrtbak-manifest.json` file can preserve wrtbak metadata for humans or wrtbak-aware tools after export.

Native `sysupgrade -r` restores files from a sysupgrade archive, but it does not validate wrtbak metadata. Any device, firmware, profile, or schema checks must be performed by wrtbak-aware tooling before invoking native restore commands.
