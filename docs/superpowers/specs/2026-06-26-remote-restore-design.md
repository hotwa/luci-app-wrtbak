# Remote Restore Design

## Goal

Add safe WebDAV and S3 remote restore support to `luci-app-wrtbak`.

The feature lets an OpenWrt operator list remote backups, download a selected backup to a local restore cache, inspect it, review a machine-readable restore plan, create a pre-restore backup of the current router state, and then explicitly confirm an apply step.

The selected v1 approach is **confirmed restore**:

1. Download from WebDAV or S3.
2. Generate and display a restore plan.
3. Force a pre-restore backup before any write.
4. Require an explicit confirmation token before applying.
5. Restart affected services or recommend a reboot after the apply step.

## Non-Goals

- Do not silently restore remote backups.
- Do not restore without first creating a pre-restore backup.
- Do not commit real WebDAV, S3, router, or backup secrets to this repository.
- Do not implement cross-device automatic restore in v1.
- Do not implement background restore queues in v1.
- Do not guarantee that network, SSH, Tailscale, or WireGuard restores keep the current management session alive.
- Do not replace OpenWrt's native `sysupgrade -r` behavior for `.sysupgrade.tar.gz` archives.

## Existing Foundation

The current package already provides:

- `.wrtbak` archive creation.
- `.sysupgrade.tar.gz` export.
- `inspect FILE`.
- `restore-plan --input FILE --json`, which is read-only.
- WebDAV/S3 `remote-test`, `remote-upload`, `remote-list`, `remote-delete`, and `remote-prune`.
- LuCI remote storage configuration and remote backup management.

Remote restore extends those pieces instead of rewriting them.

## User Experience

LuCI adds restore actions to the existing remote backup table:

- `Restore` on each remote `.wrtbak` backup.
- `Restore via sysupgrade` on each remote `.sysupgrade.tar.gz` backup.
- A restore review panel below the remote table.

The restore review panel shows:

- target name and driver
- remote path
- downloaded local path
- archive format
- archive size
- manifest schema
- source device ID, hostname, board, and firmware metadata when present
- current device ID
- compatibility warnings
- files that would be written
- sensitive item warnings
- services that should restart
- whether a reboot is recommended
- pre-restore backup result

The dangerous apply action is disabled until:

- the archive has been downloaded successfully
- `restore-plan --json` has succeeded
- the pre-restore backup has succeeded
- the user enters `RESTORE`

After apply, LuCI displays:

- written file count
- skipped file count
- pre-restore backup path
- restart services
- reboot recommendation
- restore log path

## CLI Commands

### `remote-download`

```sh
wrtbak remote-download --target default|webdav|s3 --path REMOTE_PATH --json
```

Downloads a remote backup under the current device prefix into:

```text
/tmp/wrtbak/restore-cache/<safe-filename>
```

Rules:

- The selected target must be enabled and valid.
- The remote path must pass the same current-device-prefix validation used by `remote-delete`.
- The file suffix must be `.wrtbak` or `.sysupgrade.tar.gz`.
- The command acquires the remote operation lock before downloading.
- Cache filenames are deterministic: `<sha256(remote_path)-12>-<safe-basename>`.
- A sidecar file `<local_path>.remote.json` records `target`, `driver`, `remote_path`, `filename`, `format`, `size`, `remote_modified`, `remote_etag`, `downloaded_at`, and local `sha256`.
- Existing cache files may be reused only when the sidecar `target`, `remote_path`, and `size` match the current remote metadata and the local file sha256 still equals the sidecar sha256.
- If a driver exposes `remote_modified` or `remote_etag`, the matching sidecar value must also match for cache reuse.
- If a driver exposes neither `remote_modified` nor `remote_etag`, size plus local sha256 is sufficient because v1 cannot require remote content hashes from WebDAV/OpenList or generic S3 listings.
- Cache collision without a matching sidecar returns `ok:false` with `code:"cache_conflict"`.
- The command verifies local file size against the remote size.
- If the remote driver cannot determine size, v1 returns `ok:false` with `code:"size_unavailable"` instead of downloading.
- Partial downloads write to `<local_path>.part.$$` and are removed on failure.
- Successful downloads rename the partial file atomically, compute sha256, then write the sidecar atomically.
- The command writes a sanitized history record.

JSON success shape:

