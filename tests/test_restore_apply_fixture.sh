#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-restore-apply-test.XXXXXX")
source_root="$work_dir/source-root"
fixture_root="$work_dir/fixture-root"
unusable_root="$work_dir/unusable-root"
bin_dir="$work_dir/bin"
paths_file="$work_dir/paths.default"
source_archive="$work_dir/source.wrtbak"
source_sysupgrade="$work_dir/source.sysupgrade.tar.gz"
cache_archive="/tmp/wrtbak/restore-cache/sample.wrtbak"
cache_sysupgrade="/tmp/wrtbak/restore-cache/sample.sysupgrade.tar.gz"
cache_service_archive="/tmp/wrtbak/restore-cache/service-sample.wrtbak"
cache_mismatch_archive="/tmp/wrtbak/restore-cache/mismatch.wrtbak"
cache_failure_archive="/tmp/wrtbak/restore-cache/write-failure.wrtbak"
cache_unlisted_archive="/tmp/wrtbak/restore-cache/unlisted.wrtbak"
cache_nested_files_archive="/tmp/wrtbak/restore-cache/nested-files.wrtbak"
cache_implicit_dir_archive="/tmp/wrtbak/restore-cache/implicit-dir.wrtbak"
cache_prefix_archive="/tmp/wrtbak/restore-cache/file-prefix.wrtbak"
cache_compact_archive="/tmp/wrtbak/restore-cache/compact.wrtbak"
cache_bad_service_archive="/tmp/wrtbak/restore-cache/bad-service.wrtbak"
cache_unsafe_sysupgrade="/tmp/wrtbak/restore-cache/unsafe.sysupgrade.tar.gz"
cache_identity_mismatch_archive="/tmp/wrtbak/restore-cache/identity-mismatch.wrtbak"
cache_legacy_archive="/tmp/wrtbak/restore-cache/legacy-no-uid.wrtbak"
cache_missing_algorithm_archive="/tmp/wrtbak/restore-cache/missing-algorithm.wrtbak"
cache_unsupported_algorithm_archive="/tmp/wrtbak/restore-cache/unsupported-algorithm.wrtbak"
cache_account_archive="/tmp/wrtbak/restore-cache/account-files.wrtbak"
cache_unsupported_schema_archive="/tmp/wrtbak/restore-cache/unsupported-schema.wrtbak"
cache_unsafe_absolute_archive="/tmp/wrtbak/restore-cache/unsafe-absolute.wrtbak"
cache_unsafe_dotdot_archive="/tmp/wrtbak/restore-cache/unsafe-dotdot.wrtbak"
cache_unsafe_symlink_archive="/tmp/wrtbak/restore-cache/unsafe-symlink.wrtbak"
cache_unsafe_hardlink_archive="/tmp/wrtbak/restore-cache/unsafe-hardlink.wrtbak"
cache_unsafe_chardev_archive="/tmp/wrtbak/restore-cache/unsafe-chardev.wrtbak"
cache_unsafe_blockdev_archive="/tmp/wrtbak/restore-cache/unsafe-blockdev.wrtbak"
cache_unsafe_fifo_archive="/tmp/wrtbak/restore-cache/unsafe-fifo.wrtbak"
cache_unsafe_socket_archive="/tmp/wrtbak/restore-cache/unsafe-socket.wrtbak"
libdir="$repo_dir/root/usr/lib/wrtbak"
cli="$repo_dir/root/usr/bin/wrtbak"

cleanup() {
	if [ "${WRTBAK_KEEP_TEST_WORKDIR:-0}" = "1" ]; then
		printf '%s\n' "$work_dir" >&2
		return 0
	fi
	rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p \
	"$source_root/etc/config" \
	"$source_root/etc" \
	"$source_root/tmp/sysinfo" \
	"$source_root/sys/class/net/br-lan" \
	"$fixture_root/etc/config" \
	"$fixture_root/etc/init.d" \
	"$fixture_root/etc" \
	"$fixture_root/tmp/sysinfo" \
	"$fixture_root/sys/class/net/br-lan" \
	"$fixture_root/tmp/wrtbak/restore-cache" \
	"$fixture_root/tmp/wrtbak/downloads" \
	"$unusable_root/etc/config" \
	"$unusable_root/tmp/wrtbak/restore-cache" \
	"$unusable_root/tmp/wrtbak/pre-restore" \
	"$bin_dir"

cat >"$fixture_root/etc/init.d/dnsmasq" <<'EOT'
#!/bin/sh
[ "$1" = "restart" ] || exit 2
printf 'dnsmasq restarted\n' >> "${WRTBAK_ROOT%/}/tmp/wrtbak/dnsmasq-restart.log"
exit 0
EOT
chmod +x "$fixture_root/etc/init.d/dnsmasq"

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
            remaining = expr[2:].split(".")
            tail = remaining[remaining.index(part) + 1:]
            for item in value:
                current = item
                for child in tail:
                    current = current[child]
                if isinstance(current, bool):
                    print("true" if current else "false")
                elif current is not None:
                    print(current)
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

cat >"$bin_dir/sysupgrade" <<'EOT'
#!/bin/sh
printf '%s\n' "$*" > "${WRTBAK_SYSUPGRADE_LOG:-/tmp/wrtbak-sysupgrade.log}"
exit "${WRTBAK_SYSUPGRADE_EXIT:-0}"
EOT
chmod +x "$bin_dir/sysupgrade"

cat >"$source_root/etc/config/system" <<'EOT'
config system
	option hostname 'source-router'
EOT

cat >"$source_root/etc/config/network" <<'EOT'
config interface 'lan'
	option proto 'static'
	option ipaddr '192.0.2.10'
EOT

cat >"$source_root/etc/board.json" <<'EOT'
{
  "model": {
    "id": "source-board-id",
    "name": "Source Board"
  }
}
EOT
printf 'source-machine-id' >"$source_root/etc/machine-id"
printf 'Source Board\n' >"$source_root/tmp/sysinfo/board_name"
printf '02:11:22:33:44:55\n' >"$source_root/sys/class/net/br-lan/address"

cat >"$fixture_root/etc/config/wrtbak" <<'EOT'
config wrtbak 'main'
	option output_dir '/tmp/wrtbak'
EOT

cat >"$fixture_root/etc/config/system" <<'EOT'
config system
	option hostname 'target-router'
EOT

cat >"$unusable_root/etc/config/wrtbak" <<'EOT'
config wrtbak 'main'
	option device_id 'unusable-test-device'
EOT
cat >"$unusable_root/etc/config/system" <<'EOT'
config system
	option hostname 'unusable-router'
EOT

cat >"$fixture_root/etc/board.json" <<'EOT'
{
  "model": {
    "id": "target-board-id",
    "name": "Target Board"
  }
}
EOT
printf 'target-machine-id' >"$fixture_root/etc/machine-id"
printf 'Source Board\n' >"$fixture_root/tmp/sysinfo/board_name"
printf '02:11:22:33:44:55\n' >"$fixture_root/sys/class/net/br-lan/address"

cat >"$paths_file" <<'EOT'
/etc/config/system
/etc/config/network
EOT

run_cli() {
	PATH="$bin_dir:$PATH" \
	WRTBAK_ROOT="$fixture_root" \
	WRTBAK_LIBDIR="$libdir" \
	WRTBAK_SYSUPGRADE_EXIT="${WRTBAK_SYSUPGRADE_EXIT:-}" \
	WRTBAK_SYSUPGRADE_LOG="${WRTBAK_SYSUPGRADE_LOG:-}" \
		"$cli" "$@"
}

run_cli_unusable() {
	PATH="$bin_dir:$PATH" \
	WRTBAK_ROOT="$unusable_root" \
	WRTBAK_LIBDIR="$libdir" \
		"$cli" "$@"
}

assert_reject_code() {
	expected_code=$1
	shift
	output_file="$work_dir/reject.json"
	err_file="$work_dir/reject.err"

	if run_cli "$@" >"$output_file" 2>"$err_file"; then
		echo "expected command to fail: $*" >&2
		cat "$output_file" >&2
		cat "$err_file" >&2
		exit 1
	fi

	assert_json_code "$output_file" "$expected_code"
}

assert_reject_code_unusable() {
	expected_code=$1
	shift
	output_file="$work_dir/reject-unusable.json"
	err_file="$work_dir/reject-unusable.err"

	if run_cli_unusable "$@" >"$output_file" 2>"$err_file"; then
		echo "expected command to fail: $*" >&2
		cat "$output_file" >&2
		cat "$err_file" >&2
		exit 1
	fi

	assert_json_code "$output_file" "$expected_code"
}

assert_json_code() {
	output_file=$1
	expected_code=$2
	python3 - "$output_file" "$expected_code" <<'PY'
import json
import sys

path, expected_code = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)

assert data["ok"] is False
assert data["code"] == expected_code, data
assert data["operation"].startswith("restore-")
PY
}

