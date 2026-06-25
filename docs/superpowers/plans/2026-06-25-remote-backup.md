# Remote Backup Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add WebDAV and S3-compatible remote backup support to `luci-app-wrtbak`, including CLI contracts, LuCI configuration, scheduling, and router integration verification.

**Architecture:** Keep the existing archive creation and sysupgrade export code unchanged. Add focused shell modules for remote configuration, target drivers, history/locking, and cron scheduling; LuCI only saves UCI config and calls stable `wrtbak` JSON commands. Use fake `curl` and `rclone` fixture tests locally, then verify real WebDAV/S3 behavior on the test OpenWrt router.

**Tech Stack:** POSIX shell/BusyBox ash, OpenWrt UCI/rpcd/LuCI JavaScript, `curl` for WebDAV, `rclone` for S3-compatible storage, Python only in local fixture tests for JSON/XML assertions.

---

## OpenSpec Phase Gates

**Spec:** `docs/superpowers/specs/2026-06-25-remote-backup-design.md`

- [x] **Phase 1: Foundation Gate** - config helpers, device ID, path normalization, JSON result helpers, target validation tests pass.
- [x] **Phase 2: Driver Gate** - fake WebDAV and fake S3 driver tests pass without real credentials.
- [x] **Phase 3: Remote CLI Gate** - status/test/upload/list/delete/prune/history/lock commands pass local fixture tests.
- [x] **Phase 4: Schedule Gate** - cron generation, schedule status, item snapshot, and prune-on-upload tests pass.
- [ ] **Phase 5: LuCI Gate** - remote storage UI, secret handling, ACL, button mapping, and layout tests pass.
- [ ] **Phase 6: Package Gate** - GitHub Actions builds an APK from the branch.
- [ ] **Phase 7: Router QA Gate** - install on `192.168.11.234`, configure runtime credentials, verify WebDAV/S3 upload/list/prune and automatic backup.

## File Structure

- Create `root/usr/lib/wrtbak/config.sh`: section-aware UCI readers, validators, secret presence helpers, target-required-field validation.
- Create `root/usr/lib/wrtbak/remote.sh`: remote command orchestration, device ID generation, path normalization, JSON success/error emitters, target resolution, history JSONL, operation lock, upload/list/delete/prune orchestration.
- Create `root/usr/lib/wrtbak/remote_webdav.sh`: WebDAV driver using `curl`, including `MKCOL`, upload, `HEAD`/`PROPFIND`, list, delete, and probe cleanup.
- Create `root/usr/lib/wrtbak/remote_s3.sh`: S3-compatible driver using temporary `rclone` config, including mkdir, copyto, lsjson/size verification, list, delete, and probe cleanup.
- Create `root/usr/lib/wrtbak/schedule.sh`: schedule validation, cron block generation/removal, cron status reporting.
- Modify `root/usr/bin/wrtbak`: source new modules, update usage, add parsers for remote and schedule commands.
- Modify `root/etc/config/wrtbak`: add default remote and schedule sections without credentials.
- Modify `root/usr/share/rpcd/acl.d/luci-app-wrtbak.json`: add UCI read/write and remote command exec permissions.
- Modify `htdocs/luci-static/resources/view/wrtbak/index.js`: add remote storage and automatic backup UI while keeping existing backup item table and download behavior.
- Modify `docs/DEVELOPMENT.md` and `docs/ROADMAP.md`: document test commands and phased status.
- Create tests:
  - `tests/test_remote_config_fixture.sh`
  - `tests/test_remote_webdav_fixture.sh`
  - `tests/test_remote_s3_fixture.sh`
  - `tests/test_remote_cli_fixture.sh`
  - `tests/test_remote_schedule_fixture.sh`
  - `tests/test_luci_remote_layout.sh`

## Chunk 1: Foundation

### Task 1: Add Section-Aware Config And Device Identity

**Files:**
- Create: `root/usr/lib/wrtbak/config.sh`
- Create: `root/usr/lib/wrtbak/remote.sh`
- Modify: `root/usr/bin/wrtbak`
- Test: `tests/test_remote_config_fixture.sh`

- [x] **Step 1: Write the failing config fixture test**

Create `tests/test_remote_config_fixture.sh` with a fixture root containing:

```sh
mkdir -p "$fixture_root/etc/config" "$fixture_root/etc" "$fixture_root/sys/class/net/eth0" "$fixture_root/sys/class/net/br-lan"
cat >"$fixture_root/etc/config/wrtbak" <<'EOT'
config wrtbak 'main'
	option enabled '1'
	option output_dir '/tmp/wrtbak'
	option default_target 'webdav'
	option history_file '/overlay/wrtbak/remote-history.jsonl'
	option history_max_entries '20'
	option keep_local_after_upload '0'

config remote 'webdav'
	option enabled '1'
	option driver 'curl'
	option url 'https://example.invalid/dav'
	option username 'user'
	option password 'secret'
	option path '/R2/'

config remote 's3'
	option enabled '0'
	option driver 'rclone'
	option endpoint 'https://s3.example.invalid'
	option bucket 'bucket-a'
	option access_key 'access'
	option secret_key 'secret'
	option path '/'

config schedule 'auto'
	option enabled '0'
	option frequency 'daily'
	option time '03:30'
	option profile 'auto'
	option items 'all'
	option format 'wrtbak'
	option max_backups '0'
EOT
printf 'fixture-machine-id' >"$fixture_root/etc/machine-id"
printf '02:11:22:33:44:55\n' >"$fixture_root/sys/class/net/br-lan/address"
printf '00:11:22:33:44:66\n' >"$fixture_root/sys/class/net/eth0/address"
```

Assert:
- `wrtbak remote-status --json` emits valid JSON.
- `device_id` is the generated ID when UCI `device_id` is blank.
- `generated_device_id` is present.
- `default_target` is `webdav`.
- `targets.webdav.password_set` is `true`.
- no raw `secret`, password, access key, or secret key values appear.
- `targets.webdav.path` is normalized to `R2`.
- `targets.s3.enabled` is `false`.

- [x] **Step 2: Run the failing test**

Run:

```sh
sh tests/test_remote_config_fixture.sh
```

Expected: FAIL because `remote-status` is not implemented.

- [x] **Step 3: Implement config helpers**

Create `root/usr/lib/wrtbak/config.sh` with:

```sh
wrtbak_uci_get_section_option() {
	wrtbak_config=$1
	wrtbak_type=$2
	wrtbak_name=$3
	wrtbak_option=$4
	wrtbak_default=$5
	awk -v type="$wrtbak_type" -v name="$wrtbak_name" -v opt="$wrtbak_option" -v def="$wrtbak_default" '
		$1 == "config" {
			in_section = ($2 == type && $3 == "\047" name "\047")
			next
		}
		in_section && $1 == "option" && $2 == opt {
			$1 = ""; $2 = ""; sub(/^[ \t]+/, "")
			gsub(/^\047|\047$/, "", $0)
			gsub(/^"|"$/, "", $0)
			print $0
			found = 1
			exit
		}
		END { if (!found) print def }
	' "$wrtbak_config"
}
```

Also add wrappers:
- `wrtbak_config_file`
- `wrtbak_main_option`
- `wrtbak_remote_option TARGET OPTION DEFAULT`
- `wrtbak_schedule_option OPTION DEFAULT`
- `wrtbak_bool_enabled`
- `wrtbak_secret_is_set`

- [x] **Step 4: Implement device ID and path helpers**

In `root/usr/lib/wrtbak/remote.sh`, add:
- `wrtbak_normalize_remote_segment`
- `wrtbak_join_remote_path`
- `wrtbak_effective_device_id`
- `wrtbak_hash8`
- `wrtbak_first_stable_mac`
- `wrtbak_remote_status_json`

Device ID must follow the spec:
- use `/etc/machine-id` first
- else deterministic MAC with global-admin preference
- else board name plus hostname
- `sha256sum` first 8 hex characters
- max length 64

- [x] **Step 5: Wire `remote-status` into the CLI**

Modify `root/usr/bin/wrtbak`:
- source `config.sh`
- source `remote.sh`
- add usage line `wrtbak remote-status --json`
- add parser for `remote-status --json`

- [x] **Step 6: Run the foundation test**

Run:

```sh
sh tests/test_remote_config_fixture.sh
```

