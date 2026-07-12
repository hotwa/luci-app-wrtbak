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

mkdir -p "$bin_dir" "$fixture_root/etc/config" "$fixture_root/etc" "$fixture_root/tmp/sysinfo" "$fixture_root/sys/class/net/br-lan" "$output_dir" "$state_dir"

device_uid="fixture-device-uid-0001"
device_alias="fixture-router"
legacy_device_id="old-device-id-0001"
remote_prefix="R2"

cat >"$fixture_root/etc/config/wrtbak" <<EOT
config wrtbak 'main'
	option enabled '1'
	option output_dir '$output_dir'
	option default_target 'webdav'
	option device_id '$legacy_device_id'
	option device_alias '$device_alias'
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
printf 'Remote WebDAV CLI Board\n' >"$fixture_root/tmp/sysinfo/board_name"
printf '02:11:22:33:44:55\n' >"$fixture_root/sys/class/net/br-lan/address"
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
	stat -c '%s' "$upload_file" >"$WRTBAK_FAKE_STATE_DIR/last-upload.size"
	printf '%s\n' "$url" >"$WRTBAK_FAKE_STATE_DIR/last-upload.url"
	case "$url" in
		*/aliases/*.json)
			cp "$upload_file" "$WRTBAK_FAKE_STATE_DIR/alias-index.json"
			printf '%s\n' "$url" >"$WRTBAK_FAKE_STATE_DIR/alias-index.url"
			;;
		*)
			stat -c '%s' "$upload_file" >"$WRTBAK_FAKE_STATE_DIR/upload.size"
			printf '%s\n' "$url" >"$WRTBAK_FAKE_STATE_DIR/upload.url"
			;;
	esac
	exit 0
fi
if [ "$head" -eq 1 ]; then
	size=$(cat "$WRTBAK_FAKE_STATE_DIR/upload.size" 2>/dev/null || printf '5')
	printf 'HTTP/1.1 200 OK\r\nContent-Length: %s\r\n\r\n' "$size"
	exit 0
fi
case "$method" in
	PROPFIND)
		size=$(cat "$WRTBAK_FAKE_STATE_DIR/last-upload.size" 2>/dev/null || printf 5)
		last_upload_url=$(cat "$WRTBAK_FAKE_STATE_DIR/last-upload.url" 2>/dev/null || printf '')
		uploaded_url=$(cat "$WRTBAK_FAKE_STATE_DIR/upload.url" 2>/dev/null || printf '')
		if [ -z "$uploaded_url" ] || [ "$url" = "$last_upload_url" ]; then
			printf "<?xml version=\"1.0\"?><D:multistatus xmlns:D=\"DAV:\"><D:response><D:href>%s</D:href><D:propstat><D:prop><D:getcontentlength>%s</D:getcontentlength></D:prop></D:propstat></D:response></D:multistatus>
" "$url" "$size"
		else
			uploaded_href=${uploaded_url#https://webdav.example.invalid}
			printf "<?xml version=\"1.0\"?><D:multistatus xmlns:D=\"DAV:\">\n"
			printf "<D:response><D:href>/dav/R2/devices/%s/wrtbak/2026/newer-a.wrtbak</D:href><D:propstat><D:prop><D:getcontentlength>7</D:getcontentlength><D:getlastmodified>Thu, 25 Jun 2026 12:00:00 GMT</D:getlastmodified></D:prop></D:propstat></D:response>\n" "$WRTBAK_FAKE_DEVICE_UID"
			printf "<D:response><D:href>/dav/R2/devices/%s/wrtbak/2026/newer-b.wrtbak</D:href><D:propstat><D:prop><D:getcontentlength>8</D:getcontentlength><D:getlastmodified>Thu, 25 Jun 2026 11:00:00 GMT</D:getlastmodified></D:prop></D:propstat></D:response>\n" "$WRTBAK_FAKE_DEVICE_UID"
			printf "<D:response><D:href>/dav/R2/wrtbak/%s/wrtbak/2026/legacy.wrtbak</D:href><D:propstat><D:prop><D:getcontentlength>4</D:getcontentlength><D:getlastmodified>Wed, 24 Jun 2026 02:00:00 GMT</D:getlastmodified></D:prop></D:propstat></D:response>\n" "$WRTBAK_FAKE_DEVICE_ALIAS"
			printf "<D:response><D:href>/dav/R2/wrtbak/old-device-id-0001/wrtbak/2026/legacy-device-id.wrtbak</D:href><D:propstat><D:prop><D:getcontentlength>3</D:getcontentlength><D:getlastmodified>Wed, 24 Jun 2026 04:00:00 GMT</D:getlastmodified></D:prop></D:propstat></D:response>\n"
			printf "<D:response><D:href>%s</D:href><D:propstat><D:prop><D:getcontentlength>%s</D:getcontentlength><D:getlastmodified>Thu, 25 Jun 2026 01:00:00 GMT</D:getlastmodified></D:prop></D:propstat></D:response>\n" "$uploaded_href" "$size"
			printf "</D:multistatus>\n"
		fi
		exit 0
		;;
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
	WRTBAK_ALLOW_TEST_HOOKS=1 \
	WRTBAK_FAKE_DEVICE_UID="$device_uid" \
	WRTBAK_FAKE_DEVICE_ALIAS="$device_alias" \
		"$cli" "$@"
}

run_cli remote-upload --target default --profile webdav-test --items all --format wrtbak --prune-max 2 --json >"$work_dir/upload.json"
python3 - "$work_dir/upload.json" "$fixture_root" "$remote_prefix" "$device_uid" "$device_alias" "$state_dir" <<'PY'
import json, pathlib, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
root = pathlib.Path(sys.argv[2])
remote_prefix = sys.argv[3]
device_uid = sys.argv[4]
device_alias = sys.argv[5]
state_dir = pathlib.Path(sys.argv[6])
assert data["ok"] is True
assert data["target"] == "webdav"
assert data["driver"] == "curl"
assert data["format"] == "wrtbak"
assert data["remote_path"].startswith(f"{remote_prefix}/devices/{device_uid}/wrtbak/")
assert data["remote_path"].endswith(".wrtbak")
assert data["alias_index_updated"] is True
assert data["alias_index_path"] == f"{remote_prefix}/aliases/{device_alias}.json"
assert data["local_archive_retained"] is False
assert not pathlib.Path(data["local_archive_path"]).exists()
assert (root / "overlay/wrtbak/remote-history.jsonl").exists()
assert data["prune"]["deleted_count"] == 1
assert data["remote_path"] not in data["prune"]["deleted_paths"]
alias_index = json.loads((state_dir / "alias-index.json").read_text(encoding="utf-8"))
assert alias_index["alias"] == device_alias
assert alias_index["uid"] == device_uid
assert alias_index["latest_backup_key"] == data["remote_path"]
assert alias_index["updated_at"].endswith("Z")
PY

uploaded_url=$(cat "$state_dir/upload.url")
if grep -F -q "$uploaded_url" "$delete_log"; then
	echo "WebDAV prune deleted the just-uploaded backup" >&2
	exit 1
fi

run_cli remote-delete --target default --path "$remote_prefix/devices/$device_uid/wrtbak/2026/webdav-test.wrtbak" --json >"$work_dir/delete.json"
python3 - "$work_dir/delete.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
assert data["ok"] is True
assert data["deleted"] is True
assert data["driver"] == "curl"
PY

legacy_delete_path="$remote_prefix/wrtbak/$device_alias/wrtbak/2026/legacy.wrtbak"
if run_cli remote-delete --target default --path "$legacy_delete_path" --json >"$work_dir/delete-legacy.json"; then
	echo "WebDAV delete should reject legacy alias paths" >&2
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
	echo "WebDAV delete attempted legacy alias path" >&2
	exit 1
fi

legacy_device_delete_path="$remote_prefix/wrtbak/$legacy_device_id/wrtbak/2026/legacy-device-id.wrtbak"
if run_cli remote-delete --target default --path "$legacy_device_delete_path" --json >"$work_dir/delete-legacy-device-id.json"; then
	echo "WebDAV delete should reject legacy device_id paths" >&2
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
	echo "WebDAV delete attempted legacy device_id path" >&2
	exit 1
fi

if grep -q 'webdav-user\|webdav-secret-value' "$curl_log"; then
	echo "WebDAV credentials leaked into curl arguments" >&2
	exit 1
fi

echo "fixture WebDAV remote CLI management test passed"
