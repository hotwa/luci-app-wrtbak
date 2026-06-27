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
legacy_only_xml_file="$work_dir/webdav-legacy-only.xml"

cleanup() {
	rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$bin_dir" "$fixture_root/etc/config" "$fixture_root/etc"

device_uid="fixture-device-uid-0001"
device_alias="fixture-router"
legacy_device_id="old-device-id-0001"
remote_prefix="R2"

cat >"$fixture_root/etc/config/wrtbak" <<'EOT'
config wrtbak 'main'
	option enabled '1'
	option default_target 'webdav'
	option device_id 'old-device-id-0001'
	option device_alias 'fixture-router'
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
    <D:href>/dav/R2/devices/$device_uid/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/R2/devices/$device_uid/wrtbak/2026/auto-20260625T020000Z.wrtbak</D:href>
    <D:propstat><D:prop><D:getcontentlength>5</D:getcontentlength><D:getlastmodified>Thu, 25 Jun 2026 02:00:00 GMT</D:getlastmodified><D:resourcetype/></D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/R2/devices/$device_uid/sysupgrade/2026/auto-20260625T020000Z.sysupgrade.tar.gz</D:href>
    <D:propstat><D:prop><D:getcontentlength>7</D:getcontentlength><D:getlastmodified>Thu, 25 Jun 2026 03:00:00 GMT</D:getlastmodified><D:resourcetype/></D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/R2/wrtbak/$device_alias/wrtbak/2026/legacy.wrtbak</D:href>
    <D:propstat><D:prop><D:getcontentlength>3</D:getcontentlength><D:getlastmodified>Wed, 24 Jun 2026 02:00:00 GMT</D:getlastmodified><D:resourcetype/></D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/R2/wrtbak/$legacy_device_id/wrtbak/2026/legacy-device-id.wrtbak</D:href>
    <D:propstat><D:prop><D:getcontentlength>17</D:getcontentlength><D:getlastmodified>Wed, 24 Jun 2026 04:00:00 GMT</D:getlastmodified><D:resourcetype/></D:prop></D:propstat>
  </D:response>
</D:multistatus>
EOT

cat >"$legacy_only_xml_file" <<EOT
<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/R2/wrtbak/$legacy_device_id/wrtbak/2026/legacy-device-id-only.wrtbak</D:href>
    <D:propstat><D:prop><D:getcontentlength>19</D:getcontentlength><D:getlastmodified>Wed, 24 Jun 2026 05:00:00 GMT</D:getlastmodified><D:resourcetype/></D:prop></D:propstat>
  </D:response>
</D:multistatus>
EOT

cat >"$bin_dir/curl" <<'EOT'
#!/bin/sh
printf '%s\n' "$*" >>"$WRTBAK_FAKE_CURL_LOG"

previous=
url=
for arg in "$@"; do
	if [ "$previous" = "--netrc-file" ]; then
		printf '%s\n' "$arg" >>"$WRTBAK_FAKE_NETRC_LOG"
		mode=$(stat -c '%a' "$arg")
		if [ "$mode" != "600" ]; then
			printf 'bad netrc mode: %s\n' "$mode" >&2
			exit 44
		fi
	fi
	case "$arg" in
		http://*|https://*)
			url=$arg
			;;
	esac
	previous=$arg
done

case " $* " in
	*" -X PROPFIND "*)
		if [ "${WRTBAK_FAKE_PROPFIND_FAIL:-0}" = "1" ]; then
			printf 'HTTP 405 PROPFIND unsupported\n' >&2
			exit 22
		fi
		current_uid=${WRTBAK_FAKE_DEVICE_UID:-}
		if [ -n "$current_uid" ] && [ "${WRTBAK_FAKE_CURRENT_PROPFIND_FAIL:-0}" = "1" ]; then
			case "$url" in
				*/devices/"$current_uid"|*/devices/"$current_uid"/)
					printf 'HTTP 404 current collection missing\n' >&2
					exit 22
					;;
			esac
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
WRTBAK_ALLOW_TEST_HOOKS=1 \
WRTBAK_FAKE_DEVICE_UID="$device_uid" \
	"$cli" remote-test --target webdav --json >"$work_dir/test.json"

python3 - "$work_dir/test.json" "$remote_prefix" "$device_uid" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
remote_prefix = sys.argv[2]
device_uid = sys.argv[3]