Expected: PASS.

- [x] **Step 7: Run existing tests**

Run:

```sh
sh -n root/usr/bin/wrtbak root/usr/lib/wrtbak/*.sh tests/*.sh
for test_script in tests/*.sh; do sh "$test_script"; done
git diff --check
```

Expected: all commands exit 0.

- [x] **Step 8: Commit foundation**

Run:

```sh
git add root/usr/bin/wrtbak root/usr/lib/wrtbak/config.sh root/usr/lib/wrtbak/remote.sh tests/test_remote_config_fixture.sh
git commit -m "feat: add remote backup config foundation"
```

## Chunk 2: Remote Drivers

### Task 2: Add WebDAV Driver With Fake Curl Tests

**Files:**
- Create: `root/usr/lib/wrtbak/remote_webdav.sh`
- Modify: `root/usr/lib/wrtbak/remote.sh`
- Modify: `root/usr/bin/wrtbak`
- Test: `tests/test_remote_webdav_fixture.sh`

- [x] **Step 1: Write the failing WebDAV fixture test**

Create a temporary fake `curl` executable earlier in `PATH`:

```sh
#!/bin/sh
printf '%s\n' "$*" >>"$WRTBAK_FAKE_CURL_LOG"
case "$*" in
	*PROPFIND*)
		cat "$WRTBAK_FAKE_WEBDAV_XML"
		exit 0
		;;
	*--upload-file*)
		exit 0
		;;
	*-I*|*--head*)
		printf 'HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n'
		exit 0
		;;
	*-X\ DELETE*)
		exit 0
		;;
	*-X\ MKCOL*)
		exit 0
		;;
esac
exit 0
```

Assert:
- `wrtbak remote-test --target webdav --json` emits `ok:true`.
- fake curl log does not contain the raw password in command arguments.
- a temporary credential file is created with mode `600` and removed by the end of the command.
- `wrtbak remote-list --target webdav --json` parses PROPFIND XML and returns normalized paths under `R2/wrtbak/<device-id>/`.
- unsupported PROPFIND returns `ok:false` and `code:"unsupported_list"`.

- [x] **Step 2: Run test to verify failure**

Run:

```sh
sh tests/test_remote_webdav_fixture.sh
```

Expected: FAIL because WebDAV commands are not implemented.

- [x] **Step 3: Implement WebDAV driver**

Create `root/usr/lib/wrtbak/remote_webdav.sh` with:
- `wrtbak_webdav_mkcol_chain`
- `wrtbak_webdav_upload`
- `wrtbak_webdav_verify_size`
- `wrtbak_webdav_list`
- `wrtbak_webdav_delete`
- `wrtbak_webdav_probe`
- `wrtbak_webdav_temp_netrc`

Use `curl --netrc-file "$tmp_netrc"` or `curl --config "$tmp_config"` so credentials are not passed as command arguments.

- [x] **Step 4: Wire driver functions**

Modify `root/usr/lib/wrtbak/remote.sh`:
- resolve `webdav` target config
- call WebDAV driver for `remote-test` and `remote-list`
- return JSON via common success/error helpers

Modify `root/usr/bin/wrtbak`:
- source `remote_webdav.sh`
- add parsers for `remote-test --target webdav --json` and `remote-list --target webdav --json`

- [x] **Step 5: Run WebDAV tests**

Run:

```sh
sh tests/test_remote_webdav_fixture.sh
```

Expected: PASS.

### Task 3: Add S3 Driver With Fake Rclone Tests

**Files:**
- Create: `root/usr/lib/wrtbak/remote_s3.sh`
- Modify: `root/usr/lib/wrtbak/remote.sh`
- Modify: `root/usr/bin/wrtbak`
- Test: `tests/test_remote_s3_fixture.sh`

- [x] **Step 1: Write the failing S3 fixture test**

Create a temporary fake `rclone` executable earlier in `PATH`:

```sh
#!/bin/sh
printf '%s\n' "$*" >>"$WRTBAK_FAKE_RCLONE_LOG"
case "$1" in
	mkdir|copyto|deletefile)
		exit 0
		;;
	lsjson)
		printf '[{"Path":"wrtbak/device/wrtbak/2026/auto-20260625T020000Z.wrtbak","Name":"auto-20260625T020000Z.wrtbak","Size":5,"ModTime":"2026-06-25T02:00:00Z"}]\n'
		exit 0
		;;
	size)
		printf 'Total objects: 1\nTotal size: 5 B (5 Bytes)\n'
		exit 0
		;;
esac
exit 0
```

Assert:
- `wrtbak remote-test --target s3 --json` emits `ok:true`.
- fake rclone log references `--config` but does not include secret values.
- temporary rclone config is mode `600` and removed by the end of the command.
- `wrtbak remote-list --target s3 --json` returns normalized object keys.
- missing `rclone` returns `ok:false` and `code:"missing_dependency"`.

- [x] **Step 2: Run test to verify failure**

Run:

```sh
sh tests/test_remote_s3_fixture.sh
```

Expected: FAIL because S3 commands are not implemented.

- [x] **Step 3: Implement S3 driver**

Create `root/usr/lib/wrtbak/remote_s3.sh` with:
- `wrtbak_s3_temp_rclone_config`
- `wrtbak_s3_mkdir`
- `wrtbak_s3_upload`
- `wrtbak_s3_verify_size`
- `wrtbak_s3_list`
- `wrtbak_s3_delete`
- `wrtbak_s3_probe`

Use a temporary config section named `wrtbak_remote` and object keys from normalized `REMOTE_PATH`.

- [x] **Step 4: Wire S3 driver functions**

Modify `root/usr/lib/wrtbak/remote.sh`:
- resolve `s3` target config
- call S3 driver for `remote-test` and `remote-list`
- map driver failures to sanitized JSON errors

Modify `root/usr/bin/wrtbak`:
- source `remote_s3.sh`

- [x] **Step 5: Run driver tests**

Run:

```sh
sh tests/test_remote_webdav_fixture.sh
sh tests/test_remote_s3_fixture.sh
```

Expected: PASS.

- [x] **Step 6: Run all local tests and commit drivers**

Run:

```sh
sh -n root/usr/bin/wrtbak root/usr/lib/wrtbak/*.sh tests/*.sh
for test_script in tests/*.sh; do sh "$test_script"; done
git diff --check
git add root/usr/bin/wrtbak root/usr/lib/wrtbak/remote.sh root/usr/lib/wrtbak/remote_webdav.sh root/usr/lib/wrtbak/remote_s3.sh tests/test_remote_webdav_fixture.sh tests/test_remote_s3_fixture.sh
git commit -m "feat: add remote storage drivers"
```

Expected: tests pass and commit succeeds.

## Chunk 3: Remote CLI Management

### Task 4: Add Upload, Delete, Prune, History, And Locking

**Files:**
- Modify: `root/usr/lib/wrtbak/remote.sh`
- Modify: `root/usr/bin/wrtbak`
- Test: `tests/test_remote_cli_fixture.sh`

- [x] **Step 1: Write the failing remote CLI fixture test**

Create fixture tests with fake drivers and a fixture root. Assert:
- `remote-upload --target default --profile auto --items all --format wrtbak --json` creates a local archive, uploads it, verifies size, and returns `ok:true`.
- `--items all` uses existing default item selection.
- `remote-upload --prune-max 2` runs pruning after upload.
- upload success with `keep_local_after_upload=0` deletes local archive after verification.
- upload failure keeps the local archive.
- `remote-delete --target default --path VALID --json` returns `deleted:true`.
- deleting outside the device prefix returns `invalid_config`.
- missing remote object returns `remote_not_found`.
- `remote-prune --target default --max 0 --json` returns `no_op:true`.
- `remote-prune --target default --max 2 --json` applies per-format retention.
- busy lock returns `ok:false` and `code:"busy"`.
- history JSONL never contains credentials and is capped by `history_max_entries`.

- [x] **Step 2: Run test to verify failure**

Run:

```sh
sh tests/test_remote_cli_fixture.sh
```

Expected: FAIL because upload/delete/prune/history/lock are incomplete.

- [x] **Step 3: Implement JSON result helpers**

In `root/usr/lib/wrtbak/remote.sh`, add:
- `wrtbak_json_ok_begin OPERATION`
- `wrtbak_json_error OPERATION TARGET CODE MESSAGE DETAIL`
- `wrtbak_sanitize_detail`
- `wrtbak_remote_exit_json`

