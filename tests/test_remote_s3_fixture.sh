#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-remote-s3-test.XXXXXX")
fixture_root="$work_dir/root"
bin_dir="$work_dir/bin"
libdir="$repo_dir/root/usr/lib/wrtbak"
cli="$repo_dir/root/usr/bin/wrtbak"
rclone_log="$work_dir/rclone.log"
config_log="$work_dir/rclone-config-paths.log"
remote_store="$work_dir/remote-store"

cleanup() {
	rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$bin_dir" "$fixture_root/etc/config" "$fixture_root/etc" "$remote_store"

device_uid="fixture-device-uid-0001"
device_alias="fixture-router"
legacy_device_id="old-device-id-0001"
remote_prefix="openwrt-config-backup"

cat >"$fixture_root/etc/config/wrtbak" <<'EOT'
config wrtbak 'main'
	option enabled '1'
	option default_target 's3'
	option device_id 'old-device-id-0001'
	option device_alias 'fixture-router'

config remote 's3'
	option enabled '1'
	option driver 'rclone'
	option endpoint 'https://s3.example.invalid'
	option region 'us-east-1'
	option bucket 'bucket-a'
	option access_key 's3-access-value'
	option secret_key 's3-secret-value'
	option path '/openwrt-config-backup/'
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

cat >"$bin_dir/rclone" <<'EOT'
#!/bin/sh
printf '%s\n' "$*" >>"$WRTBAK_FAKE_RCLONE_LOG"

previous=
command=
remote_ref=
operand_count=0
copy_source=
copy_dest=
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
		previous=$arg
		continue
	fi
	case "$arg" in
		--*)
			previous=$arg
			continue
			;;
	esac
	if [ -n "$command" ]; then
		operand_count=$((operand_count + 1))
		if [ "$operand_count" -eq 1 ]; then
			copy_source=$arg
		elif [ "$operand_count" -eq 2 ]; then
			copy_dest=$arg
		fi
	fi
	case "$arg" in
		wrtbak_remote:*)
			remote_ref=$arg
			;;
	esac
	previous=$arg
done