assert data["ok"] is True
assert data["operation"] == "remote-test"
assert data["target"] == "webdav"
assert data["driver"] == "curl"
assert data["remote_path"] == f"{remote_prefix}/devices/{device_uid}/.probe"
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
WRTBAK_ALLOW_TEST_HOOKS=1 \
WRTBAK_FAKE_DEVICE_UID="$device_uid" \
	"$cli" remote-list --target webdav --json >"$work_dir/list.json"

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
assert data["target"] == "webdav"
assert data["driver"] == "curl"
paths = [item["path"] for item in data["backups"]]
current_wrtbak = f"{remote_prefix}/devices/{device_uid}/wrtbak/2026/auto-20260625T020000Z.wrtbak"
current_sysupgrade = f"{remote_prefix}/devices/{device_uid}/sysupgrade/2026/auto-20260625T020000Z.sysupgrade.tar.gz"
legacy = f"{remote_prefix}/wrtbak/{device_alias}/wrtbak/2026/legacy.wrtbak"
legacy_device = f"{remote_prefix}/wrtbak/{legacy_device_id}/wrtbak/2026/legacy-device-id.wrtbak"
assert current_wrtbak in paths
assert current_sysupgrade in paths
assert legacy in paths
assert legacy_device in paths
assert len(paths) == len(set(paths))
by_path = {item["path"]: item for item in data["backups"]}
assert by_path[current_wrtbak].get("legacy") in (None, False)
assert by_path[current_sysupgrade].get("legacy") in (None, False)
assert by_path[legacy]["legacy"] is True
assert by_path[legacy_device]["legacy"] is True
assert by_path[current_wrtbak]["filename"].startswith("auto-")
assert by_path[current_sysupgrade]["filename"].startswith("auto-")
assert by_path[legacy]["filename"] == "legacy.wrtbak"
assert by_path[legacy_device]["filename"] == "legacy-device-id.wrtbak"
assert {item["format"] for item in data["backups"]} == {"wrtbak", "sysupgrade"}
assert {item["size"] for item in data["backups"]} == {3, 5, 7, 17}
PY

PATH="$bin_dir:$PATH" \
WRTBAK_ROOT="$fixture_root" \
WRTBAK_LIBDIR="$libdir" \
WRTBAK_FAKE_CURL_LOG="$curl_log" \
WRTBAK_FAKE_NETRC_LOG="$netrc_log" \
WRTBAK_FAKE_WEBDAV_XML="$legacy_only_xml_file" \
WRTBAK_FAKE_CURRENT_PROPFIND_FAIL=1 \
WRTBAK_ALLOW_TEST_HOOKS=1 \
WRTBAK_FAKE_DEVICE_UID="$device_uid" \
	"$cli" remote-list --target webdav --json >"$work_dir/list-legacy-only.json"

python3 - "$work_dir/list-legacy-only.json" "$remote_prefix" "$device_uid" "$legacy_device_id" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
remote_prefix = sys.argv[2]
device_uid = sys.argv[3]
legacy_device_id = sys.argv[4]

assert data["ok"] is True
assert data["operation"] == "remote-list"
assert data["target"] == "webdav"
paths = [item["path"] for item in data["backups"]]
legacy_device = f"{remote_prefix}/wrtbak/{legacy_device_id}/wrtbak/2026/legacy-device-id-only.wrtbak"
assert legacy_device in paths
assert all(not path.startswith(f"{remote_prefix}/devices/{device_uid}/") for path in paths)
by_path = {item["path"]: item for item in data["backups"]}
assert by_path[legacy_device]["legacy"] is True
assert by_path[legacy_device]["filename"] == "legacy-device-id-only.wrtbak"
assert by_path[legacy_device]["format"] == "wrtbak"
assert by_path[legacy_device]["size"] == 19
PY

if PATH="$bin_dir:$PATH" \
	WRTBAK_ROOT="$fixture_root" \
	WRTBAK_LIBDIR="$libdir" \
	WRTBAK_FAKE_CURL_LOG="$curl_log" \
	WRTBAK_FAKE_NETRC_LOG="$netrc_log" \
	WRTBAK_FAKE_WEBDAV_XML="$xml_file" \
	WRTBAK_FAKE_PROPFIND_FAIL=1 \
	WRTBAK_ALLOW_TEST_HOOKS=1 \
	WRTBAK_FAKE_DEVICE_UID="$device_uid" \
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
