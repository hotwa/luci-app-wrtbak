# Remote Restore Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add safe WebDAV/S3 remote restore to `luci-app-wrtbak`, including remote download, restore review, mandatory pre-restore backup, explicit confirmation, LuCI controls, APK build, and real WebDAV/S3 restore QA on the test OpenWrt router.

**Architecture:** Keep remote storage operations in `remote*.sh`, move restore write behavior into a new focused `restore.sh`, and keep LuCI as a thin state machine that calls stable JSON CLI commands. Separate browser-download archives from restore cache paths so rpcd ACLs can expose only safe download files.

**Tech Stack:** POSIX shell/BusyBox ash, OpenWrt LuCI JavaScript, rpcd ACL JSON, curl WebDAV, rclone S3, shell fixture tests, GitHub Actions OpenWrt SDK build.

---

## File Structure

- Modify `root/usr/bin/wrtbak`: add usage entries, source `restore.sh`, parse new commands, and keep argument validation close to existing CLI parser style.
- Modify `root/usr/lib/wrtbak/web.sh`: move browser-created downloads into `/tmp/wrtbak/downloads/`.
- Modify `root/usr/lib/wrtbak/remote.sh`: add `remote-download`, restore cache helpers, sidecar handling, cache reuse, and driver dispatch.
- Modify `root/usr/lib/wrtbak/remote_webdav.sh`: add WebDAV size metadata and download helper using curl netrc.
- Modify `root/usr/lib/wrtbak/remote_s3.sh`: add S3 size metadata and download helper using rclone config files.
- Modify `root/usr/lib/wrtbak/agent.sh`: extract reusable read-only archive-plan helpers so existing `restore-plan` and new `restore-prepare` share one validation path.
- Create `root/usr/lib/wrtbak/restore.sh`: local archive path policy, `restore-prepare`, `restore-prebackup`, `restore-apply`, and `restore-sysupgrade`.
- Modify `root/usr/share/rpcd/acl.d/luci-app-wrtbak.json`: add restore exec permissions and replace broad `/tmp/wrtbak/*` read access with `/tmp/wrtbak/downloads/*.wrtbak` and `/tmp/wrtbak/downloads/*.sysupgrade.tar.gz`.
- Modify `htdocs/luci-static/resources/view/wrtbak/index.js`: add restore actions, review panel, confirmation/prebackup/apply state machine.
- Add `tests/test_remote_download_fixture.sh`: remote download and cache behavior.
- Add `tests/test_restore_apply_fixture.sh`: prepare, prebackup, selected/all apply, service restart reporting, sysupgrade preflight/failure behavior.
- Modify `tests/test_web_create_fixture.sh`: assert browser downloads now live in `/tmp/wrtbak/downloads/`.
- Modify `tests/test_luci_layout.sh`: assert restore UI commands, buttons, and narrowed ACL.
- Modify docs: `docs/ROADMAP.md`, `docs/AGENT_MAINTENANCE.md`, `docs/DEVELOPMENT.md`, and `docs/BACKUP_FORMAT.md` if command semantics or archive format behavior are clarified.

---

## Chunk 1: Path Isolation, CLI Skeleton, And ACL

### Task 1: Move browser downloads into a safe downloads directory

**Files:**
- Modify: `root/usr/lib/wrtbak/web.sh`
- Modify: `tests/test_web_create_fixture.sh`
- Modify: `tests/test_luci_layout.sh`
- Modify: `root/usr/share/rpcd/acl.d/luci-app-wrtbak.json`

- [ ] **Step 1: Write failing fixture assertions**

In `tests/test_web_create_fixture.sh`, after each `create-download` JSON parse, assert:

```python
expected_dir = os.path.join(output_dir, "downloads")
assert data["path"].startswith(expected_dir + os.sep)
assert data["path"] == os.path.join(expected_dir, data["filename"])
assert data["path"].endswith(".wrtbak") or data["path"].endswith(".sysupgrade.tar.gz")
```

In `tests/test_luci_layout.sh`, replace the current broad ACL assertion:

```sh
! grep -Fq '"/tmp/wrtbak/*"' "$acl_file"
grep -Fq '"/tmp/wrtbak/downloads/*.wrtbak"' "$acl_file"
grep -Fq '"/tmp/wrtbak/downloads/*.sysupgrade.tar.gz"' "$acl_file"
! grep -Fq '"/tmp/wrtbak/*.wrtbak"' "$acl_file"
! grep -Fq '"/tmp/wrtbak/*.sysupgrade.tar.gz"' "$acl_file"
! grep -Fq '"/tmp/wrtbak/restore-cache/*"' "$acl_file"
! grep -Fq '"/tmp/wrtbak/restore-logs/*"' "$acl_file"
! grep -Fq '"/tmp/wrtbak/*.remote.json"' "$acl_file"
! grep -Fq '"/tmp/wrtbak/*.receipt.json"' "$acl_file"
```

- [ ] **Step 2: Run failing tests**

Run:

```sh
sh tests/test_web_create_fixture.sh
sh tests/test_luci_layout.sh
```

Expected: both fail because downloads still use `/tmp/wrtbak` and ACL still has `/tmp/wrtbak/*`.

- [ ] **Step 3: Implement downloads directory helper**

In `root/usr/lib/wrtbak/web.sh`, change `wrtbak_create_download` to use:

```sh
wrtbak_dir="$(wrtbak_output_dir)/downloads"
wrtbak_prepare_output_dir "$wrtbak_dir"
wrtbak_cleanup_downloads "$wrtbak_dir"
```

Do not change `output_dir` itself; only generated browser downloads move to the child directory.

- [ ] **Step 4: Narrow rpcd file ACL**

In `root/usr/share/rpcd/acl.d/luci-app-wrtbak.json`, replace:

```json
"/tmp/wrtbak/*": ["read", "stat"]
```

with:

```json
"/tmp/wrtbak/downloads/*.wrtbak": ["read", "stat"],
"/tmp/wrtbak/downloads/*.sysupgrade.tar.gz": ["read", "stat"]
```

- [ ] **Step 5: Verify path isolation**

Run:

```sh
sh tests/test_web_create_fixture.sh
sh tests/test_luci_layout.sh
python3 -m json.tool root/usr/share/rpcd/acl.d/luci-app-wrtbak.json >/dev/null
```

Expected: PASS.

- [ ] **Step 6: Commit**

```sh
git add root/usr/lib/wrtbak/web.sh root/usr/share/rpcd/acl.d/luci-app-wrtbak.json tests/test_web_create_fixture.sh tests/test_luci_layout.sh
git commit -m "feat: isolate wrtbak browser downloads"
```

### Task 2: Add restore command parser skeletons

