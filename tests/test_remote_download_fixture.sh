#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-remote-download-test.XXXXXX")
fixture_root="$work_dir/root"
bin_dir="$work_dir/bin"
state_dir="$work_dir/state"
libdir="$repo_dir/root/usr/lib/wrtbak"
cli="$repo_dir/root/usr/bin/wrtbak"
curl_log="$work_dir/curl.log"
rclone_log="$work_dir/rclone.log"
netrc_log="$work_dir/netrc-paths.log"
config_log="$work_dir/rclone-config-paths.log"
download_log="$work_dir/downloads.log"

cleanup() {
	rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$bin_dir" "$fixture_root/etc/config" "$fixture_root/etc" "$fixture_root/overlay/wrtbak" "$state_dir"
: > "$curl_log"
: > "$rclone_log"
: > "$netrc_log"
: > "$config_log"
: > "$download_log"

hash8=$(python3 - <<'PY'
import hashlib
print(hashlib.sha256(b"fixture-machine-id").hexdigest()[:8])
PY
)
device_id="fixture-router-test-board-model-$hash8"
webdav_prefix="R2/wrtbak/$device_id"
s3_prefix="backups/wrtbak/$device_id"
webdav_sample="$webdav_prefix/wrtbak/2026/sample.wrtbak"
s3_sample="$s3_prefix/wrtbak/2026/sample.wrtbak"
sample_content="sample-remote-backup-content"

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

cat >"$bin_dir/curl" <<'EOT'
#!/bin/sh
printf '%s\n' "$*" >>"$WRTBAK_FAKE_CURL_LOG"

previous=
method=GET
output=
location=0
dump_headers=
url=
for arg in "$@"; do
	if [ "$previous" = "--netrc-file" ]; then
		printf '%s\n' "$arg" >>"$WRTBAK_FAKE_NETRC_LOG"
		mode=$(stat -c '%a' "$arg")
		[ "$mode" = "600" ] || {
			printf 'bad netrc mode: %s\n' "$mode" >&2
			exit 44
		}
	fi
	if [ "$previous" = "-X" ]; then
		method=$arg
	fi
	if [ "$previous" = "-o" ] || [ "$previous" = "--output" ]; then
		output=$arg
	fi
	if [ "$previous" = "-D" ] || [ "$previous" = "--dump-header" ]; then
		dump_headers=$arg
	fi
	if [ "$arg" = "-L" ] || [ "$arg" = "--location" ]; then
		location=1
	fi
	case "$arg" in
		http://*|https://*)
			url=$arg
			;;
	esac
	previous=$arg
done

content=${WRTBAK_FAKE_REMOTE_CONTENT:-sample-remote-backup-content}
size=${WRTBAK_FAKE_REMOTE_SIZE:-}
[ -n "$size" ] || size=$(printf '%s' "$content" | wc -c | awk '{ print $1 }')
modified=${WRTBAK_FAKE_REMOTE_MODIFIED:-Fri, 26 Jun 2026 03:30:00 GMT}
etag=${WRTBAK_FAKE_REMOTE_ETAG:-etag-1}

if [ "$method" = "PROPFIND" ]; then
	printf '<?xml version="1.0" encoding="utf-8"?>\n'
	printf '<D:multistatus xmlns:D="DAV:"><D:response><D:propstat><D:prop>'
	if [ "${WRTBAK_FAKE_SIZE_UNAVAILABLE:-0}" != "1" ]; then
		printf '<D:getcontentlength>%s</D:getcontentlength>' "$size"
	fi
	if [ "${WRTBAK_FAKE_NO_METADATA:-0}" != "1" ]; then
		printf '<D:getlastmodified>%s</D:getlastmodified>' "$modified"
		printf '<D:getetag>%s</D:getetag>' "$etag"
	fi
	printf '</D:prop></D:propstat></D:response></D:multistatus>\n'
	exit 0
fi

if [ -n "$output" ]; then
	case "$url" in
		https://storage.example.invalid/*)
			[ -z "$dump_headers" ] || printf 'HTTP/1.1 200 OK\r\nContent-Length: %s\r\n\r\n' "$size" > "$dump_headers"
			printf '%s' "$content" > "$output"
			printf 'webdav\t%s\n' "$output" >>"$WRTBAK_FAKE_DOWNLOAD_LOG"
			exit 0
			;;
	esac
	if [ "${WRTBAK_FAKE_DOWNLOAD_FAIL:-0}" = "1" ]; then
		printf 'partial' > "$output"
		exit 55
	fi
	if [ "${WRTBAK_FAKE_DOWNLOAD_REDIRECT:-0}" = "1" ] && [ "$location" = "1" ]; then
		printf 'forbidden' > "$output"
		exit 22
	fi
	if [ "${WRTBAK_FAKE_DOWNLOAD_REDIRECT:-0}" = "1" ]; then
		[ -z "$dump_headers" ] || printf 'HTTP/1.1 302 Found\r\nLocation: https://example.invalid/proxy/sample.wrtbak\r\nContent-Length: 70\r\n\r\n' > "$dump_headers"
		printf '<a href="https://storage.example.invalid/sample.wrtbak">Found</a>.' > "$output"
		exit 0
	fi
	[ -z "$dump_headers" ] || printf 'HTTP/1.1 200 OK\r\nContent-Length: %s\r\n\r\n' "$size" > "$dump_headers"
	printf '%s' "$content" > "$output"
	printf 'webdav\t%s\n' "$output" >>"$WRTBAK_FAKE_DOWNLOAD_LOG"
	exit 0
fi

exit 0
EOT
chmod +x "$bin_dir/curl"

cat >"$bin_dir/rclone" <<'EOT'
#!/bin/sh
printf '%s\n' "$*" >>"$WRTBAK_FAKE_RCLONE_LOG"

config=
command=
if [ "$#" -gt 0 ] && [ "$1" = "--config" ]; then
	config=$2
	printf '%s\n' "$config" >>"$WRTBAK_FAKE_RCLONE_CONFIG_LOG"
	mode=$(stat -c '%a' "$config")
	[ "$mode" = "600" ] || {
		printf 'bad rclone config mode: %s\n' "$mode" >&2
		exit 44
	}
	grep -q '^access_key_id = s3-access-value$' "$config" || exit 45
	grep -q '^secret_access_key = s3-secret-value$' "$config" || exit 46
	shift 2
fi

[ "$#" -gt 0 ] || exit 0
command=$1
shift

content=${WRTBAK_FAKE_REMOTE_CONTENT:-sample-remote-backup-content}
size=${WRTBAK_FAKE_REMOTE_SIZE:-}
[ -n "$size" ] || size=$(printf '%s' "$content" | wc -c | awk '{ print $1 }')
modified=${WRTBAK_FAKE_REMOTE_MODIFIED:-2026-06-26T03:30:00Z}
etag=${WRTBAK_FAKE_REMOTE_ETAG:-}

case "$command" in
	lsjson)
		remote_ref=$1
		remote_path=${remote_ref#wrtbak_remote:bucket-a/}
		name=${remote_path##*/}
		printf '[{\n'
		printf '  "Path": "%s",\n' "$remote_path"
		printf '  "Name": "%s"' "$name"
		if [ "${WRTBAK_FAKE_SIZE_UNAVAILABLE:-0}" != "1" ]; then
			printf ',\n  "Size": %s' "$size"
		fi
		if [ "${WRTBAK_FAKE_NO_METADATA:-0}" != "1" ]; then
			printf ',\n  "ModTime": "%s"' "$modified"
			if [ -n "$etag" ]; then
				printf ',\n  "ETag": "%s"' "$etag"
			fi
		fi
		printf '\n}]\n'
		exit 0
		;;
	copyto)
		source=$1
		destination=$2
		case "$source" in
			wrtbak_remote:*)
				if [ "${WRTBAK_FAKE_DOWNLOAD_FAIL:-0}" = "1" ]; then
					printf 'partial' > "$destination"
					exit 55
				fi
				printf '%s' "$content" > "$destination"
				printf 's3\t%s\n' "$destination" >>"$WRTBAK_FAKE_DOWNLOAD_LOG"
				exit 0
				;;
			*)
				exit 0
				;;
		esac
		;;
