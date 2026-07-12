#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fixture_root="$work_dir/root"
bin_dir="$work_dir/bin"
ubus_board_file="$work_dir/ubus-board-name"
ubus_json_file="$work_dir/ubus-board.json"
mkdir -p "$bin_dir"

cat >"$bin_dir/ubus" <<'EOT'
#!/bin/sh
if [ "${WRTBAK_FAKE_UBUS_FAIL:-0}" = "1" ]; then
	exit 1
fi
if [ "$1" = "call" ] && [ "$2" = "system" ] && [ "$3" = "board" ]; then
	if [ -n "${WRTBAK_FAKE_UBUS_JSON_FILE:-}" ] && [ -r "$WRTBAK_FAKE_UBUS_JSON_FILE" ]; then
		cat "$WRTBAK_FAKE_UBUS_JSON_FILE"
		exit 0
	fi
	board_name=$(cat "$WRTBAK_FAKE_UBUS_BOARD_FILE" 2>/dev/null || true)
	printf '{"board_name":"%s"}\n' "$board_name"
	exit 0
fi
exit 1
EOT
chmod +x "$bin_dir/ubus"

run_env() {
	env \
		PATH="$bin_dir:$PATH" \
		WRTBAK_ROOT="$fixture_root" \
		WRTBAK_LIBDIR="$repo_root/root/usr/lib/wrtbak" \
		WRTBAK_FAKE_UBUS_BOARD_FILE="$ubus_board_file" \
		WRTBAK_FAKE_UBUS_JSON_FILE="$ubus_json_file" \
		"$@"
}

run_cli() {
	run_env "$repo_root/root/usr/bin/wrtbak" "$@"
}

reset_fixture() {
	rm -rf "$fixture_root"
	mkdir -p "$fixture_root/tmp/sysinfo" "$fixture_root/sys/class/net" "$fixture_root/etc/config" "$fixture_root/proc/device-tree"
	: >"$ubus_board_file"
	rm -f "$ubus_json_file"
}

set_board() {
	printf '%s\n' "$1" >"$fixture_root/tmp/sysinfo/board_name"
}

set_compatible() {
	printf '%b' "$1" >"$fixture_root/proc/device-tree/compatible"
}

set_iface_mac() {
	mkdir -p "$fixture_root/sys/class/net/$1"
	printf '%s\n' "$2" >"$fixture_root/sys/class/net/$1/address"
}

set_wrtbak_primary_mac() {
	cat >"$fixture_root/etc/config/wrtbak" <<EOT
config identity 'identity'
	option primary_mac '$1'
EOT
}

set_network_lan_mac() {
	cat >"$fixture_root/etc/config/network" <<EOT
config interface 'lan'
	option macaddr '$1'
EOT
}

clear_network() {
	rm -f "$fixture_root/etc/config/network"
}

clear_wrtbak_config() {
	: >"$fixture_root/etc/config/wrtbak"
}

assert_uid_for() {
	json_file=$1
	board_slug=$2
	mac=$3
	mac_source=$4
	python3 - "$json_file" "$board_slug" "$mac" "$mac_source" <<'PY'
import hashlib
import json
import sys

path, board_slug, mac, mac_source = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
normalized = "".join(ch for ch in mac.lower() if ch in "0123456789abcdef")
expected_hash = hashlib.sha256(normalized.encode()).hexdigest()[:10]
assert data["ok"] is True
assert data["status"] == "ok"
assert data["uid_algorithm"] == "wrtbak-board-mac-sha256-10/v1"
assert data["board_slug"] == board_slug
assert data["mac_hash"] == expected_hash
assert data["uid"] == f"{board_slug}-{expected_hash}"
assert data["mac_source"] == mac_source
PY
}

assert_unusable() {
	json_file=$1
	python3 - "$json_file" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["ok"] is False
assert data["status"] == "unusable"
assert "uid" not in data
PY
}

reset_fixture
set_board 'JDCloud,RE-SS-01'
set_iface_mac br-lan '02:11:22:33:44:55'

run_cli identity --json >"$work_dir/identity.json"
python3 - "$work_dir/identity.json" <<'PY'
import hashlib
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
expected_hash = hashlib.sha256("021122334455".encode()).hexdigest()[:10]
assert data["ok"] is True
assert data["uid_algorithm"] == "wrtbak-board-mac-sha256-10/v1"
assert data["board_slug"] == "jdcloud-re-ss-01"
assert data["mac_hash"] == expected_hash
assert data["uid"] == f"jdcloud-re-ss-01-{expected_hash}"
assert data["mac_source"] == "br-lan"
PY

rm -f "$fixture_root/sys/class/net/br-lan/address"
if run_cli identity --json >"$work_dir/no-mac.json"; then
	echo "identity should fail without a stable MAC" >&2
	exit 1
fi
grep -q '"status": "unusable"' "$work_dir/no-mac.json"