Handled failures must print parseable stdout JSON and exit nonzero.

- [x] **Step 4: Implement operation lock**

Add:
- `wrtbak_remote_lock_acquire`
- `wrtbak_remote_lock_release`

Use `flock` when available; otherwise atomic `mkdir /tmp/wrtbak/remote.lock`. Wait up to 5 seconds before returning `busy`.

- [x] **Step 5: Implement history JSONL**

Add:
- `wrtbak_history_append`
- `wrtbak_history_latest`
- `wrtbak_history_truncate`

History records include timestamp, operation, target, driver, `ok`, code, remote path, local archive retention, and sanitized message.

- [x] **Step 6: Implement upload orchestration**

Add:
- `wrtbak_remote_create_local_archive`
- `wrtbak_remote_upload`
- `wrtbak_remote_cleanup_local_archive`
- `wrtbak_remote_prune_after_upload`

Support:

```sh
wrtbak remote-upload --target default|webdav|s3 --profile NAME --items IDS|all --format wrtbak|sysupgrade --prune-max N --json
```

- [x] **Step 7: Implement delete and prune orchestration**

Add:
- `wrtbak_remote_delete`
- `wrtbak_remote_prune`
- safe-prefix validation
- backup filename validation
- per-format retention sorting

- [x] **Step 8: Wire CLI parsers**

Modify `root/usr/bin/wrtbak`:
- add usage lines for upload/list/delete/prune
- parse `--target`, `--profile`, `--items`, `--format`, `--prune-max`, `--max`, `--path`, `--json`
- reject unknown args

- [x] **Step 9: Run remote CLI tests**

Run:

```sh
sh tests/test_remote_cli_fixture.sh
```

Expected: PASS.

- [x] **Step 10: Run all tests and commit**

Run:

```sh
sh -n root/usr/bin/wrtbak root/usr/lib/wrtbak/*.sh tests/*.sh
for test_script in tests/*.sh; do sh "$test_script"; done
git diff --check
git add root/usr/bin/wrtbak root/usr/lib/wrtbak/remote.sh tests/test_remote_cli_fixture.sh
git commit -m "feat: add remote backup cli management"
```

Expected: tests pass and commit succeeds.

## Chunk 4: Schedule

### Task 5: Add Automatic Backup Schedule Support

**Files:**
- Create: `root/usr/lib/wrtbak/schedule.sh`
- Modify: `root/usr/lib/wrtbak/remote.sh`
- Modify: `root/usr/bin/wrtbak`
- Modify: `root/etc/config/wrtbak`
- Test: `tests/test_remote_schedule_fixture.sh`

- [x] **Step 1: Write the failing schedule fixture test**

Assert:
- `schedule-apply --json` with disabled schedule removes only the marked wrtbak cron block.
- disabled schedule with no block returns `action:"unchanged"`.
- enabled daily schedule creates a marked block and sanitized cron command.
- weekly/monthly schedule values produce correct cron fields.
- invalid `profile`, `items`, `format`, `time`, `weekday`, and `day_of_month` return `invalid_config` and do not change cron.
- missing default target dependency returns `missing_dependency`.
- `current selection` snapshot is represented as comma-separated UCI item IDs before schedule apply.
- `remote-status --json` exposes schedule status and `cron_installed`.

- [x] **Step 2: Run test to verify failure**

Run:

```sh
sh tests/test_remote_schedule_fixture.sh
```

Expected: FAIL because `schedule-apply` is not implemented.

- [x] **Step 3: Implement schedule module**

Create `root/usr/lib/wrtbak/schedule.sh` with:
- `wrtbak_schedule_validate`
- `wrtbak_schedule_quote_arg`
- `wrtbak_schedule_cron_fields`
- `wrtbak_schedule_command`
- `wrtbak_schedule_apply`
- `wrtbak_schedule_status_json_fields`

Cron command:

```sh
/usr/bin/wrtbak remote-upload --target default --profile '<profile>' --items '<items>' --format '<format>' --prune-max '<max_backups>' --json >/tmp/wrtbak/remote-cron.log 2>&1
```