esac

exit 0
EOT
chmod +x "$bin_dir/rclone"

run_cli() {
	run_cli_with_path "$bin_dir" "$@"
}

make_fake_path() {
	wrtbak_fake_path=$1
	wrtbak_hide_1=${2:-}
	wrtbak_hide_2=${3:-}
	[ -d "$wrtbak_fake_path" ] || {
		mkdir -p "$wrtbak_fake_path"
		for wrtbak_src_name in awk basename cat chmod cut date dirname grep ln mkdir mktemp rm sed sha256sum sort stat tail tr wc; do
			[ -n "$wrtbak_hide_1" ] && [ "$wrtbak_src_name" = "$wrtbak_hide_1" ] && continue
			[ -n "$wrtbak_hide_2" ] && [ "$wrtbak_src_name" = "$wrtbak_hide_2" ] && continue
			wrtbak_src_file=$(command -v "$wrtbak_src_name") || continue
			[ -e "$wrtbak_fake_path/$wrtbak_src_name" ] || ln -s "$wrtbak_src_file" "$wrtbak_fake_path/$wrtbak_src_name"
		done
	}
}

run_cli_with_path() {
	wrtbak_path_prefix=$1
	shift
	WRTBAK_ROOT="$fixture_root" \
	WRTBAK_LIBDIR="$libdir" \
	WRTBAK_FAKE_CURL_LOG="$curl_log" \
	WRTBAK_FAKE_RCLONE_LOG="$rclone_log" \
	WRTBAK_FAKE_NETRC_LOG="$netrc_log" \
	WRTBAK_FAKE_RCLONE_CONFIG_LOG="$config_log" \
	WRTBAK_FAKE_DOWNLOAD_LOG="$download_log" \
	WRTBAK_FAKE_STATE_DIR="$state_dir" \
	WRTBAK_FAKE_REMOTE_CONTENT="${WRTBAK_FAKE_REMOTE_CONTENT:-$sample_content}" \
	WRTBAK_FAKE_REMOTE_SIZE="${WRTBAK_FAKE_REMOTE_SIZE:-}" \
	WRTBAK_FAKE_REMOTE_MODIFIED="${WRTBAK_FAKE_REMOTE_MODIFIED:-}" \
	WRTBAK_FAKE_REMOTE_ETAG="${WRTBAK_FAKE_REMOTE_ETAG:-}" \
	WRTBAK_FAKE_SIZE_UNAVAILABLE="${WRTBAK_FAKE_SIZE_UNAVAILABLE:-0}" \
	WRTBAK_FAKE_DOWNLOAD_FAIL="${WRTBAK_FAKE_DOWNLOAD_FAIL:-0}" \
	WRTBAK_FAKE_DOWNLOAD_REDIRECT="${WRTBAK_FAKE_DOWNLOAD_REDIRECT:-0}" \
	WRTBAK_FAKE_NO_METADATA="${WRTBAK_FAKE_NO_METADATA:-0}" \
	PATH="$wrtbak_path_prefix:$PATH" \
		"$cli" "$@"
}

