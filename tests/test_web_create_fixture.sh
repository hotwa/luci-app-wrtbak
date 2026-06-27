#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-web-test.XXXXXX")
fixture_root="$work_dir/root"
output_dir="$work_dir/output"
libdir="$repo_dir/root/usr/lib/wrtbak"
cli="$repo_dir/root/usr/bin/wrtbak"

cleanup() {
	rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$fixture_root/etc/config" "$fixture_root/tmp/sysinfo" "$fixture_root/sys/class/net/br-lan" "$output_dir"

cat >"$fixture_root/etc/config/wrtbak" <<EOT
config wrtbak 'main'
	option output_dir '$output_dir'
	option default_mode 'review-required'
EOT

cat >"$fixture_root/etc/config/system" <<'EOT'
config system
	option hostname 'web-router'
EOT
printf 'Web Create Board\n' >"$fixture_root/tmp/sysinfo/board_name"
printf '02:11:22:33:44:55\n' >"$fixture_root/sys/class/net/br-lan/address"

assert_reject() {
	if "$@" >"$work_dir/reject.out" 2>"$work_dir/reject.err"; then
		echo "expected command to fail: $*" >&2
		cat "$work_dir/reject.out" >&2
		cat "$work_dir/reject.err" >&2
		exit 1
	fi
}

WRTBAK_ROOT="$fixture_root" \
WRTBAK_LIBDIR="$libdir" \
	"$cli" create-download --profile web-test --items core-system --format wrtbak >"$work_dir/wrtbak.json"

python3 - "$work_dir/wrtbak.json" "$output_dir" <<'PY'
import json
import os
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

output_dir = sys.argv[2]
expected_dir = os.path.join(output_dir, "downloads")
assert data["format"] == "wrtbak"
assert data["filename"].startswith("web-test-")
assert data["filename"].endswith(".wrtbak")
assert data["path"].startswith(expected_dir + os.sep)
assert data["path"] == os.path.join(expected_dir, data["filename"])
assert data["path"].endswith(".wrtbak") or data["path"].endswith(".sysupgrade.tar.gz")
assert data["size"] > 0
assert os.path.isfile(data["path"])
PY

wrtbak_path=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["path"])' "$work_dir/wrtbak.json")
tar tzf "$wrtbak_path" >"$work_dir/wrtbak.list"
grep -q '^rootfs/etc/config/system$' "$work_dir/wrtbak.list"

WRTBAK_ROOT="$fixture_root" \
WRTBAK_LIBDIR="$libdir" \
	"$cli" create-download --profile web-test --items core-system --format sysupgrade >"$work_dir/sysupgrade.json"

python3 - "$work_dir/sysupgrade.json" "$output_dir" <<'PY'
import json
import os
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

output_dir = sys.argv[2]
expected_dir = os.path.join(output_dir, "downloads")
assert data["format"] == "sysupgrade"
assert data["filename"].endswith(".sysupgrade.tar.gz")
assert data["path"].startswith(expected_dir + os.sep)
assert data["path"] == os.path.join(expected_dir, data["filename"])
assert data["path"].endswith(".wrtbak") or data["path"].endswith(".sysupgrade.tar.gz")
assert data["size"] > 0
assert os.path.isfile(data["path"])
PY

sysupgrade_path=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["path"])' "$work_dir/sysupgrade.json")
tar tzf "$sysupgrade_path" >"$work_dir/sysupgrade.list"
grep -q '^etc/config/system$' "$work_dir/sysupgrade.list"
grep -q '^etc/backup/wrtbak-manifest.json$' "$work_dir/sysupgrade.list"

assert_reject env WRTBAK_ROOT="$fixture_root" WRTBAK_LIBDIR="$libdir" \
	"$cli" create-download --profile '../bad' --items core-system --format wrtbak

assert_reject env WRTBAK_ROOT="$fixture_root" WRTBAK_LIBDIR="$libdir" \
	"$cli" create-download --profile web-test --items 'core-system;/bin/sh' --format wrtbak

echo "fixture LuCI download command test passed"
