# Remote Backup Design

## Goal

Add remote automatic backup support to `luci-app-wrtbak` without rewriting the proven archive core. The feature lets an OpenWrt operator configure WebDAV and S3-compatible object storage in LuCI, test each target, choose one default target, upload backups manually, and schedule automatic uploads.

## Non-Goals

- Do not replace the existing `.wrtbak`, `.sysupgrade.tar.gz`, `create-download`, `export-sysupgrade`, or `restore-plan` implementation.
- Do not commit real WebDAV, S3, or router secrets to this repository.
- Do not implement full async upload queues in v1.
- Do not implement remote restore in v1. V1 may list, delete, and prune remote backups for the current device, but it must not download a remote backup and feed it into the restore flow.

## Selected Approach

Use a modular extension rather than a full plugin rewrite.

Keep the existing stable modules:

- `backup.sh`
- `pack.sh`
- `manifest.sh`
- `items.sh`
- `web.sh`
- `agent.sh`
- current LuCI backup item selection behavior

Add focused modules:

- `remote.sh`: remote target config, WebDAV upload, S3 upload, list, delete, pruning helpers.
- `schedule.sh`: cron generation, cron removal, schedule status.
- LuCI remote sections: device identity, remote target config, default target selector, automatic backup settings, history/diagnostics.

V1 scope includes:

- configure and test WebDAV and S3-compatible targets
- choose one default target
- manually upload to the default target or an explicit target
- list backups under the current device prefix
- delete a selected backup under the current device prefix
- prune older backups under the current device prefix
- install or remove one automatic backup cron job

V1 scope excludes:

- remote restore
- remote download into local restore review
- background upload queues
- multiple simultaneous automatic targets

## Remote Target Policy

Two remote targets can be configured at the same time:

- `webdav`
- `s3`

Only one target is the default at any time:

```text
default_target = webdav | s3
```

Manual buttons may explicitly target WebDAV or S3. Scheduled automatic backup uses only `default_target`.

Target enabled rules:

- `remote-test --target webdav|s3` may run against a disabled target so the operator can validate settings before enabling it.
- `remote-upload`, `remote-list`, `remote-delete`, and `remote-prune` require the selected target to be enabled.
- `remote-upload --target default` resolves `default_target`, then applies the same enabled/config validation.
- `schedule-apply --json` may install a schedule only when `default_target` is enabled and valid. If the schedule is disabled, it may remove the cron block even when the target is disabled.
- A disabled selected target returns `ok:false` with `code: target_disabled`.
- A selected target with missing required fields returns `ok:false` with `code: invalid_config`.
- LuCI should allow editing disabled targets, allow testing disabled targets, and disable upload/list/delete/prune buttons for disabled targets.

Required target fields:

- WebDAV requires `url`, `username`, and `password`.
- WebDAV `path` is optional and defaults to the WebDAV collection root.
- WebDAV `driver` defaults to `curl` and must be `curl` in v1.
- S3 requires `endpoint`, `bucket`, `access_key`, and `secret_key`.
- S3 `region` defaults to `us-east-1` when blank.
- S3 `path` is optional and defaults to the bucket root.
- S3 `force_path_style` defaults to `1`.
- S3 `driver` defaults to `rclone` and must be `rclone` in v1.
- Empty required values return `invalid_config`; malformed URL, endpoint, bucket, or path values also return `invalid_config`.

## Driver Policy

WebDAV v1 uses `curl`.

Rationale:

- It is easy to test the exact HTTP behavior against OpenList WebDAV.
- The OpenWrt test router already has `curl`.
- The CLI contract can stay stable if WebDAV later switches to `rclone`.

S3 v1 uses `rclone`.

Rationale:

- S3-compatible signing and endpoint behavior are easy to get subtly wrong in shell.
- The OpenWrt test router already has `rclone`.
- `rclone` handles MinIO-style S3-compatible object storage well.

Dependency policy:

- `curl` and `rclone` are optional runtime dependencies detected by `remote-status`.
- WebDAV operations return `missing_dependency` when `curl` is unavailable.
- S3 operations return `missing_dependency` when `rclone` is unavailable.
- The LuCI UI should show dependency availability and disable or warn on actions for targets whose driver is missing.
- Packaging may recommend both packages, but v1 behavior must degrade cleanly when only one target's driver is installed.