run_cli_with_exact_path() {
	wrtbak_exact_path=$1
	shift
	WRTBAK_ROOT="$fixture_root" \
	WRTBAK_LIBDIR="$libdir" \
	WRTBAK_FAKE_CURL_LOG="$curl_log" \
	WRTBAK_FAKE_RCLONE_LOG="$rclone_log" \
	WRTBAK_FAKE_NETRC_LOG="$netrc_log" \
	WRTBAK_FAKE_RCLONE_CONFIG_LOG="$config_log" \
	WRTBAK_FAKE_DOWNLOAD_LOG="$download_log" \
	WRTBAK_FAKE_STATE_DIR="$state_dir" \
	WRTBAK_FAKE_REMOTE_CONTENT="${WRTBAK_FAKE_REMOTE_CONTENT:-$sample_content}" \
	WRTBAK_FAKE_REMOTE_SIZE="${WRTBAK_FAKE_REMOTE_SIZE:-}" \
	WRTBAK_FAKE_REMOTE_MODIFIED="${WRTBAK_FAKE_REMOTE_MODIFIED:-}" \
	WRTBAK_FAKE_REMOTE_ETAG="${WRTBAK_FAKE_REMOTE_ETAG:-}" \
	WRTBAK_FAKE_SIZE_UNAVAILABLE="${WRTBAK_FAKE_SIZE_UNAVAILABLE:-0}" \
	WRTBAK_FAKE_DOWNLOAD_FAIL="${WRTBAK_FAKE_DOWNLOAD_FAIL:-0}" \
	WRTBAK_FAKE_DOWNLOAD_REDIRECT="${WRTBAK_FAKE_DOWNLOAD_REDIRECT:-0}" \
	WRTBAK_FAKE_NO_METADATA="${WRTBAK_FAKE_NO_METADATA:-0}" \
	PATH="$wrtbak_exact_path" \
		"$cli" "$@"
}