**Files:**
- Modify: `root/usr/bin/wrtbak`
- Modify: `root/usr/lib/wrtbak/remote.sh`
- Create: `root/usr/lib/wrtbak/restore.sh`
- Modify: `tests/test_luci_layout.sh`

- [ ] **Step 1: Write failing parser/layout checks**

In `tests/test_luci_layout.sh`, assert the CLI and ACL-visible command names:

```sh
python3 - "$acl_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    acl = json.load(handle)["luci-app-wrtbak"]

read_file = acl["read"]["file"]
write_file = acl["write"]["file"]

for command in [
    "/usr/bin/wrtbak remote-download *",
    "/usr/bin/wrtbak restore-prepare *",
]:
    assert command in read_file, command
    assert read_file[command] == ["exec"], command
    assert command not in write_file, command

for command in [
    "/usr/bin/wrtbak restore-prebackup *",
    "/usr/bin/wrtbak restore-apply *",
    "/usr/bin/wrtbak restore-sysupgrade *",
]:
    assert command in write_file, command
    assert write_file[command] == ["exec"], command
    assert command not in read_file, command

for pattern in [
    "/tmp/wrtbak/downloads/*.wrtbak",
    "/tmp/wrtbak/downloads/*.sysupgrade.tar.gz",
]:
    assert read_file.get(pattern) == ["read", "stat"], pattern

for forbidden in [
    "/tmp/wrtbak/*",
    "/tmp/wrtbak/*.wrtbak",
    "/tmp/wrtbak/*.sysupgrade.tar.gz",
    "/tmp/wrtbak/restore-cache/*",
    "/tmp/wrtbak/restore-logs/*",
    "/tmp/wrtbak/*.remote.json",
    "/tmp/wrtbak/*.receipt.json",
]:
    assert forbidden not in read_file, forbidden
PY
```

- [ ] **Step 2: Create `restore.sh` with JSON error helper and path policy stubs**

Create `root/usr/lib/wrtbak/restore.sh`:

```sh
#!/bin/sh

wrtbak_restore_error_json() {
	wrtbak_operation=$1
	wrtbak_code=$2
	wrtbak_message=$3
	wrtbak_detail=${4:-}
	printf '{\n'
	printf '  "ok": false,\n'
	printf '  "operation": '; wrtbak_json_string "$wrtbak_operation"; printf ',\n'
	printf '  "code": '; wrtbak_json_string "$wrtbak_code"; printf ',\n'
	printf '  "message": '; wrtbak_json_string "$wrtbak_message"; printf ',\n'
	printf '  "detail": '; wrtbak_json_string "$wrtbak_detail"; printf '\n'
	printf '}\n'
}

wrtbak_restore_invalid_json() {
	wrtbak_operation=$1
	wrtbak_code=$2
	wrtbak_message=$3
	wrtbak_value=${4:-}
	wrtbak_restore_error_json "$wrtbak_operation" "$wrtbak_code" "$wrtbak_message" "$wrtbak_value"
	return 1
}

wrtbak_restore_validate_input_path() {
	wrtbak_operation=$1
	wrtbak_input=$2
	wrtbak_expected=$3
	wrtbak_restore_invalid_json "$wrtbak_operation" not_implemented "Local Archive Path Policy is not implemented" "$wrtbak_expected:$wrtbak_input"
}

wrtbak_restore_validate_prebackup_path() {
	wrtbak_operation=$1
	wrtbak_prebackup=$2
	wrtbak_restore_invalid_json "$wrtbak_operation" not_implemented "prebackup path validation is not implemented" "$wrtbak_prebackup"
}

wrtbak_restore_prepare() {
	wrtbak_restore_error_json restore-prepare not_implemented "restore-prepare is not implemented" ""
	return 1
}

wrtbak_restore_prebackup() {
	wrtbak_restore_error_json restore-prebackup not_implemented "restore-prebackup is not implemented" ""
	return 1
}

wrtbak_restore_apply() {
	wrtbak_restore_error_json restore-apply not_implemented "restore-apply is not implemented" ""
	return 1
}

wrtbak_restore_sysupgrade() {
	wrtbak_restore_error_json restore-sysupgrade not_implemented "restore-sysupgrade is not implemented" ""
	return 1
}
```

- [ ] **Step 3: Add `remote-download` skeleton**

In `root/usr/lib/wrtbak/remote.sh`, add a temporary command skeleton so ACL and parser routing are deliberate in Chunk 1:

```sh
wrtbak_remote_download() {
	wrtbak_remote_error_json remote-download "$1" not_implemented "remote-download is not implemented" "$2"
	return 1
}
```

- [ ] **Step 4: Source `restore.sh` and add CLI usage/parser functions**

In `root/usr/bin/wrtbak`, source `restore.sh` after `remote_s3.sh`, add usage lines for all new commands, then add parsers with these exact argument contracts:

- `remote-download`: accepts `--target`, `--path`, `--json`; requires target and path; calls `wrtbak_remote_download "$wrtbak_target" "$wrtbak_path"`.
- `restore-prepare`: accepts `--input`, `--json`; requires input; calls `wrtbak_restore_prepare "$wrtbak_input"`.
- `restore-prebackup`: accepts `--profile`, `--items`, `--format`, `--json`; defaults format to `wrtbak`; requires profile and items; calls `wrtbak_restore_prebackup "$wrtbak_profile" "$wrtbak_items" "$wrtbak_format"`.
- `restore-apply`: accepts `--input`, `--mode`, `--items`, `--prebackup`, `--confirm`, `--restart-services`, `--json`; defaults mode to `selected`, items to `all`, restart-services to `0`; requires input, prebackup, and confirm; calls `wrtbak_restore_apply "$wrtbak_input" "$wrtbak_mode" "$wrtbak_items" "$wrtbak_prebackup" "$wrtbak_confirm" "$wrtbak_restart_services"`.
- `restore-sysupgrade`: accepts `--input`, `--prebackup`, `--confirm`, `--execute`, `--json`; defaults execute to `0`; requires input, prebackup, and confirm; calls `wrtbak_restore_sysupgrade "$wrtbak_input" "$wrtbak_prebackup" "$wrtbak_confirm" "$wrtbak_execute"`.

Use the existing case-parser style. `--json` is optional-but-accepted for consistency with existing JSON commands; output is JSON for these commands regardless.

- [ ] **Step 5: Add ACL exec permissions**

Add read exec permissions for `remote-download` and `restore-prepare`; add write exec permissions for `restore-prebackup`, `restore-apply`, and `restore-sysupgrade`.

- [ ] **Step 6: Verify skeleton**

Run:

```sh
sh -n root/usr/bin/wrtbak root/usr/lib/wrtbak/*.sh
for script in root/usr/bin/wrtbak root/usr/lib/wrtbak/*.sh; do sh -n "$script"; done
sh tests/test_luci_layout.sh
tmp_root=$(mktemp -d)
mkdir -p "$tmp_root/etc/config"
printf "config wrtbak 'main'\n" > "$tmp_root/etc/config/wrtbak"
WRTBAK_ROOT="$tmp_root" WRTBAK_LIBDIR="$PWD/root/usr/lib/wrtbak" root/usr/bin/wrtbak remote-download --target webdav --path bad.wrtbak --json > /tmp/wrtbak-skeleton-remote.json || true
WRTBAK_ROOT="$tmp_root" WRTBAK_LIBDIR="$PWD/root/usr/lib/wrtbak" root/usr/bin/wrtbak restore-prepare --input /tmp/wrtbak/restore-cache/missing.wrtbak --json > /tmp/wrtbak-skeleton-prepare.json || true
WRTBAK_ROOT="$tmp_root" WRTBAK_LIBDIR="$PWD/root/usr/lib/wrtbak" root/usr/bin/wrtbak restore-prebackup --profile pre-restore --items all --format wrtbak --json > /tmp/wrtbak-skeleton-prebackup.json || true
WRTBAK_ROOT="$tmp_root" WRTBAK_LIBDIR="$PWD/root/usr/lib/wrtbak" root/usr/bin/wrtbak restore-apply --input /tmp/wrtbak/restore-cache/missing.wrtbak --mode all --items all --prebackup /tmp/wrtbak/pre-restore-missing.wrtbak --confirm RESTORE --restart-services 0 --json > /tmp/wrtbak-skeleton-apply.json || true
WRTBAK_ROOT="$tmp_root" WRTBAK_LIBDIR="$PWD/root/usr/lib/wrtbak" root/usr/bin/wrtbak restore-sysupgrade --input /tmp/wrtbak/restore-cache/missing.sysupgrade.tar.gz --prebackup /tmp/wrtbak/pre-restore-missing.wrtbak --confirm RESTORE --execute 0 --json > /tmp/wrtbak-skeleton-sysupgrade.json || true
python3 - <<'PY'
import json
for path, operation in [
    ("/tmp/wrtbak-skeleton-remote.json", "remote-download"),
    ("/tmp/wrtbak-skeleton-prepare.json", "restore-prepare"),
    ("/tmp/wrtbak-skeleton-prebackup.json", "restore-prebackup"),
    ("/tmp/wrtbak-skeleton-apply.json", "restore-apply"),
    ("/tmp/wrtbak-skeleton-sysupgrade.json", "restore-sysupgrade"),
]:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    assert data["ok"] is False
    assert data["operation"] == operation
    assert data["code"] == "not_implemented"
PY
rm -rf "$tmp_root"
```

Expected: syntax/layout pass; new commands return not implemented if invoked.

- [ ] **Step 7: Commit**

```sh
git add root/usr/bin/wrtbak root/usr/lib/wrtbak/remote.sh root/usr/lib/wrtbak/restore.sh root/usr/share/rpcd/acl.d/luci-app-wrtbak.json tests/test_luci_layout.sh
git commit -m "feat: add restore command skeletons"
```

---

## Chunk 2: Remote Download And Restore Preparation

### Task 3: Implement remote download drivers and cache sidecars

**Files:**
- Modify: `root/usr/lib/wrtbak/remote.sh`
- Modify: `root/usr/lib/wrtbak/remote_webdav.sh`
- Modify: `root/usr/lib/wrtbak/remote_s3.sh`
- Modify: `root/usr/bin/wrtbak`
- Add: `tests/test_remote_download_fixture.sh`

- [ ] **Step 1: Write fixture for WebDAV and S3 download**

Create `tests/test_remote_download_fixture.sh` with fake `curl` and `rclone` binaries. The fixture must prove:

```sh
remote-download --target webdav --path "$device_prefix/wrtbak/2026/sample.wrtbak" --json
remote-download --target s3 --path "$device_prefix/wrtbak/2026/sample.wrtbak" --json
```

Both outputs contain `ok:true`, `local_path` under `/tmp/wrtbak/restore-cache/`, `sidecar_path`, `size`, `sha256`, and no secret values in fake command logs.
The fixture must also cover:

- invalid remote path outside the current device prefix returns `ok:false`
- unsupported suffix returns `ok:false`
- missing remote size returns `code:"size_unavailable"`
- failed driver download removes `.part.$$`
- existing cache without matching sidecar returns `code:"cache_conflict"`
- first download writes a sidecar with `target`, `driver`, `remote_path`, `filename`, `format`, `size`, `remote_modified`, `remote_etag`, `downloaded_at`, and local `sha256`
- second download reuses cache when size and local sha match and the driver exposes no modified/etag metadata
- second download reuses cache when size, local sha, `remote_modified`, and `remote_etag` all match
- second download rejects reuse and re-downloads when `remote_modified` changes
- second download rejects reuse and re-downloads when `remote_etag` changes

- [ ] **Step 2: Add cache helper functions**

In `remote.sh`, add:

```sh
wrtbak_restore_cache_dir() { printf '%s\n' "$(wrtbak_root_path /tmp/wrtbak/restore-cache)"; }
wrtbak_remote_safe_basename() { basename -- "$1" | tr -c 'A-Za-z0-9._-' '-'; }
```

Cache filenames use `<sha256(remote_path)-12>-<safe-basename>`.
Implement the remaining helpers with these exact contracts:

- `wrtbak_remote_cache_path_for remote_path`: creates the restore cache directory with mode `700`, computes `sha256sum` of the normalized remote path, takes the first 12 hex chars, appends the safe basename, and prints the absolute cache path.
- `wrtbak_remote_sidecar_matches sidecar local_path target driver remote_path size remote_modified remote_etag`: returns success only when the sidecar exists, JSON fields `target`, `driver`, `remote_path`, and `size` match, the local file exists, local sha256 equals the sidecar `sha256`, and any non-empty `remote_modified` or `remote_etag` equals the sidecar value.
- `wrtbak_remote_write_sidecar sidecar local_path target driver remote_path filename format size remote_modified remote_etag`: writes to `sidecar.tmp.$$`, includes all required fields, sets mode `600`, and atomically renames into place.
- If a driver exposes neither `remote_modified` nor `remote_etag`, `wrtbak_remote_sidecar_matches` accepts size plus local sha256.

Cache decision table:

| Local cache | Sidecar | Metadata / sha state | Action |
|-------------|---------|----------------------|--------|
| absent | absent | any | download to `.part.$$`, verify, write sidecar |
| absent | present | any | remove stale sidecar, download to `.part.$$`, verify, write sidecar |
| present | absent | any | fail with `code:"cache_conflict"` |
| present | present | target, driver, remote_path, size, local sha, and provided modified/etag all match | reuse cache and emit JSON without downloading |
| present | present | target, driver, or remote_path mismatch | fail with `code:"cache_conflict"` |
| present | present | sidecar sha differs from current local file sha | fail with `code:"cache_conflict"` |
| present | present | size differs | re-download to `.part.$$`, verify, replace cache, rewrite sidecar |
| present | present | `remote_modified` differs while driver provides it | re-download to `.part.$$`, verify, replace cache, rewrite sidecar |
| present | present | `remote_etag` differs while driver provides it | re-download to `.part.$$`, verify, replace cache, rewrite sidecar |

The deliberate re-download path is only the last three rows: changed size, changed `remote_modified`, or changed `remote_etag` for the same target/driver/remote path and an intact local cache file.

- [ ] **Step 3: Add driver metadata/download helpers**

In `remote_webdav.sh`, add:

```sh
wrtbak_webdav_stat_file url username password remote_path
wrtbak_webdav_download_file url username password remote_path local_path
```

`stat_file` prints TSV: `size<TAB>modified<TAB>etag`. `download_file` uses `curl --netrc-file` and never passes credentials through argv.

In `remote_s3.sh`, add:

```sh
wrtbak_s3_stat_file endpoint region bucket access_key secret_key force_path_style remote_path
wrtbak_s3_download_file endpoint region bucket access_key secret_key force_path_style remote_path local_path
```

Use `rclone lsjson` for metadata and `rclone copyto` for download; secrets stay in the temporary config file.

- [ ] **Step 4: Implement `wrtbak_remote_download`**

In `remote.sh`, implement:

```sh
wrtbak_remote_download target remote_path
```

It resolves target, validates the path with `wrtbak_remote_validate_backup_path`, checks suffix, acquires the remote lock, gets metadata, rejects missing size, downloads to `.part.$$`, verifies size, computes sha256, writes sidecar, appends sanitized history, and emits spec-shaped JSON.

- [ ] **Step 5: Complete and verify the existing CLI parser**

In `root/usr/bin/wrtbak`, replace the Chunk 1 `remote-download` skeleton routing with the real parser behavior: accept `--target`, `--path`, and optional `--json`, require target and path, then call `wrtbak_remote_download`.

- [ ] **Step 6: Run fixture**

Run:

```sh
sh tests/test_remote_download_fixture.sh
```

Expected: PASS for WebDAV, S3, invalid prefix, cache conflict, unavailable size, partial cleanup, and cache reuse.

- [ ] **Step 7: Commit**

```sh
git add root/usr/bin/wrtbak root/usr/lib/wrtbak/remote.sh root/usr/lib/wrtbak/remote_webdav.sh root/usr/lib/wrtbak/remote_s3.sh tests/test_remote_download_fixture.sh
git commit -m "feat: download remote backups into restore cache"
```

### Task 4: Implement restore-prepare and prebackup receipts

**Files:**
- Modify: `root/usr/lib/wrtbak/restore.sh`
- Modify: `root/usr/lib/wrtbak/agent.sh`
- Add: `tests/test_restore_apply_fixture.sh`

- [ ] **Step 1: Write failing prepare/prebackup tests**

In `tests/test_restore_apply_fixture.sh`, create a fixture root, a source archive, and assert:

```sh
wrtbak restore-prepare --input "$cache_archive" --json
wrtbak restore-prebackup --profile pre-restore --items all --format wrtbak --json
```

Expected prepare output includes `operation`, `format`, `archive`, `current_device`, `source_device`, `manifest`, `compatibility`, and `plan.paths[]` entries with `path`, `archive_path`, `type`, `size`, `sha256`, `items`, `sensitive`, `selected`, and `action`.
The `.wrtbak` prepare JSON assertions must explicitly check:

```python
assert data["ok"] is True
assert data["operation"] == "restore-prepare"
assert data["input"] == cache_archive
assert data["format"] == "wrtbak"
assert data["archive"]["filename"].endswith(".wrtbak")
assert data["archive"]["size"] > 0
assert len(data["archive"]["sha256"]) == 64
assert data["current_device"]["device_id"]
assert data["current_device"]["hostname"]
assert data["source_device"]["hostname"]
assert data["manifest"]["schema"] == "wrtbak/v1"
assert data["manifest"]["profile"] == source_profile
assert data["manifest"]["created_at"].endswith("Z")
assert data["compatibility"]["blocking"] is False
assert isinstance(data["compatibility"]["warnings"], list)
assert data["plan"]["file_count"] >= 1
assert data["plan"]["total_bytes"] > 0
assert isinstance(data["plan"]["restart_services"], list)
assert data["plan"]["reboot_recommended"] is True
assert data["plan"]["requires_confirmation"] is True
path = data["plan"]["paths"][0]
assert path["path"].startswith("/")
assert path["archive_path"].startswith("rootfs/")
assert path["type"] in ("file", "directory")
assert "size" in path
assert "sha256" in path
assert isinstance(path["items"], list)
assert isinstance(path["sensitive"], bool)
assert path["selected"] is True
assert path["action"] == "write"
```

The sysupgrade prepare JSON assertions must explicitly check:

```python
assert data["ok"] is True
assert data["operation"] == "restore-prepare"
assert data["input"] == sysupgrade_archive
assert data["format"] == "sysupgrade"
assert data["archive"]["filename"].endswith(".sysupgrade.tar.gz")
assert data["archive"]["size"] > 0
assert len(data["archive"]["sha256"]) == 64
assert data["manifest"]["present"] is True
assert data["manifest"]["schema"] == "wrtbak/v1"
assert data["manifest"]["path"] == "etc/backup/wrtbak-manifest.json"
assert data["compatibility"]["blocking"] is False
assert isinstance(data["compatibility"]["warnings"], list)
assert data["plan"]["file_count"] >= 1
assert data["plan"]["total_bytes"] > 0
assert isinstance(data["plan"]["restart_services"], list)
assert data["plan"]["reboot_recommended"] is True
assert data["plan"]["requires_confirmation"] is True
path = data["plan"]["paths"][0]
assert path["path"].startswith("/")
assert path["archive_path"].startswith("etc/")
assert path["type"] in ("file", "directory")
assert "size" in path
assert "sha256" in path
assert isinstance(path["items"], list)
assert isinstance(path["sensitive"], bool)
assert path["selected"] is True
assert path["action"] == "sysupgrade-restore"
```

- [ ] **Step 2: Add local archive path policy**

In `restore.sh`, implement:

```sh
wrtbak_restore_validate_input_path OPERATION INPUT EXPECTED_FORMATS
wrtbak_restore_validate_prebackup_path PREBACKUP
```

Use spec patterns:

```text
/tmp/wrtbak/restore-cache/*.wrtbak
/tmp/wrtbak/restore-cache/*.sysupgrade.tar.gz
/tmp/wrtbak/downloads/*.wrtbak
/tmp/wrtbak/downloads/*.sysupgrade.tar.gz
/tmp/wrtbak/pre-restore-*.wrtbak
```

Reject symlinks, non-regular files, `..`, relative paths, wrong suffixes, and wrong command/format combinations.
Add fixture assertions for each rejection:

```sh
assert_reject wrtbak restore-prepare --input relative.wrtbak --json
assert_reject wrtbak restore-prepare --input /tmp/wrtbak/restore-cache/../bad.wrtbak --json
assert_reject wrtbak restore-prepare --input /tmp/wrtbak/restore-cache/link.wrtbak --json
assert_reject wrtbak restore-prepare --input /etc/config/system --json
assert_reject wrtbak restore-prepare --input /tmp/wrtbak/restore-cache/directory.wrtbak --json
assert_reject wrtbak restore-prepare --input /tmp/wrtbak/restore-cache/bad.txt --json
assert_reject wrtbak restore-apply --input /tmp/wrtbak/restore-cache/sample.wrtbak --mode all --items all --prebackup /etc/config/system --confirm RESTORE --json
assert_reject wrtbak restore-apply --input /tmp/wrtbak/restore-cache/sample.sysupgrade.tar.gz --mode all --items all --prebackup "$prebackup" --confirm RESTORE --json
assert_reject wrtbak restore-sysupgrade --input /tmp/wrtbak/restore-cache/sample.wrtbak --prebackup "$prebackup" --confirm RESTORE --json
```

Each rejection assertion must parse JSON and verify `invalid_input_path` for bad `--input` values or `invalid_prebackup` for bad `--prebackup` values.

- [ ] **Step 3: Implement `restore-prepare` for `.wrtbak`**

Extract to a temp dir, reuse existing archive safety validation, validate manifest, read device/firmware fields, build `plan.paths[]` from `manifest.files[]` when available, and map paths to current item IDs using `wrtbak_item_paths_by_id`.

- [ ] **Step 4: Implement `restore-prepare` for sysupgrade**

Validate root-relative tar members, reject unsafe types, read `etc/backup/wrtbak-manifest.json` when present, and emit the sysupgrade success shape with `action:"sysupgrade-restore"`.

- [ ] **Step 5: Implement `restore-prebackup`**

Create `/tmp/wrtbak/pre-restore-<timestamp>.wrtbak` using `wrtbak_create_archive`, compute size and sha256, and write `<archive>.receipt.json` with `operation`, `host_device_id`, `host_hostname`, `path`, `size`, `sha256`, `created_at`, and `format`.
The fixture must parse `<archive>.receipt.json` and assert:

```python
assert receipt["operation"] == "restore-prebackup"
assert data["receipt_path"].endswith(".receipt.json")
assert os.path.isfile(data["receipt_path"])
assert os.path.isfile(data["path"])
assert receipt["path"] == data["path"]
assert receipt["size"] == data["size"]
assert receipt["sha256"] == data["sha256"]
assert os.path.getsize(data["path"]) == data["size"]
assert sha256_file(data["path"]) == data["sha256"]
assert receipt["host_device_id"]
assert receipt["host_device_id"] == current_device_id
assert receipt["host_hostname"]
assert receipt["created_at"].endswith("Z")
assert parse_utc(receipt["created_at"]) >= now_utc - datetime.timedelta(minutes=5)
assert receipt["format"] == "wrtbak"
```

- [ ] **Step 6: Run prepare/prebackup tests**

Run:

```sh
sh tests/test_restore_apply_fixture.sh
```

Expected: prepare/prebackup assertions and Local Archive Path Policy rejection assertions pass. Apply assertions may be added in Task 5, but the fixture must remain runnable and passing at the end of this task.

- [ ] **Step 7: Commit**

```sh
git add root/usr/lib/wrtbak/restore.sh root/usr/lib/wrtbak/agent.sh tests/test_restore_apply_fixture.sh
git commit -m "feat: prepare restore plans and prebackup receipts"
```

---

## Chunk 3: Apply, Sysupgrade, LuCI, Docs, And Verification

### Task 5: Implement safe `.wrtbak` apply and sysupgrade preflight

**Files:**
- Modify: `root/usr/lib/wrtbak/restore.sh`
- Modify: `tests/test_restore_apply_fixture.sh`

- [ ] **Step 1: Extend fixture for apply and sysupgrade**

Assert:

```sh
wrtbak restore-apply --input "$cache_archive" --mode selected --items test-restore --prebackup "$prebackup" --confirm RESTORE --restart-services 0 --json
wrtbak restore-apply --input "$cache_archive" --mode all --items all --prebackup "$prebackup" --confirm RESTORE --restart-services 1 --json
wrtbak restore-sysupgrade --input "$sysupgrade_archive" --prebackup "$prebackup" --confirm RESTORE --execute 0 --json
```

Also assert missing confirmation, invalid prebackup, unsafe tar members, sha mismatch, non-sysupgrade input, and fake non-zero `sysupgrade` exit.
The fixture must explicitly assert:

- `restore-apply` rejects missing confirmation with `code:"missing_confirmation"`
- `restore-apply` rejects missing prebackup with `code:"invalid_prebackup"`
- `restore-apply` rejects stale prebackup receipts older than 24 hours with `code:"invalid_prebackup"`
- `restore-apply` rejects unrelated prebackup receipts whose `host_device_id` differs from the current device with `code:"invalid_prebackup"`
- `restore-apply` rejects sha-mismatched prebackup receipts with `code:"invalid_prebackup"`
- `restore-sysupgrade` rejects missing confirmation with `code:"missing_confirmation"`
- `restore-sysupgrade` rejects stale, unrelated, and sha-mismatched prebackup receipts with `code:"invalid_prebackup"`
- `restore-sysupgrade --execute 1` with fake `sysupgrade` exit code `7` returns exact `ok:false`, `operation:"restore-sysupgrade"`, `execute:true`, `status:"failed"`, `code:"sysupgrade_failed"`, `message:"sysupgrade restore failed"`, `input` equal to the sysupgrade archive, `prebackup_path` equal to the supplied prebackup, `sysupgrade_exit_code:7`, and `reboot_recommended:true`
- `restore-apply --restart-services 1` with manifest services `network dnsmasq` returns `restarted_services:["dnsmasq"]`, `blocked_restart_services:["network"]`, and `reboot_recommended:true`
- `restore-apply --mode selected` with overlapping items de-duplicates final target paths before writing
- `restore-apply --mode selected` reports `missing_from_archive` for selected catalog paths absent from the archive without failing
- `restore-apply --mode selected` reports files present in the archive but outside the selected item paths as skipped and increments `skipped_count`
- a forced mid-apply write failure returns `ok:false` with `written_count`, `failed_path`, and `restore_log`, and the log file exists