## Remote Path Layout

Use this multi-device layout:

```text
<remote-root>/wrtbak/<device-id>/<format>/<yyyy>/<filename>
```

Examples:

```text
R2/wrtbak/dae-wrt-jdcloud-re-ss-01-a1b2c3/wrtbak/2026/office-20260625T020000Z.wrtbak
R2/wrtbak/dae-wrt-jdcloud-re-ss-01-a1b2c3/sysupgrade/2026/office-20260625T020000Z.sysupgrade.tar.gz

wrtbak/office-ax6600-4f8a21/wrtbak/2026/office-20260625T020000Z.wrtbak
wrtbak/office-ax6600-4f8a21/sysupgrade/2026/office-20260625T020000Z.sysupgrade.tar.gz
```

Rules:

- `remote-root` comes from the target path setting.
- `device-id` is editable in LuCI.
- `format` is `wrtbak` or `sysupgrade`.
- `yyyy` is extracted from the UTC timestamp.
- `filename` remains the local archive filename.
- `REMOTE_PATH` in CLI JSON and delete/list operations is the normalized storage-relative path beginning at `<remote-root>/wrtbak/<device-id>/...`, not the full WebDAV URL and not the S3 endpoint URL.

This layout supports many routers sharing one bucket or WebDAV directory while keeping pruning and browsing simple.

Path normalization:

- Treat configured target paths as logical POSIX paths.
- Strip leading and trailing slashes from configured paths before joining.
- Reject empty path segments after normalization except for the remote root.
- Reject `.` and `..` segments.
- Reject control characters.
- Allow only UTF-8 strings that can be percent-encoded for WebDAV.
- Join segments with exactly one `/`.
- Return display paths without duplicate slashes.

WebDAV path rules:

- `wrtbak.webdav.url` is the collection URL, for example `https://host.example/dav`.
- `wrtbak.webdav.path` is an optional logical path below that collection, for example `R2`.
- The upload URL is `<url>/<path>/wrtbak/<device-id>/<format>/<yyyy>/<filename>` after path normalization.
- WebDAV URL path segments are percent-encoded individually for HTTP calls. `/` is never encoded inside the joiner.
- `REMOTE_PATH` is `<path>/wrtbak/<device-id>/<format>/<yyyy>/<filename>` with no leading slash. If `path` is empty, it starts with `wrtbak/...`.

S3 path rules:

- `wrtbak.s3.bucket` is the bucket name and is not part of `REMOTE_PATH`.
- `wrtbak.s3.path` is an optional object key prefix.
- The object key is `<path>/wrtbak/<device-id>/<format>/<yyyy>/<filename>` after path normalization.
- `REMOTE_PATH` is that object key with no leading slash.
- `rclone` remote names are temporary implementation details and must not appear in persisted history except as `driver: rclone`.

## Device ID

The plugin generates a default device ID when the operator has not set one.

Default construction:

```text
<hostname>-<board-model-or-board-name>-<stable-hash>
```

Normalization:

- lowercase
- spaces and unsupported characters become `-`
- repeated `-` collapsed
- maximum length 64

Stable hash inputs, in priority order:

- `/etc/machine-id` if present
- first stable MAC address from `/sys/class/net/*/address`, using the deterministic MAC rule below
- board name plus hostname fallback

Hash algorithm:

- choose the first non-empty input from the priority list above
- compute `sha256sum` of that exact string without a trailing newline
- use the first 8 lowercase hex characters

Length rule:

- normalize hostname and board model first
- append `-<hash8>`
- if the result exceeds 64 characters, trim the normalized hostname/model prefix so the final result including `-<hash8>` is at most 64 characters

Deterministic MAC rule:

- inspect `/sys/class/net/*/address`
- exclude interfaces named `lo`
- exclude empty, all-zero, and multicast addresses
- split the remaining addresses into globally administered and locally administered groups using the standard local-admin bit
- prefer the globally administered group when it is non-empty
- otherwise use the locally administered group
- sort candidate interface names lexicographically
- choose the address from the first sorted candidate interface
- lowercase the chosen MAC before hashing
- if no usable MAC exists, fall back to board name plus hostname

The LuCI page exposes this value as editable. It should be shown near the remote settings because it controls remote folder layout.

## UCI Model

Extend `/etc/config/wrtbak`.