run_cli_without_dependency() {
	wrtbak_missing_tool=$1
	shift
	wrtbak_missing_tool_bin="$work_dir/no-$wrtbak_missing_tool-bin"
	make_fake_path "$wrtbak_missing_tool_bin" "$wrtbak_missing_tool"
	run_cli_with_exact_path "$wrtbak_missing_tool_bin" "$@"
}

run_cli_with_fake_sha256sum() {
	wrtbak_fake_sha256_dir="$work_dir/fake-sha256-bin"
	make_fake_path "$wrtbak_fake_sha256_dir" curl rclone
	rm -f "$wrtbak_fake_sha256_dir/sha256sum"
	cat >"$wrtbak_fake_sha256_dir/sha256sum" <<'EOT'
#!/bin/sh
if [ "$#" -eq 0 ]; then
	exec /usr/bin/sha256sum
fi
exit 99
EOT
	chmod +x "$wrtbak_fake_sha256_dir/sha256sum"
	run_cli_with_path "$wrtbak_fake_sha256_dir:$bin_dir" "$@"
}

run_success() {
	output_file=$1
	shift
	if ! run_cli "$@" > "$output_file"; then
		echo "expected command to succeed: $*" >&2
		cat "$output_file" >&2
		exit 1
	fi
}

download_count() {
	driver=$1
	awk -v driver="$driver" '$1 == driver { count += 1 } END { print count + 0 }' "$download_log"
}

assert_success_json() {
	output_file=$1
	target=$2
	driver=$3
	remote_path=$4
	modified=$5
	etag=$6
	sidecar_modified=${7:-$modified}
	sidecar_etag=${8:-$etag}
	python3 - "$output_file" "$fixture_root" "$target" "$driver" "$remote_path" "$sample_content" "$modified" "$etag" "$sidecar_modified" "$sidecar_etag" <<'PY'
import hashlib
import json
import pathlib
import sys

output, fixture_root, target, driver, remote_path, content, modified, etag, sidecar_modified, sidecar_etag = sys.argv[1:]
with open(output, encoding="utf-8") as handle:
    data = json.load(handle)

expected_sha = hashlib.sha256(content.encode()).hexdigest()
cache_root = pathlib.Path(fixture_root) / "tmp/wrtbak/restore-cache"

assert data["ok"] is True
assert data["operation"] == "remote-download"
assert data["target"] == target
assert data["driver"] == driver
assert data["remote_path"] == remote_path
assert pathlib.Path(data["local_path"]).is_file()
assert str(data["local_path"]).startswith(str(cache_root) + "/")
assert pathlib.Path(data["local_path"]).name.endswith("sample.wrtbak")
assert data["sidecar_path"] == data["local_path"] + ".remote.json"
assert pathlib.Path(data["sidecar_path"]).is_file()
assert data["filename"] == "sample.wrtbak"
assert data["format"] == "wrtbak"
assert data["size"] == len(content)
assert data["sha256"] == expected_sha
assert data["remote_modified"] == modified
assert data["remote_etag"] == etag

with open(data["sidecar_path"], encoding="utf-8") as handle:
    sidecar = json.load(handle)

for field in [
    "target",
    "driver",
    "remote_path",
    "filename",
    "format",
    "size",
    "remote_modified",
    "remote_etag",
    "downloaded_at",
    "sha256",
    "provider",
    "remote_name",
    "cache_path",
    "mtime",
]:
    assert field in sidecar, field

assert sidecar["target"] == target
assert sidecar["driver"] == driver
assert sidecar["remote_path"] == remote_path
assert sidecar["filename"] == "sample.wrtbak"
assert sidecar["format"] == "wrtbak"
assert sidecar["size"] == len(content)
assert sidecar["remote_modified"] == sidecar_modified
assert sidecar["remote_etag"] == sidecar_etag
assert sidecar["provider"] == sidecar["target"]
assert sidecar["remote_name"] == sidecar["target"]
assert sidecar["cache_path"] == data["local_path"]
assert sidecar["mtime"] == sidecar_modified
assert sidecar["downloaded_at"].endswith("Z")
assert sidecar["sha256"] == expected_sha
PY
}

