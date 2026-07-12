#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-manifest-identity-test.XXXXXX")
fixture_root="$work_dir/root"
output_dir="$work_dir/output"
bin_dir="$work_dir/bin"
libdir="$repo_dir/root/usr/lib/wrtbak"
cli="$repo_dir/root/usr/bin/wrtbak"
archive="$work_dir/sample.wrtbak"
no_identity_archive="$work_dir/no-identity.wrtbak"
rclone_log="$work_dir/rclone.log"

cleanup() {
	rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p \
	"$bin_dir" \
	"$fixture_root/tmp/sysinfo" \
	"$fixture_root/sys/class/net/br-lan" \
	"$fixture_root/etc/config" \
	"$output_dir"

cat >"$bin_dir/rclone" <<'EOT'
#!/bin/sh
printf '%s\n' "$*" >>"$WRTBAK_FAKE_RCLONE_LOG"
exit 55
EOT
chmod +x "$bin_dir/rclone"

cat >"$fixture_root/etc/config/wrtbak" <<EOT
config wrtbak 'main'
	option device_alias 'office-re-ss-01'
	option output_dir '$output_dir'
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
	option hostname 'office-router'
EOT

cat >"$fixture_root/etc/config/network" <<'EOT'
config interface 'lan'
	option proto 'static'
	option ipaddr '192.0.2.1'
EOT

printf 'JDCloud,RE-SS-01\n' >"$fixture_root/tmp/sysinfo/board_name"
printf '02:11:22:33:44:55\n' >"$fixture_root/sys/class/net/br-lan/address"

count_wrtbak_files() {
	find "$output_dir" "$work_dir" -type f -name '*.wrtbak' 2>/dev/null | wc -l | awk '{ print $1 }'
}

run_cli() {
	PATH="$bin_dir:$PATH" \
	WRTBAK_ROOT="$fixture_root" \
	WRTBAK_LIBDIR="$libdir" \
	WRTBAK_FAKE_RCLONE_LOG="$rclone_log" \
		"$cli" "$@"
}

run_cli create --profile office-re-ss-01 --items all --output "$archive" >"$work_dir/create.out"

tar xOzf "$archive" manifest.json >"$work_dir/manifest.json"
python3 - "$work_dir/manifest.json" <<'PY'
import hashlib
import json
import sys

path = sys.argv[1]
manifest = json.load(open(path, encoding="utf-8"))
device = manifest["device"]
expected_hash = hashlib.sha256(b"021122334455").hexdigest()[:10]
expected_uid = f"jdcloud-re-ss-01-{expected_hash}"

assert device["uid"] == expected_uid
assert device["uid_algorithm"] == "wrtbak-board-mac-sha256-10/v1"
assert device["uid_input"]["board_slug"] == "jdcloud-re-ss-01"
assert device["uid_input"]["mac_hash"] == expected_hash
assert device["uid_input"]["mac_source"] == "br-lan"
assert device["alias"] == "office-re-ss-01"
assert "02:11:22:33:44:55" not in json.dumps(device, sort_keys=True)
assert "021122334455" not in json.dumps(device, sort_keys=True)
PY

rm -f "$fixture_root/sys/class/net/br-lan/address"

if run_cli create --profile office-re-ss-01 --items all --output "$no_identity_archive" >"$work_dir/no-identity.out" 2>"$work_dir/no-identity.err"; then
	echo "create should fail when identity is unusable" >&2
	exit 1
fi
if [ -e "$no_identity_archive" ]; then
	echo "create wrote an archive with unusable identity" >&2
	exit 1
fi
grep -q 'identity_unusable' "$work_dir/no-identity.err"

before_count=$(count_wrtbak_files)
if run_cli remote-upload --target s3 --profile office-re-ss-01 --items all --format wrtbak --json >"$work_dir/upload.json" 2>"$work_dir/upload.err"; then
	echo "remote-upload should fail when identity is unusable" >&2
	exit 1
fi
after_count=$(count_wrtbak_files)
if [ "$before_count" != "$after_count" ]; then
	echo "remote-upload created an archive before rejecting unusable identity" >&2
	exit 1
fi
if [ -s "$rclone_log" ]; then
	echo "remote-upload attempted an upload before rejecting unusable identity" >&2
	exit 1
fi

python3 - "$work_dir/upload.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["ok"] is False
assert data["operation"] == "remote-upload"
assert data["code"] == "identity_unusable"
PY

echo "fixture manifest identity test passed"