```json
{
  "ok": true,
  "operation": "remote-download",
  "target": "webdav",
  "driver": "curl",
  "remote_path": "R2/wrtbak/device/wrtbak/2026/backup.wrtbak",
  "local_path": "/tmp/wrtbak/restore-cache/abc123-backup.wrtbak",
  "sidecar_path": "/tmp/wrtbak/restore-cache/abc123-backup.wrtbak.remote.json",
  "filename": "backup.wrtbak",
  "format": "wrtbak",
  "size": 12345,
  "remote_modified": "Fri, 26 Jun 2026 03:30:00 GMT",
  "remote_etag": "",
  "sha256": "..."
}
```

### `restore-prepare`

```sh
wrtbak restore-prepare --input LOCAL_ARCHIVE --json
```

Runs all read-only checks needed before an apply:

- validates that the local path is under the restore cache or `/tmp/wrtbak`
- determines archive format from the filename and tar structure
- for `.wrtbak`, validates `manifest.json` and `rootfs/`, then runs the same validation as `restore-plan --json`
- for `.sysupgrade.tar.gz`, validates root-relative tar members and reads `etc/backup/wrtbak-manifest.json` when present
- computes compatibility warnings
- creates no writes to the live root filesystem

This command exists so LuCI can have a stable single command for the review step.

JSON success shape:

```json
{
  "ok": true,
  "operation": "restore-prepare",
  "input": "/tmp/wrtbak/restore-cache/abc-backup.wrtbak",
  "format": "wrtbak",
  "archive": {
    "filename": "backup.wrtbak",
    "size": 12345,
    "sha256": "..."
  },
  "current_device": {
    "device_id": "current-device",
    "hostname": "dae-wrt",
    "board": "jdcloud-re-ss-01",
    "firmware": "ImmortalWrt SNAPSHOT"
  },
  "source_device": {
    "device_id": "source-device",
    "hostname": "source",
    "board": "jdcloud-re-ss-01",
    "firmware": "ImmortalWrt SNAPSHOT"
  },
  "manifest": {
    "schema": "wrtbak/v1",
    "profile": "auto",
    "created_at": "2026-06-26T03:30:00Z"
  },
  "compatibility": {
    "blocking": false,
    "warnings": [
      {
        "code": "device_id_mismatch",
        "severity": "warning",
        "message": "Backup source device differs from current device."
      }
    ]
  },
  "plan": {
    "file_count": 12,
    "total_bytes": 34567,
    "paths": [
      {
        "path": "/etc/config/system",
        "archive_path": "rootfs/etc/config/system",
        "type": "file",
        "size": 456,
        "sha256": "...",
        "items": ["core-system"],
        "sensitive": false,
        "selected": true,
        "action": "write"
      }
    ],
    "restart_services": ["network"],
    "reboot_recommended": true,
    "requires_confirmation": true
  }
}
```

Sysupgrade prepare success shape differs because the archive is root-relative:

```json
{
  "ok": true,
  "operation": "restore-prepare",
  "input": "/tmp/wrtbak/restore-cache/abc-backup.sysupgrade.tar.gz",
  "format": "sysupgrade",
  "archive": {
    "filename": "backup.sysupgrade.tar.gz",
    "size": 12345,
    "sha256": "..."
  },
  "manifest": {
    "schema": "wrtbak/v1",
    "present": true,
    "path": "etc/backup/wrtbak-manifest.json"
  },
  "compatibility": {
    "blocking": false,
    "warnings": []
  },
  "plan": {
    "file_count": 12,
    "total_bytes": 34567,
    "paths": [
      {
        "path": "/etc/config/system",
        "archive_path": "etc/config/system",
        "type": "file",
        "size": 456,
        "sha256": "",
        "items": [],
        "sensitive": true,
        "selected": true,
        "action": "sysupgrade-restore"
      }
    ],
    "restart_services": [],
    "reboot_recommended": true,
    "requires_confirmation": true
  }
}
```

All command errors use the existing envelope:

```json
{
  "ok": false,
  "operation": "restore-prepare",
  "code": "invalid_archive",
  "message": "restore archive is not valid",
  "detail": "manifest.json is missing"
}
```

### `restore-prebackup`

```sh
wrtbak restore-prebackup --profile pre-restore --items all --format wrtbak --json
```

Creates a local pre-restore backup before the apply step.

Rules:

- Must run before `restore-apply`.
- Uses the current backup item catalog.
- Defaults to `.wrtbak`.
- May optionally upload to the default remote target in a later version, but v1 requires at least a local pre-restore archive.
- Returns `ok:false` when archive creation fails.

