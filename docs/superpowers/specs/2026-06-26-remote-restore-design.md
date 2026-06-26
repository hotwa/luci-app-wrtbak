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
- Existing cache files may be overwritten only when they match the same remote path and size, or when `--force-cache` is added in a later version.
- The command verifies local file size against the remote size when the driver can provide it.
- The command writes a sanitized history record.

JSON success shape:

```json
{
  "ok": true,
  "operation": "remote-download",
  "target": "webdav",
  "driver": "curl",
  "remote_path": "R2/wrtbak/device/wrtbak/2026/backup.wrtbak",
  "local_path": "/tmp/wrtbak/restore-cache/backup.wrtbak",
  "filename": "backup.wrtbak",
  "format": "wrtbak",
  "size": 12345
}
```

### `restore-prepare`

```sh
wrtbak restore-prepare --input LOCAL_ARCHIVE --json
```

Runs all read-only checks needed before an apply:

- validates that the local path is under the restore cache or `/tmp/wrtbak`
- runs `inspect`
- runs `restore-plan --json`
- computes compatibility warnings
- creates no writes to the live root filesystem

This command exists so LuCI can have a stable single command for the review step.

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

### `restore-apply`

```sh
wrtbak restore-apply --input LOCAL_ARCHIVE --mode all|selected --items IDS|all --prebackup LOCAL_ARCHIVE --confirm RESTORE --json
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

Service handling:

- The command returns the services recommended by the manifest.
- By default it does not reboot.
- It may restart non-network services automatically only when `--restart-services 1` is provided.
- It does not automatically restart `network`, `firewall`, `dropbear`, `tailscale`, `wireguard`, `nikki`, or `mosdns` in v1 unless LuCI or the CLI call explicitly asks for service restart.
- When high-risk services are present, the JSON must include `reboot_recommended:true`.

### `restore-sysupgrade`

```sh
wrtbak restore-sysupgrade --input LOCAL_ARCHIVE --prebackup LOCAL_ARCHIVE --confirm RESTORE --json
```

Applies a downloaded `.sysupgrade.tar.gz` archive through OpenWrt native restore.

Rules:

- Requires `--confirm RESTORE`.
- Requires an existing pre-restore backup.
- Runs `tar tzf` safety validation before invoking `sysupgrade -r`.
- Does not attempt file-level selective restore.
- Returns JSON before invoking the final native command when possible.
- LuCI must warn that the current management session can be interrupted.

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

## ACL Changes

`root/usr/share/rpcd/acl.d/luci-app-wrtbak.json` must allow:

- `/usr/bin/wrtbak remote-download *`
- `/usr/bin/wrtbak restore-prepare *`
- `/usr/bin/wrtbak restore-prebackup *`
- `/usr/bin/wrtbak restore-apply *`
- `/usr/bin/wrtbak restore-sysupgrade *`

Existing backup and remote permissions remain unchanged.

## Testing Strategy

Local fixture tests:

- fake WebDAV download succeeds and verifies size
- fake WebDAV partial download cleanup on failure
- fake S3 download succeeds and verifies size
- credentials do not leak into command arguments
- `remote-download` rejects paths outside the current device prefix
- `restore-prepare` returns plan JSON for a valid `.wrtbak`
- `restore-apply` rejects missing confirmation
- `restore-apply` rejects missing prebackup
- `restore-apply` rejects unsafe tar members
- `restore-apply --mode selected` writes only selected item paths
- `restore-apply --mode all` writes all archive paths
- `restore-sysupgrade` rejects non-sysupgrade input
- LuCI layout contains restore buttons, review panel, confirmation input, and apply buttons

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
- no plaintext remote credentials are committed or printed
- the implementation is merged to `main`
