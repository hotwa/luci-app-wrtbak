#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-agent-status-test.XXXXXX")
fixture_root="$work_dir/root"
bin_dir="$work_dir/bin"
output_dir="$work_dir/output"
libdir="$repo_dir/root/usr/lib/wrtbak"
cli="$repo_dir/root/usr/bin/wrtbak"

cleanup() {
	rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$bin_dir" "$fixture_root/etc/config" "$output_dir"

cat >"$bin_dir/apk" <<'EOT'
#!/bin/sh
if [ "$1" = "info" ]; then
	cat <<'EOF'
luci-app-mosdns
luci-app-nikki
nikki
EOF
	exit 0
fi
exit 1
EOT
chmod +x "$bin_dir/apk"

cat >"$fixture_root/etc/config/wrtbak" <<EOT
config wrtbak 'main'
	option output_dir '$output_dir'
	option default_mode 'review-required'
EOT

cat >"$fixture_root/etc/config/system" <<'EOT'
config system
	option hostname 'agent-router'
EOT

cat >"$fixture_root/etc/config/network" <<'EOT'
config interface 'lan'
	option proto 'static'
	option ipaddr '192.0.2.234'
EOT

cat >"$fixture_root/etc/openwrt_release" <<'EOT'
DISTRIB_ID='ImmortalWrt'
DISTRIB_RELEASE='SNAPSHOT'
DISTRIB_REVISION='r0-test'
DISTRIB_TARGET='qualcommax/ipq60xx'
DISTRIB_ARCH='aarch64_cortex-a53'
EOT

cat >"$output_dir/agent-router-old.wrtbak" <<'EOT'
placeholder archive path only
EOT

PATH="$bin_dir:$PATH" \
WRTBAK_ROOT="$fixture_root" \
WRTBAK_LIBDIR="$libdir" \
	"$cli" status --json >"$work_dir/status.json"

python3 - "$work_dir/status.json" "$fixture_root" "$libdir" "$output_dir" <<'PY'
import json
import sys

status_path, fixture_root, libdir, output_dir = sys.argv[1:]
with open(status_path, encoding="utf-8") as handle:
    data = json.load(handle)

assert data["tool_version"] == "0.1.0"
assert data["root"] == fixture_root
assert data["libdir"] == libdir
assert data["package_manager"] == "apk"
assert data["paths_file"].endswith("/paths.default")
assert data["output_dir"] == output_dir
assert data["device"]["hostname"] == "agent-router"
assert data["device"]["management_ip"] == "192.0.2.234"
assert data["firmware"]["distribution"] == "ImmortalWrt"
assert data["firmware"]["target"] == "qualcommax/ipq60xx"
assert data["counts"]["detected_items"] >= 3
assert data["counts"]["installed_items"] >= 2
assert data["counts"]["recent_backups"] == 1
assert data["recent_backups"][0]["filename"] == "agent-router-old.wrtbak"
assert "placeholder archive path only" not in json.dumps(data)
PY

PATH="$bin_dir:$PATH" \
WRTBAK_ROOT="$fixture_root" \
WRTBAK_LIBDIR="$libdir" \
	"$cli" doctor --json >"$work_dir/doctor.json"

python3 - "$work_dir/doctor.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

checks = {check["name"]: check for check in data["checks"]}
for required in [
    "libdir",
    "paths_file",
    "output_dir",
    "package_manager",
    "archive_tools",
]:
    assert required in checks, required
    assert isinstance(checks[required]["ok"], bool)
    assert checks[required]["detail"]

assert data["ok"] is True
PY

echo "fixture agent status and doctor test passed"