```text
config wrtbak 'main'
	option enabled '1'
	option max_upload_mb '32'
	option output_dir '/tmp/wrtbak'
	option rollback_dir '/overlay/wrtbak/rollback'
	option default_mode 'review-required'
	option device_id ''
	option default_target 'webdav'
	option history_file '/overlay/wrtbak/remote-history.jsonl'
	option history_max_entries '20'
	option keep_local_after_upload '0'

config remote 'webdav'
	option enabled '0'
	option driver 'curl'
	option url ''
	option username ''
	option password ''
	option path ''

config remote 's3'
	option enabled '0'
	option driver 'rclone'
	option endpoint ''
	option region 'us-east-1'
	option bucket ''
	option access_key ''
	option secret_key ''
	option path ''
	option force_path_style '1'

config schedule 'auto'
	option enabled '0'
	option frequency 'daily'
	option time '03:30'
	option weekday '0'
	option day_of_month '1'
	option profile 'auto'
	option items 'all'
	option format 'wrtbak'
	option max_backups '0'
```

Secrets are stored only in router UCI config. Tests and docs must use placeholders unless intentionally running a local/remote integration test outside git.

Section access rules:

- main settings are read from `wrtbak.main.<option>`
- WebDAV settings are read from `wrtbak.webdav.<option>`
- S3 settings are read from `wrtbak.s3.<option>`
- automatic schedule settings are read from `wrtbak.auto.<option>`

The implementation must add section-aware config helpers. Existing flat option lookup can remain for old main options, but remote and schedule code must not read duplicate option names globally.

Device ID persistence:

- `wrtbak.main.device_id` is the explicit stored device ID.
- When it is blank, CLI commands compute an effective device ID using the Device ID rules.
- `remote-status --json` returns both `device_id` and `generated_device_id` when the stored value is blank.
- CLI remote operations may use the effective generated ID when the stored value is blank, but they must not write it back to UCI as a side effect.
- LuCI may prefill the generated value in the editable field; saving the page stores the value explicitly.

LuCI persistence rules:

- LuCI reads and writes `/etc/config/wrtbak` through UCI.
- The page must save pending remote settings before running test, upload, list, delete, prune, or schedule buttons.
- A save failure stops the action and shows the save error.
- Secret fields use blank-means-keep semantics: leaving a password or secret field blank keeps the existing UCI value.
- Replacing a secret requires entering a new non-empty value.
- Clearing a secret requires an explicit `clear password` or `clear secret` checkbox for that target.
- Status JSON may expose `password_set`, `access_key_set`, and `secret_key_set` booleans, but never the secret values.

RPCD ACL requirements:

- Add UCI read and write access for package `wrtbak`.
- Add read exec access for `/usr/bin/wrtbak remote-status --json`.
- Add write exec access for `/usr/bin/wrtbak remote-test *`, `/usr/bin/wrtbak remote-upload *`, `/usr/bin/wrtbak remote-list *`, `/usr/bin/wrtbak remote-delete *`, `/usr/bin/wrtbak remote-prune *`, and `/usr/bin/wrtbak schedule-apply --json`.
- Keep existing download ACLs for `/tmp/wrtbak/*`.

## CLI Contract

LuCI must not call `curl` or `rclone` directly. LuCI buttons call stable `wrtbak` CLI commands and parse JSON.

All remote and schedule commands that accept `--json` must:

- print one JSON object to stdout on success or failure
- include `ok: true` on success
- include `ok: false` on handled failure
- exit `0` when `ok: true`
- exit nonzero when `ok: false`
- keep stderr sanitized and optional

LuCI parsing must parse stdout JSON even when the process exits nonzero. It should fall back to stderr only when stdout is empty or invalid JSON.

### `remote-status --json`

Returns:

- device ID
- generated device ID when `wrtbak.main.device_id` is blank
- default target
- enabled targets
- dependency availability (`curl`, `rclone`)
- sanitized target configuration
- schedule configuration and status
- latest sanitized history record when available

Never returns passwords, access keys, or secret keys.

Schedule status fields:

- `enabled`
- `frequency`
- `time`
- `weekday`
- `day_of_month`
- `profile`
- `items`
- `format`
- `max_backups`
- `cron_installed`
- `cron_command` sanitized without secrets

### `remote-test --target webdav|s3 --json`

