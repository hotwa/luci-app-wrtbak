#!/bin/sh

wrtbak_restore_error_json() {
	wrtbak_operation=$1
	wrtbak_code=$2
	wrtbak_message=$3
	wrtbak_detail=${4:-}
	printf '{\n'
	printf '  "ok": false,\n'
	printf '  "operation": '; wrtbak_json_string "$wrtbak_operation"; printf ',\n'
	printf '  "code": '; wrtbak_json_string "$wrtbak_code"; printf ',\n'
	printf '  "message": '; wrtbak_json_string "$wrtbak_message"; printf ',\n'
	printf '  "detail": '; wrtbak_json_string "$wrtbak_detail"; printf '\n'
	printf '}\n'
}

wrtbak_restore_invalid_json() {
	wrtbak_operation=$1
	wrtbak_code=$2
	wrtbak_message=$3
	wrtbak_value=${4:-}
	wrtbak_restore_error_json "$wrtbak_operation" "$wrtbak_code" "$wrtbak_message" "$wrtbak_value"
	return 1
}

wrtbak_restore_validate_input_path() {
	wrtbak_operation=$1
	wrtbak_input=$2
	wrtbak_expected=$3
	wrtbak_restore_invalid_json "$wrtbak_operation" not_implemented "Local Archive Path Policy is not implemented" "$wrtbak_expected:$wrtbak_input"
}

wrtbak_restore_validate_prebackup_path() {
	wrtbak_operation=$1
	wrtbak_prebackup=$2
	wrtbak_restore_invalid_json "$wrtbak_operation" not_implemented "prebackup path validation is not implemented" "$wrtbak_prebackup"
}

wrtbak_restore_prepare() {
	wrtbak_restore_error_json restore-prepare not_implemented "restore-prepare is not implemented" ""
	return 1
}

wrtbak_restore_prebackup() {
	wrtbak_restore_error_json restore-prebackup not_implemented "restore-prebackup is not implemented" ""
	return 1
}

wrtbak_restore_apply() {
	wrtbak_restore_error_json restore-apply not_implemented "restore-apply is not implemented" ""
	return 1
}

wrtbak_restore_sysupgrade() {
	wrtbak_restore_error_json restore-sysupgrade not_implemented "restore-sysupgrade is not implemented" ""
	return 1
}