WRTBAK_ROOT="$source_root" \
WRTBAK_LIBDIR="$libdir" \
WRTBAK_PATHS_FILE="$paths_file" \
PATH="$bin_dir:$PATH" \
	"$cli" create --profile restore-apply-source --output "$source_archive" >/dev/null

WRTBAK_ROOT="$source_root" \
WRTBAK_LIBDIR="$libdir" \
PATH="$bin_dir:$PATH" \
	"$cli" export-sysupgrade --input "$source_archive" --output "$source_sysupgrade" >/dev/null

cp "$source_archive" "$fixture_root$cache_archive"
cp "$source_sysupgrade" "$fixture_root$cache_sysupgrade"

python3 - "$source_archive" "$fixture_root$cache_service_archive" "$fixture_root$cache_mismatch_archive" "$fixture_root$cache_failure_archive" "$fixture_root$cache_unlisted_archive" "$fixture_root$cache_nested_files_archive" "$fixture_root$cache_implicit_dir_archive" "$fixture_root$cache_prefix_archive" "$fixture_root$cache_compact_archive" "$fixture_root$cache_bad_service_archive" "$fixture_root$cache_unsafe_sysupgrade" "$fixture_root$cache_identity_mismatch_archive" "$fixture_root$cache_legacy_archive" "$fixture_root$cache_missing_algorithm_archive" "$fixture_root$cache_unsupported_algorithm_archive" "$fixture_root$cache_account_archive" "$fixture_root$cache_unsupported_schema_archive" "$fixture_root$cache_unsafe_absolute_archive" "$fixture_root$cache_unsafe_dotdot_archive" "$fixture_root$cache_unsafe_symlink_archive" "$fixture_root$cache_unsafe_hardlink_archive" "$fixture_root$cache_unsafe_chardev_archive" "$fixture_root$cache_unsafe_blockdev_archive" "$fixture_root$cache_unsafe_fifo_archive" "$fixture_root$cache_unsafe_socket_archive" <<'PY'
import hashlib
import io
import json
import os
import tarfile
import time
import sys

(
    source,
    service_archive,
    mismatch_archive,
    failure_archive,
    unlisted_archive,
    nested_files_archive,
    implicit_dir_archive,
    prefix_archive,
    compact_archive,
    bad_service_archive,
    unsafe_sysupgrade,
    identity_mismatch_archive,
    legacy_archive,
    missing_algorithm_archive,
    unsupported_algorithm_archive,
    account_archive,
    unsupported_schema_archive,
    unsafe_absolute_archive,
    unsafe_dotdot_archive,
    unsafe_symlink_archive,
    unsafe_hardlink_archive,
    unsafe_chardev_archive,
    unsafe_blockdev_archive,
    unsafe_fifo_archive,
    unsafe_socket_archive,
) = sys.argv[1:]

def read_archive(path):
    entries = []
    with tarfile.open(path, "r:gz") as archive:
        for member in archive.getmembers():
            data = archive.extractfile(member).read() if member.isfile() else None
            entries.append((member, data))
    return entries

def write_archive(path, entries):
    with tarfile.open(path, "w:gz") as archive:
        for old, data in entries:
            info = tarfile.TarInfo(old.name)
            info.mtime = int(time.time())
            info.mode = old.mode
            info.type = old.type
            if old.isdir():
                archive.addfile(info)
            else:
                payload = data or b""
                info.size = len(payload)
                archive.addfile(info, io.BytesIO(payload))

entries = read_archive(source)
source_manifest_data = None
for member, data in entries:
    if member.name == "manifest.json":
        source_manifest_data = json.loads(data.decode())
        break
assert source_manifest_data is not None
source_device_identity = dict(source_manifest_data.get("device", {}))

service_entries = []
for member, data in entries:
    if member.name == "manifest.json":
        manifest = json.loads(data.decode())
        manifest["restore"]["restart_services"] = ["network", "dnsmasq"]
        data = json.dumps(manifest, indent=2).encode()
    service_entries.append((member, data))
write_archive(service_archive, service_entries)

mismatch_entries = []
for member, data in entries:
    if member.name == "manifest.json":
        manifest = json.loads(data.decode())
        for item in manifest["files"]:
            if item.get("archive_path") == "rootfs/etc/config/system":
                item["sha256"] = "0" * 64
        data = json.dumps(manifest, indent=2).encode()
    mismatch_entries.append((member, data))