remote_key() {
	case "$1" in
		wrtbak_remote:bucket-a/*)
			printf '%s\n' "${1#wrtbak_remote:bucket-a/}"
			;;
		*)
			return 1
			;;
	esac
}

store_path() {
	key=$(remote_key "$1") || return 1
	printf '%s/%s\n' "${WRTBAK_FAKE_REMOTE_STORE%/}" "$key"
}

case "$command" in
	mkdir)
		printf "S3 driver should not call mkdir\n" >&2
		exit 45
		;;
	copyto)
		case "$copy_source" in
			wrtbak_remote:*)
				source_path=$(store_path "$copy_source") || exit 46
				cp "$source_path" "$copy_dest" || exit 47
				if [ "${WRTBAK_FAKE_CORRUPT_DOWNLOAD:-0}" = "1" ]; then
					printf 'corrupt' >> "$copy_dest"
				fi
				;;
			*)
				destination_path=$(store_path "$copy_dest") || exit 46
				mkdir -p "$(dirname -- "$destination_path")" || exit 47
				cp "$copy_source" "$destination_path" || exit 47
				;;
		esac
		exit 0
		;;
	deletefile)
		delete_path=$(store_path "$remote_ref") || exit 46
		rm -f "$delete_path"
		exit 0
		;;
	size)
		size_path=$(store_path "$remote_ref") || exit 46
		size=$(stat -c '%s' "$size_path") || exit 47
		printf 'Total objects: 1\nTotal size: %s Byte (%s Byte)\n' "$size" "$size"
		exit 0
		;;
	lsjson)
		if stat_path=$(store_path "$remote_ref" 2>/dev/null) && [ -f "$stat_path" ]; then
			stat_key=$(remote_key "$remote_ref")
			stat_name=$(basename -- "$stat_key")
			stat_size=$(stat -c '%s' "$stat_path")
			cat <<JSON
[
  {
    "Path": "$stat_key",
    "Name": "$stat_name",
    "Size": $stat_size,
    "ModTime": "2026-06-25T05:00:00Z",
    "ETag": "fixture-etag"
  }
]
JSON
			exit 0
		fi
		case "$remote_ref" in
			wrtbak_remote:bucket-a/devices/$WRTBAK_FAKE_DEVICE_UID*)
				cat <<JSON
[
  {
    "Path": "devices/$WRTBAK_FAKE_DEVICE_UID/wrtbak/2026/root-auto-20260625T020000Z.wrtbak",
    "Name": "root-auto-20260625T020000Z.wrtbak",
    "Size": 29,
    "ModTime": "2026-06-25T02:00:00Z"
  },
  {
    "Path": "devices/$WRTBAK_FAKE_DEVICE_UID/sysupgrade/2026/root-auto-20260625T020000Z.sysupgrade.tar.gz",
    "Name": "root-auto-20260625T020000Z.sysupgrade.tar.gz",
    "Size": 31,
    "ModTime": "2026-06-25T03:00:00Z"
  },
  {
    "Path": "devices/$WRTBAK_FAKE_DEVICE_UID/pre-restore/2026/root-safety-20260624T010000Z.wrtbak",
    "Name": "root-safety-20260624T010000Z.wrtbak",
    "Size": 37,
    "ModTime": "2026-06-24T01:00:00Z"
  }
]
JSON
				;;
			*"openwrt-config-backup/devices/$WRTBAK_FAKE_DEVICE_UID"*)
				cat <<JSON
[
  {
    "Path": "openwrt-config-backup/devices/$WRTBAK_FAKE_DEVICE_UID/wrtbak/2026/auto-20260625T020000Z.wrtbak",
    "Name": "auto-20260625T020000Z.wrtbak",
    "Size": 5,
    "ModTime": "2026-06-25T02:00:00Z"
  },
  {
    "Path": "openwrt-config-backup/devices/$WRTBAK_FAKE_DEVICE_UID/sysupgrade/2026/auto-20260625T020000Z.sysupgrade.tar.gz",
    "Name": "auto-20260625T020000Z.sysupgrade.tar.gz",
    "Size": 7,
    "ModTime": "2026-06-25T03:00:00Z"
  },
  {
    "Path": "wrtbak/2026/relative-20260625T040000Z.wrtbak",
    "Name": "relative-20260625T040000Z.wrtbak",
    "Size": 11,
    "ModTime": "2026-06-25T04:00:00Z"
  },
  {
    "Path": "openwrt-config-backup/devices/$WRTBAK_FAKE_DEVICE_UID/pre-restore/2026/safety-20260624T010000Z.wrtbak",
    "Name": "safety-20260624T010000Z.wrtbak",
    "Size": 23,
    "ModTime": "2026-06-24T01:00:00Z"
  }
]
JSON
				;;
			*"openwrt-config-backup/devices")
				cat <<JSON
[
  {
    "Path": "openwrt-config-backup/devices/other-device-uid/wrtbak/2026/other-device.wrtbak",
    "Name": "other-device.wrtbak",
    "Size": 19,
    "ModTime": "2026-06-23T02:00:00Z"
  }
]
JSON
				;;
			*"openwrt-config-backup/wrtbak/$WRTBAK_FAKE_LEGACY_DEVICE_ID"*)
				cat <<JSON
[
  {
    "Path": "openwrt-config-backup/wrtbak/$WRTBAK_FAKE_LEGACY_DEVICE_ID/wrtbak/2026/legacy-device-id.wrtbak",
    "Name": "legacy-device-id.wrtbak",
    "Size": 17,
    "ModTime": "2026-06-24T04:00:00Z"
  }
]
JSON
				;;
			*"openwrt-config-backup/wrtbak/$WRTBAK_FAKE_DEVICE_ALIAS"*)
				cat <<JSON
[
  {
    "Path": "openwrt-config-backup/wrtbak/$WRTBAK_FAKE_DEVICE_ALIAS/wrtbak/2026/legacy.wrtbak",
    "Name": "legacy.wrtbak",
    "Size": 3,
    "ModTime": "2026-06-24T02:00:00Z"
  },
  {
    "Path": "wrtbak/2026/legacy-relative.wrtbak",
    "Name": "legacy-relative.wrtbak",
    "Size": 13,
    "ModTime": "2026-06-24T03:00:00Z"
  }
]
JSON
				;;
			*)
				printf '[]\n'
				;;
		esac
		exit 0
		;;
esac

exit 0
EOT
chmod +x "$bin_dir/rclone"
export WRTBAK_FAKE_REMOTE_STORE="$remote_store"

PATH="$bin_dir:$PATH" \
WRTBAK_ROOT="$fixture_root" \
WRTBAK_LIBDIR="$libdir" \
WRTBAK_FAKE_RCLONE_LOG="$rclone_log" \
WRTBAK_FAKE_RCLONE_CONFIG_LOG="$config_log" \
WRTBAK_ALLOW_TEST_HOOKS=1 \
WRTBAK_FAKE_DEVICE_UID="$device_uid" \
WRTBAK_FAKE_DEVICE_ALIAS="$device_alias" \
WRTBAK_FAKE_LEGACY_DEVICE_ID="$legacy_device_id" \
	"$cli" remote-test --target s3 --json >"$work_dir/test.json"

python3 - "$work_dir/test.json" "$remote_prefix" "$device_uid" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
remote_prefix = sys.argv[2]
device_uid = sys.argv[3]

assert data["ok"] is True
assert data["operation"] == "remote-test"
assert data["target"] == "s3"
assert data["driver"] == "rclone"
assert data["remote_path"] == f"{remote_prefix}/devices/{device_uid}/.probe"
PY

PATH="$bin_dir:$PATH" \
WRTBAK_ROOT="$fixture_root" \
WRTBAK_LIBDIR="$libdir" \
WRTBAK_FAKE_RCLONE_LOG="$rclone_log" \
WRTBAK_FAKE_RCLONE_CONFIG_LOG="$config_log" \
WRTBAK_ALLOW_TEST_HOOKS=1 \
WRTBAK_FAKE_DEVICE_UID="$device_uid" \
WRTBAK_FAKE_DEVICE_ALIAS="$device_alias" \
WRTBAK_FAKE_LEGACY_DEVICE_ID="$legacy_device_id" \
	"$cli" restore-prebackup --profile pre-restore --items all --format wrtbak --require-remote 1 --target s3 --json >"$work_dir/prebackup-remote.json"

python3 - "$work_dir/prebackup-remote.json" "$fixture_root" "$remote_store" "$remote_prefix" "$device_uid" <<'PY'
import hashlib
import json
import os
import sys

path, fixture_root, remote_store, remote_prefix, device_uid = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)

def sha256_file(filename):
    digest = hashlib.sha256()
    with open(filename, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()

assert data["ok"] is True
assert data["operation"] == "restore-prebackup"
assert data["stage"] == "remote_upload_complete"
assert data["uid"] == device_uid
filename = os.path.basename(data["local_path"])
year = filename[:4]
expected_key = f"{remote_prefix}/devices/{device_uid}/pre-restore/{year}/{filename}"
assert data["remote_key"] == expected_key
assert os.path.isfile(fixture_root + data["local_path"])
assert os.path.isfile(fixture_root + data["receipt_path"])
assert os.path.isfile(os.path.join(remote_store, expected_key))
assert sha256_file(fixture_root + data["local_path"]) == data["sha256"]
assert sha256_file(os.path.join(remote_store, expected_key)) == data["sha256"]

with open(fixture_root + data["receipt_path"], encoding="utf-8") as handle:
    receipt = json.load(handle)
assert receipt["stage"] == "remote_upload_complete"
assert receipt["current_uid"] == device_uid
assert receipt["source_backup_key"] == ""
assert receipt["pre_restore"]["local_path"] == data["local_path"]
assert receipt["pre_restore"]["remote_key"] == expected_key
assert receipt["pre_restore"]["sha256"] == data["sha256"]
assert receipt["pre_restore"]["size"] == data["size"]
PY

if PATH="$bin_dir:$PATH" \
	WRTBAK_ROOT="$fixture_root" \
	WRTBAK_LIBDIR="$libdir" \
	WRTBAK_FAKE_RCLONE_LOG="$rclone_log" \
	WRTBAK_FAKE_RCLONE_CONFIG_LOG="$config_log" \
	WRTBAK_ALLOW_TEST_HOOKS=1 \
	WRTBAK_FAKE_DEVICE_UID="$device_uid" \
	WRTBAK_FAKE_DEVICE_ALIAS="$device_alias" \
	WRTBAK_FAKE_LEGACY_DEVICE_ID="$legacy_device_id" \
	WRTBAK_FAKE_CORRUPT_DOWNLOAD=1 \
		"$cli" restore-prebackup --profile pre-restore --items all --format wrtbak --require-remote 1 --target s3 --json >"$work_dir/prebackup-remote-verify-fail.json"; then
	echo "restore-prebackup should fail when remote verification hash mismatches" >&2
	exit 1
fi

python3 - "$work_dir/prebackup-remote-verify-fail.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
assert data["ok"] is False
assert data["operation"] == "restore-prebackup"
assert data["code"] == "pre_restore_remote_verify_failed"
PY

for forbidden in s3-access-value s3-secret-value; do
	if grep -q "$forbidden" "$rclone_log"; then
		echo "S3 secret leaked into rclone arguments: $forbidden" >&2
		exit 1
	fi
done

while IFS= read -r config_path || [ -n "$config_path" ]; do
	[ ! -e "$config_path" ] || {
		echo "temporary rclone config was not removed: $config_path" >&2
		exit 1
	}
done < "$config_log"

PATH="$bin_dir:$PATH" \
WRTBAK_ROOT="$fixture_root" \
WRTBAK_LIBDIR="$libdir" \
WRTBAK_FAKE_RCLONE_LOG="$rclone_log" \
WRTBAK_FAKE_RCLONE_CONFIG_LOG="$config_log" \
WRTBAK_ALLOW_TEST_HOOKS=1 \
WRTBAK_FAKE_DEVICE_UID="$device_uid" \
WRTBAK_FAKE_DEVICE_ALIAS="$device_alias" \
WRTBAK_FAKE_LEGACY_DEVICE_ID="$legacy_device_id" \
	"$cli" remote-list --target s3 --json >"$work_dir/list.json"

python3 - "$work_dir/list.json" "$remote_prefix" "$device_uid" "$device_alias" "$legacy_device_id" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
remote_prefix = sys.argv[2]
device_uid = sys.argv[3]
device_alias = sys.argv[4]
legacy_device_id = sys.argv[5]

assert data["ok"] is True
assert data["operation"] == "remote-list"
assert data["target"] == "s3"
assert data["driver"] == "rclone"
paths = [item["path"] for item in data["backups"]]
current_wrtbak = f"{remote_prefix}/devices/{device_uid}/wrtbak/2026/auto-20260625T020000Z.wrtbak"
current_sysupgrade = f"{remote_prefix}/devices/{device_uid}/sysupgrade/2026/auto-20260625T020000Z.sysupgrade.tar.gz"
current_relative = f"{remote_prefix}/devices/{device_uid}/wrtbak/2026/relative-20260625T040000Z.wrtbak"
pre_restore = f"{remote_prefix}/devices/{device_uid}/pre-restore/2026/safety-20260624T010000Z.wrtbak"
legacy = f"{remote_prefix}/wrtbak/{device_alias}/wrtbak/2026/legacy.wrtbak"
legacy_relative = f"{remote_prefix}/wrtbak/{device_alias}/wrtbak/2026/legacy-relative.wrtbak"
legacy_device = f"{remote_prefix}/wrtbak/{legacy_device_id}/wrtbak/2026/legacy-device-id.wrtbak"
assert current_wrtbak in paths
assert current_sysupgrade in paths
assert current_relative in paths
assert legacy in paths
assert legacy_relative in paths
assert legacy_device in paths
assert pre_restore not in paths
assert all("/pre-restore/" not in path for path in paths)
assert len(paths) == len(set(paths))
by_path = {item["path"]: item for item in data["backups"]}
assert by_path[current_wrtbak].get("legacy") in (None, False)
assert by_path[current_sysupgrade].get("legacy") in (None, False)
assert by_path[current_relative].get("legacy") in (None, False)
assert by_path[legacy]["legacy"] is True
assert by_path[legacy_relative]["legacy"] is True
assert by_path[legacy_device]["legacy"] is True
assert {item["format"] for item in data["backups"]} == {"wrtbak", "sysupgrade"}
assert {item["size"] for item in data["backups"]} == {3, 5, 7, 11, 13, 17}
PY

PATH="$bin_dir:$PATH" \
WRTBAK_ROOT="$fixture_root" \
WRTBAK_LIBDIR="$libdir" \
WRTBAK_FAKE_RCLONE_LOG="$rclone_log" \
WRTBAK_FAKE_RCLONE_CONFIG_LOG="$config_log" \
WRTBAK_ALLOW_TEST_HOOKS=1 \
WRTBAK_FAKE_DEVICE_UID="$device_uid" \
WRTBAK_FAKE_DEVICE_ALIAS="$device_alias" \
WRTBAK_FAKE_LEGACY_DEVICE_ID="$legacy_device_id" \
	"$cli" remote-prune --target s3 --max 1 --json >"$work_dir/prune.json"

python3 - "$work_dir/prune.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

assert data["ok"] is True
assert all("/pre-restore/" not in path for path in data["deleted_paths"])
PY

cp "$fixture_root/etc/config/wrtbak" "$work_dir/wrtbak-prefixed.conf"
sed "s#option path '/openwrt-config-backup/'#option path '/'#" "$work_dir/wrtbak-prefixed.conf" >"$work_dir/wrtbak-root-prefix.conf"
mv "$work_dir/wrtbak-root-prefix.conf" "$fixture_root/etc/config/wrtbak"

PATH="$bin_dir:$PATH" \
WRTBAK_ROOT="$fixture_root" \
WRTBAK_LIBDIR="$libdir" \
WRTBAK_FAKE_RCLONE_LOG="$rclone_log" \
WRTBAK_FAKE_RCLONE_CONFIG_LOG="$config_log" \
WRTBAK_ALLOW_TEST_HOOKS=1 \
WRTBAK_FAKE_DEVICE_UID="$device_uid" \
WRTBAK_FAKE_DEVICE_ALIAS="$device_alias" \
WRTBAK_FAKE_LEGACY_DEVICE_ID="$legacy_device_id" \
	"$cli" remote-list --target s3 --json >"$work_dir/list-root-prefix.json"

python3 - "$work_dir/list-root-prefix.json" "$device_uid" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
device_uid = sys.argv[2]
paths = [item["path"] for item in data["backups"]]
assert f"devices/{device_uid}/wrtbak/2026/root-auto-20260625T020000Z.wrtbak" in paths
assert f"devices/{device_uid}/sysupgrade/2026/root-auto-20260625T020000Z.sysupgrade.tar.gz" in paths
assert f"devices/{device_uid}/pre-restore/2026/root-safety-20260624T010000Z.wrtbak" not in paths
assert all("/pre-restore/" not in path for path in paths)
PY

PATH="$bin_dir:$PATH" \
WRTBAK_ROOT="$fixture_root" \
WRTBAK_LIBDIR="$libdir" \
WRTBAK_FAKE_RCLONE_LOG="$rclone_log" \
WRTBAK_FAKE_RCLONE_CONFIG_LOG="$config_log" \
WRTBAK_ALLOW_TEST_HOOKS=1 \
WRTBAK_FAKE_DEVICE_UID="$device_uid" \
WRTBAK_FAKE_DEVICE_ALIAS="$device_alias" \
WRTBAK_FAKE_LEGACY_DEVICE_ID="$legacy_device_id" \
	"$cli" remote-prune --target s3 --max 1 --json >"$work_dir/prune-root-prefix.json"

python3 - "$work_dir/prune-root-prefix.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
assert data["ok"] is True
assert all("/pre-restore/" not in path for path in data["deleted_paths"])
PY

pre_restore_root_path="devices/$device_uid/pre-restore/2026/root-safety-20260624T010000Z.wrtbak"
if PATH="$bin_dir:$PATH" \
	WRTBAK_ROOT="$fixture_root" \
	WRTBAK_LIBDIR="$libdir" \
	WRTBAK_FAKE_RCLONE_LOG="$rclone_log" \
	WRTBAK_FAKE_RCLONE_CONFIG_LOG="$config_log" \
	WRTBAK_ALLOW_TEST_HOOKS=1 \
	WRTBAK_FAKE_DEVICE_UID="$device_uid" \
	WRTBAK_FAKE_DEVICE_ALIAS="$device_alias" \
	WRTBAK_FAKE_LEGACY_DEVICE_ID="$legacy_device_id" \
	"$cli" remote-download --target s3 --path "$pre_restore_root_path" --json >"$work_dir/download-pre-restore-root.json"; then
	echo "remote-download should reject root-prefix pre-restore paths" >&2
	exit 1
fi

if PATH="$bin_dir:$PATH" \
	WRTBAK_ROOT="$fixture_root" \
	WRTBAK_LIBDIR="$libdir" \
	WRTBAK_FAKE_RCLONE_LOG="$rclone_log" \
	WRTBAK_FAKE_RCLONE_CONFIG_LOG="$config_log" \
	WRTBAK_ALLOW_TEST_HOOKS=1 \
	WRTBAK_FAKE_DEVICE_UID="$device_uid" \
	WRTBAK_FAKE_DEVICE_ALIAS="$device_alias" \
	WRTBAK_FAKE_LEGACY_DEVICE_ID="$legacy_device_id" \
	"$cli" remote-delete --target s3 --path "$pre_restore_root_path" --json >"$work_dir/delete-pre-restore-root.json"; then
	echo "remote-delete should reject root-prefix pre-restore paths" >&2
	exit 1
fi

mv "$work_dir/wrtbak-prefixed.conf" "$fixture_root/etc/config/wrtbak"

config_tmp="$work_dir/wrtbak-reserved.conf"
sed "s/option device_alias 'fixture-router'/option device_alias 'devices'/" "$fixture_root/etc/config/wrtbak" >"$config_tmp"
mv "$config_tmp" "$fixture_root/etc/config/wrtbak"

PATH="$bin_dir:$PATH" \
WRTBAK_ROOT="$fixture_root" \
WRTBAK_LIBDIR="$libdir" \
WRTBAK_FAKE_RCLONE_LOG="$rclone_log" \
WRTBAK_FAKE_RCLONE_CONFIG_LOG="$config_log" \
WRTBAK_ALLOW_TEST_HOOKS=1 \
WRTBAK_FAKE_DEVICE_UID="$device_uid" \
WRTBAK_FAKE_DEVICE_ALIAS="devices" \
WRTBAK_FAKE_LEGACY_DEVICE_ID="$legacy_device_id" \
	"$cli" remote-list --target s3 --json >"$work_dir/list-reserved-alias.json"

python3 - "$work_dir/list-reserved-alias.json" "$remote_prefix" "$device_uid" "$legacy_device_id" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
remote_prefix = sys.argv[2]
device_uid = sys.argv[3]
legacy_device_id = sys.argv[4]

paths = [item["path"] for item in data["backups"]]
assert f"{remote_prefix}/devices/{device_uid}/wrtbak/2026/auto-20260625T020000Z.wrtbak" in paths
assert f"{remote_prefix}/devices/other-device-uid/wrtbak/2026/other-device.wrtbak" not in paths
legacy_device = f"{remote_prefix}/wrtbak/{legacy_device_id}/wrtbak/2026/legacy-device-id.wrtbak"
assert legacy_device in paths
assert {item["path"]: item for item in data["backups"]}[legacy_device]["legacy"] is True
PY

config_tmp="$work_dir/wrtbak-duplicate-legacy.conf"
sed "s/option device_alias 'devices'/option device_alias 'old-device-id-0001'/" "$fixture_root/etc/config/wrtbak" >"$config_tmp"
mv "$config_tmp" "$fixture_root/etc/config/wrtbak"

PATH="$bin_dir:$PATH" \
WRTBAK_ROOT="$fixture_root" \
WRTBAK_LIBDIR="$libdir" \
WRTBAK_FAKE_RCLONE_LOG="$rclone_log" \
WRTBAK_FAKE_RCLONE_CONFIG_LOG="$config_log" \
WRTBAK_ALLOW_TEST_HOOKS=1 \
WRTBAK_FAKE_DEVICE_UID="$device_uid" \
WRTBAK_FAKE_DEVICE_ALIAS="$legacy_device_id" \
WRTBAK_FAKE_LEGACY_DEVICE_ID="$legacy_device_id" \
	"$cli" remote-list --target s3 --json >"$work_dir/list-duplicate-legacy-name.json"

python3 - "$work_dir/list-duplicate-legacy-name.json" "$remote_prefix" "$legacy_device_id" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
remote_prefix = sys.argv[2]
legacy_device_id = sys.argv[3]

legacy_device = f"{remote_prefix}/wrtbak/{legacy_device_id}/wrtbak/2026/legacy-device-id.wrtbak"
paths = [item["path"] for item in data["backups"]]
assert paths.count(legacy_device) == 1
PY

expected_ref="wrtbak_remote:bucket-a/$remote_prefix/devices/$device_uid/.probe"
grep -Fq "$expected_ref" "$rclone_log" || {
	echo "S3 probe did not use expected object key: $expected_ref" >&2
	exit 1
}
if grep -Fq 'openwrt-config-backup/wrtbak/wrtbak/' "$rclone_log"; then
	echo "S3 object key contains doubled wrtbak segment" >&2
	exit 1
fi

echo "fixture S3 remote test passed"
