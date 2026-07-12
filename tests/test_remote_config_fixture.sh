#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-remote-config-test.XXXXXX")
fixture_root="$work_dir/root"
libdir="$repo_dir/root/usr/lib/wrtbak"
cli="$repo_dir/root/usr/bin/wrtbak"

cleanup() {
	rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p \
	"$fixture_root/etc/config" \
	"$fixture_root/etc" \
	"$fixture_root/tmp/sysinfo" \
	"$fixture_root/sys/class/net/br-lan" \
	"$fixture_root/sys/class/net/eth0"

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
	option username 'webdav-user'
	option password 'webdav-pass-value'
	option path '/R2/'

config remote 's3'
	option enabled '0'
	option driver 'rclone'
	option endpoint 'https://s3.example.invalid'
	option bucket 'bucket-a'
	option access_key 's3-access-value'
	option secret_key 's3-secret-value'
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

cat >"$fixture_root/etc/config/system" <<'EOT'
config system
	option hostname 'fixture-router'
EOT

cat >"$fixture_root/etc/board.json" <<'EOT'
{
  "model": {
    "id": "test-board-id",
    "name": "Test Board Model"
  }
}
EOT

printf 'fixture-machine-id' >"$fixture_root/etc/machine-id"
printf 'Test Board Model\n' >"$fixture_root/tmp/sysinfo/board_name"
printf '02:11:22:33:44:55\n' >"$fixture_root/sys/class/net/br-lan/address"
printf '00:11:22:33:44:66\n' >"$fixture_root/sys/class/net/eth0/address"

WRTBAK_ROOT="$fixture_root" \
WRTBAK_LIBDIR="$libdir" \
	"$cli" remote-status --json >"$work_dir/remote-status.json"

python3 - "$work_dir/remote-status.json" <<'PY'
import hashlib
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

hash10 = hashlib.sha256(b"021122334455").hexdigest()[:10]
expected_uid = f"test-board-model-{hash10}"
hash8 = hashlib.sha256(b"fixture-machine-id").hexdigest()[:8]
expected_id = f"fixture-router-test-board-model-{hash8}"

assert data["ok"] is True
assert data["operation"] == "remote-status"
assert data["uid"] == expected_uid
assert data["generated_uid"] == expected_uid
assert data["device_id"] == expected_id
assert data["generated_device_id"] == expected_id
assert data["uid_algorithm"] == "wrtbak-board-mac-sha256-10/v1"
assert data["uid_status"] == "ok"
assert data["board_slug"] == "test-board-model"
assert data["mac_source"] == "br-lan"
assert data["default_target"] == "webdav"
assert data["targets"]["webdav"]["enabled"] is True
assert data["targets"]["webdav"]["driver"] == "curl"
assert data["targets"]["webdav"]["url"] == "https://example.invalid/dav"
assert data["targets"]["webdav"]["username"] == "webdav-user"
assert data["targets"]["webdav"]["password_set"] is True
assert data["targets"]["webdav"]["path"] == "R2"
assert data["targets"]["s3"]["enabled"] is False
assert data["targets"]["s3"]["driver"] == "rclone"
assert data["targets"]["s3"]["endpoint"] == "https://s3.example.invalid"
assert data["targets"]["s3"]["bucket"] == "bucket-a"
assert data["targets"]["s3"]["access_key_set"] is True
assert data["targets"]["s3"]["secret_key_set"] is True
assert data["targets"]["s3"]["path"] == ""
assert data["schedule"]["enabled"] is False
assert data["schedule"]["frequency"] == "daily"
assert data["schedule"]["profile"] == "auto"
assert data["schedule"]["items"] == "all"
assert data["schedule"]["format"] == "wrtbak"
assert data["dependencies"]["curl"] in (True, False)
assert data["dependencies"]["rclone"] in (True, False)

dump = json.dumps(data)
for forbidden in [
    "webdav-pass-value",
    "s3-access-value",
    "s3-secret-value",
]:
    assert forbidden not in dump, forbidden

assert re.fullmatch(r"[a-z0-9._-]{1,64}", data["uid"])
PY

echo "fixture remote config test passed"
