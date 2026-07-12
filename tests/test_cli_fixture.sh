#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-cli-test.XXXXXX")
fixture_root="$work_dir/root"
paths_file="$work_dir/paths.default"
archive="$work_dir/test.wrtbak"
sysupgrade="$work_dir/test.sysupgrade.tar.gz"
libdir="$repo_dir/root/usr/lib/wrtbak"
cli="$repo_dir/root/usr/bin/wrtbak"

cleanup() {
	rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p \
	"$fixture_root/tmp/sysinfo" \
	"$fixture_root/sys/class/net/br-lan" \
	"$fixture_root/etc/config" \
	"$fixture_root/etc/dropbear" \
	"$fixture_root/etc/nikki/nftables" \
	"$fixture_root/etc/nikki/profiles" \
	"$work_dir"

printf 'Fixture CLI Board\n' >"$fixture_root/tmp/sysinfo/board_name"
printf '02:11:22:33:44:55\n' >"$fixture_root/sys/class/net/br-lan/address"

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
placeholder-authorized-key-for-tests
EOT

cat >"$fixture_root/etc/nikki/nftables/geoip_cn.nft" <<'EOT'
table inet nikki_geoip {}
EOT

cat >"$fixture_root/etc/nikki/profiles/default.yaml" <<'EOT'
profile: placeholder
EOT

chmod 600 "$fixture_root/etc/config/system" "$fixture_root/etc/dropbear/authorized_keys"
chmod 644 "$fixture_root/etc/config/network"

cat >"$paths_file" <<'EOT'
/etc/config/system
/etc/config/network
/etc/dropbear/authorized_keys
/etc/nikki
/etc/config/not-present
EOT

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
WRTBAK_PATHS_FILE="$paths_file" \
	"$cli" info >"$work_dir/info.txt"
grep -q "luci-app-wrtbak" "$work_dir/info.txt"

WRTBAK_ROOT="$fixture_root" \
WRTBAK_LIBDIR="$libdir" \
WRTBAK_PATHS_FILE="$paths_file" \
	"$cli" create --profile fixture --output "$archive"

tar tzf "$archive" >"$work_dir/wrtbak.list"
grep -q '^manifest.json$' "$work_dir/wrtbak.list"
grep -q '^README.txt$' "$work_dir/wrtbak.list"
grep -q '^rootfs/etc/config/system$' "$work_dir/wrtbak.list"
grep -q '^rootfs/etc/config/network$' "$work_dir/wrtbak.list"
grep -q '^rootfs/etc/dropbear/authorized_keys$' "$work_dir/wrtbak.list"
grep -q '^rootfs/etc/nikki/nftables/geoip_cn.nft$' "$work_dir/wrtbak.list"
grep -q '^rootfs/etc/nikki/profiles/default.yaml$' "$work_dir/wrtbak.list"
if grep -q '^rootfs/etc/nikki/nftables/profiles' "$work_dir/wrtbak.list"; then
	echo "directory traversal reused a clobbered parent path" >&2
	exit 1
fi

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

WRTBAK_LIBDIR="$libdir" \
	"$cli" inspect "$archive" >"$work_dir/inspect.txt"
grep -q "manifest.json" "$work_dir/inspect.txt"

WRTBAK_LIBDIR="$libdir" \
	"$cli" export-sysupgrade --input "$archive" --output "$sysupgrade"

tar tzf "$sysupgrade" >"$work_dir/sysupgrade.list"
grep -q '^etc/backup/wrtbak-manifest.json$' "$work_dir/sysupgrade.list"
grep -q '^etc/config/system$' "$work_dir/sysupgrade.list"
if grep -q '^rootfs/' "$work_dir/sysupgrade.list"; then
	echo "sysupgrade archive must not contain rootfs/ entries" >&2
	exit 1
fi

tar xOzf "$sysupgrade" etc/backup/wrtbak-manifest.json | python3 -m json.tool >"$work_dir/sysupgrade-manifest.pretty.json"

python3 - "$work_dir" <<'PY'
import io
import json
import tarfile
import sys

work_dir = sys.argv[1]
manifest = json.dumps({
    "schema": "wrtbak/v1",
    "profile": "negative",
    "backup_id": "negative",
    "created_at": "2026-06-24T00:00:00Z",
    "tool_version": "0.1.0",
    "device": {},
    "firmware": {},
    "restore": {},
    "files": [],
}).encode()

def add_file(tar, name, data):
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = 0o600
    tar.addfile(info, io.BytesIO(data))

def add_dir(tar, name):
    info = tarfile.TarInfo(name)
    info.type = tarfile.DIRTYPE
    info.mode = 0o700
    tar.addfile(info)

def write_archive(path, entries):
    with tarfile.open(f"{work_dir}/{path}", "w:gz") as tar:
        for kind, name, data in entries:
            if kind == "file":
                add_file(tar, name, data)
            elif kind == "dir":
                add_dir(tar, name)
            elif kind == "symlink":
                info = tarfile.TarInfo(name)
                info.type = tarfile.SYMTYPE
                info.linkname = data
                tar.addfile(info)

write_archive("unsafe-dash.wrtbak", [
    ("file", "manifest.json", manifest),
    ("dir", "rootfs", None),
    ("file", "rootfs/-dash", b"bad"),
])
write_archive("symlink.wrtbak", [
    ("file", "manifest.json", manifest),
    ("dir", "rootfs", None),
    ("dir", "rootfs/etc", None),
    ("symlink", "rootfs/etc/link", "/etc/passwd"),
])
write_archive("missing-manifest.wrtbak", [
    ("dir", "rootfs", None),
    ("file", "rootfs/etc-config-system", b"data"),
])
write_archive("missing-rootfs.wrtbak", [
    ("file", "manifest.json", manifest),
])
PY

for bad_archive in unsafe-dash.wrtbak symlink.wrtbak missing-manifest.wrtbak missing-rootfs.wrtbak; do
	assert_reject env WRTBAK_LIBDIR="$libdir" "$cli" inspect "$work_dir/$bad_archive"
	assert_reject env WRTBAK_LIBDIR="$libdir" "$cli" export-sysupgrade --input "$work_dir/$bad_archive" --output "$work_dir/$bad_archive.sysupgrade.tar.gz"
done

bad_profile=$(printf 'bad\001profile')
assert_reject env \
	WRTBAK_ROOT="$fixture_root" \
	WRTBAK_LIBDIR="$libdir" \
	WRTBAK_PATHS_FILE="$paths_file" \
	"$cli" create --profile "$bad_profile" --output "$work_dir/control-char.wrtbak"

echo "fixture CLI archive test passed"
