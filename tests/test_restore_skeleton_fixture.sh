#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-restore-skeleton-test.XXXXXX")
fixture_root="$work_dir/root"
libdir="$repo_dir/root/usr/lib/wrtbak"
cli="$repo_dir/root/usr/bin/wrtbak"

cleanup() {
	rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$fixture_root/etc/config" "$fixture_root/tmp/sysinfo" "$fixture_root/sys/class/net/br-lan"
cat >"$fixture_root/etc/config/wrtbak" <<'EOT'
config wrtbak 'main'
EOT
printf 'Restore Skeleton Board\n' >"$fixture_root/tmp/sysinfo/board_name"
printf '02:11:22:33:44:55\n' >"$fixture_root/sys/class/net/br-lan/address"
mkdir -p "$fixture_root/tmp/wrtbak/restore-cache" "$fixture_root/tmp/wrtbak"
printf 'placeholder\n' >"$fixture_root/tmp/wrtbak/restore-cache/sample.wrtbak"
printf 'placeholder\n' >"$fixture_root/tmp/wrtbak/restore-cache/sample.sysupgrade.tar.gz"
printf 'placeholder\n' >"$fixture_root/tmp/wrtbak/pre-restore-sample.wrtbak"

run_cli() {
	WRTBAK_ROOT="$fixture_root" \
	WRTBAK_LIBDIR="$libdir" \
		"$cli" "$@"
}

assert_skeleton_json() {
	output_file=$1
	operation=$2
	python3 - "$output_file" "$operation" <<'PY'
import json
import sys

path, operation = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)

assert data["ok"] is False
assert data["operation"] == operation
assert data["code"] == "not_implemented"
PY
}

assert_skeleton_command() {
	operation=$1
	output_file="$work_dir/$operation.json"
	shift

	if run_cli "$@" >"$output_file"; then
		echo "expected $operation skeleton command to fail" >&2
		cat "$output_file" >&2
		exit 1
	fi

	assert_skeleton_json "$output_file" "$operation"
}

assert_error_code() {
	output_file=$1
	operation=$2
	code=$3
	python3 - "$output_file" "$operation" "$code" <<'PY'
import json
import sys

path, operation, code = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)

assert data["ok"] is False
assert data["operation"] == operation
assert data["code"] == code
PY
}

prepare_output="$work_dir/restore-prepare-invalid.json"
if run_cli restore-prepare --input /tmp/wrtbak/restore-cache/missing.wrtbak --json >"$prepare_output"; then
	echo "expected restore-prepare invalid path command to fail" >&2
	cat "$prepare_output" >&2
	exit 1
fi
assert_error_code "$prepare_output" restore-prepare invalid_input_path

prebackup_output="$work_dir/restore-prebackup.json"
run_cli restore-prebackup --profile pre-restore --items all --format wrtbak --json >"$prebackup_output"
python3 - "$prebackup_output" "$fixture_root" <<'PY'
import json
import os
import sys

path, fixture_root = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)

assert data["ok"] is True
assert data["operation"] == "restore-prebackup"
assert data["path"].startswith("/tmp/wrtbak/pre-restore-")
assert os.path.isfile(fixture_root + data["path"])
assert os.path.isfile(fixture_root + data["receipt_path"])
PY

apply_output="$work_dir/restore-apply-invalid-prebackup.json"
if run_cli restore-apply --input /tmp/wrtbak/restore-cache/sample.wrtbak --mode all --items all --prebackup /tmp/wrtbak/pre-restore-sample.wrtbak --confirm RESTORE --restart-services 0 --json >"$apply_output"; then
	echo "expected restore-apply invalid prebackup command to fail" >&2
	cat "$apply_output" >&2
	exit 1
fi
assert_error_code "$apply_output" restore-apply invalid_prebackup

sysupgrade_output="$work_dir/restore-sysupgrade-invalid-prebackup.json"
if run_cli restore-sysupgrade --input /tmp/wrtbak/restore-cache/sample.sysupgrade.tar.gz --prebackup /tmp/wrtbak/pre-restore-sample.wrtbak --confirm RESTORE --execute 0 --json >"$sysupgrade_output"; then
	echo "expected restore-sysupgrade invalid prebackup command to fail" >&2
	cat "$sysupgrade_output" >&2
	exit 1
fi
assert_error_code "$sysupgrade_output" restore-sysupgrade invalid_prebackup

echo "fixture restore skeleton command test passed"
