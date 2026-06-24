#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-detect-test.XXXXXX")
fixture_root="$work_dir/root"
bin_dir="$work_dir/bin"
archive="$work_dir/selected.wrtbak"
libdir="$repo_dir/root/usr/lib/wrtbak"
cli="$repo_dir/root/usr/bin/wrtbak"

cleanup() {
	rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p \
	"$bin_dir" \
	"$fixture_root/etc/config" \
	"$fixture_root/etc/nikki/profiles" \
	"$fixture_root/etc/mosdns" \
	"$fixture_root/etc/wireguard" \
	"$fixture_root/etc/dropbear"

cat >"$bin_dir/apk" <<'EOT'
#!/bin/sh
if [ "$1" = "info" ]; then
	cat <<'EOF'
luci-app-ddns-go
luci-app-mosdns
luci-app-nikki
luci-app-tailscale-community
luci-app-upnp
wireguard-tools
EOF
	exit 0
fi
exit 1
EOT
chmod +x "$bin_dir/apk"

cat >"$fixture_root/etc/config/system" <<'EOT'
config system
	option hostname 'detect-router'
EOT

cat >"$fixture_root/etc/config/network" <<'EOT'
config interface 'lan'
	option proto 'static'
	option ipaddr '192.0.2.1'

config interface 'wg0'
	option proto 'wireguard'
EOT

cat >"$fixture_root/etc/config/dhcp" <<'EOT'
config dnsmasq
	option domainneeded '1'
EOT

cat >"$fixture_root/etc/config/firewall" <<'EOT'
config defaults
	option input 'REJECT'
EOT

cat >"$fixture_root/etc/config/wireless" <<'EOT'
config wifi-device 'radio0'
	option disabled '0'
EOT

cat >"$fixture_root/etc/config/nikki" <<'EOT'
config nikki 'config'
	option enabled '1'
EOT

cat >"$fixture_root/etc/nikki/profiles/default.yaml" <<'EOT'
proxy: placeholder
EOT

cat >"$fixture_root/etc/config/mosdns" <<'EOT'
config mosdns 'config'
	option enabled '1'
EOT

cat >"$fixture_root/etc/mosdns/config.yaml" <<'EOT'
log:
  level: info
EOT

cat >"$fixture_root/etc/wireguard/wg0.conf" <<'EOT'
[Interface]
PrivateKey = placeholder
EOT

PATH="$bin_dir:$PATH" \
WRTBAK_ROOT="$fixture_root" \
WRTBAK_LIBDIR="$libdir" \
	"$cli" detect --json >"$work_dir/detect.json"

python3 - "$work_dir/detect.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

assert data["package_manager"] == "apk"
items = {item["id"]: item for item in data["items"]}

for required in [
    "core-system",
    "network",
    "wireless",
    "dropbear",
    "ddns-go",
    "nikki",
    "mosdns",
    "tailscale",
    "wireguard",
    "luci-app-upnp",
]:
    assert required in items, required

assert items["nikki"]["installed"] is True
assert "/etc/config/nikki" in items["nikki"]["paths"]
assert "/etc/nikki" in items["nikki"]["paths"]
assert items["wireguard"]["sensitive"] is True
assert "/etc/wireguard" in items["wireguard"]["paths"]
assert items["luci-app-upnp"]["known"] is False
PY

PATH="$bin_dir:$PATH" \
WRTBAK_ROOT="$fixture_root" \
WRTBAK_LIBDIR="$libdir" \
	"$cli" create --profile selected --items core-system,nikki,wireguard --output "$archive"

tar tzf "$archive" >"$work_dir/archive.list"
grep -q '^rootfs/etc/config/system$' "$work_dir/archive.list"
grep -q '^rootfs/etc/config/nikki$' "$work_dir/archive.list"
grep -q '^rootfs/etc/nikki/profiles/default.yaml$' "$work_dir/archive.list"
grep -q '^rootfs/etc/config/network$' "$work_dir/archive.list"
grep -q '^rootfs/etc/wireguard/wg0.conf$' "$work_dir/archive.list"

if grep -q '^rootfs/etc/config/mosdns$' "$work_dir/archive.list"; then
	echo "unselected mosdns item should not be archived" >&2
	exit 1
fi

echo "fixture detect and selected-items test passed"