- [x] **Step 4: Wire schedule into status and CLI**

Modify:
- `root/usr/lib/wrtbak/remote.sh` to include schedule status in `remote-status`.
- `root/usr/bin/wrtbak` to source `schedule.sh` and parse `schedule-apply --json`.
- `root/etc/config/wrtbak` to include new main/remote/schedule default sections.

- [x] **Step 5: Run schedule tests**

Run:

```sh
sh tests/test_remote_schedule_fixture.sh
```

Expected: PASS.

- [x] **Step 6: Run all tests and commit**

Run:

```sh
sh -n root/usr/bin/wrtbak root/usr/lib/wrtbak/*.sh tests/*.sh
for test_script in tests/*.sh; do sh "$test_script"; done
git diff --check
git add root/usr/bin/wrtbak root/usr/lib/wrtbak/remote.sh root/usr/lib/wrtbak/schedule.sh root/etc/config/wrtbak tests/test_remote_schedule_fixture.sh
git commit -m "feat: add remote backup schedule"
```

Expected: tests pass and commit succeeds.

## Chunk 5: LuCI Remote UI

### Task 6: Add Remote Storage And Automatic Backup UI

**Files:**
- Modify: `htdocs/luci-static/resources/view/wrtbak/index.js`
- Modify: `root/usr/share/rpcd/acl.d/luci-app-wrtbak.json`
- Test: `tests/test_luci_layout.sh`
- Test: `tests/test_luci_remote_layout.sh`

- [ ] **Step 1: Write the failing LuCI remote layout test**

Create `tests/test_luci_remote_layout.sh`. Assert:
- view imports `uci`.
- view calls `wrtbak remote-status --json`.
- WebDAV fields exist: URL, username, password, path, enabled, clear password.
- S3 fields exist: endpoint, region, bucket, access key, secret key, path, enabled, clear secrets.
- default target selector exists.
- buttons call `remote-test`, `remote-upload`, `remote-list`, `remote-delete`, `remote-prune`, and `schedule-apply`.
- password and secret fields use password inputs.
- blank secret semantics are represented in the save logic.
- automatic backup fields exist: enabled, frequency, time, profile, item mode, format, max backups.
- ACL JSON includes UCI `wrtbak` read/write and remote command exec permissions.

- [ ] **Step 2: Run test to verify failure**

Run:

```sh
sh tests/test_luci_remote_layout.sh
```

Expected: FAIL because remote UI is not implemented.

- [ ] **Step 3: Add UCI load/save structure**

Modify `htdocs/luci-static/resources/view/wrtbak/index.js`:
- require `uci`
- load `detect`, `remote-status`, and `uci.load('wrtbak')`
- save main, webdav, s3, and auto sections before action buttons
- implement blank-means-keep for password fields
- implement explicit clear checkboxes for secrets

- [ ] **Step 4: Add Remote Storage section**

Add controls:
- device ID field with generated ID hint
- default target select
- WebDAV enabled, URL, username, password, clear password, path
- S3 enabled, endpoint, region, bucket, access key, clear access key, secret key, clear secret key, path, force path style
- test buttons for WebDAV and S3
- upload buttons for default/WebDAV/S3

- [ ] **Step 5: Add History / Diagnostics section**

Add controls:
- target selector including default/WebDAV/S3
- list backups button
- backup table with remote path, format, size, modified time
- delete selected backup button
- prune target button with max value
- latest history display from `remote-status`

- [ ] **Step 6: Add Automatic Backup section**

Add controls:
- enabled toggle
- frequency select daily/weekly/monthly
- time input
- weekday and day-of-month inputs
- profile input
- item mode select: all/current selection
- format select
- max backups input
- apply schedule button

When item mode is current selection, write selected checkbox IDs to `wrtbak.auto.items` before calling `schedule-apply`.

- [ ] **Step 7: Update ACL**

Modify `root/usr/share/rpcd/acl.d/luci-app-wrtbak.json`:
- add UCI read/write for `wrtbak`
- add exec ACLs for:
  - `/usr/bin/wrtbak remote-status --json`
  - `/usr/bin/wrtbak remote-test *`
  - `/usr/bin/wrtbak remote-upload *`
  - `/usr/bin/wrtbak remote-list *`
  - `/usr/bin/wrtbak remote-delete *`
  - `/usr/bin/wrtbak remote-prune *`
  - `/usr/bin/wrtbak schedule-apply --json`