Tests connectivity and write/list capability for one target.

WebDAV:

- validate URL, username, password, path
- ensure remote directory exists using `MKCOL` as needed
- upload a tiny temporary probe with `curl --upload-file`
- verify the uploaded probe with `HEAD` or `PROPFIND`
- delete the probe

S3:

- generate temporary rclone config
- run `rclone mkdir`
- upload a tiny probe using `rclone copyto`
- verify with `rclone lsf` or `rclone lsjson`
- delete the probe

Output includes `ok`, `target`, `driver`, `remote_path`, and sanitized diagnostics.

### `remote-upload --target default|webdav|s3 --profile NAME --items IDS|all --format wrtbak|sysupgrade [--prune-max N] --json`

Creates a local archive using existing code, uploads it to the chosen remote target, and returns:

- local archive path
- remote path
- size
- sha256
- target
- driver
- elapsed seconds
- prune result when `--prune-max N` is greater than `0`

The command should create the local archive in `output_dir` first. It should not stream archive creation directly to the remote in v1 because keeping the local file simplifies verification and retry.

Item rules:

- `--items all` is accepted.
- `all` means the current built-in default selection used by `wrtbak create`: known items whose default `selected` flag is true, with existing unknown LuCI apps included only when explicitly selected elsewhere.
- A comma-separated item list must reference detected item IDs.
- Unknown item IDs return `ok:false` with `code: invalid_config`.

Local cleanup:

- If upload succeeds and `keep_local_after_upload=0`, delete the local archive after remote existence and size checks pass.
- If upload succeeds and `keep_local_after_upload=1`, keep the local archive.
- If upload fails, keep the local archive when it was created successfully so the operator can retry or download it.
- Return `local_archive_retained: true|false` and `local_archive_path` in JSON. If the file was deleted, `local_archive_path` is the deleted path for audit context, not a downloadable file.
- Return local `sha256` for audit, but do not require the remote to expose or match SHA256 in v1.
- Do not treat S3 ETag as SHA256 because compatible object stores and multipart uploads can make ETag semantics provider-specific.

Remote verification:

- WebDAV upload success requires a successful `curl --upload-file` response and then `HEAD` or `PROPFIND` showing the same byte size.
- S3 upload success requires `rclone copyto` success and then `rclone lsjson` or `rclone size` showing the same byte size.
- If size cannot be verified, return `ok:false` with `code: verification_failed` and keep the local archive.

Post-upload pruning:

- `--prune-max N` defaults to `0`.
- When `N > 0`, run `remote-prune` semantics for the same resolved target after upload verification succeeds.
- Pruning happens after local cleanup.
- If upload succeeds but pruning fails, return `ok:false` with `code: command_failed`, include upload details plus the prune failure, and write history showing upload success with prune failure.
- Automatic backups pass `wrtbak.auto.max_backups` as `--prune-max`.

### `remote-list --target default|webdav|s3 --json`

Lists backup files under:

```text
<remote-root>/wrtbak/<device-id>/
```

Returns path, filename, format, size when available, and modified time when available. It only lists files below the current device prefix and only treats `.wrtbak` and `.sysupgrade.tar.gz` files as backup objects.

WebDAV list behavior:

- Use `curl -X PROPFIND` against the encoded device-prefix collection URL.
- Send `Depth: infinity`.
- Request at least `getcontentlength`, `getlastmodified`, and `resourcetype`.
- Parse XML enough to collect `response/href` plus those properties. The parser may be shell/awk based if covered by fixtures, but it must tolerate namespace prefixes.
- Ignore collection entries.
- Include only files ending in `.wrtbak` or `.sysupgrade.tar.gz`.
- Convert returned hrefs back to normalized `REMOTE_PATH` values under the current device prefix.
- If the server rejects recursive listing with 405, 403, or another non-2xx response, return `ok:false` with `code: unsupported_list` or the closest matching error code; do not guess remote contents.

S3 list behavior:

- Use `rclone lsjson` under the current device prefix.
- Include only files ending in `.wrtbak` or `.sysupgrade.tar.gz`.
- Convert object keys to normalized `REMOTE_PATH` values.

`--target default` resolves `wrtbak.main.default_target`, then applies the same enabled/config/dependency validation as an explicit target.

### `remote-delete --target default|webdav|s3 --path REMOTE_PATH --json`