- [ ] **Step 2: Implement receipt validation**

In `restore.sh`, add:

```sh
wrtbak_restore_validate_receipt PREBACKUP
```

Check receipt path, existence, size, sha256, host device ID, age under 24 hours, and format `wrtbak`.

- [ ] **Step 3: Implement selected/all file matching**

Build selected target paths from `wrtbak_write_paths_for_items`. A file is eligible if it exactly equals a selected file path or is below a selected directory. Unknown item IDs return `invalid_items`.
The implementation must sort and de-duplicate eligible final target paths before validation and writing.
It must keep three report lists in the JSON result or restore log: `written`, `skipped`, and `missing_from_archive`.

- [ ] **Step 4: Implement write-phase safety**

Validate all archive files before writing. Copy to `<target>.wrtbak-restore.$$`, fsync when available, chmod, rename into place, and write per-file previous backups and JSONL restore log under `/tmp/wrtbak/restore-logs/`.
The mid-apply failure path must stop immediately and return `ok:false` with `written_count`, `failed_path`, and `restore_log`.

- [ ] **Step 5: Implement service restart reporting**

Use high-risk list `network firewall dropbear tailscale wireguard nikki mosdns`. Restart only low-risk services when `--restart-services 1`. Emit `restart_services`, `restarted_services`, `blocked_restart_services`, `restart_errors`, and `reboot_recommended`.

- [ ] **Step 6: Implement sysupgrade preflight and execute**

For `--execute 0`, emit preflight JSON and do not write. For `--execute 1`, call `sysupgrade -r "$input"` after validation. Emit success JSON when it returns 0 and `sysupgrade_failed` JSON when non-zero.

- [ ] **Step 7: Run apply tests**

Run:

```sh
sh tests/test_restore_apply_fixture.sh
```

Expected: PASS.

- [ ] **Step 8: Commit**

```sh
git add root/usr/lib/wrtbak/restore.sh tests/test_restore_apply_fixture.sh
git commit -m "feat: apply reviewed restore archives safely"
```

### Task 6: Add LuCI restore workflow

**Files:**
- Modify: `htdocs/luci-static/resources/view/wrtbak/index.js`
- Modify: `tests/test_luci_layout.sh`

- [ ] **Step 1: Write failing LuCI layout assertions**

Add assertions for:

```sh
grep -Fq "runWrtbak([ 'remote-download'" "$view_file"
grep -Fq "runWrtbak([ 'restore-prepare'" "$view_file"
grep -Fq "runWrtbak([ 'restore-prebackup'" "$view_file"
grep -Fq "runWrtbak([ 'restore-apply'" "$view_file"
grep -Fq "runWrtbak([ 'restore-sysupgrade'" "$view_file"
grep -Fq "RESTORE" "$view_file"
grep -Fq "wrtbak-restore-panel" "$view_file"
grep -Fq "restoreState.phase === 'prebackup_ready'" "$view_file"
grep -Fq "confirmationInput.value === 'RESTORE'" "$view_file"
grep -Fq "blocked_restart_services" "$view_file"
grep -Fq "sysupgrade_failed" "$view_file"
grep -Fq "wrtbak-sysupgrade-execute" "$view_file"
grep -Fq "wrtbak-restore-unknown" "$view_file"
```

Add a small Node.js structural test under `tests/test_luci_layout.sh` or a new `tests/test_luci_restore_view_fixture.sh` that reads `index.js` as text and verifies:

```js
assert(view.includes("'remote-download', '--target', selectedTarget(), '--path'"));
assert(view.includes("'restore-prepare', '--input'"));
assert(view.includes("'restore-prebackup', '--profile', 'pre-restore', '--items', 'all', '--format', 'wrtbak'"));
assert(view.includes("'restore-apply', '--input'"));
assert(view.includes("'--prebackup', restoreState.prebackup.path"));
assert(view.includes("'--confirm', 'RESTORE'"));
assert(view.includes("'--restart-services', '0'"));
assert(view.includes("'restore-sysupgrade', '--input'"));
assert(view.includes("'--execute', '0'"));
assert(view.includes("'--execute', '1'"));
assert(view.includes("applyButton.disabled = restoreState.phase !== 'prebackup_ready'"));
assert(view.includes("confirmationInput.value === 'RESTORE'"));
assert(view.includes("sysupgrade_exit_code"));
assert(view.includes("wrtbak-restore-unknown"));
assert(view.includes("restoreState.phase = 'idle'"));
```

This is still static, but it proves command argument mapping and gate expressions, not only command names.

- [ ] **Step 2: Add restore state object and helpers**

In `index.js`, add:

```js
var restoreState = { phase: 'idle', target: null, backup: null, download: null, prepare: null, prebackup: null };
function setRestorePhase(phase) { restoreState.phase = phase; renderRestorePanel(); }
```

Keep LuCI as a command orchestrator; do not parse archive contents in JavaScript.

- [ ] **Step 3: Add row actions**

Change `renderBackupRows(table, backups, onDelete)` to accept `onRestore`, and add:

```js
E('button', { click: function() { onRestore(backup); } }, backup.format === 'sysupgrade' ? _('Restore via sysupgrade') : _('Restore'))
```

- [ ] **Step 4: Add review panel**

Render archive metadata, compatibility warnings, `plan.paths`, prebackup result, confirmation input, and apply buttons. Apply buttons stay disabled until phase is `prebackup_ready` and confirmation input is exactly `RESTORE`.

- [ ] **Step 5: Wire command flow**

Restore button calls:

```js
remote-download -> restore-prepare -> show review
```

Prebackup button calls:

```js
restore-prebackup --profile pre-restore --items all --format wrtbak --json
```

Apply calls either:

```js
restore-apply --mode selected --items core-system --confirm RESTORE --restart-services 0
restore-apply --mode all --items all --confirm RESTORE --restart-services 0
restore-sysupgrade --confirm RESTORE --execute 0
restore-sysupgrade --confirm RESTORE --execute 1
```

Every apply/sysupgrade command must include `--prebackup restoreState.prebackup.path`.

The sysupgrade UI path is concrete:

- The first sysupgrade button runs `restore-sysupgrade --execute 0` and displays the preflight JSON.
- A second danger button with id/class marker `wrtbak-sysupgrade-execute` appears only after successful preflight, successful prebackup, and exact `RESTORE` confirmation.
- The danger button runs `restore-sysupgrade --execute 1`.
- If the command returns `ok:true`, LuCI shows `status:"completed"` and tells the operator to reconnect after reboot.
- If the command returns `ok:false` with `code:"sysupgrade_failed"`, LuCI renders the exit code and keeps the restore panel in `failed`.
- If the HTTP/RPC call rejects or times out during execute, LuCI marks the panel with `wrtbak-restore-unknown` and tells the operator to reconnect and inspect router state.
- Refreshing the remote backup list must reset `restoreState` to `{ phase: 'idle', target: null, backup: null, download: null, prepare: null, prebackup: null }` and clear the restore panel.

- [ ] **Step 6: Run layout test**

Run:

```sh
sh tests/test_luci_layout.sh
```

Expected: PASS.

- [ ] **Step 7: Commit**

```sh
git add htdocs/luci-static/resources/view/wrtbak/index.js tests/test_luci_layout.sh
git commit -m "feat: add LuCI remote restore workflow"
```

### Task 7: Documentation, full local verification, and SDK build

**Files:**
- Modify: `docs/ROADMAP.md`
- Modify: `docs/AGENT_MAINTENANCE.md`
- Modify: `docs/DEVELOPMENT.md`
- Modify: `docs/BACKUP_FORMAT.md`
- Modify: `README.md` if command list or feature matrix changes.

- [ ] **Step 1: Update docs**

Document:

```text
restore can interrupt management access
pre-restore backup is mandatory
RESTORE confirmation is mandatory
cross-device restores warn but do not block unless schema/safety fails
.sysupgrade.tar.gz uses sysupgrade -r
agents must ask before high-risk network restore
```

- [ ] **Step 2: Run full local checks**

Run:

```sh
sh -n root/usr/bin/wrtbak root/usr/lib/wrtbak/*.sh tests/*.sh
for test_script in tests/*.sh; do sh "$test_script"; done
git diff --check
```

Expected: all pass.

- [ ] **Step 3: Trigger GitHub Actions SDK build**

Run:

```sh
export triggered_after=$(date -u +%Y-%m-%dT%H:%M:%SZ)
gh workflow run build-package.yml --repo hotwa/luci-app-wrtbak --ref codex/remote-restore-design -f arch=aarch64_cortex-a53 -f packages=luci-app-wrtbak
sleep 10
gh run list --repo hotwa/luci-app-wrtbak --workflow build-package.yml --branch codex/remote-restore-design --limit 10
```

Wait for the matching run created after `$triggered_after` and verify `package-layout` and `openwrt-sdk-build` pass.

- [ ] **Step 4: Download APK artifact**

Run:

```sh
mkdir -p /tmp/wrtbak-apk
run_id=$(
  gh run list --repo hotwa/luci-app-wrtbak --workflow build-package.yml --branch codex/remote-restore-design \
    --json databaseId,event,conclusion,status,createdAt \
    | python3 -c 'import json,os,sys; t=os.environ["triggered_after"]; runs=json.load(sys.stdin); print(next(str(r["databaseId"]) for r in runs if r["event"]=="workflow_dispatch" and r["status"]=="completed" and r["conclusion"]=="success" and r["createdAt"] >= t), "")'
)
test -n "$run_id"
gh run download "$run_id" --repo hotwa/luci-app-wrtbak --name luci-app-wrtbak-sdk-aarch64_cortex-a53 --dir /tmp/wrtbak-apk
find /tmp/wrtbak-apk -name 'luci-app-wrtbak*.apk' -print
```

- [ ] **Step 5: Deploy to test router**

Run:

```sh
apk_path=$(find /tmp/wrtbak-apk -name 'luci-app-wrtbak*.apk' -print -quit)
test -n "$apk_path"
scp "$apk_path" root@192.168.11.234:/tmp/
ssh root@192.168.11.234 'apk add --allow-untrusted /tmp/luci-app-wrtbak*.apk && /etc/init.d/rpcd restart && /etc/init.d/uhttpd restart'
```

- [ ] **Step 6: Commit docs**

```sh
git add docs README.md
git commit -m "docs: document remote restore operations"
```

### Task 8: Real WebDAV/S3 restore QA and merge

**Files:**
- No secret-bearing files. Use router runtime UCI only.
- Update docs only if QA exposes operator notes.

- [ ] **Step 1: Confirm router dependencies and remote config**

Run:

```sh
ssh root@192.168.11.234 'wrtbak remote-status --json; command -v curl; command -v rclone; command -v jsonfilter'
```

Expected: WebDAV and S3 configured, curl, rclone, and jsonfilter available. Do not print secrets.

- [ ] **Step 2: Record the test router baseline**

Run:

```sh
ssh root@192.168.11.234 '
set -eu
mkdir -p /tmp/wrtbak-qa
sha256sum /etc/config/system | awk "{print \$1}" > /tmp/wrtbak-qa/system.before.sha256
cp /etc/config/system /tmp/wrtbak-qa/system.before
'
```

The automated QA uses the low-risk `core-system` item on the disposable test router only.
It intentionally changes `/etc/config/system`, then restores the original content from remote.
It must not restore `network`, `firewall`, `dropbear`, `tailscale`, `wireguard`, `nikki`, or `mosdns`.

- [ ] **Step 3: WebDAV end-to-end**

Run on router:

```sh
ssh root@192.168.11.234 '
set -eu
mkdir -p /tmp/wrtbak-qa
wrtbak remote-upload --target webdav --profile qa-webdav-restore --items core-system --format wrtbak --prune-max 0 --json > /tmp/wrtbak-qa/webdav-upload.json
jsonfilter -i /tmp/wrtbak-qa/webdav-upload.json -e "@.remote_path" > /tmp/wrtbak-qa/webdav-remote-path.txt
cp /etc/config/system /tmp/wrtbak-qa/system.webdav.expected
printf \"# wrtbak qa webdav marker\\n\" >> /etc/config/system
changed_sha=$(sha256sum /etc/config/system | awk "{print \$1}")
before_sha=$(cat /tmp/wrtbak-qa/system.before.sha256)
test "$changed_sha" != "$before_sha"
remote_path=$(cat /tmp/wrtbak-qa/webdav-remote-path.txt)
wrtbak remote-download --target webdav --path "$remote_path" --json > /tmp/wrtbak-qa/webdav-download.json
local_path=$(jsonfilter -i /tmp/wrtbak-qa/webdav-download.json -e "@.local_path")
wrtbak restore-prepare --input "$local_path" --json > /tmp/wrtbak-qa/webdav-prepare.json
wrtbak restore-prebackup --profile pre-restore --items all --format wrtbak --json > /tmp/wrtbak-qa/webdav-prebackup.json
prebackup_path=$(jsonfilter -i /tmp/wrtbak-qa/webdav-prebackup.json -e "@.path")
wrtbak restore-apply --input "$local_path" --mode selected --items core-system --prebackup "$prebackup_path" --confirm RESTORE --restart-services 0 --json > /tmp/wrtbak-qa/webdav-apply.json
restored_sha=$(sha256sum /etc/config/system | awk "{print \$1}")
test "$restored_sha" = "$before_sha"
for name in webdav-download webdav-prepare webdav-prebackup webdav-apply; do
  test "$(jsonfilter -i /tmp/wrtbak-qa/$name.json -e "@.ok")" = "true"
done
written_count=$(jsonfilter -i /tmp/wrtbak-qa/webdav-apply.json -e "@.written_count")
test "$written_count" -ge 1
if jsonfilter -i /tmp/wrtbak-qa/webdav-apply.json -e "@.restarted_services[*]" | grep -Fx network; then
  echo "network must not be restarted during QA" >&2
  exit 1
fi
'
```

Expected: upload, download, prepare, prebackup, and low-risk apply pass; `/etc/config/system` hash is restored to the baseline; no secrets printed.

- [ ] **Step 4: S3 end-to-end**

Run the same content-change restore flow using `--target s3` and separate evidence files:

```sh
ssh root@192.168.11.234 '
set -eu
mkdir -p /tmp/wrtbak-qa
wrtbak remote-upload --target s3 --profile qa-s3-restore --items core-system --format wrtbak --prune-max 0 --json > /tmp/wrtbak-qa/s3-upload.json
jsonfilter -i /tmp/wrtbak-qa/s3-upload.json -e "@.remote_path" > /tmp/wrtbak-qa/s3-remote-path.txt
printf \"# wrtbak qa s3 marker\\n\" >> /etc/config/system
changed_sha=$(sha256sum /etc/config/system | awk "{print \$1}")
before_sha=$(cat /tmp/wrtbak-qa/system.before.sha256)
test "$changed_sha" != "$before_sha"
remote_path=$(cat /tmp/wrtbak-qa/s3-remote-path.txt)
wrtbak remote-download --target s3 --path "$remote_path" --json > /tmp/wrtbak-qa/s3-download.json
local_path=$(jsonfilter -i /tmp/wrtbak-qa/s3-download.json -e "@.local_path")
wrtbak restore-prepare --input "$local_path" --json > /tmp/wrtbak-qa/s3-prepare.json
wrtbak restore-prebackup --profile pre-restore --items all --format wrtbak --json > /tmp/wrtbak-qa/s3-prebackup.json
prebackup_path=$(jsonfilter -i /tmp/wrtbak-qa/s3-prebackup.json -e "@.path")
wrtbak restore-apply --input "$local_path" --mode selected --items core-system --prebackup "$prebackup_path" --confirm RESTORE --restart-services 0 --json > /tmp/wrtbak-qa/s3-apply.json
restored_sha=$(sha256sum /etc/config/system | awk "{print \$1}")
test "$restored_sha" = "$before_sha"
for name in s3-download s3-prepare s3-prebackup s3-apply; do
  test "$(jsonfilter -i /tmp/wrtbak-qa/$name.json -e "@.ok")" = "true"
done
written_count=$(jsonfilter -i /tmp/wrtbak-qa/s3-apply.json -e "@.written_count")
test "$written_count" -ge 1
if jsonfilter -i /tmp/wrtbak-qa/s3-apply.json -e "@.restarted_services[*]" | grep -Fx network; then
  echo "network must not be restarted during QA" >&2
  exit 1
fi
'
```

- [ ] **Step 5: LuCI browser QA**

Open `http://192.168.11.234/cgi-bin/luci/admin/system/wrtbak`, then verify:

```text
remote backups list renders
Restore button downloads and prepares
review panel shows plan and warnings
prebackup button enables apply
RESTORE confirmation gates apply
low-risk apply completes
```

Use Playwright/Chrome DevTools if available; otherwise capture CLI-backed evidence from LuCI commands and a screenshot.
The browser QA evidence must include:

- screenshot of the remote backup table with restore actions
- screenshot of the review panel after `restore-prepare`
- screenshot showing apply disabled before `RESTORE`
- screenshot or DOM assertion showing `blocked_restart_services` when present
- saved `/tmp/wrtbak-qa/webdav-*.json` and `/tmp/wrtbak-qa/s3-*.json`
- a final shell check that current `/etc/config/system` sha256 equals `/tmp/wrtbak-qa/system.before.sha256`
- a local scan confirming the saved JSON evidence does not contain WebDAV password, S3 access key, or S3 secret key

Use this secret scan without printing secret values:

```sh
ssh root@192.168.11.234 '
set -eu
webdav_password=$(uci -q get wrtbak.webdav.password || true)
s3_access=$(uci -q get wrtbak.s3.access_key || true)
s3_secret=$(uci -q get wrtbak.s3.secret_key || true)
for value_name in webdav_password s3_access s3_secret; do
  eval "value=\${$value_name}"
  [ -n "$value" ] || continue
  if grep -R -F "$value" /tmp/wrtbak-qa/*.json >/dev/null 2>&1; then
    echo "secret leaked in QA evidence: $value_name" >&2
    exit 1
  fi
done
'
```

- [ ] **Step 6: Push branch and create PR**

Run:

```sh
git status --short
git push -u origin codex/remote-restore-design
cat >/tmp/wrtbak-remote-restore-pr.md <<'EOF'
## Summary
- add safe WebDAV/S3 remote restore workflow
- require restore-prepare, pre-restore backup, and RESTORE confirmation before apply
- add LuCI restore review and apply controls

## Verification
- local shell syntax and fixture tests pass
- GitHub Actions package layout and OpenWrt SDK build pass
- APK installed on 192.168.11.234
- WebDAV restore QA passed
- S3 restore QA passed
- LuCI restore QA passed
EOF
gh pr create --repo hotwa/luci-app-wrtbak --base main --head codex/remote-restore-design --title "Add safe remote restore workflow" --body-file /tmp/wrtbak-remote-restore-pr.md
```

- [ ] **Step 7: Merge after CI**

After PR checks pass:

```sh
gh pr merge --repo hotwa/luci-app-wrtbak --squash --delete-branch
```

The goal is complete only after local checks, GitHub SDK build, APK install, WebDAV restore QA, S3 restore QA, LuCI restore QA, and merge to `main` are verified.
