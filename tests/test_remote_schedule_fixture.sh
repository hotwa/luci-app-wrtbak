#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-schedule-test.XXXXXX")
fixture_root="$work_dir/root"
bin_dir="$work_dir/bin"
libdir="$repo_dir/root/usr/lib/wrtbak"
cli="$repo_dir/root/usr/bin/wrtbak"
cron_file="$fixture_root/etc/crontabs/root"

cleanup() {
	rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$bin_dir" "$fixture_root/etc/config" "$fixture_root/etc/crontabs" "$fixture_root/etc"
cat >"$bin_dir/rclone" <<'EOT'
#!/bin/sh
exit 0
EOT
chmod +x "$bin_dir/rclone"

cat >"$fixture_root/etc/config/system" <<'EOT'
config system
	option hostname 'fixture-router'
EOT
cat >"$fixture_root/etc/board.json" <<'EOT'
{"model":{"id":"test-board-id","name":"Test Board Model"}}
EOT
printf 'fixture-machine-id' >"$fixture_root/etc/machine-id"

write_config() {
	enabled=$1
	frequency=$2
	time_value=$3
	weekday=$4
	day_value=$5
	items=$6
	default_target=${7:-s3}
	cat >"$fixture_root/etc/config/wrtbak" <<EOT
config wrtbak 'main'
	option enabled '1'
	option output_dir '$work_dir/output'
	option default_target '$default_target'
	option history_file '/overlay/wrtbak/remote-history.jsonl'
	option keep_local_after_upload '0'

config remote 's3'
	option enabled '1'
	option driver 'rclone'
	option endpoint 'https://s3.example.invalid'
	option region 'us-east-1'
	option bucket 'bucket-a'
	option access_key 's3-access-value'
	option secret_key 's3-secret-value'
	option path '/backups/'
	option force_path_style '1'

config schedule 'auto'
	option enabled '$enabled'
	option frequency '$frequency'
	option time '$time_value'
	option weekday '$weekday'
	option day_of_month '$day_value'
	option profile 'auto'
	option items '$items'
	option format 'wrtbak'
	option max_backups '2'
	option target 'default'
EOT
}

run_cli() {
	PATH="$bin_dir:/usr/bin:/bin" \
	WRTBAK_ROOT="$fixture_root" \
	WRTBAK_LIBDIR="$libdir" \
	WRTBAK_SKIP_CRON_RELOAD=1 \
		"$cli" "$@"
}

run_cli_no_rclone() {
	PATH="/usr/bin:/bin" \
	WRTBAK_ROOT="$fixture_root" \
	WRTBAK_LIBDIR="$libdir" \
	WRTBAK_SKIP_CRON_RELOAD=1 \
		"$cli" "$@"
}

write_config 0 daily 03:30 0 1 all
run_cli schedule-apply --json >"$work_dir/disabled.json"
python3 - "$work_dir/disabled.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
assert data["ok"] is True
assert data["operation"] == "schedule-apply"
assert data["enabled"] is False
assert data["action"] == "unchanged"
assert data["cron_installed"] is False
PY

echo '5 1 * * * echo keep' >"$cron_file"
{
	echo '# wrtbak auto backup begin'
	echo '30 3 * * * /usr/bin/wrtbak old-command'
	echo '# wrtbak auto backup end'
} >>"$cron_file"
run_cli schedule-apply --json >"$work_dir/disabled-remove.json"
if grep -q 'old-command\|wrtbak auto backup' "$cron_file"; then
	echo "disabled schedule should remove wrtbak block" >&2
	exit 1
fi
grep -q 'echo keep' "$cron_file"

write_config 1 daily 03:30 0 1 all
run_cli schedule-apply --json >"$work_dir/daily.json"
python3 - "$work_dir/daily.json" "$cron_file" <<'PY'
import json, pathlib, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
cron = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
assert data["ok"] is True
assert data["enabled"] is True
assert data["action"] in {"installed", "updated"}
assert data["cron_installed"] is True
assert "30 3 * * *" in cron
assert "remote-upload" in cron
assert "--target 'default'" in cron
assert "--profile 'auto'" in cron
assert "--items 'all'" in cron
assert "--format 'wrtbak'" in cron
assert "--prune-max '2'" in cron
assert "s3-access-value" not in cron
assert "s3-secret-value" not in cron
PY

run_cli schedule-status --json >"$work_dir/status.json"
run_cli remote-status --json >"$work_dir/remote-status.json"
python3 - "$work_dir/status.json" "$work_dir/remote-status.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    status = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    remote = json.load(handle)
assert status["ok"] is True
assert status["schedule"]["cron_installed"] is True
assert "remote-upload" in status["schedule"]["cron_command"]
assert remote["schedule"]["cron_installed"] is True
PY

write_config 1 weekly 04:05 2 1 all
run_cli schedule-apply --json >/dev/null
grep -q '^5 4 \* \* 2 ' "$cron_file"

write_config 1 monthly 06:07 0 15 all
run_cli schedule-apply --json >/dev/null
grep -q '^7 6 15 \* \* ' "$cron_file"

write_config 1 daily 25:99 0 1 all
if run_cli schedule-apply --json >"$work_dir/invalid.json"; then
	echo "invalid schedule should fail" >&2
	exit 1
fi
python3 - "$work_dir/invalid.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
assert data["ok"] is False
assert data["operation"] == "schedule-apply"
assert data["code"] == "invalid_config"
PY

write_config 1 daily 03:30 0 1 all
if run_cli_no_rclone schedule-apply --json >"$work_dir/missing-dep.json"; then
	echo "missing rclone should fail" >&2
	exit 1
fi
python3 - "$work_dir/missing-dep.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
assert data["ok"] is False
assert data["code"] == "missing_dependency"
PY

write_config 1 daily 03:30 0 1 current
run_cli schedule-apply --json >/dev/null
if grep -q -- "--items 'current'" "$cron_file"; then
	echo "current item selection should be snapshotted" >&2
	exit 1
fi
grep -q -- "--items 'core-system,network" "$cron_file"

echo "fixture remote schedule test passed"