Deletes a remote backup path only when it is under the current device prefix.

`--target default` resolves `wrtbak.main.default_target`, then applies the same enabled/config/dependency validation as an explicit target.

Success response fields:

- `ok: true`
- `operation: remote-delete`
- resolved `target`
- `driver`
- `remote_path`
- `deleted: true`

Failure behavior:

- A path outside the current device prefix returns `invalid_config`.
- A non-backup filename returns `invalid_config`.
- A missing remote object returns `remote_not_found`.

### `remote-prune --target default|webdav|s3 --max N --json`

Deletes older remote backups under the current device prefix. `N=0` means no pruning.

Retention rules:

- Apply `max` per format, not across all formats.
- Sort newest first by remote modified time when available.
- If modified time is unavailable, parse the compact UTC timestamp in the filename.
- If neither modified time nor filename timestamp is available, sort by full remote path descending for deterministic behavior.
- Never prune files outside `<remote-root>/wrtbak/<device-id>/`.
- `--target default` resolves `wrtbak.main.default_target`, then applies the same enabled/config/dependency validation as an explicit target.

Success response fields:

- `ok: true`
- `operation: remote-prune`
- resolved `target`
- `driver`
- `max`
- `deleted_count`
- `kept_count`
- `deleted_paths`
- `no_op: true|false`

No-op behavior:

- `--max 0` returns `ok:true`, `deleted_count:0`, and `no_op:true`.
- If the remote contains no backups or already satisfies retention, return `ok:true`, `deleted_count:0`, and `no_op:true`.

### `schedule-apply --json`

Writes or removes a cron entry that calls:

```text
/usr/bin/wrtbak remote-upload --target default --profile <profile> --items <items> --format <format> --prune-max <max_backups> --json >/tmp/wrtbak/remote-cron.log 2>&1
```

`profile` comes from `wrtbak.auto.profile`. If it is empty, use `auto`. Device ID controls the remote folder and must not be used as the implicit profile name.

The cron entry must be bracketed with marker comments:

```text
# wrtbak auto backup begin
# wrtbak auto backup end
```

Cron install rules:

- `frequency=daily` uses `time`.
- `frequency=weekly` uses `weekday` plus `time`.
- `frequency=monthly` uses `day_of_month` plus `time`.
- Custom cron expressions are future work and not part of v1.
- Applying a disabled schedule removes only the marked wrtbak cron block.
- Applying an enabled schedule replaces only the marked wrtbak cron block and restarts or reloads cron.
- Applying an enabled schedule validates the resolved default target, required target fields, and required driver dependency first.
- If the default target driver is missing, `schedule-apply` returns `ok:false` with `code: missing_dependency` and does not modify cron.

Success response fields:

- `ok: true`
- `operation: schedule-apply`
- `enabled`
- `cron_installed`
- `action`: `installed`, `removed`, or `unchanged`
- `cron_command` sanitized without secrets when installed
- `profile`
- `items`
- `format`
- `max_backups`

No-op behavior:

- Applying a disabled schedule when no wrtbak cron block exists returns `ok:true`, `action: unchanged`, and `cron_installed:false`.
- Applying an enabled schedule with the same generated block may return `action: unchanged`.

Cron validation and escaping:

- Validate `profile` with the same rule as manual profile names: `^[A-Za-z0-9._-]{1,64}$`.
- Validate `items` as either `all` or a comma-separated list of detected item IDs matching `^[A-Za-z0-9._-]+$`.
- Validate `format` as `wrtbak` or `sysupgrade`.
- Validate `time` as `HH:MM` with `00 <= HH <= 23` and `00 <= MM <= 59`.
- Validate `weekday` as `0..6`.
- Validate `day_of_month` as `1..31`.
- Reject invalid schedule values with `ok:false`, `code: invalid_config`, and do not modify cron.
- Generate cron commands from validated values only.
- Quote generated shell arguments using single-quote escaping. Do not concatenate raw UCI values into cron command strings.

Scheduled item semantics:

- The Automatic Backup section offers `all` and `current selection`.
- Choosing `all` stores `option items 'all'` in `wrtbak.auto.items`.
- Choosing `current selection` stores the current checked item IDs as a comma-separated snapshot in `wrtbak.auto.items` before `schedule-apply` runs.
- Cron execution reads only `wrtbak.auto.items`; it has no dependency on live LuCI page state.
- When `items=all`, each cron run uses the current built-in default selection at runtime.
- When `items` is a comma-separated snapshot, each cron run uses exactly that snapshot until the operator saves a new schedule.