write_archive(mismatch_archive, mismatch_entries)

unlisted_entries = list(entries)
extra_info = tarfile.TarInfo("rootfs/etc/config/extra")
extra_info.mode = 0o644
extra_info.mtime = int(time.time())
extra_payload = b"not listed in manifest\n"
extra_info.size = len(extra_payload)
unlisted_entries.append((extra_info, extra_payload))
write_archive(unlisted_archive, unlisted_entries)

nested_entries = []
for member, data in entries:
    if member.name == "manifest.json":
        manifest = json.loads(data.decode())
        manifest.setdefault("device", {})["files"] = [
            {
                "path": "/etc/config/extra",
                "archive_path": "rootfs/etc/config/extra",
                "type": "file",
                "mode": "0644",
                "size": len(extra_payload),
                "sha256": hashlib.sha256(extra_payload).hexdigest(),
            }
        ]
        data = json.dumps(manifest, indent=2).encode()
    nested_entries.append((member, data))
nested_entries.append((extra_info, extra_payload))
write_archive(nested_files_archive, nested_entries)

compact_entries = []
for member, data in entries:
    if member.name == "manifest.json":
        manifest = json.loads(data.decode())
        data = json.dumps(manifest, separators=(",", ":")).encode()
    compact_entries.append((member, data))
write_archive(compact_archive, compact_entries)

def add_file(archive, name, payload, mode=0o644):
    info = tarfile.TarInfo(name)
    info.mode = mode
    info.size = len(payload)
    info.mtime = int(time.time())
    archive.addfile(info, io.BytesIO(payload))

def add_dir(archive, name, mode=0o755):
    info = tarfile.TarInfo(name)
    info.type = tarfile.DIRTYPE
    info.mode = mode
    info.mtime = int(time.time())
    archive.addfile(info)

system_payload = b"config system\n\toption hostname 'failure-source'\n"
blocked_payload = b"blocked\n"
files = [
    ("directory", "/etc", "rootfs/etc", "0755", None),
    ("directory", "/etc/config", "rootfs/etc/config", "0755", None),
    ("file", "/etc/config/system", "rootfs/etc/config/system", "0644", system_payload),
    ("directory", "/zzblocked", "rootfs/zzblocked", "0755", None),
    ("file", "/zzblocked/child", "rootfs/zzblocked/child", "0644", blocked_payload),
]
manifest_files = []
for kind, target, archive_path, mode, payload in files:
    row = {"path": target, "archive_path": archive_path, "type": kind, "mode": mode}
    if payload is not None:
        row["size"] = len(payload)
        row["sha256"] = hashlib.sha256(payload).hexdigest()
    manifest_files.append(row)
manifest = {
    "schema": "wrtbak/v1",
    "profile": "write-failure",
    "backup_id": "write-failure-1",
    "created_at": "2026-06-26T00:00:00Z",
    "tool_version": "0.1.0",
    "device": dict(source_device_identity, hostname="fixture", board_model="fixture"),
    "firmware": {"distribution": "OpenWrt", "version": "test"},
    "restore": {
        "default_mode": "review-required",
        "restart_services": ["dnsmasq"],
        "reboot_recommended": False,
        "requires_confirmation": True,
    },
    "files": manifest_files,
}
with tarfile.open(failure_archive, "w:gz") as archive:
    add_file(archive, "manifest.json", json.dumps(manifest, indent=2).encode())
    add_file(archive, "README.txt", b"failure fixture\n")
    add_dir(archive, "rootfs")
    add_dir(archive, "rootfs/etc")
    add_dir(archive, "rootfs/etc/config")
    add_file(archive, "rootfs/etc/config/system", system_payload)
    add_dir(archive, "rootfs/zzblocked")
    add_file(archive, "rootfs/zzblocked/child", blocked_payload)

implicit_payload = b"implicit directory child\n"
implicit_manifest = dict(manifest)
implicit_manifest["profile"] = "implicit-dir"
implicit_manifest["backup_id"] = "implicit-dir-1"
implicit_manifest["files"] = [
    {
        "path": "/etc/config/unlisted_dir/child",
        "archive_path": "rootfs/etc/config/unlisted_dir/child",
        "type": "file",
        "mode": "0644",
        "size": len(implicit_payload),
        "sha256": hashlib.sha256(implicit_payload).hexdigest(),
    }
]
with tarfile.open(implicit_dir_archive, "w:gz") as archive:
    add_file(archive, "manifest.json", json.dumps(implicit_manifest, indent=2).encode())
    add_file(archive, "README.txt", b"implicit directory fixture\n")
    add_dir(archive, "rootfs")
    add_dir(archive, "rootfs/etc")
    add_dir(archive, "rootfs/etc/config")
    add_dir(archive, "rootfs/etc/config/unlisted_dir", mode=0o777)
    add_file(archive, "rootfs/etc/config/unlisted_dir/child", implicit_payload)

prefix_payload = b"should not restore via core-system\n"
prefix_files = [
    ("directory", "/etc", "rootfs/etc", "0755", None),
    ("directory", "/etc/config", "rootfs/etc/config", "0755", None),
    ("directory", "/etc/config/system", "rootfs/etc/config/system", "0755", None),
    ("file", "/etc/config/system/child", "rootfs/etc/config/system/child", "0644", prefix_payload),
]
prefix_manifest_files = []
for kind, target, archive_path, mode, payload in prefix_files:
    row = {"path": target, "archive_path": archive_path, "type": kind, "mode": mode}
    if payload is not None:
        row["size"] = len(payload)
        row["sha256"] = hashlib.sha256(payload).hexdigest()
    prefix_manifest_files.append(row)
prefix_manifest = dict(manifest)
prefix_manifest["profile"] = "file-prefix-spoof"
prefix_manifest["backup_id"] = "file-prefix-spoof-1"
prefix_manifest["files"] = prefix_manifest_files
with tarfile.open(prefix_archive, "w:gz") as archive:
    add_file(archive, "manifest.json", json.dumps(prefix_manifest, separators=(",", ":")).encode())
    add_file(archive, "README.txt", b"file prefix spoof fixture\n")
    add_dir(archive, "rootfs")
    add_dir(archive, "rootfs/etc")
    add_dir(archive, "rootfs/etc/config")
    add_dir(archive, "rootfs/etc/config/system")
    add_file(archive, "rootfs/etc/config/system/child", prefix_payload)

