#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-restore-plan-test.XXXXXX")
source_root="$work_dir/source-root"
target_root="$work_dir/target-root"
bin_dir="$work_dir/bin"
paths_file="$work_dir/paths.default"
archive="$work_dir/restore-fixture.wrtbak"
libdir="$repo_dir/root/usr/lib/wrtbak"
cli="$repo_dir/root/usr/bin/wrtbak"

cleanup() {
	rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$source_root/etc/config" "$source_root/tmp/sysinfo" "$source_root/sys/class/net/br-lan" "$target_root/etc/config" "$bin_dir"

cat >"$bin_dir/jsonfilter" <<'EOT'
#!/bin/sh
input=
expr=

while [ "$#" -gt 0 ]; do
	case "$1" in
		-i)
			input=$2
			shift 2
			;;
		-e)
			expr=$2
			shift 2
			;;
		*)
			shift
			;;
	esac
done

python3 - "$input" "$expr" <<'PY'
import json
import sys

path, expr = sys.argv[1:]

try:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
except Exception:
    sys.exit(1)

if not expr.startswith("@."):
    sys.exit(1)

value = data
for part in expr[2:].split("."):
    try:
        if part.endswith("[*]"):
            value = value[part[:-3]]
            if not isinstance(value, list):
                sys.exit(1)
            for item in value:
                if isinstance(item, bool):
                    print("true" if item else "false")
                elif item is not None:
                    print(item)
            sys.exit(0)
        value = value[part]
    except Exception:
        sys.exit(1)

if isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, (str, int, float)):
    print(value)
elif value is None:
    pass
else:
    print(json.dumps(value, separators=(",", ":")))
PY
EOT
chmod +x "$bin_dir/jsonfilter"

cat >"$source_root/etc/config/system" <<'EOT'
config system
	option hostname 'restore-plan-router'
EOT

cat >"$source_root/etc/config/network" <<'EOT'
config interface 'lan'
	option proto 'static'
	option ipaddr '192.0.2.1'
EOT
printf 'Restore Plan Board\n' >"$source_root/tmp/sysinfo/board_name"
printf '02:11:22:33:44:55\n' >"$source_root/sys/class/net/br-lan/address"

cat >"$paths_file" <<'EOT'
/etc/config/system
/etc/config/network
EOT

cat >"$target_root/etc/config/marker" <<'EOT'
do not modify
EOT

assert_reject() {
	if "$@" >"$work_dir/reject.out" 2>"$work_dir/reject.err"; then
		echo "expected command to fail: $*" >&2
		cat "$work_dir/reject.out" >&2
		cat "$work_dir/reject.err" >&2
		exit 1
	fi
}

WRTBAK_ROOT="$source_root" \
WRTBAK_LIBDIR="$libdir" \
WRTBAK_PATHS_FILE="$paths_file" \
	"$cli" create --profile restore-plan --output "$archive" >/dev/null

(cd "$target_root" && find . -print | sort) >"$work_dir/target-before.txt"

PATH="$bin_dir:$PATH" \
WRTBAK_ROOT="$target_root" \
WRTBAK_LIBDIR="$libdir" \
	"$cli" restore-plan --input "$archive" --json >"$work_dir/restore-plan.json"

(cd "$target_root" && find . -print | sort) >"$work_dir/target-after.txt"
cmp "$work_dir/target-before.txt" "$work_dir/target-after.txt"

python3 - "$work_dir/restore-plan.json" "$archive" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

assert data["archive"] == sys.argv[2]
assert data["schema"] == "wrtbak/v1"
assert data["profile"] == "restore-plan"
assert data["backup_id"].startswith("restore-plan-")
assert data["created_at"].endswith("Z")
assert data["tool_version"] == "0.1.0"
assert data["file_count"] == 2
assert data["directory_count"] >= 2
assert data["total_file_bytes"] > 0
assert data["reboot_recommended"] is True
assert data["requires_confirmation"] is True
assert "network" in data["restart_services"]

paths = {entry["path"]: entry for entry in data["paths"]}
assert paths["/etc/config/system"]["type"] == "file"
assert paths["/etc/config/system"]["size"] > 0
assert paths["/etc/config/network"]["type"] == "file"
assert paths["/etc/config"]["type"] == "directory"
PY

python3 - "$work_dir" <<'PY'
import io
import json
import tarfile
import sys

work_dir = sys.argv[1]
manifest = json.dumps({
    "schema": "wrtbak/v1",
    "profile": "unsafe",
    "backup_id": "unsafe",
    "created_at": "2026-06-25T00:00:00Z",
    "tool_version": "0.1.0",
    "device": {},
    "firmware": {},
    "restore": {},
    "files": [],
}).encode()

with tarfile.open(f"{work_dir}/unsafe-restore.wrtbak", "w:gz") as tar:
    info = tarfile.TarInfo("manifest.json")
    info.size = len(manifest)
    tar.addfile(info, io.BytesIO(manifest))
    root = tarfile.TarInfo("rootfs")
    root.type = tarfile.DIRTYPE
    tar.addfile(root)
    link = tarfile.TarInfo("rootfs/etc-link")
    link.type = tarfile.SYMTYPE
    link.linkname = "/etc/passwd"
    tar.addfile(link)
PY

assert_reject env PATH="$bin_dir:$PATH" WRTBAK_ROOT="$target_root" WRTBAK_LIBDIR="$libdir" \
	"$cli" restore-plan --input "$work_dir/unsafe-restore.wrtbak" --json

python3 - "$work_dir" <<'PY'
import io
import json
import tarfile
import sys

work_dir = sys.argv[1]

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

def write_manifest_archive(path, manifest_bytes):
    with tarfile.open(f"{work_dir}/{path}", "w:gz") as tar:
        add_file(tar, "manifest.json", manifest_bytes)
        add_dir(tar, "rootfs")
        add_dir(tar, "rootfs/etc")
        add_file(tar, "rootfs/etc/config-test", b"placeholder")

write_manifest_archive("invalid-json.wrtbak", b"{ not-json")
write_manifest_archive("unsupported-schema.wrtbak", json.dumps({
    "schema": "wrtbak/v99",
    "profile": "bad-schema",
    "backup_id": "bad-schema",
    "created_at": "2026-06-25T00:00:00Z",
    "tool_version": "0.1.0",
    "restore": {
        "restart_services": [],
        "reboot_recommended": True,
        "requires_confirmation": True,
    },
}).encode())
write_manifest_archive("missing-restore.wrtbak", json.dumps({
    "schema": "wrtbak/v1",
    "profile": "missing-restore",
    "backup_id": "missing-restore",
    "created_at": "2026-06-25T00:00:00Z",
    "tool_version": "0.1.0",
}).encode())
write_manifest_archive("restore-keys-outside.wrtbak", json.dumps({
    "schema": "wrtbak/v1",
    "profile": "restore-keys-outside",
    "backup_id": "restore-keys-outside",
    "created_at": "2026-06-25T00:00:00Z",
    "tool_version": "0.1.0",
    "restart_services": ["network"],
    "reboot_recommended": True,
    "requires_confirmation": True,
    "restore": {},
}).encode())
PY

for bad_manifest_archive in invalid-json.wrtbak unsupported-schema.wrtbak missing-restore.wrtbak restore-keys-outside.wrtbak; do
	assert_reject env PATH="$bin_dir:$PATH" WRTBAK_ROOT="$target_root" WRTBAK_LIBDIR="$libdir" \
		"$cli" restore-plan --input "$work_dir/$bad_manifest_archive" --json
done

echo "fixture restore plan test passed"
