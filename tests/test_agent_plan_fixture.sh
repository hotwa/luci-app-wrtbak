#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-agent-plan-test.XXXXXX")
fixture_root="$work_dir/root"
libdir="$repo_dir/root/usr/lib/wrtbak"
cli="$repo_dir/root/usr/bin/wrtbak"

cleanup() {
	rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$fixture_root/etc/config"

cat >"$fixture_root/etc/config/system" <<'EOT'
config system
	option hostname 'agent-plan-router'
EOT

cat >"$fixture_root/etc/config/nikki" <<'EOT'
config nikki 'config'
	option enabled '1'
	option secret 'do-not-print-this'
EOT

assert_reject() {
	if "$@" >"$work_dir/reject.out" 2>"$work_dir/reject.err"; then
		echo "expected command to fail: $*" >&2
		cat "$work_dir/reject.out" >&2
		cat "$work_dir/reject.err" >&2
		exit 1
	fi
}

WRTBAK_ROOT="$fixture_root" \
WRTBAK_LIBDIR="$libdir" \
	"$cli" plan --profile agent-test --items core-system,nikki --format wrtbak --json >"$work_dir/plan.json"

python3 - "$work_dir/plan.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

assert data["profile"] == "agent-test"
assert data["format"] == "wrtbak"

items = {item["id"]: item for item in data["items"]}
assert set(items) == {"core-system", "nikki"}
assert items["core-system"]["known"] is True
assert items["core-system"]["sensitive"] is False
assert items["nikki"]["known"] is True
assert items["nikki"]["sensitive"] is True
assert "/etc/config/nikki" in items["nikki"]["paths"]
assert "/etc/nikki" in items["nikki"]["paths"]

paths = {(entry["item_id"], entry["path"]): entry for entry in data["paths"]}
assert paths[("core-system", "/etc/config/system")]["exists"] is True
assert paths[("core-system", "/etc/config/system")]["type"] == "file"
assert paths[("nikki", "/etc/config/nikki")]["exists"] is True
assert paths[("nikki", "/etc/nikki")]["exists"] is False
assert paths[("nikki", "/etc/nikki")]["type"] == "missing"

assert data["summary"]["requested_items"] == 2
assert data["summary"]["existing_paths"] == 2
assert data["summary"]["missing_paths"] == 1
assert data["summary"]["sensitive_items"] == 1

warning_codes = {warning["code"] for warning in data["warnings"]}
assert "sensitive_item" in warning_codes
assert "missing_path" in warning_codes
assert "do-not-print-this" not in json.dumps(data)
PY

WRTBAK_ROOT="$fixture_root" \
WRTBAK_LIBDIR="$libdir" \
	"$cli" plan --profile agent-test --items all --format sysupgrade --json >"$work_dir/plan-all.json"

python3 - "$work_dir/plan-all.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

ids = {item["id"] for item in data["items"]}
assert data["format"] == "sysupgrade"
assert "core-system" in ids
assert "network" in ids
assert "wireless" in ids
assert data["summary"]["requested_items"] == len(ids)
PY

assert_reject env WRTBAK_ROOT="$fixture_root" WRTBAK_LIBDIR="$libdir" \
	"$cli" plan --profile '../bad' --items core-system --format wrtbak --json

assert_reject env WRTBAK_ROOT="$fixture_root" WRTBAK_LIBDIR="$libdir" \
	"$cli" plan --profile agent-test --items 'core-system;/bin/sh' --format wrtbak --json

assert_reject env WRTBAK_ROOT="$fixture_root" WRTBAK_LIBDIR="$libdir" \
	"$cli" plan --profile agent-test --items core-system --format zip --json

echo "fixture agent backup plan test passed"
