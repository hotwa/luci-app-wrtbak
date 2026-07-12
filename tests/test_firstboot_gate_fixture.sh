#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
init_script="$repo_dir/root/etc/init.d/wrtbak-firstboot-auto"

[ -x "$init_script" ] || {
	echo "wrtbak firstboot init script is missing or not executable" >&2
	exit 1
}

grep -Fq 'GATE_FILE=${WRTBAK_FIRSTBOOT_GATE_FILE:-$LOG_DIR/gate.json}' "$init_script" || {
	echo "firstboot init does not expose the recovery gate receipt" >&2
	exit 1
}

grep -Fq 'wrtbak_auto_write_gate pending' "$init_script" || {
	echo "firstboot init does not close the gate before recovery" >&2
	exit 1
}

for state in disabled already_done restored reboot_pending no_backup failed_final; do
	grep -Fq "wrtbak_auto_write_gate $state" "$init_script" || {
		echo "firstboot init does not emit terminal state: $state" >&2
		exit 1
	}
done

grep -Fq 'mv -f "$gate_tmp" "$GATE_FILE"' "$init_script" || {
	echo "firstboot gate receipt is not written atomically" >&2
	exit 1
}

grep -Fq 'chmod 600 "$GATE_FILE"' "$init_script" || {
	echo "firstboot gate receipt is not restricted to root" >&2
	exit 1
}

grep -Fq 'wrtbak_auto_write_gate no_backup no_current_device_backup' "$init_script" || {
	echo "firstboot init cannot distinguish no-backup exhaustion" >&2
	exit 1
}

echo "firstboot recovery gate fixture passed"
