#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-proxy-dae-test.XXXXXX")
fixture_root="$work_dir/root"
bin_dir="$work_dir/bin"
libdir="$repo_dir/root/usr/lib/wrtbak"
cli="$repo_dir/root/usr/bin/wrtbak"
remote_store="$work_dir/remote-store"

cleanup() {
	rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p \
	"$fixture_root/etc/config" \
	"$fixture_root/etc/dae" \
	"$fixture_root/etc/init.d" \
	"$fixture_root/tmp/sysinfo" \
	"$fixture_root/sys/class/net/br-lan" \
	"$fixture_root/overlay/wrtbak/proxy-rollback" \
	"$fixture_root/overlay/wrtbak/proxy-receipts" \
	"$fixture_root/tmp/wrtbak/proxy-cache" \
	"$bin_dir" \
	"$remote_store"

cat >"$fixture_root/etc/config/wrtbak" <<'EOT'
config wrtbak 'main'
	option enabled '1'
	option default_target 's3'
	option device_alias 'office-re-ss-01-test'
	option site 'office'
	option proxy_artifacts_enabled '1'
	option proxy_update_mode 'review-required'

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
printf 'previous-dae-config\n' >"$fixture_root/etc/dae/final.yaml"

cat >"$fixture_root/etc/init.d/daed" <<'EOT'
#!/bin/sh
target="${WRTBAK_ROOT%/}/etc/dae/final.yaml"
case "$1" in
	restart)
		printf 'restart\n' >> "${WRTBAK_ROOT%/}/tmp/wrtbak/dae-service.log"
		exit 0
		;;
	status)
		if [ -f "$target" ] && grep -q 'bad-dae-config' "$target"; then
			printf 'not running\n'
			exit 1
		fi
		printf 'running\n'
		exit 0
		;;
	stop)
		printf 'stop\n' >> "${WRTBAK_ROOT%/}/tmp/wrtbak/dae-service.log"
		exit 0
		;;
	*)
		exit 2
		;;
esac
EOT
chmod +x "$fixture_root/etc/init.d/daed"

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

cat >"$bin_dir/rclone" <<'EOT'
#!/bin/sh
previous=
command=
operand_count=0
copy_source=
copy_dest=
remote_ref=
for arg in "$@"; do
	if [ "$previous" = "--config" ]; then
		previous=$arg
		continue
	fi
	if [ -z "$command" ] && [ "$arg" != "--config" ]; then
		command=$arg
		previous=$arg
		continue
	fi
	case "$arg" in
		--*)
			previous=$arg
			continue
			;;
	esac
	if [ -n "$command" ]; then
		operand_count=$((operand_count + 1))
		if [ "$operand_count" -eq 1 ]; then
			copy_source=$arg
		elif [ "$operand_count" -eq 2 ]; then
			copy_dest=$arg
		fi
	fi
	case "$arg" in
		wrtbak_remote:*)
			remote_ref=$arg
			;;
	esac
	previous=$arg
done

