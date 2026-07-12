#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-remote-cli-test.XXXXXX")
fixture_root="$work_dir/root"
bin_dir="$work_dir/bin"
output_dir="$work_dir/output"
state_dir="$work_dir/state"
libdir="$repo_dir/root/usr/lib/wrtbak"
cli="$repo_dir/root/usr/bin/wrtbak"
rclone_log="$work_dir/rclone.log"
config_log="$work_dir/rclone-config-paths.log"
delete_log="$work_dir/delete.log"

cleanup() {
	rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$bin_dir" "$fixture_root/etc/config" "$fixture_root/etc" "$fixture_root/tmp/sysinfo" "$fixture_root/sys/class/net/br-lan" "$fixture_root/overlay/wrtbak" "$output_dir" "$state_dir"

device_uid="fixture-device-uid-0001"
device_alias="fixture-router"
legacy_device_id="old-device-id-0001"
remote_prefix="openwrt-config-backup"

cat >"$fixture_root/etc/config/wrtbak" <<EOT
config wrtbak 'main'
	option enabled '1'
	option output_dir '$output_dir'
	option default_target 's3'
	option device_id '$legacy_device_id'
	option device_alias '$device_alias'
	option history_file '/overlay/wrtbak/remote-history.jsonl'
	option history_max_entries '3'
	option keep_local_after_upload '0'

config remote 's3'
	option enabled '1'
	option driver 'rclone'
	option endpoint 'https://s3.example.invalid'
	option region 'us-east-1'
	option bucket 'bucket-a'
	option access_key 's3-access-value'
	option secret_key 's3-secret-value'
	option path '/$remote_prefix/'
	option force_path_style '1'
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
printf 'Remote CLI Board\n' >"$fixture_root/tmp/sysinfo/board_name"
printf '02:11:22:33:44:55\n' >"$fixture_root/sys/class/net/br-lan/address"
cat >"$fixture_root/etc/config/network" <<'EOT'
config interface 'lan'
	option proto 'static'
	option ipaddr '192.0.2.1'
EOT

cat >"$bin_dir/rclone" <<'EOT'
#!/bin/sh
printf '%s\n' "$*" >>"$WRTBAK_FAKE_RCLONE_LOG"

previous=
command=
source_file=
destination_file=
for arg in "$@"; do
	if [ "$previous" = "--config" ]; then
		printf '%s\n' "$arg" >>"$WRTBAK_FAKE_RCLONE_CONFIG_LOG"
		mode=$(stat -c '%a' "$arg")
		if [ "$mode" != "600" ]; then
			printf 'bad rclone config mode: %s\n' "$mode" >&2
			exit 44
		fi
		grep -q '^no_check_bucket = true$' "$arg" || { echo "missing no_check_bucket" >&2; exit 45; }
		previous=$arg
		continue
	fi
	if [ -z "$command" ] && [ "$arg" != "--config" ]; then
		command=$arg
	elif [ "$command" = "copyto" ] && [ -z "$source_file" ]; then
		source_file=$arg
	elif [ "$command" = "copyto" ] && [ -z "$destination_file" ]; then
		destination_file=$arg
	fi
	previous=$arg
done

case "$command" in
	mkdir)
		printf "S3 driver should not call mkdir\n" >&2
		exit 45
		;;
	copyto)
		stat -c '%s' "$source_file" >"$WRTBAK_FAKE_STATE_DIR/upload.size"
		case "$destination_file" in
			*wrtbak_remote:bucket-a/openwrt-config-backup/aliases/*.json)
				if [ "${WRTBAK_FAKE_ALIAS_FAIL:-0}" = "1" ]; then
					exit 67
				fi
				cp "$source_file" "$WRTBAK_FAKE_STATE_DIR/alias-index.json"
				printf '%s\n' "$destination_file" >"$WRTBAK_FAKE_STATE_DIR/alias-index.key"
				;;
			*)
				printf '%s\n' "$destination_file" >"$WRTBAK_FAKE_STATE_DIR/upload.key"
				;;
		esac
		exit 0
		;;
	size)
		size=$(cat "$WRTBAK_FAKE_STATE_DIR/upload.size" 2>/dev/null || printf '5')
		printf 'Total objects: 1\nTotal size: 9.529 MiB (%s Byte)\n' "$size"
		exit 0
		;;
	deletefile)
		printf '%s\n' "$*" >>"$WRTBAK_FAKE_DELETE_LOG"
		case "$*" in
			*MISSING*) exit 1 ;;
		esac
		exit 0
		;;
	lsjson)
		cat <<JSON
[
  {"Path":"openwrt-config-backup/devices/$WRTBAK_FAKE_DEVICE_UID/wrtbak/2026/newest-20260625T040000Z.wrtbak","Name":"newest-20260625T040000Z.wrtbak","Size":9,"ModTime":"2026-06-25T04:00:00Z"},
  {"Path":"openwrt-config-backup/devices/$WRTBAK_FAKE_DEVICE_UID/wrtbak/2026/mid-20260625T030000Z.wrtbak","Name":"mid-20260625T030000Z.wrtbak","Size":8,"ModTime":"2026-06-25T03:00:00Z"},
  {"Path":"openwrt-config-backup/devices/$WRTBAK_FAKE_DEVICE_UID/wrtbak/2026/old-20260625T020000Z.wrtbak","Name":"old-20260625T020000Z.wrtbak","Size":7,"ModTime":"2026-06-25T02:00:00Z"},
  {"Path":"openwrt-config-backup/devices/$WRTBAK_FAKE_DEVICE_UID/sysupgrade/2026/newest-20260625T040000Z.sysupgrade.tar.gz","Name":"newest-20260625T040000Z.sysupgrade.tar.gz","Size":6,"ModTime":"2026-06-25T04:00:00Z"},
  {"Path":"openwrt-config-backup/devices/$WRTBAK_FAKE_DEVICE_UID/sysupgrade/2026/old-20260625T020000Z.sysupgrade.tar.gz","Name":"old-20260625T020000Z.sysupgrade.tar.gz","Size":5,"ModTime":"2026-06-25T02:00:00Z"},
  {"Path":"openwrt-config-backup/wrtbak/$WRTBAK_FAKE_DEVICE_ALIAS/wrtbak/2026/legacy.wrtbak","Name":"legacy.wrtbak","Size":4,"ModTime":"2026-06-24T02:00:00Z"},
  {"Path":"openwrt-config-backup/wrtbak/old-device-id-0001/wrtbak/2026/legacy-device-id.wrtbak","Name":"legacy-device-id.wrtbak","Size":3,"ModTime":"2026-06-24T04:00:00Z"}
]
JSON
		exit 0
		;;
esac

exit 0
EOT
chmod +x "$bin_dir/rclone"

run_cli() {
	PATH="$bin_dir:$PATH" \
	WRTBAK_ROOT="$fixture_root" \
	WRTBAK_LIBDIR="$libdir" \
	WRTBAK_FAKE_RCLONE_LOG="$rclone_log" \
	WRTBAK_FAKE_RCLONE_CONFIG_LOG="$config_log" \
	WRTBAK_FAKE_DELETE_LOG="$delete_log" \
	WRTBAK_FAKE_STATE_DIR="$state_dir" \
	WRTBAK_FAKE_ALIAS_FAIL="${WRTBAK_FAKE_ALIAS_FAIL:-0}" \
	WRTBAK_ALLOW_TEST_HOOKS=1 \
	WRTBAK_FAKE_DEVICE_UID="$device_uid" \
	WRTBAK_FAKE_DEVICE_ALIAS="$device_alias" \
		"$cli" "$@"
}

run_cli_without_identity() {
	PATH="$bin_dir:$PATH" \
	WRTBAK_ROOT="$fixture_root" \
	WRTBAK_LIBDIR="$libdir" \
	WRTBAK_FAKE_RCLONE_LOG="$rclone_log" \
	WRTBAK_FAKE_RCLONE_CONFIG_LOG="$config_log" \
	WRTBAK_FAKE_DELETE_LOG="$delete_log" \
	WRTBAK_FAKE_STATE_DIR="$state_dir" \
	WRTBAK_FAKE_ALIAS_FAIL="${WRTBAK_FAKE_ALIAS_FAIL:-0}" \
	WRTBAK_ALLOW_TEST_HOOKS=0 \
	WRTBAK_FAKE_DEVICE_UID= \
	WRTBAK_FAKE_DEVICE_ALIAS="$device_alias" \
		"$cli" "$@"
}

run_cli remote-upload --target default --profile cli-test --items all --format wrtbak --prune-max 1 --json >"$work_dir/upload.json"

python3 - "$work_dir/upload.json" "$fixture_root" "$remote_prefix" "$device_uid" "$device_alias" "$state_dir" <<'PY'
import json
import pathlib
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
root = pathlib.Path(sys.argv[2])
remote_prefix = sys.argv[3]
device_uid = sys.argv[4]
device_alias = sys.argv[5]
state_dir = pathlib.Path(sys.argv[6])
assert data["ok"] is True
assert data["operation"] == "remote-upload"
assert data["target"] == "s3"
assert data["driver"] == "rclone"
assert data["format"] == "wrtbak"
assert data["remote_path"].startswith(f"{remote_prefix}/devices/{device_uid}/wrtbak/")
assert data["remote_path"].endswith(".wrtbak")
assert "/wrtbak/wrtbak/" not in data["remote_path"]
assert data["alias_index_updated"] is True
assert data["alias_index_path"] == f"{remote_prefix}/aliases/{device_alias}.json"
assert data["local_archive_retained"] is False
assert not pathlib.Path(data["local_archive_path"]).exists()
assert data["prune"]["deleted_count"] == 3
history = root / "overlay/wrtbak/remote-history.jsonl"
assert history.exists()
text = history.read_text(encoding="utf-8")
assert "remote-upload" in text
assert "s3-access-value" not in text
assert "s3-secret-value" not in text

upload_key = (state_dir / "upload.key").read_text(encoding="utf-8").strip()
assert upload_key == f"wrtbak_remote:bucket-a/{data['remote_path']}"
alias_key = (state_dir / "alias-index.key").read_text(encoding="utf-8").strip()
assert alias_key == f"wrtbak_remote:bucket-a/{data['alias_index_path']}"
alias_index = json.loads((state_dir / "alias-index.json").read_text(encoding="utf-8"))
assert alias_index["alias"] == device_alias
assert alias_index["uid"] == device_uid
assert alias_index["latest_backup_key"] == data["remote_path"]
assert alias_index["updated_at"].endswith("Z")
PY

if grep -q 's3-access-value\|s3-secret-value' "$rclone_log"; then
	echo "S3 credentials leaked into rclone arguments" >&2
	exit 1
fi
if grep -Fq 'openwrt-config-backup/wrtbak/wrtbak/' "$rclone_log"; then
	echo "S3 object key contains doubled wrtbak segment" >&2
	exit 1
fi

WRTBAK_FAKE_ALIAS_FAIL=1 run_cli remote-upload --target default --profile cli-test --items all --format wrtbak --prune-max 0 --json >"$work_dir/upload-alias-fail.json"
python3 - "$work_dir/upload-alias-fail.json" "$remote_prefix" "$device_uid" "$device_alias" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
remote_prefix = sys.argv[2]
device_uid = sys.argv[3]
device_alias = sys.argv[4]
assert data["ok"] is True
assert data["operation"] == "remote-upload"
assert data["remote_path"].startswith(f"{remote_prefix}/devices/{device_uid}/wrtbak/")
assert data["alias_index_updated"] is False
assert data["alias_index_path"] == f"{remote_prefix}/aliases/{device_alias}.json"
assert data["prune"]["deleted_count"] == 0
PY

run_cli remote-delete --target default --path "$remote_prefix/devices/$device_uid/wrtbak/2026/newest-20260625T040000Z.wrtbak" --json >"$work_dir/delete.json"
python3 - "$work_dir/delete.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
assert data["ok"] is True
assert data["operation"] == "remote-delete"
assert data["deleted"] is True
PY

legacy_delete_path="$remote_prefix/wrtbak/$device_alias/wrtbak/2026/legacy.wrtbak"
if run_cli remote-delete --target default --path "$legacy_delete_path" --json >"$work_dir/delete-legacy.json"; then
	echo "delete for legacy alias path should fail" >&2
	exit 1
fi
python3 - "$work_dir/delete-legacy.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
assert data["ok"] is False
assert data["code"] == "invalid_config"
PY
if grep -Fq "$legacy_delete_path" "$delete_log"; then
	echo "delete attempted legacy alias path" >&2
	exit 1
fi

legacy_device_delete_path="$remote_prefix/wrtbak/$legacy_device_id/wrtbak/2026/legacy-device-id.wrtbak"
if run_cli remote-delete --target default --path "$legacy_device_delete_path" --json >"$work_dir/delete-legacy-device-id.json"; then
	echo "delete for legacy device_id path should fail" >&2
	exit 1
fi
python3 - "$work_dir/delete-legacy-device-id.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
assert data["ok"] is False
assert data["code"] == "invalid_config"
PY
if grep -Fq "$legacy_device_delete_path" "$delete_log"; then
	echo "delete attempted legacy device_id path" >&2
	exit 1
fi

if run_cli remote-delete --target default --path "$remote_prefix/other-device/wrtbak/2026/bad.wrtbak" --json >"$work_dir/delete-bad.json"; then
	echo "delete outside device prefix should fail" >&2
	exit 1
fi
python3 - "$work_dir/delete-bad.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
assert data["ok"] is False
assert data["code"] == "invalid_config"
PY

run_cli remote-prune --target default --max 0 --json >"$work_dir/prune-zero.json"
python3 - "$work_dir/prune-zero.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
assert data["ok"] is True
assert data["operation"] == "remote-prune"
assert data["max"] == 0
assert data["no_op"] is True
assert data["deleted_count"] == 0
PY

run_cli remote-prune --target default --max 9 --json >"$work_dir/prune-noop.json"
python3 - "$work_dir/prune-noop.json" <<\PY
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
assert data["ok"] is True
assert data["operation"] == "remote-prune"
assert data["max"] == 9
assert data["no_op"] is True
assert data["deleted_count"] == 0
assert data["kept_count"] == 5
assert data["deleted_paths"] == []
PY

if grep -Fq "$remote_prefix/wrtbak/$device_alias/wrtbak/2026/legacy.wrtbak" "$delete_log"; then
	echo "prune attempted legacy alias path" >&2
	exit 1
fi
if grep -Fq "$legacy_device_delete_path" "$delete_log"; then
	echo "prune attempted legacy device_id path" >&2
	exit 1
fi

board_file="$fixture_root/tmp/sysinfo/board_name"
mac_file="$fixture_root/sys/class/net/br-lan/address"
mv "$board_file" "$board_file.saved"
mv "$mac_file" "$mac_file.saved"
if run_cli_without_identity remote-prune --target default --max 1 --json >"$work_dir/prune-no-identity.json"; then
	echo "remote-prune should fail when device identity is unusable" >&2
	exit 1
fi
python3 - "$work_dir/prune-no-identity.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
assert data["ok"] is False
assert data["code"] == "identity_unusable"
PY
mv "$board_file.saved" "$board_file"
mv "$mac_file.saved" "$mac_file"

mkdir -p "$fixture_root/tmp/wrtbak/remote.lock"
if run_cli remote-prune --target default --max 1 --json >"$work_dir/busy.json"; then
	echo "remote-prune should fail while lock is held" >&2
	exit 1
fi
python3 - "$work_dir/busy.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
assert data["ok"] is False
assert data["code"] == "busy"
PY

echo "fixture remote CLI management test passed"