assert_error_code() {
	output_file=$1
	code=$2
	python3 - "$output_file" "$code" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

assert data["ok"] is False
assert data["operation"] == "remote-download"
if sys.argv[2]:
    assert data["code"] == sys.argv[2], data
PY
}

WRTBAK_FAKE_DOWNLOAD_REDIRECT=1
WRTBAK_FAKE_REMOTE_MODIFIED="Fri, 26 Jun 2026 03:31:00 GMT"
WRTBAK_FAKE_REMOTE_ETAG="etag-redirect"
run_success "$work_dir/webdav-redirect.json" remote-download --target webdav --path "$webdav_sample" --json
assert_success_json "$work_dir/webdav-redirect.json" webdav curl "$webdav_sample" "Fri, 26 Jun 2026 03:31:00 GMT" "etag-redirect"
grep -- '-L' "$curl_log" >/dev/null 2>&1 || {
	echo "WebDAV download did not request curl location following" >&2
	exit 1
}
WRTBAK_FAKE_DOWNLOAD_REDIRECT=0

WRTBAK_FAKE_REMOTE_MODIFIED="Fri, 26 Jun 2026 03:30:00 GMT"
WRTBAK_FAKE_REMOTE_ETAG="etag-1"
run_success "$work_dir/webdav.json" remote-download --target webdav --path "$webdav_sample" --json
assert_success_json "$work_dir/webdav.json" webdav curl "$webdav_sample" "Fri, 26 Jun 2026 03:30:00 GMT" "etag-1"

WRTBAK_FAKE_REMOTE_MODIFIED="2026-06-26T03:30:00Z"
WRTBAK_FAKE_REMOTE_ETAG=
run_success "$work_dir/s3.json" remote-download --target s3 --path "$s3_sample" --json
assert_success_json "$work_dir/s3.json" s3 rclone "$s3_sample" "2026-06-26T03:30:00Z" ""

webdav_before=$(download_count webdav)
WRTBAK_FAKE_REMOTE_MODIFIED="Fri, 26 Jun 2026 03:30:00 GMT"
WRTBAK_FAKE_REMOTE_ETAG="etag-1"
run_success "$work_dir/webdav-reuse.json" remote-download --target webdav --path "$webdav_sample" --json
webdav_after=$(download_count webdav)
[ "$webdav_before" = "$webdav_after" ] || {
	echo "WebDAV cache was not reused when metadata matched" >&2
	exit 1
}
assert_success_json "$work_dir/webdav-reuse.json" webdav curl "$webdav_sample" "Fri, 26 Jun 2026 03:30:00 GMT" "etag-1"

s3_before=$(download_count s3)
WRTBAK_FAKE_NO_METADATA=1
WRTBAK_FAKE_REMOTE_MODIFIED=
WRTBAK_FAKE_REMOTE_ETAG=
run_success "$work_dir/s3-reuse-no-metadata.json" remote-download --target s3 --path "$s3_sample" --json
s3_after=$(download_count s3)
[ "$s3_before" = "$s3_after" ] || {
	echo "S3 cache was not reused when metadata was unavailable" >&2
	exit 1
}
assert_success_json "$work_dir/s3-reuse-no-metadata.json" s3 rclone "$s3_sample" "" "" "2026-06-26T03:30:00Z" ""
WRTBAK_FAKE_NO_METADATA=0

