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

`manifest.json` describes the backup profile, source device, firmware, restore behavior, and file inventory. The exact schema may evolve, but every manifest should include enough metadata for a restore UI or CLI to warn about device or firmware mismatches before applying files.

## `.sysupgrade.tar.gz`

A `.sysupgrade.tar.gz` export is a gzip-compressed tar archive compatible with OpenWrt's native backup restore layout. Paths are root-relative and are not nested under `rootfs/`.

For example, a sysupgrade archive may contain:

- `etc/config/network`
- `etc/config/system`
- `etc/backup/wrtbak-manifest.json`

The optional `etc/backup/wrtbak-manifest.json` file can preserve wrtbak metadata for humans or wrtbak-aware tools after export.

Native `sysupgrade -r` restores files from a sysupgrade archive, but it does not validate wrtbak metadata. Any device, firmware, profile, or schema checks must be performed by wrtbak-aware tooling before invoking native restore commands.

