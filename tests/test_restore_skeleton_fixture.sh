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

mkdir -p "$fixture_root/etc/config"
cat >"$fixture_root/etc/config/wrtbak" <<'EOT'
config wrtbak 'main'
EOT

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

assert_skeleton_command restore-prepare \
	restore-prepare --input /tmp/wrtbak/restore-cache/missing.wrtbak --json
assert_skeleton_command restore-prebackup \
	restore-prebackup --profile pre-restore --items all --format wrtbak --json
assert_skeleton_command restore-apply \
	restore-apply --input /tmp/wrtbak/restore-cache/missing.wrtbak --mode all --items all --prebackup /tmp/wrtbak/pre-restore-missing.wrtbak --confirm RESTORE --restart-services 0 --json
assert_skeleton_command restore-sysupgrade \
	restore-sysupgrade --input /tmp/wrtbak/restore-cache/missing.sysupgrade.tar.gz --prebackup /tmp/wrtbak/pre-restore-missing.wrtbak --confirm RESTORE --execute 0 --json

echo "fixture restore skeleton command test passed"