bad_service_payload = b"#!/bin/sh\nprintf 'executed:%s\\n' \"$1\" > \"${WRTBAK_ROOT%/}/tmp/wrtbak/bad-service.marker\"\n"
bad_service_manifest = dict(manifest)
bad_service_manifest["profile"] = "bad-service"
bad_service_manifest["backup_id"] = "bad-service-1"
bad_service_manifest["restore"] = dict(manifest["restore"])
bad_service_manifest["restore"]["restart_services"] = ["../../tmp/pwnsvc"]
bad_service_manifest["files"] = [
    {
        "path": "/tmp/pwnsvc",
        "archive_path": "rootfs/tmp/pwnsvc",
        "type": "file",
        "mode": "0755",
        "size": len(bad_service_payload),
        "sha256": hashlib.sha256(bad_service_payload).hexdigest(),
    }
]
with tarfile.open(bad_service_archive, "w:gz") as archive:
    add_file(archive, "manifest.json", json.dumps(bad_service_manifest, indent=2).encode())
    add_file(archive, "README.txt", b"bad service fixture\n")
    add_dir(archive, "rootfs")
    add_dir(archive, "rootfs/tmp")
    add_file(archive, "rootfs/tmp/pwnsvc", bad_service_payload, mode=0o755)

def mutate_manifest(dest, mutate):
    mutated = []
    for member, data in entries:
        if member.name == "manifest.json":
            manifest = json.loads(data.decode())
            mutate(manifest)
            data = json.dumps(manifest, indent=2).encode()
        mutated.append((member, data))
    write_archive(dest, mutated)

def set_identity_mismatch(manifest):
    device = manifest.setdefault("device", {})
    device["uid"] = "different-device-uid"
    device["alias"] = "target-router"

def remove_uid(manifest):
    manifest.setdefault("device", {}).pop("uid", None)

def remove_algorithm(manifest):
    manifest.setdefault("device", {}).pop("uid_algorithm", None)

def set_unsupported_algorithm(manifest):
    manifest.setdefault("device", {})["uid_algorithm"] = "future-uid-algorithm/v99"

def set_unsupported_schema(manifest):
    manifest["schema"] = "wrtbak/v99"

mutate_manifest(identity_mismatch_archive, set_identity_mismatch)
mutate_manifest(legacy_archive, remove_uid)
mutate_manifest(missing_algorithm_archive, remove_algorithm)
mutate_manifest(unsupported_algorithm_archive, set_unsupported_algorithm)
mutate_manifest(unsupported_schema_archive, set_unsupported_schema)

account_payloads = {
    "/etc/passwd": b"root:x:0:0:archive root:/root:/bin/ash\n",
    "/etc/shadow": b"root:$1$archive:19000:0:99999:7:::\n",
    "/etc/group": b"root:x:0:\n",
    "/etc/gshadow": b"root:*::\n",
}
account_entries = []
for member, data in entries:
    if member.name == "manifest.json":
        manifest = json.loads(data.decode())
        files = manifest.setdefault("files", [])
        for target, payload in account_payloads.items():
            archive_path = "rootfs" + target
            files.append({
                "path": target,
                "archive_path": archive_path,
                "type": "file",
                "mode": "0600",
                "size": len(payload),
                "sha256": hashlib.sha256(payload).hexdigest(),
            })
        data = json.dumps(manifest, indent=2).encode()
    account_entries.append((member, data))

with tarfile.open(account_archive, "w:gz") as archive:
    for old, data in account_entries:
        info = tarfile.TarInfo(old.name)
        info.mtime = int(time.time())
        info.mode = old.mode
        info.type = old.type
        if old.isdir():
            archive.addfile(info)
        else:
            payload = data or b""
            info.size = len(payload)
            archive.addfile(info, io.BytesIO(payload))
    for target, payload in account_payloads.items():
        add_file(archive, "rootfs" + target, payload, mode=0o600)

source_manifest = None
for member, data in entries:
    if member.name == "manifest.json":
        source_manifest = data
        break
assert source_manifest is not None

def write_unsafe_archive(path, member_name, member_type=None):
    with tarfile.open(path, "w:gz") as archive:
        add_file(archive, "manifest.json", source_manifest)
        add_file(archive, "README.txt", b"unsafe fixture\n")
        add_dir(archive, "rootfs")
        info = tarfile.TarInfo(member_name)
        info.mtime = int(time.time())
        info.mode = 0o644
        if member_type is None:
            payload = b"unsafe\n"
            info.size = len(payload)
            archive.addfile(info, io.BytesIO(payload))
            return
        info.type = member_type
        if member_type == tarfile.SYMTYPE:
            info.linkname = "/etc/passwd"
        elif member_type == tarfile.LNKTYPE:
            info.linkname = "rootfs/etc/config/system"
        elif member_type in (tarfile.CHRTYPE, tarfile.BLKTYPE):
            info.devmajor = 1
            info.devminor = 3
        archive.addfile(info)

write_unsafe_archive(unsafe_absolute_archive, "/absolute")
write_unsafe_archive(unsafe_dotdot_archive, "rootfs/../evil")
write_unsafe_archive(unsafe_symlink_archive, "rootfs/etc/config/unsafe-link", tarfile.SYMTYPE)
write_unsafe_archive(unsafe_hardlink_archive, "rootfs/etc/config/unsafe-hardlink", tarfile.LNKTYPE)
write_unsafe_archive(unsafe_chardev_archive, "rootfs/etc/config/unsafe-char", tarfile.CHRTYPE)
write_unsafe_archive(unsafe_blockdev_archive, "rootfs/etc/config/unsafe-block", tarfile.BLKTYPE)
write_unsafe_archive(unsafe_fifo_archive, "rootfs/etc/config/unsafe-fifo", tarfile.FIFOTYPE)
write_unsafe_archive(unsafe_socket_archive, "rootfs/etc/config/unsafe-socket", b"s")

with tarfile.open(unsafe_sysupgrade, "w:gz") as archive:
    add_file(archive, "../evil", b"unsafe\n")
PY

(cd "$fixture_root" && find . -print | sort) >"$work_dir/target-before.txt"
run_cli restore-prepare --input "$cache_archive" --json >"$work_dir/prepare-wrtbak.json"
run_cli restore-prepare --input "$cache_sysupgrade" --json >"$work_dir/prepare-sysupgrade.json"
(cd "$fixture_root" && find . -print | sort) >"$work_dir/target-after-prepare.txt"
cmp "$work_dir/target-before.txt" "$work_dir/target-after-prepare.txt"

python3 - "$work_dir/prepare-wrtbak.json" "$cache_archive" "restore-apply-source" <<'PY'
import json
import sys