- [ ] **Step 8: Run LuCI tests**

Run:

```sh
sh tests/test_luci_layout.sh
sh tests/test_luci_remote_layout.sh
```

Expected: PASS.

- [ ] **Step 9: Run all tests and commit**

Run:

```sh
sh -n root/usr/bin/wrtbak root/usr/lib/wrtbak/*.sh tests/*.sh
python3 -m json.tool root/usr/share/rpcd/acl.d/luci-app-wrtbak.json >/dev/null
for test_script in tests/*.sh; do sh "$test_script"; done
git diff --check
git add htdocs/luci-static/resources/view/wrtbak/index.js root/usr/share/rpcd/acl.d/luci-app-wrtbak.json tests/test_luci_layout.sh tests/test_luci_remote_layout.sh
git commit -m "feat: add luci remote backup ui"
```

Expected: tests pass and commit succeeds.

## Chunk 6: Package Build And Router Integration

### Task 7: Build APK And Install On Test Router

**Files:**
- Modify: `docs/DEVELOPMENT.md`
- Modify: `docs/ROADMAP.md`

- [ ] **Step 1: Run all local checks before pushing**

Run:

```sh
sh -n root/usr/bin/wrtbak root/usr/lib/wrtbak/*.sh tests/*.sh
for test_script in tests/*.sh; do sh "$test_script"; done
git diff --check
```

Expected: all commands exit 0.

- [ ] **Step 2: Push implementation branch**

Run:

```sh
git push -u origin codex/remote-backup-design
```

Expected: push succeeds.

- [ ] **Step 3: Trigger GitHub Actions package build**

Run:

```sh
gh workflow run build-package.yml --repo hotwa/luci-app-wrtbak --ref codex/remote-backup-design
gh run list --repo hotwa/luci-app-wrtbak --workflow build-package.yml --limit 3
```

Expected: a new run starts on the implementation branch.

- [ ] **Step 4: Wait for build and download APK**

Run:

```sh
gh run watch RUN_ID --repo hotwa/luci-app-wrtbak
gh run download RUN_ID --repo hotwa/luci-app-wrtbak --dir /tmp/wrtbak-apk
find /tmp/wrtbak-apk -name 'luci-app-wrtbak-*.apk' -print
```

Expected: build succeeds and an APK path is printed.

- [ ] **Step 5: Install APK on test router**

Run:

```sh
scp /tmp/wrtbak-apk/**/luci-app-wrtbak-*.apk root@192.168.11.234:/tmp/
ssh root@192.168.11.234 "apk add --allow-untrusted /tmp/luci-app-wrtbak-*.apk"
ssh root@192.168.11.234 "wrtbak remote-status --json"
```

Expected: install succeeds and `remote-status` returns parseable JSON.

### Task 8: Verify Runtime WebDAV And S3

**Files:**
- Do not commit runtime credentials or test archives.
- Update docs only with sanitized results if needed.

- [ ] **Step 1: Configure WebDAV credentials at runtime**

Run on router with credentials supplied outside git:

```sh
ssh root@192.168.11.234 "uci set wrtbak.webdav.enabled='1'; uci set wrtbak.webdav.url='\$WEBDAV_URL'; uci set wrtbak.webdav.username='\$WEBDAV_USER'; uci set wrtbak.webdav.password='\$WEBDAV_PASS'; uci set wrtbak.webdav.path='\$WEBDAV_PATH'; uci commit wrtbak"
```

Expected: UCI commit succeeds. Do not paste credentials into commits, docs, or logs.

- [ ] **Step 2: Test WebDAV**

Run:

```sh
ssh root@192.168.11.234 "wrtbak remote-test --target webdav --json"
ssh root@192.168.11.234 "wrtbak remote-upload --target webdav --profile office-test --items all --format wrtbak --json"
ssh root@192.168.11.234 "wrtbak remote-list --target webdav --json"
```

Expected: all commands return `ok:true`, and list includes the uploaded backup.

- [ ] **Step 3: Configure S3 credentials at runtime**

