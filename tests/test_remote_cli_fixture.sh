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

mkdir -p "$bin_dir" "$fixture_root/etc/config" "$fixture_root/etc" "$fixture_root/overlay/wrtbak" "$output_dir" "$state_dir"

hash8=$(python3 - <<'PY'
import hashlib
print(hashlib.sha256(b"fixture-machine-id").hexdigest()[:8])
PY
)
device_id="fixture-router-test-board-model-$hash8"

cat >"$fixture_root/etc/config/wrtbak" <<EOT
config wrtbak 'main'
	option enabled '1'
	option output_dir '$output_dir'
	option default_target 's3'
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
for arg in "$@"; do
	if [ "$previous" = "--config" ]; then
		printf '%s\n' "$arg" >>"$WRTBAK_FAKE_RCLONE_CONFIG_LOG"
		mode=$(stat -c '%a' "$arg")
		if [ "$mode" != "600" ]; then
			printf 'bad rclone config mode: %s\n' "$mode" >&2
			exit 44
		fi
		previous=$arg
		continue
	fi
	if [ -z "$command" ] && [ "$arg" != "--config" ]; then
		command=$arg
	elif [ "$command" = "copyto" ] && [ -z "$source_file" ]; then
		source_file=$arg
	fi
	previous=$arg
done

case "$command" in
	mkdir)
		exit 0
		;;
	copyto)
		stat -c '%s' "$source_file" >"$WRTBAK_FAKE_STATE_DIR/upload.size"
		exit 0
		;;
	size)
		size=$(cat "$WRTBAK_FAKE_STATE_DIR/upload.size" 2>/dev/null || printf '5')
		printf 'Total objects: 1\nTotal size: %s B (%s Bytes)\n' "$size" "$size"
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
  {"Path":"backups/wrtbak/$WRTBAK_FAKE_DEVICE_ID/wrtbak/2026/newest-20260625T040000Z.wrtbak","Name":"newest-20260625T040000Z.wrtbak","Size":9,"ModTime":"2026-06-25T04:00:00Z"},
  {"Path":"backups/wrtbak/$WRTBAK_FAKE_DEVICE_ID/wrtbak/2026/mid-20260625T030000Z.wrtbak","Name":"mid-20260625T030000Z.wrtbak","Size":8,"ModTime":"2026-06-25T03:00:00Z"},
  {"Path":"backups/wrtbak/$WRTBAK_FAKE_DEVICE_ID/wrtbak/2026/old-20260625T020000Z.wrtbak","Name":"old-20260625T020000Z.wrtbak","Size":7,"ModTime":"2026-06-25T02:00:00Z"},
  {"Path":"backups/wrtbak/$WRTBAK_FAKE_DEVICE_ID/sysupgrade/2026/newest-20260625T040000Z.sysupgrade.tar.gz","Name":"newest-20260625T040000Z.sysupgrade.tar.gz","Size":6,"ModTime":"2026-06-25T04:00:00Z"},
  {"Path":"backups/wrtbak/$WRTBAK_FAKE_DEVICE_ID/sysupgrade/2026/old-20260625T020000Z.sysupgrade.tar.gz","Name":"old-20260625T020000Z.sysupgrade.tar.gz","Size":5,"ModTime":"2026-06-25T02:00:00Z"}
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
	WRTBAK_FAKE_DEVICE_ID="$device_id" \
		"$cli" "$@"
}

run_cli remote-upload --target default --profile cli-test --items all --format wrtbak --prune-max 1 --json >"$work_dir/upload.json"

python3 - "$work_dir/upload.json" "$fixture_root" <<'PY'
import json
import pathlib
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
root = pathlib.Path(sys.argv[2])
assert data["ok"] is True
assert data["operation"] == "remote-upload"
assert data["target"] == "s3"
assert data["driver"] == "rclone"
assert data["format"] == "wrtbak"
assert data["remote_path"].endswith(".wrtbak")
assert data["local_archive_retained"] is False
assert not pathlib.Path(data["local_archive_path"]).exists()
assert data["prune"]["deleted_count"] == 3
history = root / "overlay/wrtbak/remote-history.jsonl"
assert history.exists()
text = history.read_text(encoding="utf-8")
assert "remote-upload" in text
assert "s3-access-value" not in text
assert "s3-secret-value" not in text
PY

if grep -q 's3-access-value\|s3-secret-value' "$rclone_log"; then
	echo "S3 credentials leaked into rclone arguments" >&2
	exit 1
fi

run_cli remote-delete --target default --path "backups/wrtbak/$device_id/wrtbak/2026/newest-20260625T040000Z.wrtbak" --json >"$work_dir/delete.json"
python3 - "$work_dir/delete.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
assert data["ok"] is True
assert data["operation"] == "remote-delete"
assert data["deleted"] is True
PY

if run_cli remote-delete --target default --path "backups/other-device/wrtbak/2026/bad.wrtbak" --json >"$work_dir/delete-bad.json"; then
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