path, cache_archive, source_profile = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)

assert data["ok"] is True
assert data["operation"] == "restore-prepare"
assert data["input"] == cache_archive
assert data["format"] == "wrtbak"
assert data["archive"]["filename"].endswith(".wrtbak")
assert data["archive"]["size"] > 0
assert len(data["archive"]["sha256"]) == 64
assert data["current_device"]["device_id"]
assert data["current_device"]["hostname"]
assert data["source_device"]["hostname"] == "source-router"
assert data["manifest"]["schema"] == "wrtbak/v1"
assert data["manifest"]["profile"] == source_profile
assert data["manifest"]["created_at"].endswith("Z")
assert data["compatibility"]["blocking"] is False
assert isinstance(data["compatibility"]["warnings"], list)
assert data["plan"]["file_count"] >= 1
assert data["plan"]["total_bytes"] > 0
assert isinstance(data["plan"]["restart_services"], list)
assert data["plan"]["reboot_recommended"] is True
assert data["plan"]["requires_confirmation"] is True
path_entry = data["plan"]["paths"][0]
assert path_entry["path"].startswith("/")
assert path_entry["archive_path"].startswith("rootfs/")
assert path_entry["type"] in ("file", "directory")
assert "size" in path_entry
assert "sha256" in path_entry
assert isinstance(path_entry["items"], list)
assert isinstance(path_entry["sensitive"], bool)
assert path_entry["selected"] is True
assert path_entry["action"] == "write"
assert any(entry["path"] == "/etc/config/system" and "core-system" in entry["items"] for entry in data["plan"]["paths"])
PY

python3 - "$work_dir/prepare-sysupgrade.json" "$cache_sysupgrade" <<'PY'
import json
import sys

path, sysupgrade_archive = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)

assert data["ok"] is True
assert data["operation"] == "restore-prepare"
assert data["input"] == sysupgrade_archive
assert data["format"] == "sysupgrade"
assert data["archive"]["filename"].endswith(".sysupgrade.tar.gz")
assert data["archive"]["size"] > 0
assert len(data["archive"]["sha256"]) == 64
assert data["manifest"]["present"] is True
assert data["manifest"]["schema"] == "wrtbak/v1"
assert data["manifest"]["path"] == "etc/backup/wrtbak-manifest.json"
assert data["compatibility"]["blocking"] is False
assert isinstance(data["compatibility"]["warnings"], list)
assert data["plan"]["file_count"] >= 1
assert data["plan"]["total_bytes"] > 0
assert isinstance(data["plan"]["restart_services"], list)
assert data["plan"]["reboot_recommended"] is True
assert data["plan"]["requires_confirmation"] is True
path_entry = data["plan"]["paths"][0]
assert path_entry["path"].startswith("/")
assert path_entry["archive_path"].startswith("etc/")
assert path_entry["type"] in ("file", "directory")
assert "size" in path_entry
assert "sha256" in path_entry
assert isinstance(path_entry["items"], list)
assert isinstance(path_entry["sensitive"], bool)
assert path_entry["selected"] is True
assert path_entry["action"] == "sysupgrade-restore"
PY

before_prebackup=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
run_cli restore-prebackup --profile pre-restore --items all --format wrtbak --json >"$work_dir/prebackup.json"
prebackup=$(python3 - "$work_dir/prebackup.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["path"])
PY
)

python3 - "$work_dir/prebackup.json" "$fixture_root" "$before_prebackup" <<'PY'
import datetime
import hashlib
import json
import os
import sys

path, fixture_root, before_prebackup = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)

def sha256_file(filename):
    digest = hashlib.sha256()
    with open(filename, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()

def parse_utc(value):
    return datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)

archive_path = fixture_root + data["path"]
receipt_path = fixture_root + data["receipt_path"]

assert data["ok"] is True
assert data["operation"] == "restore-prebackup"
assert data["profile"] == "pre-restore"
assert data["items"] == "all"
assert data["format"] == "wrtbak"
assert data["path"].startswith("/tmp/wrtbak/pre-restore-")
assert data["path"].endswith(".wrtbak")
assert data["filename"].startswith("pre-restore-")
assert data["size"] > 0
assert len(data["sha256"]) == 64
assert data["created_at"].endswith("Z")
assert data["receipt_path"].endswith(".receipt.json")
assert os.path.isfile(archive_path)
assert os.path.isfile(receipt_path)

with open(receipt_path, encoding="utf-8") as handle:
    receipt = json.load(handle)

assert receipt["operation"] == "restore-prebackup"
assert receipt["profile"] == data["profile"]
assert receipt["items"] == data["items"]
assert receipt["format"] == "wrtbak"
assert receipt["path"] == data["path"]
assert receipt["filename"] == data["filename"]
assert receipt["size"] == data["size"]
assert receipt["sha256"] == data["sha256"]
assert os.path.getsize(archive_path) == data["size"]
assert sha256_file(archive_path) == data["sha256"]
assert receipt["host_device_id"]
assert receipt["host_device_id"] == data["host_device_id"]
assert receipt["host_hostname"]
assert receipt["host_hostname"] == data["host_hostname"]
assert receipt["created_at"].endswith("Z")
assert parse_utc(receipt["created_at"]) >= parse_utc(before_prebackup) - datetime.timedelta(seconds=1)
assert receipt["format"] == "wrtbak"
PY

ln -s "$fixture_root$cache_archive" "$fixture_root/tmp/wrtbak/restore-cache/link.wrtbak"
mkdir -p "$fixture_root/tmp/wrtbak/restore-cache/directory.wrtbak"
cp "$source_archive" "$fixture_root/tmp/wrtbak/restore-cache/bad.txt"
cp "$source_archive" "$fixture_root/tmp/wrtbak/pre-restore-invalid-name.wrtbak"
mkdir -p "$work_dir/outside-downloads"
rm -rf "$fixture_root/tmp/wrtbak/downloads"
ln -s "$work_dir/outside-downloads" "$fixture_root/tmp/wrtbak/downloads"
cp "$source_archive" "$work_dir/outside-downloads/escaped.wrtbak"

