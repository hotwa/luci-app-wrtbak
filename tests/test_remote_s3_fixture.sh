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

cleanup() {
	rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$bin_dir" "$fixture_root/etc/config" "$fixture_root/etc"

hash8=$(python3 - <<'PY'
import hashlib
print(hashlib.sha256(b"fixture-machine-id").hexdigest()[:8])
PY
)
device_id="fixture-router-test-board-model-$hash8"

cat >"$fixture_root/etc/config/wrtbak" <<'EOT'
config wrtbak 'main'
	option enabled '1'
	option default_target 's3'

config remote 's3'
	option enabled '1'
	option driver 'rclone'
	option endpoint 'https://s3.example.invalid'
	option region 'us-east-1'
	option bucket 'bucket-a'
	option access_key 's3-access-value'
	option secret_key 's3-secret-value'
	option path '/backups/'
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
	fi
	previous=$arg
done

case "$command" in
	mkdir)
		printf "S3 driver should not call mkdir\n" >&2
		exit 45
		;;
	copyto|deletefile)
		exit 0
		;;
	size)
		printf 'Total objects: 1\nTotal size: 0.005 KiB (5 Byte)\n'
		exit 0
		;;
	lsjson)
		cat <<JSON
[
  {
    "Path": "backups/wrtbak/$WRTBAK_FAKE_DEVICE_ID/wrtbak/2026/auto-20260625T020000Z.wrtbak",
    "Name": "auto-20260625T020000Z.wrtbak",
    "Size": 5,
    "ModTime": "2026-06-25T02:00:00Z"
  },
  {
    "Path": "backups/wrtbak/$WRTBAK_FAKE_DEVICE_ID/sysupgrade/2026/auto-20260625T020000Z.sysupgrade.tar.gz",
    "Name": "auto-20260625T020000Z.sysupgrade.tar.gz",
    "Size": 7,
    "ModTime": "2026-06-25T03:00:00Z"
  }
]
JSON
		exit 0
		;;
esac

exit 0
EOT
chmod +x "$bin_dir/rclone"

PATH="$bin_dir:$PATH" \
WRTBAK_ROOT="$fixture_root" \
WRTBAK_LIBDIR="$libdir" \
WRTBAK_FAKE_RCLONE_LOG="$rclone_log" \
WRTBAK_FAKE_RCLONE_CONFIG_LOG="$config_log" \
WRTBAK_FAKE_DEVICE_ID="$device_id" \
	"$cli" remote-test --target s3 --json >"$work_dir/test.json"

python3 - "$work_dir/test.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

assert data["ok"] is True
assert data["operation"] == "remote-test"
assert data["target"] == "s3"
assert data["driver"] == "rclone"
assert data["remote_path"].endswith(".probe")
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
WRTBAK_FAKE_DEVICE_ID="$device_id" \
	"$cli" remote-list --target s3 --json >"$work_dir/list.json"

python3 - "$work_dir/list.json" "$device_id" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
device_id = sys.argv[2]

assert data["ok"] is True
assert data["operation"] == "remote-list"
assert data["target"] == "s3"
assert data["driver"] == "rclone"
paths = [item["path"] for item in data["backups"]]
assert f"backups/wrtbak/{device_id}/wrtbak/2026/auto-20260625T020000Z.wrtbak" in paths
assert f"backups/wrtbak/{device_id}/sysupgrade/2026/auto-20260625T020000Z.sysupgrade.tar.gz" in paths
assert {item["format"] for item in data["backups"]} == {"wrtbak", "sysupgrade"}
assert {item["size"] for item in data["backups"]} == {5, 7}
PY

echo "fixture S3 remote test passed"
