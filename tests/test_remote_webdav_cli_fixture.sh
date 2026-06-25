#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-webdav-cli-test.XXXXXX")
fixture_root="$work_dir/root"
bin_dir="$work_dir/bin"
output_dir="$work_dir/output"
state_dir="$work_dir/state"
libdir="$repo_dir/root/usr/lib/wrtbak"
cli="$repo_dir/root/usr/bin/wrtbak"
curl_log="$work_dir/curl.log"
delete_log="$work_dir/delete.log"

cleanup() {
	rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$bin_dir" "$fixture_root/etc/config" "$fixture_root/etc" "$output_dir" "$state_dir"

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
	option default_target 'webdav'
	option history_file '/overlay/wrtbak/remote-history.jsonl'
	option keep_local_after_upload '0'

config remote 'webdav'
	option enabled '1'
	option driver 'curl'
	option url 'https://webdav.example.invalid/dav'
	option username 'webdav-user'
	option password 'webdav-secret-value'
	option path '/R2/'
EOT

cat >"$fixture_root/etc/config/system" <<'EOT'
config system
	option hostname 'fixture-router'
EOT
cat >"$fixture_root/etc/board.json" <<'EOT'
{"model":{"id":"test-board-id","name":"Test Board Model"}}
EOT
printf 'fixture-machine-id' >"$fixture_root/etc/machine-id"
cat >"$fixture_root/etc/config/network" <<'EOT'
config interface 'lan'
	option proto 'static'
	option ipaddr '192.0.2.1'
EOT

cat >"$bin_dir/curl" <<'EOT'
#!/bin/sh
printf '%s\n' "$*" >>"$WRTBAK_FAKE_CURL_LOG"
method=
netrc=
upload_file=
head=0
url=
while [ "$#" -gt 0 ]; do
	case "$1" in
		--netrc-file)
			netrc=$2
			mode=$(stat -c '%a' "$netrc")
			[ "$mode" = "600" ] || { echo "bad netrc mode: $mode" >&2; exit 44; }
			shift 2
			;;
		-X)
			method=$2
			shift 2
			;;
		--upload-file)
			upload_file=$2
			shift 2
			;;
		-I)
			head=1
			shift
			;;
		-*)
			shift
			;;
		*)
			url=$1
			shift
			;;
	esac
done
if [ -n "$upload_file" ]; then
	stat -c '%s' "$upload_file" >"$WRTBAK_FAKE_STATE_DIR/upload.size"
	printf '%s\n' "$url" >"$WRTBAK_FAKE_STATE_DIR/upload.url"
	exit 0
fi
if [ "$head" -eq 1 ]; then
	size=$(cat "$WRTBAK_FAKE_STATE_DIR/upload.size" 2>/dev/null || printf '5')
	printf 'HTTP/1.1 200 OK\r\nContent-Length: %s\r\n\r\n' "$size"
	exit 0
fi
case "$method" in
	MKCOL)
		exit 0
		;;
	DELETE)
		printf '%s\n' "$url" >>"$WRTBAK_FAKE_DELETE_LOG"
		case "$url" in *MISSING*) exit 1 ;; esac
		exit 0
		;;
esac
exit 0
EOT
chmod +x "$bin_dir/curl"

run_cli() {
	PATH="$bin_dir:/usr/bin:/bin" \
	WRTBAK_ROOT="$fixture_root" \
	WRTBAK_LIBDIR="$libdir" \
	WRTBAK_FAKE_CURL_LOG="$curl_log" \
	WRTBAK_FAKE_DELETE_LOG="$delete_log" \
	WRTBAK_FAKE_STATE_DIR="$state_dir" \
		"$cli" "$@"
}

run_cli remote-upload --target default --profile webdav-test --items all --format wrtbak --prune-max 0 --json >"$work_dir/upload.json"
python3 - "$work_dir/upload.json" "$fixture_root" "$device_id" <<'PY'
import json, pathlib, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
root = pathlib.Path(sys.argv[2])
device_id = sys.argv[3]
assert data["ok"] is True
assert data["target"] == "webdav"
assert data["driver"] == "curl"
assert data["format"] == "wrtbak"
assert data["remote_path"].startswith(f"R2/wrtbak/{device_id}/wrtbak/")
assert data["remote_path"].endswith(".wrtbak")
assert data["local_archive_retained"] is False
assert not pathlib.Path(data["local_archive_path"]).exists()
assert (root / "overlay/wrtbak/remote-history.jsonl").exists()
PY

run_cli remote-delete --target default --path "R2/wrtbak/$device_id/wrtbak/2026/webdav-test.wrtbak" --json >"$work_dir/delete.json"
python3 - "$work_dir/delete.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
assert data["ok"] is True
assert data["deleted"] is True
assert data["driver"] == "curl"
PY

if grep -q 'webdav-user\|webdav-secret-value' "$curl_log"; then
	echo "WebDAV credentials leaked into curl arguments" >&2
	exit 1
fi

echo "fixture WebDAV remote CLI management test passed"