webdav_before=$(download_count webdav)
WRTBAK_FAKE_REMOTE_MODIFIED="Fri, 26 Jun 2026 04:30:00 GMT"
WRTBAK_FAKE_REMOTE_ETAG="etag-1"
run_success "$work_dir/webdav-modified-changed.json" remote-download --target webdav --path "$webdav_sample" --json
webdav_after=$(download_count webdav)
[ "$webdav_after" -gt "$webdav_before" ] || {
	echo "WebDAV cache was reused after remote_modified changed" >&2
	exit 1
}
assert_success_json "$work_dir/webdav-modified-changed.json" webdav curl "$webdav_sample" "Fri, 26 Jun 2026 04:30:00 GMT" "etag-1"

webdav_before=$(download_count webdav)
WRTBAK_FAKE_REMOTE_MODIFIED="Fri, 26 Jun 2026 04:30:00 GMT"
WRTBAK_FAKE_REMOTE_ETAG="etag-2"
run_success "$work_dir/webdav-etag-changed.json" remote-download --target webdav --path "$webdav_sample" --json
webdav_after=$(download_count webdav)
[ "$webdav_after" -gt "$webdav_before" ] || {
	echo "WebDAV cache was reused after remote_etag changed" >&2
	exit 1
}
assert_success_json "$work_dir/webdav-etag-changed.json" webdav curl "$webdav_sample" "Fri, 26 Jun 2026 04:30:00 GMT" "etag-2"

if run_cli remote-download --target webdav --path "R2/wrtbak/other-device/wrtbak/2026/sample.wrtbak" --json >"$work_dir/invalid-prefix.json"; then
	echo "remote-download should fail outside the current device prefix" >&2
	exit 1
fi
assert_error_code "$work_dir/invalid-prefix.json" invalid_config

if run_cli remote-download --target unknown --path "$webdav_sample" --json >"$work_dir/unknown-target.json"; then
	echo "remote-download should fail with unsupported provider for unknown target" >&2
	exit 1
fi
assert_error_code "$work_dir/unknown-target.json" unsupported_provider

if run_cli_without_dependency curl remote-download --target webdav --path "$webdav_sample" --json >"$work_dir/missing-curl.json"; then
	echo "remote-download should fail when curl is unavailable" >&2
	exit 1
fi
assert_error_code "$work_dir/missing-curl.json" missing_tool

if run_cli remote-download --target webdav --path "$webdav_prefix/wrtbak/2026/sample.txt" --json >"$work_dir/unsupported-suffix.json"; then
	echo "remote-download should fail unsupported suffixes" >&2
	exit 1
fi
assert_error_code "$work_dir/unsupported-suffix.json" invalid_format

WRTBAK_FAKE_SIZE_UNAVAILABLE=1
if run_cli remote-download --target webdav --path "$webdav_prefix/wrtbak/2026/missing-size.wrtbak" --json >"$work_dir/missing-size.json"; then
	echo "remote-download should fail when remote size is unavailable" >&2
	exit 1
fi
assert_error_code "$work_dir/missing-size.json" size_unavailable
WRTBAK_FAKE_SIZE_UNAVAILABLE=0

WRTBAK_FAKE_DOWNLOAD_FAIL=1
if run_cli remote-download --target webdav --path "$webdav_prefix/wrtbak/2026/download-fail.wrtbak" --json >"$work_dir/download-fail.json"; then
	echo "remote-download should fail when the driver download fails" >&2
	exit 1
fi
assert_error_code "$work_dir/download-fail.json" download_failed
if find "$fixture_root/tmp/wrtbak/restore-cache" -name '*.part.*' -print | grep . >/dev/null 2>&1; then
	echo "partial download file was not removed" >&2
	exit 1
fi
WRTBAK_FAKE_DOWNLOAD_FAIL=0

WRTBAK_FAKE_REMOTE_SIZE=999
if run_cli remote-download --target webdav --path "$webdav_prefix/wrtbak/2026/size-mismatch.wrtbak" --json >"$work_dir/size-mismatch.json"; then
	echo "remote-download should fail when downloaded size mismatch happens" >&2
	exit 1
fi
assert_error_code "$work_dir/size-mismatch.json" download_failed
if find "$fixture_root/tmp/wrtbak/restore-cache" -name '*.part.*' -print | grep . >/dev/null 2>&1; then
	echo "partial download file was not removed after size mismatch" >&2
	exit 1
fi
WRTBAK_FAKE_REMOTE_SIZE=