reset_fixture
set_board 'Tmp Board'
printf 'Ubus Board Plain 01\n' >"$ubus_board_file"
set_compatible 'DeviceTree,Board\0fallback'
set_iface_mac br-lan '02:11:22:33:44:55'
run_cli identity --json >"$work_dir/board-tmp.json"
assert_uid_for "$work_dir/board-tmp.json" tmp-board '02:11:22:33:44:55' br-lan

rm -f "$fixture_root/tmp/sysinfo/board_name"
run_cli identity --json >"$work_dir/board-ubus.json"
assert_uid_for "$work_dir/board-ubus.json" ubus-board-plain-01 '02:11:22:33:44:55' br-lan

cat >"$ubus_json_file" <<'EOT'
{
  "kernel": "6.6.0",
  "board_name"  :  "Ubus Board Pretty 02",
  "release": "fixture",
}
EOT
run_cli identity --json >"$work_dir/board-ubus-pretty.json"
assert_uid_for "$work_dir/board-ubus-pretty.json" ubus-board-pretty-02 '02:11:22:33:44:55' br-lan
rm -f "$ubus_json_file"

WRTBAK_FAKE_UBUS_FAIL=1 run_cli identity --json >"$work_dir/board-compatible.json"
assert_uid_for "$work_dir/board-compatible.json" devicetree-board '02:11:22:33:44:55' br-lan

for value in '' '   ' '!!!'; do
	reset_fixture
	set_board "$value"
	set_iface_mac br-lan '02:11:22:33:44:55'
	if run_cli identity --json >"$work_dir/bad-board.json"; then
		echo "identity should fail for unusable board value: [$value]" >&2
		exit 1
	fi
	assert_unusable "$work_dir/bad-board.json"
done

reset_fixture
set_board 'JDCloud, RE_SS 01!!'
set_iface_mac br-lan '02:11:22:33:44:55'
run_cli identity --json >"$work_dir/slug.json"
assert_uid_for "$work_dir/slug.json" jdcloud-re-ss-01 '02:11:22:33:44:55' br-lan

reset_fixture
long_board='Long Board abcdefghijklmnopqrstuvwxyz abcdefghijklmnopqrstuvwxyz abcdefghijklmnopqrstuvwxyz'
set_board "$long_board"
set_iface_mac br-lan '02:11:22:33:44:55'
run_cli identity --json >"$work_dir/long-board.json"
python3 - "$work_dir/long-board.json" "$long_board" <<'PY'
import hashlib
import json
import re
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
board = sys.argv[2]
expected_slug = re.sub(r"[^a-z0-9]+", "-", board.lower()).strip("-")
expected_hash = hashlib.sha256(b"021122334455").hexdigest()[:10]
expected_uid_slug = expected_slug[:53].rstrip("-")
assert data["ok"] is True
assert data["board_slug"] == expected_slug
assert data["mac_hash"] == expected_hash
assert data["uid"] == f"{expected_uid_slug}-{expected_hash}"
assert len(data["uid"]) <= 64
assert data["uid"].endswith(f"-{expected_hash}")
PY

reset_fixture
set_board 'Mac Source Board'
set_wrtbak_primary_mac '02:aa:00:00:00:01'
set_network_lan_mac '02:aa:00:00:00:02'
set_iface_mac br-lan '02:aa:00:00:00:03'
set_iface_mac eth0 '02:aa:00:00:00:04'
set_iface_mac wan '02:aa:00:00:00:05'
set_iface_mac lan1 '02:aa:00:00:00:06'
set_iface_mac aa0 '02:aa:00:00:00:07'
set_iface_mac zz0 '02:aa:00:00:00:08'
run_cli identity --json >"$work_dir/mac-uci.json"
assert_uid_for "$work_dir/mac-uci.json" mac-source-board '02:aa:00:00:00:01' wrtbak.identity.primary_mac

clear_wrtbak_config
run_cli identity --json >"$work_dir/mac-network.json"
assert_uid_for "$work_dir/mac-network.json" mac-source-board '02:aa:00:00:00:02' network.lan.macaddr

clear_network
run_cli identity --json >"$work_dir/mac-br-lan.json"
assert_uid_for "$work_dir/mac-br-lan.json" mac-source-board '02:aa:00:00:00:03' br-lan

rm -f "$fixture_root/sys/class/net/br-lan/address"
run_cli identity --json >"$work_dir/mac-eth0.json"
assert_uid_for "$work_dir/mac-eth0.json" mac-source-board '02:aa:00:00:00:04' eth0

rm -f "$fixture_root/sys/class/net/eth0/address"
run_cli identity --json >"$work_dir/mac-wan.json"
assert_uid_for "$work_dir/mac-wan.json" mac-source-board '02:aa:00:00:00:05' wan

rm -f "$fixture_root/sys/class/net/wan/address"
run_cli identity --json >"$work_dir/mac-lan1.json"
assert_uid_for "$work_dir/mac-lan1.json" mac-source-board '02:aa:00:00:00:06' lan1