assert_reject_code invalid_input_path restore-prepare --input relative.wrtbak --json
assert_reject_code invalid_input_path restore-prepare --input /tmp/wrtbak/restore-cache/../bad.wrtbak --json
assert_reject_code invalid_input_path restore-prepare --input /tmp/wrtbak/restore-cache/link.wrtbak --json
assert_reject_code invalid_input_path restore-prepare --input /tmp/wrtbak/downloads/escaped.wrtbak --json
assert_reject_code invalid_input_path restore-prepare --input "$prebackup" --json
assert_reject_code invalid_input_path restore-prepare --input /etc/config/system --json
assert_reject_code invalid_input_path restore-prepare --input /tmp/wrtbak/restore-cache/directory.wrtbak --json
assert_reject_code invalid_input_path restore-prepare --input /tmp/wrtbak/restore-cache/bad.txt --json
assert_reject_code invalid_prebackup restore-apply --input "$cache_archive" --mode all --items all --prebackup /etc/config/system --confirm RESTORE --json
assert_reject_code invalid_input_path restore-apply --input "$prebackup" --mode all --items all --prebackup "$prebackup" --confirm RESTORE --json
assert_reject_code invalid_input_path restore-apply --input "$cache_sysupgrade" --mode all --items all --prebackup "$prebackup" --confirm RESTORE --json
assert_reject_code invalid_input_path restore-sysupgrade --input "$cache_archive" --prebackup "$prebackup" --confirm RESTORE --json

fake_prebackup_bin="$work_dir/fake-prebackup-bin"
mkdir -p "$fake_prebackup_bin"
cat >"$fake_prebackup_bin/date" <<'EOT'
#!/bin/sh
if [ "${1:-}" = "-u" ]; then
	case "${2:-}" in
		+%Y-%m-%dT%H:%M:%SZ)
			printf '%s\n' "2030-01-02T03:04:05Z"
			exit 0
			;;
		+%Y%m%dT%H%M%SZ)
			printf '%s\n' "20300102T030405Z"
			exit 0
			;;
	esac
fi
exec /usr/bin/date "$@"
EOT
cat >"$fake_prebackup_bin/sha256sum" <<'EOT'
#!/bin/sh
case "${1:-}" in
	*/tmp/wrtbak/pre-restore-*.wrtbak)
		exit 99
		;;
esac
exec /usr/bin/sha256sum "$@"
EOT
chmod +x "$fake_prebackup_bin/date" "$fake_prebackup_bin/sha256sum"

if PATH="$fake_prebackup_bin:$PATH" run_cli restore-prebackup --profile pre-restore --items all --format wrtbak --json >"$work_dir/prebackup-hash-fail.json"; then
	echo "restore-prebackup should fail when archive hash fails" >&2
	exit 1
fi
assert_json_code "$work_dir/prebackup-hash-fail.json" prebackup_failed
if [ -e "$fixture_root/tmp/wrtbak/pre-restore-20300102T030405Z.wrtbak" ]; then
	echo "failed prebackup left an orphan archive" >&2
	exit 1
fi

bad_root="$work_dir/bad-root"
mkdir -p "$bad_root/tmp"
: > "$bad_root/tmp/wrtbak"
if PATH="$bin_dir:$PATH" WRTBAK_ROOT="$bad_root" WRTBAK_LIBDIR="$libdir" "$cli" restore-prebackup --profile pre-restore --items all --format wrtbak --json >"$work_dir/prebackup-mkdir-fail.json"; then
	echo "restore-prebackup should fail when prebackup directory cannot be created" >&2
	exit 1
fi
assert_json_code "$work_dir/prebackup-mkdir-fail.json" prebackup_failed

make_prebackup_variant() {
	variant_path=$1
	created_at=$2
	host_device_id=$3
	sha_mode=${4:-actual}
	cp "$fixture_root$prebackup" "$fixture_root$variant_path"
	python3 - "$fixture_root$variant_path" "$fixture_root$variant_path.receipt.json" "$variant_path" "$created_at" "$host_device_id" "$sha_mode" <<'PY'
import hashlib
import json
import os
import sys

archive, receipt_path, logical_path, created_at, host_device_id, sha_mode = sys.argv[1:]
with open(archive, "rb") as handle:
    digest = hashlib.sha256(handle.read()).hexdigest()
if sha_mode == "bad":
    digest = "1" * 64
receipt = {
    "operation": "restore-prebackup",
    "profile": "pre-restore",
    "items": "all",
    "format": "wrtbak",
    "path": logical_path,
    "filename": os.path.basename(logical_path),
    "size": os.path.getsize(archive),
    "sha256": digest,
    "created_at": created_at,
    "host_device_id": host_device_id,
    "host_hostname": "fixture",
}
with open(receipt_path, "w", encoding="utf-8") as handle:
    json.dump(receipt, handle)
PY
}

current_device=$(python3 - "$work_dir/prebackup.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["host_device_id"])
PY
)
make_prebackup_variant /tmp/wrtbak/pre-restore-stale.wrtbak 2000-01-01T00:00:00Z "$current_device"
make_prebackup_variant /tmp/wrtbak/pre-restore-unrelated.wrtbak "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" unrelated-device
make_prebackup_variant /tmp/wrtbak/pre-restore-badsha.wrtbak "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$current_device" bad

assert_reject_code missing_confirmation restore-apply --input "$cache_archive" --mode all --items all --prebackup "$prebackup" --confirm NOPE --json
assert_reject_code invalid_prebackup restore-apply --input "$cache_archive" --mode all --items all --prebackup /tmp/wrtbak/pre-restore-missing.wrtbak --confirm RESTORE --json
assert_reject_code invalid_prebackup restore-apply --input "$cache_archive" --mode all --items all --prebackup /tmp/wrtbak/pre-restore-stale.wrtbak --confirm RESTORE --json
assert_reject_code invalid_prebackup restore-apply --input "$cache_archive" --mode all --items all --prebackup /tmp/wrtbak/pre-restore-unrelated.wrtbak --confirm RESTORE --json
assert_reject_code invalid_prebackup restore-apply --input "$cache_archive" --mode all --items all --prebackup /tmp/wrtbak/pre-restore-badsha.wrtbak --confirm RESTORE --json
assert_reject_code missing_confirmation restore-sysupgrade --input "$cache_sysupgrade" --prebackup "$prebackup" --confirm NOPE --json
assert_reject_code invalid_prebackup restore-sysupgrade --input "$cache_sysupgrade" --prebackup /tmp/wrtbak/pre-restore-stale.wrtbak --confirm RESTORE --json
assert_reject_code invalid_prebackup restore-sysupgrade --input "$cache_sysupgrade" --prebackup /tmp/wrtbak/pre-restore-unrelated.wrtbak --confirm RESTORE --json
assert_reject_code invalid_prebackup restore-sysupgrade --input "$cache_sysupgrade" --prebackup /tmp/wrtbak/pre-restore-badsha.wrtbak --confirm RESTORE --json
assert_reject_code archive_mismatch restore-apply --input "$cache_mismatch_archive" --mode all --items all --prebackup "$prebackup" --confirm RESTORE --json
assert_reject_code archive_mismatch restore-apply --input "$cache_unlisted_archive" --mode all --items all --prebackup "$prebackup" --confirm RESTORE --json
if [ -e "$fixture_root/etc/config/extra" ]; then
	echo "restore-apply wrote a file that was not listed in manifest" >&2
	exit 1
