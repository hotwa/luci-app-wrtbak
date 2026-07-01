#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-firstboot-flow-test.XXXXXX")
source_root="$work_dir/source-root"
fixture_root="$work_dir/root"
bin_dir="$work_dir/bin"
libdir="$repo_dir/root/usr/lib/wrtbak"
cli="$repo_dir/root/usr/bin/wrtbak"
current_uid="jdcloud-re-ss-01-14c4a35ee8"
current_remote="openwrt-config-backup/wrtbak/devices/$current_uid/wrtbak/2026/current.wrtbak"
legacy_remote="openwrt-config-backup/wrtbak/wrtbak/office-re-ss-01-test/wrtbak/2026/legacy.wrtbak"
archive_file="$work_dir/current.wrtbak"
rclone_log="$work_dir/rclone.log"

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
	"$source_root/tmp/sysinfo" \
	"$source_root/sys/class/net/br-lan" \
	"$fixture_root/etc/config" \
	"$fixture_root/tmp/sysinfo" \
	"$fixture_root/sys/class/net/br-lan" \
	"$fixture_root/tmp/wrtbak/downloads" \
	"$fixture_root/tmp/wrtbak/restore-cache" \
	"$fixture_root/root/wrtbak/pre-restore" \
	"$fixture_root/root/wrtbak/receipts" \
	"$fixture_root/root/wrtbak/firstboot/receipts" \
	"$bin_dir"

cat >"$source_root/etc/config/system" <<'EOT'
config system
	option hostname 'source-router'
EOT
cat >"$source_root/etc/config/network" <<'EOT'
config interface 'lan'
	option proto 'static'
	option ipaddr '192.168.11.234'
EOT
printf 'jdcloud,re-ss-01\n' >"$source_root/tmp/sysinfo/board_name"
printf '02:11:22:33:44:55\n' >"$source_root/sys/class/net/br-lan/address"

cat >"$fixture_root/etc/config/wrtbak" <<'EOT'
config wrtbak 'main'
	option enabled '1'
	option default_target 's3'
	option device_alias 'office-re-ss-01-test'

config remote 's3'
	option enabled '1'
	option driver 'rclone'
	option endpoint 'https://r2.example.invalid'
	option region 'auto'
	option bucket 'knowledge'
	option access_key 'access-key-value'
	option secret_key 'secret-key-value'
	option path '/openwrt-config-backup/wrtbak/'
	option force_path_style '1'
EOT
cat >"$fixture_root/etc/config/system" <<'EOT'
config system
	option hostname 'target-router'
EOT
printf 'jdcloud,re-ss-01\n' >"$fixture_root/tmp/sysinfo/board_name"
printf '02:11:22:33:44:55\n' >"$fixture_root/sys/class/net/br-lan/address"

PATH="$bin_dir:$PATH" \
WRTBAK_ROOT="$source_root" \
WRTBAK_LIBDIR="$libdir" \
	"$cli" create --profile auto --output "$archive_file" --items all >/dev/null
archive_size=$(wc -c < "$archive_file" | awk '{ print $1 }')

cat >"$bin_dir/rclone" <<EOT
#!/bin/sh
printf '%s\\n' "\$*" >> "$rclone_log"
if [ "\$1" = "--config" ]; then
	shift 2
fi
command=\$1
shift
case "\$command" in
	lsjson)
		if [ "\$1" = "--recursive" ]; then
			shift
		fi
		remote_ref=\$1
		case "\$remote_ref" in
			wrtbak_remote:knowledge/$current_remote)
				cat <<'JSON'
[
  {
    "Path": "$current_remote",
    "Name": "current.wrtbak",
    "Size": $archive_size,
    "ModTime": "2026-07-01T00:00:00Z"
  }
]
JSON
				exit 0
				;;
			*wrtbak_remote:knowledge/openwrt-config-backup/wrtbak/devices/$current_uid)
				cat <<'JSON'
[
  {
    "Path": "$current_remote",
    "Name": "current.wrtbak",
    "Size": $archive_size,
    "ModTime": "2026-07-01T00:00:00Z"
  }
]
JSON
				exit 0
				;;
			*wrtbak_remote:knowledge/openwrt-config-backup/wrtbak/wrtbak/office-re-ss-01-test)
				cat <<'JSON'
[
  {
    "Path": "$legacy_remote",
    "Name": "legacy.wrtbak",
    "Size": 222,
    "ModTime": "2026-06-30T00:00:00Z"
  }
]
JSON
				exit 0
				;;
		esac
		printf '[]\n'
		exit 0
		;;
	copyto)
		source=\$1
		destination=\$2
		case "\$source" in
			wrtbak_remote:knowledge/$current_remote)
				cp "$archive_file" "\$destination"
				exit 0
				;;
			*)
				exit 55
				;;
		esac
		;;
esac
exit 0
EOT
chmod +x "$bin_dir/rclone"

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
parts = expr[2:].split(".")
for index, part in enumerate(parts):
    try:
        if part.endswith("[*]"):
            value = value[part[:-3]]
            if not isinstance(value, list):
                sys.exit(1)
            tail = parts[index + 1:]
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
elif value is not None:
    print(value)
PY
EOT
chmod +x "$bin_dir/jsonfilter"

run_cli() {
	PATH="$bin_dir:$PATH" \
	WRTBAK_ROOT="$fixture_root" \
	WRTBAK_LIBDIR="$libdir" \
		"$cli" "$@"
}

run_cli firstboot-candidates --target s3 --json >"$work_dir/candidates.json"
python3 - "$work_dir/candidates.json" "$current_remote" "$legacy_remote" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
current_remote, legacy_remote = sys.argv[2], sys.argv[3]

assert data["ok"] is True, data
assert data["operation"] == "firstboot-candidates", data
assert data["identity"]["uid"] == "jdcloud-re-ss-01-14c4a35ee8", data
backups = data["remote"]["backups"]
assert any(item["path"] == current_remote and item.get("legacy") is not True for item in backups), data
assert any(item["path"] == legacy_remote and item.get("legacy") is True for item in backups), data
assert data["write_policy"] == "current_device_only", data
PY

run_cli firstboot-prepare --target s3 --path "$current_remote" --json >"$work_dir/prepare.json"
python3 - "$work_dir/prepare.json" "$current_remote" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
remote_path = sys.argv[2]

assert data["ok"] is True, data
assert data["operation"] == "firstboot-prepare", data
assert data["download"]["remote_path"] == remote_path, data
assert data["download"]["path"].startswith("/tmp/wrtbak/restore-cache/"), data
assert data["download"]["local_path"].endswith(data["download"]["path"]), data
assert data["prepare"]["format"] == "wrtbak", data
assert data["plan"]["identity_match"] is True, data
assert data["plan"]["can_apply"] is True, data
assert data["plan"]["current_uid"] == data["plan"]["manifest_uid"], data
assert all(item["path"] not in ["/etc/passwd", "/etc/shadow", "/etc/group", "/etc/gshadow"] for item in data["plan"]["paths"]), data
PY

if run_cli firstboot-prepare --target s3 --path "$legacy_remote" --json >"$work_dir/legacy.json" 2>"$work_dir/legacy.err"; then
	echo "legacy firstboot prepare unexpectedly succeeded" >&2
	cat "$work_dir/legacy.json" >&2
	exit 1
fi

python3 - "$work_dir/legacy.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
assert data["ok"] is False, data
assert data["operation"] == "firstboot-prepare", data
assert data["code"] in ["legacy_backup_read_only", "invalid_config"], data
PY

echo "firstboot restore flow fixture passed"
