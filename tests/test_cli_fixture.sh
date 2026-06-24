#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir="$repo_dir/.tmp/wrtbak-cli-test"
fixture_root="$work_dir/root"
paths_file="$work_dir/paths.default"
archive="$work_dir/test.wrtbak"
sysupgrade="$work_dir/test.sysupgrade.tar.gz"

rm -rf "$work_dir"
mkdir -p \
	"$fixture_root/etc/config" \
	"$fixture_root/etc/dropbear" \
	"$work_dir"

cat >"$fixture_root/etc/config/system" <<'EOT'
config system
	option hostname 'fixture-router'
EOT

cat >"$fixture_root/etc/config/network" <<'EOT'
config interface 'lan'
	option device 'br-lan'
	option proto 'static'
	option ipaddr '192.0.2.1'
EOT

cat >"$fixture_root/etc/dropbear/authorized_keys" <<'EOT'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureOnlyForTests wrtbak-test
EOT

chmod 600 "$fixture_root/etc/config/system" "$fixture_root/etc/dropbear/authorized_keys"
chmod 644 "$fixture_root/etc/config/network"

cat >"$paths_file" <<'EOT'
/etc/config/system
/etc/config/network
/etc/dropbear/authorized_keys
/etc/config/not-present
EOT

WRTBAK_ROOT="$fixture_root" \
WRTBAK_LIBDIR="$repo_dir/root/usr/lib/wrtbak" \
WRTBAK_PATHS_FILE="$paths_file" \
	"$repo_dir/root/usr/bin/wrtbak" info >"$work_dir/info.txt"
grep -q "luci-app-wrtbak" "$work_dir/info.txt"

WRTBAK_ROOT="$fixture_root" \
WRTBAK_LIBDIR="$repo_dir/root/usr/lib/wrtbak" \
WRTBAK_PATHS_FILE="$paths_file" \
	"$repo_dir/root/usr/bin/wrtbak" create --profile fixture --output "$archive"

tar tzf "$archive" >"$work_dir/wrtbak.list"
grep -q '^manifest.json$' "$work_dir/wrtbak.list"
grep -q '^README.txt$' "$work_dir/wrtbak.list"
grep -q '^rootfs/etc/config/system$' "$work_dir/wrtbak.list"
grep -q '^rootfs/etc/config/network$' "$work_dir/wrtbak.list"
grep -q '^rootfs/etc/dropbear/authorized_keys$' "$work_dir/wrtbak.list"

tar xOzf "$archive" manifest.json | python3 -m json.tool >"$work_dir/manifest.pretty.json"

python3 - "$archive" "$fixture_root" <<'PY'
import hashlib
import json
import tarfile
import sys

archive, fixture_root = sys.argv[1:]
with tarfile.open(archive, "r:gz") as tar:
    manifest = json.load(tar.extractfile("manifest.json"))

assert manifest["schema"] == "wrtbak/v1"
assert manifest["profile"] == "fixture"
assert manifest["restore"]["default_mode"] == "review-required"

files = {entry["path"]: entry for entry in manifest["files"]}
system = files["/etc/config/system"]
assert system["archive_path"] == "rootfs/etc/config/system"
assert system["type"] == "file"
assert system["mode"] == "0600"
with open(f"{fixture_root}/etc/config/system", "rb") as handle:
    data = handle.read()
assert system["size"] == len(data)
assert system["sha256"] == hashlib.sha256(data).hexdigest()

network = files["/etc/config/network"]
assert network["mode"] == "0644"
assert network["type"] == "file"
PY

WRTBAK_LIBDIR="$repo_dir/root/usr/lib/wrtbak" \
	"$repo_dir/root/usr/bin/wrtbak" inspect "$archive" >"$work_dir/inspect.txt"
grep -q "manifest.json" "$work_dir/inspect.txt"

WRTBAK_LIBDIR="$repo_dir/root/usr/lib/wrtbak" \
	"$repo_dir/root/usr/bin/wrtbak" export-sysupgrade --input "$archive" --output "$sysupgrade"

tar tzf "$sysupgrade" >"$work_dir/sysupgrade.list"
grep -q '^etc/backup/wrtbak-manifest.json$' "$work_dir/sysupgrade.list"
grep -q '^etc/config/system$' "$work_dir/sysupgrade.list"
if grep -q '^rootfs/' "$work_dir/sysupgrade.list"; then
	echo "sysupgrade archive must not contain rootfs/ entries" >&2
	exit 1
fi

tar xOzf "$sysupgrade" etc/backup/wrtbak-manifest.json | python3 -m json.tool >"$work_dir/sysupgrade-manifest.pretty.json"

echo "fixture CLI archive test passed"