fi
assert_reject_code archive_mismatch restore-apply --input "$cache_nested_files_archive" --mode all --items all --prebackup "$prebackup" --confirm RESTORE --json
if [ -e "$fixture_root/etc/config/extra" ]; then
	echo "restore-apply treated a nested files array as the manifest allowlist" >&2
	exit 1
fi
assert_reject_code invalid_archive restore-apply --input "$cache_bad_service_archive" --mode all --items all --prebackup "$prebackup" --confirm RESTORE --restart-services 1 --json
if [ -e "$fixture_root/tmp/wrtbak/bad-service.marker" ] || [ -e "$fixture_root/tmp/pwnsvc" ]; then
	echo "restore-apply accepted or executed an unsafe restart service" >&2
	exit 1
fi
assert_reject_code invalid_archive restore-sysupgrade --input "$cache_unsafe_sysupgrade" --prebackup "$prebackup" --confirm RESTORE --execute 0 --json

cp "$fixture_root/etc/config/system" "$work_dir/system-before-identity.txt"
assert_reject_code invalid_device_uid restore-apply --input "$cache_identity_mismatch_archive" --mode all --items all --prebackup "$prebackup" --confirm RESTORE --restart-services 0 --json
assert_reject_code missing_device_uid restore-apply --input "$cache_legacy_archive" --mode all --items all --prebackup "$prebackup" --confirm RESTORE --restart-services 0 --json
assert_reject_code missing_device_uid_algorithm restore-apply --input "$cache_missing_algorithm_archive" --mode all --items all --prebackup "$prebackup" --confirm RESTORE --restart-services 0 --json
assert_reject_code unsupported_device_uid_algorithm restore-apply --input "$cache_unsupported_algorithm_archive" --mode all --items all --prebackup "$prebackup" --confirm RESTORE --restart-services 0 --json
cmp "$work_dir/system-before-identity.txt" "$fixture_root/etc/config/system"

cp "$fixture_root$cache_archive" "$unusable_root$cache_archive"
cp "$fixture_root$prebackup" "$unusable_root$prebackup"
python3 - "$unusable_root$prebackup" "$unusable_root$prebackup.receipt.json" "$prebackup" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" <<'PY'
import hashlib
import json
import os
import sys

archive, receipt_path, logical_path, created_at = sys.argv[1:]
with open(archive, "rb") as handle:
    digest = hashlib.sha256(handle.read()).hexdigest()
receipt = {
    "operation": "restore-prebackup",
    "profile": "pre-restore",
    "items": "all",
    "format": "wrtbak",
    "path": logical_path,
    "filename": os.path.basename(logical_path),
    "size": os.path.getsize(archive),
    "sha256": digest,
    "created_at": created_at,
    "host_device_id": "unusable-test-device",
    "host_hostname": "unusable-router",
}
with open(receipt_path, "w", encoding="utf-8") as handle:
    json.dump(receipt, handle)
PY
assert_reject_code_unusable identity_unusable restore-apply --input "$cache_archive" --mode all --items all --prebackup "$prebackup" --confirm RESTORE --restart-services 0 --json
if [ -e "$unusable_root/etc/config/network" ]; then
	echo "restore-apply wrote config before rejecting unusable current identity" >&2
	exit 1
fi

cp "$fixture_root/etc/config/system" "$work_dir/system-before-unsafe.txt"
assert_reject_code invalid_archive restore-apply --input "$cache_unsupported_schema_archive" --mode all --items all --prebackup "$prebackup" --confirm RESTORE --restart-services 0 --json
for unsafe_archive in \
	"$cache_unsafe_absolute_archive" \
	"$cache_unsafe_dotdot_archive" \
	"$cache_unsafe_symlink_archive" \
	"$cache_unsafe_hardlink_archive" \
	"$cache_unsafe_chardev_archive" \
	"$cache_unsafe_blockdev_archive" \
	"$cache_unsafe_fifo_archive" \
	"$cache_unsafe_socket_archive"
do
	assert_reject_code invalid_archive restore-apply --input "$unsafe_archive" --mode all --items all --prebackup "$prebackup" --confirm RESTORE --restart-services 0 --json
done
cmp "$work_dir/system-before-unsafe.txt" "$fixture_root/etc/config/system"

printf 'target passwd\n' >"$fixture_root/etc/passwd"
printf 'target shadow\n' >"$fixture_root/etc/shadow"
printf 'target group\n' >"$fixture_root/etc/group"
printf 'target gshadow\n' >"$fixture_root/etc/gshadow"
run_cli restore-apply --input "$cache_account_archive" --mode all --items all --prebackup "$prebackup" --confirm RESTORE --restart-services 0 --json >"$work_dir/apply-account.json"
python3 - "$work_dir/apply-account.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

assert data["ok"] is True
assert data["operation"] == "restore-apply"
assert data["written_count"] >= 2, data
assert data["skipped_count"] >= 4, data
PY
grep -Fxq "target passwd" "$fixture_root/etc/passwd"
grep -Fxq "target shadow" "$fixture_root/etc/shadow"
grep -Fxq "target group" "$fixture_root/etc/group"
grep -Fxq "target gshadow" "$fixture_root/etc/gshadow"
cat >"$fixture_root/etc/config/system" <<'EOT'
config system
	option hostname 'target-router'
EOT

run_cli restore-apply --input "$cache_implicit_dir_archive" --mode all --items all --prebackup "$prebackup" --confirm RESTORE --restart-services 0 --json >"$work_dir/apply-implicit-dir.json"
python3 - "$work_dir/apply-implicit-dir.json" "$fixture_root" <<'PY'
import json
import os
import stat
import sys

path, fixture_root = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)

target_dir = os.path.join(fixture_root, "etc/config/unlisted_dir")
target_file = os.path.join(target_dir, "child")

assert data["ok"] is True
assert data["operation"] == "restore-apply"
assert data["written_count"] == 1, data
assert os.path.isfile(target_file)
with open(target_file, encoding="utf-8") as handle:
    assert handle.read() == "implicit directory child\n"
assert stat.S_IMODE(os.stat(target_dir).st_mode) != 0o777
PY