JSON success shape:

```json
{
  "ok": true,
  "operation": "restore-prebackup",
  "profile": "pre-restore",
  "items": "all",
  "format": "wrtbak",
  "path": "/tmp/wrtbak/pre-restore-20260626T033000Z.wrtbak",
  "filename": "pre-restore-20260626T033000Z.wrtbak",
  "size": 12345,
  "sha256": "...",
  "created_at": "2026-06-26T03:30:00Z",
  "receipt_path": "/tmp/wrtbak/pre-restore-20260626T033000Z.wrtbak.receipt.json"
}
```

The receipt contains the same fields plus `operation`, `host_device_id`, and `host_hostname`.
`restore-apply` and `restore-sysupgrade` must validate the receipt before any live write:

- receipt file exists
- receipt `path` equals `--prebackup`
- prebackup archive exists
- prebackup size and sha256 match the receipt
- receipt `host_device_id` equals the current device ID
- receipt age is less than 24 hours unless a later version adds an override
- receipt format is `wrtbak`

Failure returns `ok:false` with `code:"invalid_prebackup"`.

### `restore-apply`

```sh
wrtbak restore-apply --input LOCAL_ARCHIVE --mode all|selected --items IDS|all --prebackup LOCAL_ARCHIVE --confirm RESTORE [--restart-services 0|1] --json
```

Applies a reviewed `.wrtbak` archive.

Rules:

- Requires `--confirm RESTORE`.
- Requires `--prebackup` pointing to an existing local pre-restore backup.
- Requires a valid `restore-plan`.
- Requires the archive's manifest `restore.requires_confirmation` to be honored.
- Rejects unsupported manifest schemas.
- Rejects tar members outside `rootfs/`.
- Rejects symlinks, device nodes, hard links, FIFOs, sockets, and paths with `..`.
- Writes only regular files and directories.
- Preserves file mode from the archive when available.
- Creates parent directories as needed.
- Does not remove files that are absent from the archive.
- In `selected` mode, writes only files belonging to selected item IDs.
- In `all` mode, writes all files from the archive.
- Records a restore log under `/tmp/wrtbak/restore-logs/`.

Selected item mapping:

- The item catalog remains the source of truth for item ID to path mapping.
- For each selected item ID, collect its configured files and directories from the current catalog.
- Unknown item IDs are blocking and return `code:"invalid_items"`.
- A restored archive file is eligible when its target path exactly equals a selected file path or is below a selected directory path.
- Overlapping items are de-duplicated by final target path before validation or writing.
- When an item path in the current catalog is absent from the archive, it is reported as `missing_from_archive` but does not fail the restore.
- Files present in the archive but not selected are skipped and reported as skipped.
- Directory selections include regular files recursively and create needed directories.

Write-phase safety:

- All archive validation completes before the first live write.
- The extracted archive file size and sha256 must match `manifest.files[]` when the manifest provides those fields.
- Any mismatch returns `code:"archive_mismatch"` and writes nothing.
- The writer copies each file to `<target>.wrtbak-restore.$$`, fsyncs when supported, chmods, then renames into place.
- A per-file backup of the previous file is written under the restore log directory before replacement when the previous target exists.
- If any write fails, the command stops, reports `ok:false`, includes `written_count`, `failed_path`, and `restore_log`, and does not attempt automatic rollback in v1.
- The restore log is line-delimited JSON with `timestamp`, `operation`, `target_path`, `status`, `source_path`, `mode`, and optional `error`.

JSON success shape:

```json
{
  "ok": true,
  "operation": "restore-apply",
  "input": "/tmp/wrtbak/restore-cache/abc-backup.wrtbak",
  "mode": "selected",
  "items": "test-restore",
  "written_count": 2,
  "skipped_count": 10,
  "prebackup_path": "/tmp/wrtbak/pre-restore-20260626T033000Z.wrtbak",
  "restore_log": "/tmp/wrtbak/restore-logs/restore-20260626T033100Z.jsonl",
  "restart_services": [],
  "reboot_recommended": false
}
```

Service handling:

- The command returns the services recommended by the manifest.
- By default it does not reboot.
- It may restart non-network services automatically only when `--restart-services 1` is provided.
- It does not automatically restart `network`, `firewall`, `dropbear`, `tailscale`, `wireguard`, `nikki`, or `mosdns` in v1 unless LuCI or the CLI call explicitly asks for service restart.
- When high-risk services are present, the JSON must include `reboot_recommended:true`.