remote_key() {
	case "$1" in
		wrtbak_remote:knowledge/*)
			printf '%s\n' "${1#wrtbak_remote:knowledge/}"
			;;
		*)
			return 1
			;;
	esac
}

store_path() {
	key=$(remote_key "$1") || return 1
	printf '%s/%s\n' "${WRTBAK_FAKE_REMOTE_STORE%/}" "$key"
}

case "$command" in
	copyto)
		case "$copy_source" in
			wrtbak_remote:*)
				source_path=$(store_path "$copy_source") || exit 46
				cp "$source_path" "$copy_dest" || exit 47
				;;
			*)
				destination_path=$(store_path "$copy_dest") || exit 46
				mkdir -p "$(dirname -- "$destination_path")" || exit 47
				cp "$copy_source" "$destination_path" || exit 47
				;;
		esac
		exit 0
		;;
	lsjson)
		stat_path=$(store_path "$remote_ref") || exit 46
		[ -f "$stat_path" ] || exit 47
		stat_key=$(remote_key "$remote_ref")
		stat_name=$(basename -- "$stat_key")
		stat_size=$(stat -c '%s' "$stat_path")
		cat <<JSON
[
  {
    "Path": "$stat_key",
    "Name": "$stat_name",
    "Size": $stat_size,
    "ModTime": "2026-07-03T00:00:00Z",
    "ETag": "fixture-etag"
  }
]
JSON
		exit 0
		;;
	*)
		exit 48
		;;
esac
EOT
chmod +x "$bin_dir/rclone"

cat >"$bin_dir/logread" <<'EOT'
#!/bin/sh
target="${WRTBAK_ROOT%/}/etc/dae/final.yaml"
if [ -f "$target" ] && grep -q 'log-error-dae-config' "$target"; then
	printf 'daemon.err daed: failed to load dae config\n'
fi
EOT
chmod +x "$bin_dir/logread"

write_proxy_artifact() {
	scope=$1
	scope_value=$2
	content=$3
	case "$scope" in
		shared)
			prefix="openwrt-config-backup/wrtbak/proxy/shared/dae"
			manifest_scope=shared
			manifest_site=
			manifest_uid=
			;;
		sites)
			prefix="openwrt-config-backup/wrtbak/proxy/sites/$scope_value/dae"
			manifest_scope=site
			manifest_site=$scope_value
			manifest_uid=
			;;
		devices)
			prefix="openwrt-config-backup/wrtbak/proxy/devices/$scope_value/dae"
			manifest_scope=device
			manifest_site=
			manifest_uid=$scope_value
			;;
	esac
	artifact="$remote_store/$prefix/final.dae"
	manifest="$remote_store/$prefix/latest.json"
	mkdir -p "$(dirname -- "$artifact")"
	printf '%s\n' "$content" >"$artifact"
	sha=$(sha256sum "$artifact" | awk '{ print $1 }')
	size=$(stat -c '%s' "$artifact")
	cat >"$manifest" <<EOT
{
  "schema": "wrtbak/proxy-artifact/v1",
  "proxy": "dae",
  "scope": "$manifest_scope",
  "site": "$manifest_site",
  "device_uid": "$manifest_uid",
  "artifact_path": "$prefix/final.dae",
  "target_path": "/etc/dae/final.yaml",
  "sha256": "$sha",
  "size": $size,
  "created_at": "2026-07-03T00:00:00Z",
  "source": {
    "repo": "nikki-sub-merge",
    "output": "output/final.dae"
  }
}
EOT
}

device_uid="jdcloud-re-ss-01-14c4a35ee8"
write_proxy_artifact shared "" "shared-dae-config"
write_proxy_artifact sites office "office-dae-config"
write_proxy_artifact devices "$device_uid" "device-dae-config"

run_cli() {
	PATH="$bin_dir:$PATH" \
	WRTBAK_ROOT="$fixture_root" \
	WRTBAK_LIBDIR="$libdir" \
	WRTBAK_FAKE_REMOTE_STORE="$remote_store" \
		"$cli" "$@"
}

candidate_path="openwrt-config-backup/wrtbak/proxy/devices/$device_uid/dae/latest.json"

run_cli proxy-candidates --target default --proxy dae --json >"$work_dir/candidates.json"
python3 - "$work_dir/candidates.json" "$candidate_path" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
expected = sys.argv[2]
assert data["ok"] is True, data
assert data["operation"] == "proxy-candidates", data
assert data["proxy"] == "dae", data
assert data["selected"]["scope"] == "device", data
assert data["selected"]["manifest_path"] == expected, data
assert [item["scope"] for item in data["candidates"]] == ["device", "site", "shared"], data
encoded = json.dumps(data)
assert "secret-key-value" not in encoded
assert "access-key-value" not in encoded
PY

run_cli proxy-prepare --target default --proxy dae --path "$candidate_path" --json >"$work_dir/prepare.json"
artifact_path=$(python3 - "$work_dir/prepare.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["ok"] is True, data
assert data["operation"] == "proxy-prepare", data
assert data["proxy"] == "dae", data
assert data["manifest"]["scope"] == "device", data
assert data["manifest"]["target_path"] == "/etc/dae/final.yaml", data
assert data["artifact"]["sha256"] == data["manifest"]["sha256"], data
print(data["artifact"]["local_path"])
PY
)
manifest_path=$(python3 - "$work_dir/prepare.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
print(data["manifest"]["local_path"])
PY
)

run_cli proxy-apply --proxy dae --input "$artifact_path" --manifest "$manifest_path" --confirm APPLY --json >"$work_dir/apply-good.json"
python3 - "$work_dir/apply-good.json" "$fixture_root" <<'PY'
import json
import pathlib
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
root = pathlib.Path(sys.argv[2])
assert data["ok"] is True, data
assert data["operation"] == "proxy-apply", data
assert data["proxy"] == "dae", data
assert data["health"]["ok"] is True, data
assert (root / "etc/dae/final.yaml").read_text() == "device-dae-config\n"
assert "restart" in (root / "tmp/wrtbak/dae-service.log").read_text()
assert data["receipt_path"].endswith("/overlay/wrtbak/proxy-receipts/dae.json"), data
PY

bad_artifact="$work_dir/bad-final.dae"
bad_manifest="$work_dir/bad-latest.json"
printf 'bad-dae-config\n' >"$bad_artifact"
bad_sha=$(sha256sum "$bad_artifact" | awk '{ print $1 }')
bad_size=$(stat -c '%s' "$bad_artifact")
cat >"$bad_manifest" <<EOT
{
  "schema": "wrtbak/proxy-artifact/v1",
  "proxy": "dae",
  "scope": "shared",
  "site": "",
  "device_uid": "",
  "artifact_path": "openwrt-config-backup/wrtbak/proxy/shared/dae/final.dae",
  "target_path": "/etc/dae/final.yaml",
  "sha256": "$bad_sha",
  "size": $bad_size,
  "created_at": "2026-07-03T01:00:00Z",
  "source": {
    "repo": "nikki-sub-merge",
    "output": "output/final.dae"
  }
}
EOT

if run_cli proxy-apply --proxy dae --input "$bad_artifact" --manifest "$bad_manifest" --confirm APPLY --json >"$work_dir/apply-bad.json"; then
	echo "bad DAE artifact unexpectedly applied" >&2
	exit 1
fi
python3 - "$work_dir/apply-bad.json" "$fixture_root" <<'PY'
import json
import pathlib
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
root = pathlib.Path(sys.argv[2])
assert data["ok"] is False, data
assert data["operation"] == "proxy-apply", data
assert data["proxy"] == "dae", data
assert data["code"] == "health_check_failed", data
assert data["health"]["reason"] == "service_status", data
assert data["rollback"]["ok"] is True, data
assert data["rollback"]["action"] == "restored_previous", data
assert (root / "etc/dae/final.yaml").read_text() == "device-dae-config\n"
PY

log_error_artifact="$work_dir/log-error-final.dae"
log_error_manifest="$work_dir/log-error-latest.json"
printf 'log-error-dae-config\n' >"$log_error_artifact"
log_error_sha=$(sha256sum "$log_error_artifact" | awk '{ print $1 }')
log_error_size=$(stat -c '%s' "$log_error_artifact")
cat >"$log_error_manifest" <<EOT
{
  "schema": "wrtbak/proxy-artifact/v1",
  "proxy": "dae",
  "scope": "shared",
  "site": "",
  "device_uid": "",
  "artifact_path": "openwrt-config-backup/wrtbak/proxy/shared/dae/final.dae",
  "target_path": "/etc/dae/final.yaml",
  "sha256": "$log_error_sha",
  "size": $log_error_size,
  "created_at": "2026-07-03T01:30:00Z",
  "source": {
    "repo": "nikki-sub-merge",
    "output": "output/final.dae"
  }
}
EOT

if run_cli proxy-apply --proxy dae --input "$log_error_artifact" --manifest "$log_error_manifest" --confirm APPLY --json >"$work_dir/apply-log-error.json"; then
	echo "DAE artifact with error logs unexpectedly applied" >&2
	exit 1
fi
python3 - "$work_dir/apply-log-error.json" "$fixture_root" <<'PY'
import json
import pathlib
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
root = pathlib.Path(sys.argv[2])
assert data["ok"] is False, data
assert data["code"] == "health_check_failed", data
assert data["health"]["reason"] == "log_failure", data
assert data["rollback"]["ok"] is True, data
assert (root / "etc/dae/final.yaml").read_text() == "device-dae-config\n"
PY

rm -f "$fixture_root/etc/dae/final.yaml"
if run_cli proxy-apply --proxy dae --input "$bad_artifact" --manifest "$bad_manifest" --confirm APPLY --json >"$work_dir/apply-bad-no-previous.json"; then
	echo "bad DAE artifact without previous config unexpectedly applied" >&2
	exit 1
fi
python3 - "$work_dir/apply-bad-no-previous.json" "$fixture_root" <<'PY'
import json
import pathlib
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
root = pathlib.Path(sys.argv[2])
assert data["ok"] is False, data
assert data["code"] == "health_check_failed", data
assert data["rollback"]["ok"] is False, data
assert data["rollback"]["action"] == "service_stopped", data
assert not (root / "etc/dae/final.yaml").exists()
assert "stop" in (root / "tmp/wrtbak/dae-service.log").read_text()
PY

echo "DAE proxy artifact fixture passed"
