#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-firstboot-status-test.XXXXXX")
fixture_root="$work_dir/root"
bin_dir="$work_dir/bin"
libdir="$repo_dir/root/usr/lib/wrtbak"
cli="$repo_dir/root/usr/bin/wrtbak"

cleanup() {
	rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p \
	"$fixture_root/etc/config" \
	"$fixture_root/tmp/sysinfo" \
	"$fixture_root/sys/class/net/br-lan" \
	"$fixture_root/root/wrtbak/firstboot/receipts" \
	"$bin_dir"

cat >"$fixture_root/etc/config/wrtbak" <<'EOT'
config wrtbak 'main'
	option enabled '1'
	option default_target 's3'
	option device_alias 'office-re-ss-01-test'
	option proxy_url 'http://proxy-secret.example.invalid:7890'

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
	option hostname 'DAE-WRT'
EOT

printf 'jdcloud,re-ss-01\n' >"$fixture_root/tmp/sysinfo/board_name"
printf '02:11:22:33:44:55\n' >"$fixture_root/sys/class/net/br-lan/address"

cat >"$bin_dir/ip" <<'EOT'
#!/bin/sh
if [ "$1" = "-4" ] && [ "$2" = "-o" ] && [ "$3" = "addr" ]; then
	printf '7: br-lan    inet 192.168.11.234/24 brd 192.168.11.255 scope global br-lan\n'
	exit 0
fi
if [ "$1" = "route" ] && [ "$2" = "show" ] && [ "$3" = "default" ]; then
	printf 'default via 192.168.11.1 dev br-lan\n'
	exit 0
fi
exit 1
EOT
chmod +x "$bin_dir/ip"

cat >"$bin_dir/nslookup" <<'EOT'
#!/bin/sh
printf 'Name: cloudflare.com\nAddress: 1.1.1.1\n'
exit 0
EOT
chmod +x "$bin_dir/nslookup"

cat >"$bin_dir/qrencode" <<'EOT'
#!/bin/sh
while [ "$#" -gt 0 ]; do
	case "$1" in
		-t|-o)
			shift 2
			;;
		*)
			url=$1
			shift
			;;
	esac
done
printf '<svg xmlns="http://www.w3.org/2000/svg">\n\t<title>%s</title>\n\t<path d="M0 0h1v1z"/>\n</svg>\n' "$url"
EOT
chmod +x "$bin_dir/qrencode"

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
        value = json.load(handle)
    for part in expr[2:].split("."):
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

run_cli firstboot-status --json >"$work_dir/status.json"

python3 - "$work_dir/status.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

assert data["ok"] is True, data
assert data["operation"] == "firstboot-status", data
assert data["identity"]["ok"] is True, data
assert data["identity"]["uid"] == "jdcloud-re-ss-01-14c4a35ee8", data
assert data["identity"]["alias"] == "office-re-ss-01-test", data
assert data["network"]["default_route"] is True, data
assert data["network"]["dns"] is True, data
assert data["network"]["time"] is True, data
assert data["network"]["lan_ip"] == "192.168.11.234", data
assert data["remote"]["default_target"] == "s3", data
assert data["remote"]["targets"]["s3"]["enabled"] is True, data
assert data["local_url"] == "http://192.168.11.234/cgi-bin/luci/admin/system/wrtbak", data
assert data["qr_svg"].startswith("<svg "), data
assert "\t" not in data["qr_svg"], data
assert "\n" not in data["qr_svg"], data
assert data["done_marker"]["exists"] is False, data
assert data["blocked_reasons"] == [], data

encoded = json.dumps(data)
assert "secret-key-value" not in encoded
assert "access-key-value" not in encoded
assert "proxy-secret" not in encoded
PY

cat >"$fixture_root/root/wrtbak/firstboot/done.json" <<'EOT'
{
  "ok": true,
  "device_uid": "different-device",
  "backup_remote_path": "openwrt-config-backup/wrtbak/devices/different-device/wrtbak/2026/sample.wrtbak",
  "prebackup_path": "/root/wrtbak/pre-restore/sample.wrtbak",
  "restore_receipt": "/root/wrtbak/firstboot/receipts/sample-restore.json",
  "created_at": "2026-07-01T00:00:00Z"
}
EOT

run_cli firstboot-status --json >"$work_dir/mismatch.json"

python3 - "$work_dir/mismatch.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

assert data["ok"] is True, data
assert data["done_marker"]["exists"] is True, data
assert data["done_marker"]["status"] == "uid_mismatch", data
assert "done_marker_uid_mismatch" in data["blocked_reasons"], data
PY

echo "firstboot status fixture passed"
