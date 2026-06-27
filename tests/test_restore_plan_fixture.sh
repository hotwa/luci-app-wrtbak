#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-restore-plan-test.XXXXXX")
source_root="$work_dir/source-root"
target_root="$work_dir/target-root"
unusable_root="$work_dir/unusable-root"
bin_dir="$work_dir/bin"
paths_file="$work_dir/paths.default"
archive="$work_dir/restore-fixture.wrtbak"
uid_mismatch_archive="$work_dir/uid-mismatch.wrtbak"
legacy_archive="$work_dir/legacy-no-uid.wrtbak"
missing_algorithm_archive="$work_dir/missing-algorithm.wrtbak"
unsupported_algorithm_archive="$work_dir/unsupported-algorithm.wrtbak"
account_archive="$work_dir/account-files.wrtbak"
libdir="$repo_dir/root/usr/lib/wrtbak"
cli="$repo_dir/root/usr/bin/wrtbak"

cleanup() {
	rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p \
	"$source_root/etc/config" \
	"$source_root/tmp/sysinfo" \
	"$source_root/sys/class/net/br-lan" \
	"$target_root/etc/config" \
	"$target_root/tmp/sysinfo" \
	"$target_root/sys/class/net/br-lan" \
	"$unusable_root/etc/config" \
	"$bin_dir"

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
cat >"$target_root/etc/config/system" <<'EOT'
config system
	option hostname 'target-router'
EOT
printf 'Restore Plan Board\n' >"$target_root/tmp/sysinfo/board_name"
printf '02:11:22:33:44:55\n' >"$target_root/sys/class/net/br-lan/address"

cat >"$unusable_root/etc/config/system" <<'EOT'
config system
	option hostname 'unusable-router'
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

python3 - "$archive" "$uid_mismatch_archive" "$legacy_archive" "$missing_algorithm_archive" "$unsupported_algorithm_archive" "$account_archive" <<'PY'
import hashlib
import io
import json
import tarfile
import time
import sys

source, uid_mismatch, legacy, missing_algorithm, unsupported_algorithm, account_archive = sys.argv[1:]

def read_archive(path):
    entries = []
    with tarfile.open(path, "r:gz") as archive:
        for member in archive.getmembers():
            data = archive.extractfile(member).read() if member.isfile() else None
            entries.append((member, data))
    return entries

def clone_info(old):
    info = tarfile.TarInfo(old.name)
    info.mtime = int(time.time())
    info.mode = old.mode
    info.type = old.type
    info.linkname = old.linkname
    info.devmajor = old.devmajor
    info.devminor = old.devminor
    return info

def write_archive(path, entries):
    with tarfile.open(path, "w:gz") as archive:
        for old, data in entries:
            info = clone_info(old)
            if old.isfile():
                payload = data or b""
                info.size = len(payload)
                archive.addfile(info, io.BytesIO(payload))
            else:
                archive.addfile(info)

def mutate_manifest(dest, mutate):
    mutated = []
    for member, data in read_archive(source):
        if member.name == "manifest.json":
            manifest = json.loads(data.decode())
            mutate(manifest)
            data = json.dumps(manifest, indent=2).encode()
        mutated.append((member, data))
    write_archive(dest, mutated)

def remove_uid(manifest):
    manifest.setdefault("device", {}).pop("uid", None)

def remove_algorithm(manifest):
    manifest.setdefault("device", {}).pop("uid_algorithm", None)

def set_unsupported_algorithm(manifest):
    manifest.setdefault("device", {})["uid_algorithm"] = "future-uid-algorithm/v99"

def set_uid_mismatch(manifest):
    device = manifest.setdefault("device", {})
    device["uid"] = "different-device-uid"
    device["alias"] = "target-router"

mutate_manifest(uid_mismatch, set_uid_mismatch)
mutate_manifest(legacy, remove_uid)
mutate_manifest(missing_algorithm, remove_algorithm)
mutate_manifest(unsupported_algorithm, set_unsupported_algorithm)

account_payloads = {
    "/etc/passwd": b"root:x:0:0:archive root:/root:/bin/ash\n",
    "/etc/shadow": b"root:$1$archive:19000:0:99999:7:::\n",
    "/etc/group": b"root:x:0:\n",
    "/etc/gshadow": b"root:*::\n",
}
entries = []
for member, data in read_archive(source):
    if member.name == "manifest.json":
        manifest = json.loads(data.decode())
        files = manifest.setdefault("files", [])
        for path, payload in account_payloads.items():
            archive_path = "rootfs" + path
            files.append({
                "path": path,
                "archive_path": archive_path,
                "type": "file",
                "mode": "0600",
                "size": len(payload),
                "sha256": hashlib.sha256(payload).hexdigest(),
            })
        data = json.dumps(manifest, indent=2).encode()
    entries.append((member, data))

with tarfile.open(account_archive, "w:gz") as archive:
    for old, data in entries:
        info = clone_info(old)
        if old.isfile():
            payload = data or b""
            info.size = len(payload)
            archive.addfile(info, io.BytesIO(payload))
        else:
            archive.addfile(info)
    for path, payload in account_payloads.items():
        info = tarfile.TarInfo("rootfs" + path)
        info.mode = 0o600
        info.mtime = int(time.time())
        info.size = len(payload)
        archive.addfile(info, io.BytesIO(payload))
PY

(cd "$target_root" && find . -print | sort) >"$work_dir/target-before.txt"

PATH="$bin_dir:$PATH" \
WRTBAK_ROOT="$target_root" \
WRTBAK_LIBDIR="$libdir" \
	"$cli" restore-plan --input "$archive" --json >"$work_dir/restore-plan.json"

(cd "$target_root" && find . -print | sort) >"$work_dir/target-after.txt"
cmp "$work_dir/target-before.txt" "$work_dir/target-after.txt"

python3 - "$work_dir/restore-plan.json" "$archive" <<'PY'
import hashlib
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

expected_uid = "restore-plan-board-" + hashlib.sha256(b"021122334455").hexdigest()[:10]
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
assert data["current_device_uid"] == expected_uid
assert data["manifest_device_uid"] == expected_uid
assert data["manifest_device_uid_algorithm"] == "wrtbak-board-mac-sha256-10/v1"
assert data["manifest_device_alias"] == "restore-plan-router"
assert data["identity_match"] is True
assert data["can_apply"] is True
assert data["reason"] == ""
assert data["skipped_files"] == []

paths = {entry["path"]: entry for entry in data["paths"]}
assert paths["/etc/config/system"]["type"] == "file"
assert paths["/etc/config/system"]["size"] > 0
assert paths["/etc/config/network"]["type"] == "file"
assert paths["/etc/config"]["type"] == "directory"
PY

for identity_case in \
	"$uid_mismatch_archive invalid_device_uid" \
	"$legacy_archive missing_device_uid" \
	"$missing_algorithm_archive missing_device_uid_algorithm" \
	"$unsupported_algorithm_archive unsupported_device_uid_algorithm"
do
	set -- $identity_case
	case_archive=$1
	expected_reason=$2
	PATH="$bin_dir:$PATH" \
	WRTBAK_ROOT="$target_root" \
	WRTBAK_LIBDIR="$libdir" \
		"$cli" restore-plan --input "$case_archive" --json >"$work_dir/identity-plan.json"
	python3 - "$work_dir/identity-plan.json" "$expected_reason" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

expected_reason = sys.argv[2]
assert data["can_apply"] is False, data
assert data["identity_match"] is False, data
assert data["reason"] == expected_reason, data
PY
done

PATH="$bin_dir:$PATH" \
WRTBAK_ROOT="$unusable_root" \
WRTBAK_LIBDIR="$libdir" \
	"$cli" restore-plan --input "$archive" --json >"$work_dir/unusable-plan.json"
python3 - "$work_dir/unusable-plan.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

assert data["current_device_uid"] == ""
assert data["manifest_device_uid"]
assert data["manifest_device_uid_algorithm"] == "wrtbak-board-mac-sha256-10/v1"
assert data["can_apply"] is False
assert data["identity_match"] is False
assert data["reason"] == "identity_unusable"
PY

PATH="$bin_dir:$PATH" \
WRTBAK_ROOT="$target_root" \
WRTBAK_LIBDIR="$libdir" \
	"$cli" restore-plan --input "$account_archive" --json >"$work_dir/account-plan.json"
python3 - "$work_dir/account-plan.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

paths = {entry["path"] for entry in data["paths"]}
skipped = {entry["path"]: entry["reason"] for entry in data["skipped_files"]}
for account_path in ("/etc/passwd", "/etc/shadow", "/etc/group", "/etc/gshadow"):
    assert account_path not in paths, data
    assert skipped[account_path] == "account_file_excluded", data
assert data["can_apply"] is True
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