run_cli restore-apply --input "$cache_prefix_archive" --mode selected --items core-system --prebackup "$prebackup" --confirm RESTORE --restart-services 0 --json >"$work_dir/apply-prefix.json"
python3 - "$work_dir/apply-prefix.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

assert data["ok"] is True
assert data["operation"] == "restore-apply"
assert data["mode"] == "selected"
assert data["items"] == "core-system"
assert data["written_count"] == 0, data
assert "/etc/config/system" in data["missing_from_archive"], data
PY
if [ -e "$fixture_root/etc/config/system/child" ]; then
	echo "restore-apply treated a file item as a directory prefix" >&2
	exit 1
fi

run_cli restore-apply --input "$cache_compact_archive" --mode selected --items core-system --prebackup "$prebackup" --confirm RESTORE --restart-services 0 --json >"$work_dir/apply-compact.json"
python3 - "$work_dir/apply-compact.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

assert data["ok"] is True
assert data["operation"] == "restore-apply"
assert data["mode"] == "selected"
assert data["items"] == "core-system"
assert data["written_count"] == 1, data
PY
grep -Fq "source-router" "$fixture_root/etc/config/system"

cat >"$fixture_root/etc/config/system" <<'EOT'
config system
	option hostname 'target-router'
	option note 'before-selected'
EOT
cat >"$fixture_root/etc/config/network" <<'EOT'
config interface 'lan'
	option proto 'dhcp'
EOT
run_cli restore-apply --input "$cache_archive" --mode selected --items network,wireguard --prebackup "$prebackup" --confirm RESTORE --restart-services 0 --json >"$work_dir/apply-selected.json"
python3 - "$work_dir/apply-selected.json" "$cache_archive" "$prebackup" <<'PY'
import json
import sys

path, archive, prebackup = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)

assert data["ok"] is True
assert data["operation"] == "restore-apply"
assert data["input"] == archive
assert data["mode"] == "selected"
assert data["items"] == "network,wireguard"
assert data["written_count"] == 1, data
assert data["skipped_count"] >= 1, data
assert data["prebackup_path"] == prebackup
assert data["restore_log"].startswith("/tmp/wrtbak/restore-logs/restore-")
assert "/etc/config/dhcp" in data["missing_from_archive"]
assert "/etc/config/firewall" in data["missing_from_archive"]
assert data["restarted_services"] == []
PY
grep -Fq "before-selected" "$fixture_root/etc/config/system"
grep -Fq "192.0.2.10" "$fixture_root/etc/config/network"

run_cli restore-apply --input "$cache_service_archive" --mode all --items all --prebackup "$prebackup" --confirm RESTORE --restart-services 1 --json >"$work_dir/apply-all.json"
python3 - "$work_dir/apply-all.json" "$cache_service_archive" <<'PY'
import json
import sys

path, archive = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)

assert data["ok"] is True
assert data["operation"] == "restore-apply"
assert data["input"] == archive
assert data["mode"] == "all"
assert data["written_count"] >= 2, data
assert data["skipped_count"] == 0, data
assert data["restart_services"] == ["network", "dnsmasq"], data
assert data["restarted_services"] == ["dnsmasq"], data
assert data["blocked_restart_services"] == ["network"], data
assert data["restart_errors"] == [], data
assert data["reboot_recommended"] is True
PY
grep -Fq "source-router" "$fixture_root/etc/config/system"
grep -Fq "dnsmasq restarted" "$fixture_root/tmp/wrtbak/dnsmasq-restart.log"

run_cli restore-prebackup --profile pre-restore --items all --format wrtbak --json >"$work_dir/prebackup-after-apply.json"
prebackup=$(python3 - "$work_dir/prebackup-after-apply.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["path"])
PY
)

run_cli restore-sysupgrade --input "$cache_sysupgrade" --prebackup "$prebackup" --confirm RESTORE --execute 0 --json >"$work_dir/sysupgrade-preflight.json"
python3 - "$work_dir/sysupgrade-preflight.json" "$cache_sysupgrade" "$prebackup" <<'PY'
import json
import sys

path, archive, prebackup = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)

assert data["ok"] is True
assert data["operation"] == "restore-sysupgrade"
assert data["execute"] is False
assert data["status"] == "preflight_only"
assert data["input"] == archive
assert data["prebackup_path"] == prebackup
assert data["archive"]["filename"].endswith(".sysupgrade.tar.gz")
assert data["manifest_present"] is True
assert data["file_count"] >= 1
assert data["total_bytes"] > 0
assert data["compatibility"]["blocking"] is False
assert data["sysupgrade_command"] == f"sysupgrade -r {archive}"
assert data["reboot_recommended"] is True
PY

if WRTBAK_SYSUPGRADE_EXIT=7 WRTBAK_SYSUPGRADE_LOG="$work_dir/sysupgrade.log" run_cli restore-sysupgrade --input "$cache_sysupgrade" --prebackup "$prebackup" --confirm RESTORE --execute 1 --json >"$work_dir/sysupgrade-execute-fail.json"; then
	echo "restore-sysupgrade execute should fail when sysupgrade exits 7" >&2
	exit 1
fi
python3 - "$work_dir/sysupgrade-execute-fail.json" "$cache_sysupgrade" "$prebackup" <<'PY'
import json
import sys

path, archive, prebackup = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)

assert data == {
    "ok": False,
    "operation": "restore-sysupgrade",
    "execute": True,
    "status": "failed",
    "code": "sysupgrade_failed",
    "message": "sysupgrade restore failed",
    "input": archive,
    "prebackup_path": prebackup,
    "sysupgrade_exit_code": 7,
    "reboot_recommended": True,
}, data
PY
grep -Fq "$fixture_root$cache_sysupgrade" "$work_dir/sysupgrade.log"

: > "$fixture_root/zzblocked"
if run_cli restore-apply --input "$cache_failure_archive" --mode all --items all --prebackup "$prebackup" --confirm RESTORE --restart-services 0 --json >"$work_dir/apply-write-failure.json"; then
	echo "restore-apply should fail when a target directory is blocked by a file" >&2
	exit 1
fi
python3 - "$work_dir/apply-write-failure.json" "$fixture_root" <<'PY'
import json
import os
import sys

path, fixture_root = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)

assert data["ok"] is False
assert data["operation"] == "restore-apply"
assert data["code"] == "write_failed"
assert data["written_count"] >= 1, data
assert data["failed_path"] == "/zzblocked"
assert data["restore_log"].startswith("/tmp/wrtbak/restore-logs/restore-")
assert os.path.isfile(fixture_root + data["restore_log"])
PY

echo "fixture restore apply prepare/prebackup test passed"
