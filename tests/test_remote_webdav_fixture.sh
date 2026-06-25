#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-remote-webdav-test.XXXXXX")
fixture_root="$work_dir/root"
bin_dir="$work_dir/bin"
libdir="$repo_dir/root/usr/lib/wrtbak"
cli="$repo_dir/root/usr/bin/wrtbak"
curl_log="$work_dir/curl.log"
netrc_log="$work_dir/netrc-paths.log"
xml_file="$work_dir/webdav.xml"

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
	option default_target 'webdav'
	option history_file '/overlay/wrtbak/remote-history.jsonl'
	option history_max_entries '20'

config remote 'webdav'
	option enabled '1'
	option driver 'curl'
	option url 'https://example.invalid/dav'
	option username 'webdav-user'
	option password 'webdav-pass-value'
	option path '/R2/'
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

cat >"$xml_file" <<EOT
<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/R2/wrtbak/$device_id/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/R2/wrtbak/$device_id/wrtbak/2026/auto-20260625T020000Z.wrtbak</D:href>
    <D:propstat><D:prop><D:getcontentlength>5</D:getcontentlength><D:getlastmodified>Thu, 25 Jun 2026 02:00:00 GMT</D:getlastmodified><D:resourcetype/></D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/R2/wrtbak/$device_id/sysupgrade/2026/auto-20260625T020000Z.sysupgrade.tar.gz</D:href>
    <D:propstat><D:prop><D:getcontentlength>7</D:getcontentlength><D:getlastmodified>Thu, 25 Jun 2026 03:00:00 GMT</D:getlastmodified><D:resourcetype/></D:prop></D:propstat>
  </D:response>
</D:multistatus>
EOT

cat >"$bin_dir/curl" <<'EOT'
#!/bin/sh
printf '%s\n' "$*" >>"$WRTBAK_FAKE_CURL_LOG"

previous=
for arg in "$@"; do
	if [ "$previous" = "--netrc-file" ]; then
		printf '%s\n' "$arg" >>"$WRTBAK_FAKE_NETRC_LOG"
		mode=$(stat -c '%a' "$arg")
		if [ "$mode" != "600" ]; then
			printf 'bad netrc mode: %s\n' "$mode" >&2
			exit 44
		fi
	fi
	previous=$arg
done

case " $* " in
	*" -X PROPFIND "*)
		if [ "${WRTBAK_FAKE_PROPFIND_FAIL:-0}" = "1" ]; then
			printf 'HTTP 405 PROPFIND unsupported\n' >&2
			exit 22
		fi
		cat "$WRTBAK_FAKE_WEBDAV_XML"
		exit 0
		;;
	*" --upload-file "*)
		exit 0
		;;
	*" -I "*|*" --head "*)
		printf 'HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n'
		exit 0
		;;
	*" -X DELETE "*)
		exit 0
		;;
	*" -X MKCOL "*)
		exit 0
		;;
esac

exit 0
EOT
chmod +x "$bin_dir/curl"

PATH="$bin_dir:$PATH" \
WRTBAK_ROOT="$fixture_root" \
WRTBAK_LIBDIR="$libdir" \
WRTBAK_FAKE_CURL_LOG="$curl_log" \
WRTBAK_FAKE_NETRC_LOG="$netrc_log" \
WRTBAK_FAKE_WEBDAV_XML="$xml_file" \
	"$cli" remote-test --target webdav --json >"$work_dir/test.json"

python3 - "$work_dir/test.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

assert data["ok"] is True
assert data["operation"] == "remote-test"
assert data["target"] == "webdav"
assert data["driver"] == "curl"
assert data["remote_path"].endswith(".probe")
PY

if grep -q 'webdav-pass-value' "$curl_log"; then
	echo "WebDAV password leaked into curl arguments" >&2
	exit 1
fi

while IFS= read -r netrc_path || [ -n "$netrc_path" ]; do
	[ ! -e "$netrc_path" ] || {
		echo "temporary netrc was not removed: $netrc_path" >&2
		exit 1
	}
done < "$netrc_log"

PATH="$bin_dir:$PATH" \
WRTBAK_ROOT="$fixture_root" \
WRTBAK_LIBDIR="$libdir" \
WRTBAK_FAKE_CURL_LOG="$curl_log" \
WRTBAK_FAKE_NETRC_LOG="$netrc_log" \
WRTBAK_FAKE_WEBDAV_XML="$xml_file" \
	"$cli" remote-list --target webdav --json >"$work_dir/list.json"

python3 - "$work_dir/list.json" "$device_id" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
device_id = sys.argv[2]

assert data["ok"] is True
assert data["operation"] == "remote-list"
assert data["target"] == "webdav"
assert data["driver"] == "curl"
paths = [item["path"] for item in data["backups"]]
assert f"R2/wrtbak/{device_id}/wrtbak/2026/auto-20260625T020000Z.wrtbak" in paths
assert f"R2/wrtbak/{device_id}/sysupgrade/2026/auto-20260625T020000Z.sysupgrade.tar.gz" in paths
assert all(item["filename"].startswith("auto-") for item in data["backups"])
assert {item["format"] for item in data["backups"]} == {"wrtbak", "sysupgrade"}
assert {item["size"] for item in data["backups"]} == {5, 7}
PY

if PATH="$bin_dir:$PATH" \
	WRTBAK_ROOT="$fixture_root" \
	WRTBAK_LIBDIR="$libdir" \
	WRTBAK_FAKE_CURL_LOG="$curl_log" \
	WRTBAK_FAKE_NETRC_LOG="$netrc_log" \
	WRTBAK_FAKE_WEBDAV_XML="$xml_file" \
	WRTBAK_FAKE_PROPFIND_FAIL=1 \
	"$cli" remote-list --target webdav --json >"$work_dir/list-fail.json"; then
	echo "remote-list should fail when PROPFIND fails" >&2
	exit 1
fi

python3 - "$work_dir/list-fail.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

assert data["ok"] is False
assert data["operation"] == "remote-list"
assert data["target"] == "webdav"
assert data["code"] == "unsupported_list"
PY

echo "fixture WebDAV remote test passed"
