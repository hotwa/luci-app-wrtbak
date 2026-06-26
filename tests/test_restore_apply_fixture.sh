#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-restore-apply-test.XXXXXX")
source_root="$work_dir/source-root"
fixture_root="$work_dir/fixture-root"
bin_dir="$work_dir/bin"
paths_file="$work_dir/paths.default"
source_archive="$work_dir/source.wrtbak"
source_sysupgrade="$work_dir/source.sysupgrade.tar.gz"
cache_archive="/tmp/wrtbak/restore-cache/sample.wrtbak"
cache_sysupgrade="/tmp/wrtbak/restore-cache/sample.sysupgrade.tar.gz"
libdir="$repo_dir/root/usr/lib/wrtbak"
cli="$repo_dir/root/usr/bin/wrtbak"

cleanup() {
	rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p \
	"$source_root/etc/config" \
	"$source_root/etc" \
	"$source_root/sys/class/net/br-lan" \
	"$fixture_root/etc/config" \
	"$fixture_root/etc" \
	"$fixture_root/sys/class/net/br-lan" \
	"$fixture_root/tmp/wrtbak/restore-cache" \
	"$fixture_root/tmp/wrtbak/downloads" \
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
printf '02:11:22:33:44:55\n' >"$source_root/sys/class/net/br-lan/address"

cat >"$fixture_root/etc/config/wrtbak" <<'EOT'
config wrtbak 'main'
	option output_dir '/tmp/wrtbak'
EOT

cat >"$fixture_root/etc/config/system" <<'EOT'
config system
	option hostname 'target-router'
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
printf '02:aa:bb:cc:dd:ee\n' >"$fixture_root/sys/class/net/br-lan/address"

cat >"$paths_file" <<'EOT'
/etc/config/system
/etc/config/network
EOT

run_cli() {
	PATH="$bin_dir:$PATH" \
	WRTBAK_ROOT="$fixture_root" \
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

assert_reject_code invalid_input_path restore-prepare --input relative.wrtbak --json
assert_reject_code invalid_input_path restore-prepare --input /tmp/wrtbak/restore-cache/../bad.wrtbak --json
assert_reject_code invalid_input_path restore-prepare --input /tmp/wrtbak/restore-cache/link.wrtbak --json
assert_reject_code invalid_input_path restore-prepare --input /etc/config/system --json
assert_reject_code invalid_input_path restore-prepare --input /tmp/wrtbak/restore-cache/directory.wrtbak --json
assert_reject_code invalid_input_path restore-prepare --input /tmp/wrtbak/restore-cache/bad.txt --json
assert_reject_code invalid_prebackup restore-apply --input "$cache_archive" --mode all --items all --prebackup /etc/config/system --confirm RESTORE --json
assert_reject_code invalid_input_path restore-apply --input "$cache_sysupgrade" --mode all --items all --prebackup "$prebackup" --confirm RESTORE --json
assert_reject_code invalid_input_path restore-sysupgrade --input "$cache_archive" --prebackup "$prebackup" --confirm RESTORE --json

echo "fixture restore apply prepare/prebackup test passed"