if run_cli_with_fake_sha256sum remote-download --target webdav --path "$webdav_prefix/wrtbak/2026/hash-fail.wrtbak" --json >"$work_dir/hash-fail.json"; then
	echo "remote-download should fail when hash calculation fails" >&2
	exit 1
fi
assert_error_code "$work_dir/hash-fail.json" hash_failed
[ ! -d "$fixture_root/tmp/wrtbak/remote.lock" ] || {
	echo "remote lock was not released after hash failure" >&2
	exit 1
}

if run_cli_with_fake_sha256sum remote-download --target webdav --path "$webdav_sample" --json >"$work_dir/hash-fail-cache.json"; then
	echo "remote-download should fail when cache hash calculation fails" >&2
	exit 1
fi
assert_error_code "$work_dir/hash-fail-cache.json" hash_failed
[ ! -d "$fixture_root/tmp/wrtbak/remote.lock" ] || {
	echo "remote lock was not released after cache hash failure" >&2
	exit 1
}

WRTBAK_FAKE_REMOTE_MODIFIED="Fri, 26 Jun 2026 05:30:00 GMT"
WRTBAK_FAKE_REMOTE_ETAG="etag-conflict"
conflict_path="$webdav_prefix/wrtbak/2026/cache-conflict.wrtbak"
run_success "$work_dir/cache-conflict-prime.json" remote-download --target webdav --path "$conflict_path" --json
conflict_local=$(python3 - "$work_dir/cache-conflict-prime.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["local_path"])
PY
)
rm -f "$conflict_local.remote.json"
if run_cli remote-download --target webdav --path "$conflict_path" --json >"$work_dir/cache-conflict.json"; then
	echo "remote-download should fail when cache exists without sidecar" >&2
	exit 1
fi
assert_error_code "$work_dir/cache-conflict.json" cache_conflict

if run_cli_without_dependency rclone remote-download --target s3 --path "$s3_sample" --json >"$work_dir/missing-rclone.json"; then
	echo "remote-download should fail when rclone is unavailable" >&2
	exit 1
fi
assert_error_code "$work_dir/missing-rclone.json" missing_tool

for forbidden in webdav-pass-value s3-access-value s3-secret-value; do
	if grep -q "$forbidden" "$curl_log" "$rclone_log"; then
		echo "secret leaked into fake command arguments: $forbidden" >&2
		exit 1
	fi
done

while IFS= read -r netrc_path || [ -n "$netrc_path" ]; do
	[ ! -e "$netrc_path" ] || {
		echo "temporary netrc was not removed: $netrc_path" >&2
		exit 1
	}
done < "$netrc_log"

while IFS= read -r config_path || [ -n "$config_path" ]; do
	[ ! -e "$config_path" ] || {
		echo "temporary rclone config was not removed: $config_path" >&2
		exit 1
	}
done < "$config_log"

assert_sidecar_rename_failure_cleans_tmp() {
	WRTBAK_ROOT="$fixture_root"
	WRTBAK_LIBDIR="$libdir"
	. "$libdir/common.sh"
	. "$libdir/remote.sh"

	sidecar_test_dir="$work_dir/sidecar-rename-failure"
	mkdir -p "$sidecar_test_dir"
	sidecar_local="$sidecar_test_dir/local.wrtbak"
	sidecar_path="$sidecar_test_dir/local.wrtbak.remote.json"
	sidecar_tmp="$sidecar_path.tmp.$$"
	printf '%s' "$sample_content" > "$sidecar_local"
	mkdir -p "$sidecar_path"
	mkdir -p "$sidecar_path/$(basename -- "$sidecar_tmp")"

	if wrtbak_remote_write_sidecar "$sidecar_path" "$sidecar_local" webdav curl "$webdav_sample" sample.wrtbak wrtbak "${#sample_content}" "Fri, 26 Jun 2026 03:30:00 GMT" "etag-1" 2>/dev/null; then
		echo "sidecar write should fail when rename target blocks mv" >&2
		exit 1
	fi
	if [ -e "$sidecar_tmp" ]; then
		echo "sidecar temp file was not removed after rename failure" >&2
		exit 1
	fi
}

assert_sidecar_rename_failure_cleans_tmp

echo "fixture remote download test passed"
