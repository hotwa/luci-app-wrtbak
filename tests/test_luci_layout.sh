#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
view_file="$repo_dir/htdocs/luci-static/resources/view/wrtbak/index.js"
menu_file="$repo_dir/root/usr/share/luci/menu.d/luci-app-wrtbak.json"
acl_file="$repo_dir/root/usr/share/rpcd/acl.d/luci-app-wrtbak.json"

test -f "$view_file"
test -f "$menu_file"
test -f "$acl_file"

python3 -m json.tool "$menu_file" >/dev/null
python3 -m json.tool "$acl_file" >/dev/null

grep -Fq '"admin/system/wrtbak"' "$menu_file"
grep -Fq '"path": "wrtbak/index"' "$menu_file"
grep -Fq '"luci-app-wrtbak"' "$acl_file"
grep -Fq '"/usr/bin/wrtbak detect --json"' "$acl_file"
grep -Fq '"/usr/bin/wrtbak remote-status --json"' "$acl_file"
grep -Fq '"/usr/bin/wrtbak remote-list *"' "$acl_file"
grep -Fq '"/usr/bin/wrtbak remote-test *"' "$acl_file"
grep -Fq '"/usr/bin/wrtbak remote-upload *"' "$acl_file"
grep -Fq '"/usr/bin/wrtbak remote-delete *"' "$acl_file"
grep -Fq '"/usr/bin/wrtbak schedule-apply --json"' "$acl_file"
grep -Fq '"wrtbak"' "$acl_file"
grep -Fq '"/usr/bin/wrtbak create-download *"' "$acl_file"
! grep -Fq '"/tmp/wrtbak/*"' "$acl_file"
grep -Fq '"/tmp/wrtbak/downloads/*.wrtbak"' "$acl_file"
grep -Fq '"/tmp/wrtbak/downloads/*.sysupgrade.tar.gz"' "$acl_file"
! grep -Fq '"/tmp/wrtbak/*.wrtbak"' "$acl_file"
! grep -Fq '"/tmp/wrtbak/*.sysupgrade.tar.gz"' "$acl_file"
! grep -Fq '"/tmp/wrtbak/restore-cache/*"' "$acl_file"
! grep -Fq '"/tmp/wrtbak/restore-logs/*"' "$acl_file"
! grep -Fq '"/tmp/wrtbak/*.remote.json"' "$acl_file"
! grep -Fq '"/tmp/wrtbak/*.receipt.json"' "$acl_file"

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

grep -Fq "'require uci'" "$view_file"
grep -Fq "runWrtbak([ 'detect', '--json' ])" "$view_file"
grep -Fq "runWrtbak([ 'remote-status', '--json' ])" "$view_file"
grep -Fq "runWrtbak([ 'create-download'" "$view_file"
grep -Fq "runWrtbak([ 'remote-test'" "$view_file"
grep -Fq "runWrtbak([ 'remote-upload'" "$view_file"
grep -Fq "runWrtbak([ 'remote-list'" "$view_file"
grep -Fq "runWrtbak([ 'remote-delete'" "$view_file"
grep -Fq "runWrtbak([ 'remote-download'" "$view_file"
grep -Fq "runWrtbak([ 'restore-prepare'" "$view_file"
grep -Fq "runWrtbak([ 'restore-prebackup'" "$view_file"
grep -Fq "runWrtbak([ 'restore-apply'" "$view_file"
grep -Fq "runWrtbak([ 'restore-sysupgrade'" "$view_file"
grep -Fq "runWrtbak([ 'schedule-apply', '--json' ])" "$view_file"
grep -Fq "RESTORE" "$view_file"
grep -Fq "wrtbak-restore-panel" "$view_file"
grep -Fq "restoreState.phase === 'prebackup_ready'" "$view_file"
grep -Fq "confirmationInput.value === 'RESTORE'" "$view_file"
grep -Fq "blocked_restart_services" "$view_file"
grep -Fq "sysupgrade_failed" "$view_file"
grep -Fq "wrtbak-sysupgrade-execute" "$view_file"
grep -Fq "wrtbak-restore-unknown" "$view_file"
grep -Fq "uci.set('wrtbak', 'webdav'" "$view_file"
grep -Fq "uci.set('wrtbak', 's3'" "$view_file"
grep -Fq "uci.set('wrtbak', 'auto'" "$view_file"
grep -Fq "wrtbak-default-target" "$view_file"
grep -Fq "wrtbak-device-id" "$view_file"
grep -Fq "wrtbak-webdav-url" "$view_file"
grep -Fq "wrtbak-s3-endpoint" "$view_file"
grep -Fq "wrtbak-schedule-enabled" "$view_file"
grep -Fq "L.env.cgi_base + '/cgi-download'" "$view_file"
grep -Fq "wrtbak-download-frame" "$view_file"
grep -Fq "Rows per page" "$view_file"
grep -Fq "Previous" "$view_file"
grep -Fq "Next" "$view_file"
grep -Fq "showDownloadResult" "$view_file"
grep -Fq "Download" "$view_file"
grep -Fq "backup.legacy === true" "$view_file"
grep -Fq "wrtbak-legacy-backup" "$view_file"
grep -Fq "Restore and delete disabled" "$view_file"
grep -Fq "handleSaveApply: null" "$view_file"
grep -Fq "handleSave: null" "$view_file"
grep -Fq "handleReset: null" "$view_file"
grep -Fq "wrtbak-profile" "$view_file"
grep -Fq "wrtbak_profile" "$view_file"
grep -Fq "[A-Za-z0-9._\\\\-]+" "$view_file"

python3 - "$view_file" <<'PY'
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    view = handle.read()

for snippet in [
    "'remote-download', '--target', selectedTarget(), '--path'",
    "'restore-prepare', '--input'",
    "'restore-prebackup', '--profile', 'pre-restore', '--items', 'all', '--format', 'wrtbak'",
    "'restore-apply', '--input'",
    "'--prebackup', restoreState.prebackup.path",
    "'--confirm', 'RESTORE'",
    "'--restart-services', '0'",
    "'restore-sysupgrade', '--input'",
    "'--execute', '0'",
    "'--execute', '1'",
    "applyButton.disabled = restoreState.phase !== 'prebackup_ready'",
    "confirmationInput.value === 'RESTORE'",
    "sysupgrade_exit_code",
    "wrtbak-restore-unknown",
    "restoreState.phase = 'idle'",
]:
    assert snippet in view, snippet

assert "'--legacy-inspect'" not in view

legacy_marker = "if (backup.legacy === true)"
else_marker = "} else {"
assert legacy_marker in view
legacy_start = view.index(legacy_marker)
legacy_end = view.index(else_marker, legacy_start)
legacy_branch = view[legacy_start:legacy_end]
assert "onDelete" not in legacy_branch
assert "onRestore" not in legacy_branch

non_legacy_branch = view[legacy_end:view.index("table.appendChild", legacy_end)]
assert "onDelete(backup)" in non_legacy_branch
assert "onRestore(backup)" in non_legacy_branch
PY

echo "LuCI layout test passed"