### History Recording

`remote-test`, `remote-upload`, `remote-delete`, `remote-prune`, and `schedule-apply` write a sanitized JSONL record to `wrtbak.main.history_file`.

Each record contains:

- UTC timestamp
- operation
- target
- driver
- `ok`
- error code when failed
- remote path when relevant
- local archive retention fields when relevant
- sanitized message

Retention:

- keep at most `history_max_entries`
- truncate by rewriting the JSONL file after appending when the limit is exceeded
- never write credentials or raw command lines containing credentials

`remote-status --json` returns the latest record as `latest_history` when the file exists.

### Concurrency

Use one global operation lock for remote and schedule mutations:

```text
/tmp/wrtbak/remote.lock
```

Rules:

- `remote-test`, `remote-upload`, `remote-delete`, `remote-prune`, and `schedule-apply` acquire the lock before doing work.
- `remote-list` may run without the lock because it is read-only.
- History append/truncate happens while holding the lock.
- If the lock is already held, wait up to 5 seconds.
- If the lock is still held after 5 seconds, return `ok:false` with `code: busy`.
- The lock must be released on normal exit, handled failure, interrupt, or termination.
- Use a lock mechanism available on OpenWrt shell environments, preferring `flock` when available and falling back to atomic `mkdir`.

## LuCI Design

Keep the page under `System -> Wrtbak`.

Use sections or tabs:

1. Backup Items
   - existing item table
   - profile
   - format
   - create and download

2. Remote Storage
   - device ID
   - default target selector
   - WebDAV config and buttons
   - S3 config and buttons
   - each password/secret field masked
   - explicit clear checkbox for each stored secret

3. Automatic Backup
   - enabled toggle
   - frequency selector: daily, weekly, monthly
   - time picker
   - profile field
   - items selector: all or current selected items, persisted to `wrtbak.auto.items` at schedule apply time
   - format selector
   - maximum remote backups
   - apply schedule button

4. History / Diagnostics
   - list default target
   - list WebDAV
   - list S3
   - delete selected remote backup
   - prune selected target
   - show latest upload result and sanitized errors

Config behavior:

- Remote and schedule controls save to UCI before action buttons run.
- If a secret input is blank, the previous UCI secret value is preserved.
- If a clear-secret checkbox is checked, the corresponding UCI secret option is deleted before the command runs.
- If a secret input is non-empty, it replaces the existing UCI secret value.
- The UI should show whether a secret is currently stored using the sanitized `*_set` booleans from `remote-status`.

Button mapping:

| Button | CLI |
| --- | --- |
| Test WebDAV | `wrtbak remote-test --target webdav --json` |
| Test S3 | `wrtbak remote-test --target s3 --json` |
| Upload to default | `wrtbak remote-upload --target default --profile ... --items ... --format ... --json` |
| Upload to WebDAV | `wrtbak remote-upload --target webdav --profile ... --items ... --format ... --json` |
| Upload to S3 | `wrtbak remote-upload --target s3 --profile ... --items ... --format ... --json` |
| List backups | `wrtbak remote-list --target ... --json` |
| Delete backup | `wrtbak remote-delete --target ... --path ... --json` |
| Prune backups | `wrtbak remote-prune --target ... --max ... --json` |
| Apply schedule | `wrtbak schedule-apply --json` |

## Security

- Do not include secrets in command arguments when avoidable.
- For `curl`, pass credentials through a temporary netrc file or config file with mode `0600`.
- For `rclone`, generate a temporary config file with mode `0600`.
- Delete temporary credential files after use.
- Never print secret values in JSON or logs.
- Validate all remote paths and reject traversal.
- Remote delete and prune must only operate below the current device prefix.

## Error Model

JSON success should include:

- `ok: true`
- `operation`
- `target` when the operation targets remote storage
- fields listed by the command contract

JSON errors should include:

- `ok: false`
- `operation`
- `code`
- `target`
- `message`
- `detail` with sanitized stderr

Recommended error codes:

- `missing_dependency`
- `invalid_config`
- `target_disabled`
- `auth_failed`
- `network_failed`
- `permission_denied`
- `quota_or_size`
- `remote_not_found`
- `unsupported_list`
- `verification_failed`
- `busy`
- `command_failed`

Example success:

```json
{
  "ok": true,
  "operation": "remote-upload",
  "target": "webdav",
  "driver": "curl",
  "remote_path": "R2/wrtbak/office-ax6600-4f8a21/wrtbak/2026/auto-20260625T020000Z.wrtbak",
  "size": 12345,
  "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "local_archive_retained": false,
  "local_archive_path": "/tmp/wrtbak/auto-20260625T020000Z.wrtbak"
}
```

Example handled failure:

```json
{
  "ok": false,
  "operation": "remote-upload",
  "target": "s3",
  "code": "target_disabled",
  "message": "S3 remote target is disabled",
  "detail": ""
}
```

## Testing

Local fixture tests:

- UCI parsing for WebDAV and S3 target configs.
- Section-specific UCI parsing for `main`, `webdav`, `s3`, and `auto`.
- Target enabled rules for test versus upload/list/delete/prune/schedule.
- Required-field validation for WebDAV and S3 targets.
- LuCI secret save semantics: blank keeps, non-empty replaces, clear checkbox deletes.
- RPCD ACL fixture includes UCI `wrtbak` read/write and all remote command exec permissions.
- Device ID generation with fixture hostname, board, and MAC.
- Deterministic MAC fixture ordering, including global-admin preference and local-admin fallback.
- Remote path construction and traversal rejection.
- WebDAV driver with a fake `curl` executable that records arguments and simulates success/failure.
- S3 driver with a fake `rclone` executable that records config path and command arguments.
- CLI JSON contract tests for `remote-status`, `remote-test`, `remote-upload`, `remote-list`, `remote-delete`, `remote-prune`, `schedule-apply`.
- CLI JSON failure tests confirm stdout contains parseable `ok:false` JSON and the process exits nonzero.
- `remote-upload --items all` uses the existing default item selection.
- `remote-list`, `remote-delete`, and `remote-prune` resolve `--target default`.
- `remote-delete`, `remote-prune`, and `schedule-apply` success response schemas.
- `remote-upload --prune-max N` runs post-upload pruning after successful verification.
- `remote-status --json` exposes sanitized schedule status.
- Scheduled `current selection` writes an item snapshot to UCI; scheduled `all` recomputes default items at runtime.
- History JSONL tests confirm records are sanitized and capped by `history_max_entries`.
- Prune tests cover per-format retention and fallback sorting.
- LuCI layout test for required buttons, fields, target selector, and secret input types.

Router integration tests:

- Install package on `192.168.11.234`.
- Configure WebDAV test credentials through UCI or LuCI.
- Run `remote-test --target webdav`.
- Run `remote-upload --target webdav`.
- Verify uploaded object exists remotely.
- Configure S3 test credentials through UCI or LuCI.
- Run `remote-test --target s3`.
- Run `remote-upload --target s3`.
- Verify uploaded object exists remotely.
- Apply a disabled schedule and confirm cron marker removal.
- Apply an enabled schedule and confirm cron marker installation.
- Trigger the generated cron command manually and confirm sanitized history is written.
- Confirm successful remote uploads delete the local archive when `keep_local_after_upload=0`.

WSL verification:

- Use `rclone` in WSL to list the configured WebDAV/S3 targets when available.
- Do not save real credentials in repository files.
- Integration credentials are injected only at runtime through router UCI commands, LuCI fields, or local environment variables used by manual test scripts.
- Test logs and command transcripts must redact passwords, access keys, and secret keys before being committed or posted.

## Rollout

1. Implement WebDAV `curl` driver and CLI contract first.
2. Validate WebDAV on the test OpenWrt router with runtime-provided test credentials.
3. Implement S3 `rclone` driver.
4. Validate S3 against the runtime-provided S3-compatible endpoint.
5. Add LuCI remote storage UI.
6. Add schedule support.
7. Build APK through GitHub Actions.
8. Install and verify on `192.168.11.234`.

## Future Work Not In V1

- Whether WebDAV should later offer a driver selector: `curl` or `rclone`.
- Whether remote restore should download into `/tmp/wrtbak` and then call `restore-plan`.
- Whether to add an upload queue after v1 proves reliable.