rm -f "$fixture_root/sys/class/net/lan1/address"
run_cli identity --json >"$work_dir/mac-fallback.json"
assert_uid_for "$work_dir/mac-fallback.json" mac-source-board '02:aa:00:00:00:07' aa0

reset_fixture
set_board 'Invalid Mac Board'
set_wrtbak_primary_mac 'not-a-mac'
set_network_lan_mac '00:00:00:00:00:00'
set_iface_mac br-lan 'ff:ff:ff:ff:ff:ff'
set_iface_mac eth0 '03:11:22:33:44:55'
set_iface_mac wan '02:11:22:33:44'
set_iface_mac lan1 '02:11:22:33:44:99'
run_cli identity --json >"$work_dir/invalid-mac-skips.json"
assert_uid_for "$work_dir/invalid-mac-skips.json" invalid-mac-board '02:11:22:33:44:99' lan1

rm -f "$fixture_root/sys/class/net/lan1/address"
if run_cli identity --json >"$work_dir/invalid-mac-all.json"; then
	echo "identity should fail when every MAC candidate is invalid" >&2
	exit 1
fi
assert_unusable "$work_dir/invalid-mac-all.json"

reset_fixture
set_board 'Virtual Board'
for iface in tailscale0 wg0 tun0 docker0 veth0 ppp0 ifb0 phy0 mon0 lo; do
	set_iface_mac "$iface" '02:bb:00:00:00:01'
done
set_iface_mac aa0 '02:bb:00:00:00:02'
run_cli identity --json >"$work_dir/virtual-skip.json"
assert_uid_for "$work_dir/virtual-skip.json" virtual-board '02:bb:00:00:00:02' aa0

reset_fixture
set_board 'Stable Board'
set_iface_mac br-lan '02:11:22:33:44:55'
run_cli identity --json >"$work_dir/stable-1.json"
run_cli identity --json >"$work_dir/stable-2.json"
set_iface_mac br-lan '02:11:22:33:44:56'
run_cli identity --json >"$work_dir/stable-3.json"
python3 - "$work_dir/stable-1.json" "$work_dir/stable-2.json" "$work_dir/stable-3.json" <<'PY'
import json
import sys

uids = [json.load(open(path, encoding="utf-8"))["uid"] for path in sys.argv[1:]]
assert uids[0] == uids[1]
assert uids[0] != uids[2]
PY

reset_fixture
if run_env \
	WRTBAK_FAKE_BOARD_NAME='Hook Board' \
	WRTBAK_FAKE_PRIMARY_MAC='02:cc:00:00:00:01' \
	"$repo_root/root/usr/bin/wrtbak" identity --json >"$work_dir/hooks-denied.json"; then
	echo "identity hooks should not work without WRTBAK_ALLOW_TEST_HOOKS=1" >&2
	exit 1
fi
assert_unusable "$work_dir/hooks-denied.json"

run_env \
	WRTBAK_ALLOW_TEST_HOOKS=1 \
	WRTBAK_FAKE_BOARD_NAME='Hook Board' \
	WRTBAK_FAKE_PRIMARY_MAC='02:cc:00:00:00:01' \
	"$repo_root/root/usr/bin/wrtbak" identity --json >"$work_dir/hooks-allowed.json"
assert_uid_for "$work_dir/hooks-allowed.json" hook-board '02:cc:00:00:00:01' test-hook

if run_env \
	WRTBAK_FAKE_DEVICE_UID='override-device' \
	"$repo_root/root/usr/bin/wrtbak" identity --json >"$work_dir/uid-hook-denied.json"; then
	echo "device UID hook should not work without WRTBAK_ALLOW_TEST_HOOKS=1" >&2
	exit 1
fi
assert_unusable "$work_dir/uid-hook-denied.json"

run_env \
	WRTBAK_ALLOW_TEST_HOOKS=1 \
	WRTBAK_FAKE_DEVICE_UID='override-device' \
	"$repo_root/root/usr/bin/wrtbak" identity --json >"$work_dir/uid-hook-allowed.json"
python3 - "$work_dir/uid-hook-allowed.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["ok"] is True
assert data["uid"] == "override-device"
assert data["uid_algorithm"] == "wrtbak-uid-override/v1"
assert data["status"] == "ok"
PY

reset_fixture
set_board 'Parser Board'
set_iface_mac br-lan '02:11:22:33:44:55'
run_cli identity --json >/dev/null
run_cli identity --help >"$work_dir/help.txt"
grep -q 'wrtbak identity --json' "$work_dir/help.txt"

if run_cli identity --bogus >"$work_dir/unknown.out" 2>"$work_dir/unknown.err"; then
	echo "identity should reject unknown arguments" >&2
	exit 1
fi
grep -q 'unknown identity argument: --bogus' "$work_dir/unknown.err"

if run_cli identity >"$work_dir/no-args.out" 2>"$work_dir/no-args.err"; then
	echo "identity should require --json" >&2
	exit 1
fi
grep -q 'identity requires --json' "$work_dir/no-args.err"

echo "fixture identity test passed"