Run on router with credentials supplied outside git:

```sh
ssh root@192.168.11.234 "uci set wrtbak.s3.enabled='1'; uci set wrtbak.s3.endpoint='\$S3_ENDPOINT'; uci set wrtbak.s3.bucket='\$S3_BUCKET'; uci set wrtbak.s3.access_key='\$S3_ACCESS_KEY'; uci set wrtbak.s3.secret_key='\$S3_SECRET_KEY'; uci set wrtbak.s3.path='\$S3_PATH'; uci commit wrtbak"
```

Expected: UCI commit succeeds. Do not paste credentials into commits, docs, or logs.

- [ ] **Step 4: Test S3**

Run:

```sh
ssh root@192.168.11.234 "wrtbak remote-test --target s3 --json"
ssh root@192.168.11.234 "wrtbak remote-upload --target s3 --profile office-test --items all --format wrtbak --json"
ssh root@192.168.11.234 "wrtbak remote-list --target s3 --json"
```

Expected: all commands return `ok:true`, and list includes the uploaded backup.

- [ ] **Step 5: Test schedule without waiting for cron**

Run:

```sh
ssh root@192.168.11.234 "uci set wrtbak.main.default_target='webdav'; uci set wrtbak.auto.enabled='1'; uci set wrtbak.auto.frequency='daily'; uci set wrtbak.auto.time='03:30'; uci set wrtbak.auto.profile='auto'; uci set wrtbak.auto.items='all'; uci set wrtbak.auto.format='wrtbak'; uci set wrtbak.auto.max_backups='2'; uci commit wrtbak; wrtbak schedule-apply --json"
ssh root@192.168.11.234 "grep -n 'wrtbak auto backup' /etc/crontabs/root && /etc/init.d/cron restart"
ssh root@192.168.11.234 "/usr/bin/wrtbak remote-upload --target default --profile auto --items all --format wrtbak --prune-max 2 --json"
```

Expected: schedule apply returns `ok:true`, cron block exists, manual cron command returns `ok:true`.

- [ ] **Step 6: Verify LuCI page manually**

Open:

```text
http://192.168.11.234/cgi-bin/luci/admin/system/wrtbak
```

Expected:
- existing backup item pagination still works
- WebDAV/S3 fields render
- Test buttons display sanitized success/failure
- Upload buttons work
- List/delete/prune controls work
- Apply schedule displays sanitized result
- no secret value is displayed after saving

- [ ] **Step 7: Commit docs update if needed**

If sanitized docs changed:

```sh
git add docs/DEVELOPMENT.md docs/ROADMAP.md docs/superpowers/plans/2026-06-25-remote-backup.md
git commit -m "docs: update remote backup verification notes"
```

Expected: commit succeeds without credentials.

## Chunk 7: Landing

### Task 9: Final Review, PR, And Merge

**Files:**
- All implementation files from prior chunks.

- [ ] **Step 1: Run final local verification**

Run:

```sh
sh -n root/usr/bin/wrtbak root/usr/lib/wrtbak/*.sh tests/*.sh
for test_script in tests/*.sh; do sh "$test_script"; done
git diff --check
```

Expected: all commands exit 0.

- [ ] **Step 2: Create PR**

Run:

```sh
gh pr create --repo hotwa/luci-app-wrtbak --base main --head codex/remote-backup-design --title "Add WebDAV and S3 remote backup support" --body-file /tmp/wrtbak-remote-pr.md
```

Expected: PR URL is returned.

- [ ] **Step 3: Wait for CI**

Run:

```sh
gh pr checks PR_NUMBER --repo hotwa/luci-app-wrtbak --watch
```

Expected: required checks pass.

- [ ] **Step 4: Merge after approval**

Run:

```sh
gh pr merge PR_NUMBER --repo hotwa/luci-app-wrtbak --squash --delete-branch
```

Expected: PR merges to `main`.

- [ ] **Step 5: Confirm package workflow on main**

Run:

```sh
gh workflow run build-package.yml --repo hotwa/luci-app-wrtbak --ref main
gh run list --repo hotwa/luci-app-wrtbak --workflow build-package.yml --limit 3
```

Expected: main branch package build starts and succeeds.