### `restore-sysupgrade`

```sh
wrtbak restore-sysupgrade --input LOCAL_ARCHIVE --prebackup LOCAL_ARCHIVE --confirm RESTORE [--execute 0|1] --json
```

Applies a downloaded `.sysupgrade.tar.gz` archive through OpenWrt native restore.

Rules:

- Requires `--confirm RESTORE`.
- Requires an existing pre-restore backup.
- Validates the prebackup receipt the same way as `restore-apply`.
- Runs sysupgrade-specific `tar tzf` safety validation before invoking `sysupgrade -r`.
- Does not attempt file-level selective restore.
- Prints a JSON preflight result and exits unless `--execute 1` is provided.
- With `--execute 1`, invokes `sysupgrade -r LOCAL_ARCHIVE` after printing the preflight JSON.
- LuCI must warn that the current management session can be interrupted.

Sysupgrade validation:

- Tar members are root-relative.
- Reject absolute paths, `..`, symlinks, hard links, devices, FIFOs, and sockets.
- Allow regular files and directories only.
- If `etc/backup/wrtbak-manifest.json` exists, validate schema and compatibility warnings.
- If no wrtbak manifest exists, allow native restore only with a visible `manifest_missing` warning.
- `.wrtbak` archives are rejected by `restore-sysupgrade`; `.sysupgrade.tar.gz` archives are rejected by `restore-apply`.

## Remote Driver Additions

WebDAV driver adds:

- `wrtbak_webdav_download_file URL USER PASS REMOTE_PATH LOCAL_PATH`
- size verification using `PROPFIND` when possible

S3 driver adds:

- `wrtbak_s3_download_file ENDPOINT REGION BUCKET ACCESS SECRET FORCE_PATH_STYLE REMOTE_PATH LOCAL_PATH`
- size verification using `rclone size` or `lsjson`

Driver rules:

- Credentials must stay in temporary `0600` files or stdin-safe config files.
- Credentials must never appear in command arguments, history JSONL, LuCI output, or test fixtures.
- Partial downloads must write to `LOCAL_PATH.part.$$` and rename atomically only after verification.

## Restore Safety Model

Remote restore has four gates:

1. **Path gate**: remote path must be under the current device prefix.
2. **Plan gate**: `restore-plan` must parse and validate the archive.
3. **Prebackup gate**: a current-state backup must exist before apply.
4. **Confirmation gate**: apply requires exact confirmation token `RESTORE`.

Failure at any gate returns `ok:false` and does not write live configuration files.

Compatibility warnings do not always block apply. They are blocking only when:

- manifest schema is unsupported
- archive safety validation fails
- selected items are unknown
- required confirmation is missing
- prebackup is missing

They are non-blocking but visible when:

- source device ID differs from current device ID
- board model differs
- firmware version differs
- backup includes high-risk network or remote-access configuration

## LuCI Changes

Add restore controls to `htdocs/luci-static/resources/view/wrtbak/index.js`:

- remote backup table row action: `RESTORE`
- restore review panel
- confirmation input
- pre-restore backup button
- apply restore button
- sysupgrade restore button for `.sysupgrade.tar.gz`

LuCI must call stable JSON commands only:

- `remote-download`
- `restore-prepare`
- `restore-prebackup`
- `restore-apply`
- `restore-sysupgrade`

LuCI must not show secret file contents. It may show paths, counts, service names, manifest metadata, and warnings.

LuCI state transitions:

1. `idle`
2. `downloading`
3. `prepared`
4. `prebackup_ready`
5. `applying`
6. `applied` or `failed`

The UI must not enable apply buttons outside `prebackup_ready`.
Refreshing the remote list resets the restore panel to `idle`.

Server-side enforcement remains authoritative. Even if a LuCI button is enabled incorrectly, `restore-apply` and `restore-sysupgrade` must reject missing confirmation, invalid prebackup receipts, invalid paths, and unsafe archives.

## ACL Changes

`root/usr/share/rpcd/acl.d/luci-app-wrtbak.json` must allow:

Read-only exec permissions:

- `/usr/bin/wrtbak remote-download *`
- `/usr/bin/wrtbak restore-prepare *`

Write exec permissions:

- `/usr/bin/wrtbak restore-prebackup *`
- `/usr/bin/wrtbak restore-apply *`
- `/usr/bin/wrtbak restore-sysupgrade *`

The existing broad read/stat ACL for `/tmp/wrtbak/*` must be narrowed.
LuCI download still needs read/stat for generated local archives, but restore cache sidecars should not be directly browsable.
Replace `/tmp/wrtbak/*` with explicit patterns for generated downloadable archives and avoid granting direct file ACLs for `/tmp/wrtbak/restore-cache/*`.
LuCI interacts with cache files only through `wrtbak` commands.
`tests/test_luci_layout.sh` must assert that the broad `/tmp/wrtbak/*` ACL is absent.

## Testing Strategy

Local fixture tests:

- fake WebDAV download succeeds and verifies size
- fake WebDAV partial download cleanup on failure
- fake S3 download succeeds and verifies size
- credentials do not leak into command arguments
- `remote-download` rejects paths outside the current device prefix
- `remote-download` rejects cache collision without matching sidecar
- `remote-download` rejects unavailable remote size
- `remote-download` cache reuse accepts size plus local sha256 when remote hash is unavailable
- `remote-download` cache reuse checks `remote_modified` or `remote_etag` when a driver provides them
- every new command returns the standard JSON error envelope
- `restore-prepare` returns plan JSON for a valid `.wrtbak`
- `restore-prepare` emits concrete `plan.paths[]` entries
- `restore-prepare` returns sysupgrade metadata and warnings for a valid `.sysupgrade.tar.gz`
- `restore-apply` parses and honors `--restart-services 0|1`
- `restore-apply` rejects missing confirmation
- `restore-apply` rejects missing prebackup
- `restore-apply` rejects stale, unrelated, or sha-mismatched prebackup receipts
- `restore-apply` rejects unsafe tar members
- `restore-apply` rejects manifest file size or sha mismatch before writing
- `restore-apply --mode selected` writes only selected item paths
- `restore-apply --mode selected` de-duplicates overlapping selected item paths
- `restore-apply --mode all` writes all archive paths
- `restore-apply` reports mid-apply failure with log path and written count
- `restore-sysupgrade` rejects non-sysupgrade input
- `restore-sysupgrade` parses and honors `--execute 0|1`
- `restore-sysupgrade` rejects unsafe sysupgrade tar members
- high-risk service restart is blocked unless explicitly requested
- LuCI ACL tests verify `/tmp/wrtbak/*` broad read/stat access was removed
- LuCI layout contains restore buttons, review panel, confirmation input, and apply buttons
- LuCI tests verify prepare, prebackup, and apply command argument mapping

Router QA on `192.168.11.234`:

- install APK built from GitHub Actions
- configure existing WebDAV and S3 runtime credentials outside git
- upload a low-risk test backup to WebDAV and S3
- download that backup from WebDAV and generate restore plan
- download that backup from S3 and generate restore plan
- run `restore-prebackup`
- run `restore-apply` against a low-risk test item that writes to a harmless test path
- confirm the test path content changes after restore
- confirm WebDAV/S3 restore flows do not leave UCI changes unless the selected test item intentionally targets UCI
- verify LuCI restore review can load remote backup metadata
- verify LuCI can drive prebackup and apply for the low-risk test item

High-risk network restore is not part of automated router QA. It remains manual and requires a human-selected maintenance window.

## Documentation Updates

Update:

- `docs/ROADMAP.md`
- `docs/AGENT_MAINTENANCE.md`
- `docs/DEVELOPMENT.md`
- `docs/BACKUP_FORMAT.md` if restore semantics need clarification

The docs must state:

- restore can interrupt management access
- pre-restore backup is mandatory
- `RESTORE` confirmation is mandatory
- cross-device restores are warning-only unless schema validation fails
- `.sysupgrade.tar.gz` restore uses OpenWrt native `sysupgrade -r`

## Completion Criteria

The feature is complete only when:

- local fixture tests pass
- CI Lint and package layout pass
- GitHub Actions SDK APK build passes
- APK installs on the test router
- WebDAV remote download, prepare, prebackup, apply, and verification pass
- S3 remote download, prepare, prebackup, apply, and verification pass
- LuCI restore controls render and can drive the prepare path
- LuCI restore controls can drive prebackup and low-risk apply paths
- no plaintext remote credentials are committed or printed
- the implementation is merged to `main`
