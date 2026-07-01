#!/bin/sh

wrtbak_firstboot_logical_dir() {
	printf '%s\n' '/root/wrtbak/firstboot'
}

wrtbak_firstboot_done_logical_path() {
	printf '%s\n' "$(wrtbak_firstboot_logical_dir)/done.json"
}

wrtbak_firstboot_receipts_logical_dir() {
	printf '%s\n' "$(wrtbak_firstboot_logical_dir)/receipts"
}

wrtbak_firstboot_error_json() {
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

wrtbak_firstboot_lan_ip() {
	wrtbak_ip_line=$(ip -4 -o addr show br-lan 2>/dev/null | sed -n '1p' || true)
	wrtbak_lan_ip=$(printf '%s\n' "$wrtbak_ip_line" | sed -n 's/.* inet \([0-9.][0-9.]*\)\/.*/\1/p')
	if [ -n "$wrtbak_lan_ip" ]; then
		printf '%s\n' "$wrtbak_lan_ip"
		return 0
	fi

	wrtbak_route_line=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n '1p' || true)
	wrtbak_lan_ip=$(printf '%s\n' "$wrtbak_route_line" | sed -n 's/.* src \([0-9.][0-9.]*\).*/\1/p')
	[ -n "$wrtbak_lan_ip" ] || return 1
	printf '%s\n' "$wrtbak_lan_ip"
}

wrtbak_firstboot_local_url() {
	wrtbak_lan_ip=$(wrtbak_firstboot_lan_ip 2>/dev/null || printf '')
	if [ -n "$wrtbak_lan_ip" ]; then
		printf 'http://%s/cgi-bin/luci/admin/system/wrtbak\n' "$wrtbak_lan_ip"
	else
		printf 'http://openwrt.lan/cgi-bin/luci/admin/system/wrtbak\n'
	fi
}

wrtbak_firstboot_qr_svg() {
	wrtbak_url=$1
	if command -v qrencode >/dev/null 2>&1; then
		qrencode -t SVG -o - "$wrtbak_url" 2>/dev/null | tr '\n' ' '
		return 0
	fi
	return 1
}

wrtbak_firstboot_bool_command() {
	if "$@" >/dev/null 2>&1; then
		printf 'true\n'
	else
		printf 'false\n'
	fi
}

wrtbak_firstboot_network_json() {
	wrtbak_lan_ip=$(wrtbak_firstboot_lan_ip 2>/dev/null || printf '')
	wrtbak_default_route=$(wrtbak_firstboot_bool_command ip route show default)
	wrtbak_dns=$(wrtbak_firstboot_bool_command nslookup cloudflare.com)
	wrtbak_year=$(date -u '+%Y' 2>/dev/null || printf '1970')

	case "$wrtbak_year" in
		20[2-9][0-9])
			wrtbak_time=true
			;;
		*)
			wrtbak_time=false
			;;
	esac

	printf '{\n'
	printf '    "lan_ip": '; wrtbak_json_string "$wrtbak_lan_ip"; printf ',\n'
	printf '    "default_route": '; wrtbak_json_bool "$wrtbak_default_route"; printf ',\n'
	printf '    "dns": '; wrtbak_json_bool "$wrtbak_dns"; printf ',\n'
	printf '    "time": '; wrtbak_json_bool "$wrtbak_time"; printf '\n'
	printf '  }'
}

wrtbak_firstboot_done_marker_json() {
	wrtbak_done_logical=$(wrtbak_firstboot_done_logical_path)
	wrtbak_done_actual=$(wrtbak_root_path "$wrtbak_done_logical")
	wrtbak_current_uid=${1:-}

	if [ ! -f "$wrtbak_done_actual" ] || [ -L "$wrtbak_done_actual" ]; then
		printf '{ "exists": false, "status": "missing", "path": '
		wrtbak_json_string "$wrtbak_done_logical"
		printf ' }'
		return 0
	fi

	wrtbak_done_uid=$(wrtbak_jsonfilter_value "$wrtbak_done_actual" '@.device_uid' "")
	if [ -n "$wrtbak_current_uid" ] && [ "$wrtbak_done_uid" = "$wrtbak_current_uid" ]; then
		wrtbak_done_status=ok
	else
		wrtbak_done_status=uid_mismatch
	fi

	printf '{\n'
	printf '    "exists": true,\n'
	printf '    "status": '; wrtbak_json_string "$wrtbak_done_status"; printf ',\n'
	printf '    "path": '; wrtbak_json_string "$wrtbak_done_logical"; printf ',\n'
	printf '    "device_uid": '; wrtbak_json_string "$wrtbak_done_uid"; printf ',\n'
	printf '    "backup_remote_path": '; wrtbak_json_string "$(wrtbak_jsonfilter_value "$wrtbak_done_actual" '@.backup_remote_path' "")"; printf ',\n'
	printf '    "prebackup_path": '; wrtbak_json_string "$(wrtbak_jsonfilter_value "$wrtbak_done_actual" '@.prebackup_path' "")"; printf ',\n'
	printf '    "created_at": '; wrtbak_json_string "$(wrtbak_jsonfilter_value "$wrtbak_done_actual" '@.created_at' "")"; printf ',\n'
	printf '    "restore_receipt": '; wrtbak_json_string "$(wrtbak_jsonfilter_value "$wrtbak_done_actual" '@.restore_receipt' "")"; printf '\n'
	printf '  }'
}

wrtbak_firstboot_blocked_reasons_json() {
	wrtbak_identity_ok=$1
	wrtbak_default_route=$2
	wrtbak_dns=$3
	wrtbak_time=$4
	wrtbak_done_status=$5
	wrtbak_first=1

	printf '['
	for wrtbak_reason in \
		"$([ "$wrtbak_identity_ok" = true ] || printf 'identity_unusable')" \
		"$([ "$wrtbak_default_route" = true ] || printf 'no_default_route')" \
		"$([ "$wrtbak_dns" = true ] || printf 'dns_not_ready')" \
		"$([ "$wrtbak_time" = true ] || printf 'time_not_ready')" \
		"$([ "$wrtbak_done_status" != uid_mismatch ] || printf 'done_marker_uid_mismatch')"
	do
		[ -n "$wrtbak_reason" ] || continue
		if [ "$wrtbak_first" -eq 1 ]; then
			wrtbak_first=0
		else
			printf ', '
		fi
		wrtbak_json_string "$wrtbak_reason"
	done
	printf ']'
}

wrtbak_firstboot_status_json() {
	wrtbak_identity_tmp=$(mktemp "${TMPDIR:-/tmp}/wrtbak-firstboot-identity.XXXXXX") || return 1
	wrtbak_remote_tmp=$(mktemp "${TMPDIR:-/tmp}/wrtbak-firstboot-remote.XXXXXX") || {
		rm -f "$wrtbak_identity_tmp"
		return 1
	}
	wrtbak_network_tmp=$(mktemp "${TMPDIR:-/tmp}/wrtbak-firstboot-network.XXXXXX") || {
		rm -f "$wrtbak_identity_tmp" "$wrtbak_remote_tmp"
		return 1
	}
	wrtbak_done_tmp=$(mktemp "${TMPDIR:-/tmp}/wrtbak-firstboot-done.XXXXXX") || {
		rm -f "$wrtbak_identity_tmp" "$wrtbak_remote_tmp" "$wrtbak_network_tmp"
		return 1
	}

	if wrtbak_identity_current_json >"$wrtbak_identity_tmp"; then
		wrtbak_identity_ok=true
	else
		wrtbak_identity_ok=false
	fi
	wrtbak_current_uid=$(wrtbak_jsonfilter_value "$wrtbak_identity_tmp" '@.uid' "")

	if ! wrtbak_remote_status_json >"$wrtbak_remote_tmp"; then
		printf '{ "ok": false, "operation": "remote-status" }\n' >"$wrtbak_remote_tmp"
	fi
	wrtbak_firstboot_network_json >"$wrtbak_network_tmp"
	wrtbak_firstboot_done_marker_json "$wrtbak_current_uid" >"$wrtbak_done_tmp"

	wrtbak_local_url=$(wrtbak_firstboot_local_url)
	wrtbak_qr_svg=$(wrtbak_firstboot_qr_svg "$wrtbak_local_url" 2>/dev/null || printf '')
	wrtbak_default_route=$(wrtbak_jsonfilter_value "$wrtbak_network_tmp" '@.default_route' "false")
	wrtbak_dns=$(wrtbak_jsonfilter_value "$wrtbak_network_tmp" '@.dns' "false")
	wrtbak_time=$(wrtbak_jsonfilter_value "$wrtbak_network_tmp" '@.time' "false")
	wrtbak_done_status=$(wrtbak_jsonfilter_value "$wrtbak_done_tmp" '@.status' "missing")

	printf '{\n'
	printf '  "ok": true,\n'
	printf '  "operation": "firstboot-status",\n'
	printf '  "identity": '; cat "$wrtbak_identity_tmp"; printf ',\n'
	printf '  "network": '; cat "$wrtbak_network_tmp"; printf ',\n'
	printf '  "remote": '; cat "$wrtbak_remote_tmp"; printf ',\n'
	printf '  "done_marker": '; cat "$wrtbak_done_tmp"; printf ',\n'
	printf '  "local_url": '; wrtbak_json_string "$wrtbak_local_url"; printf ',\n'
	printf '  "qr_svg": '; wrtbak_json_string "$wrtbak_qr_svg"; printf ',\n'
	printf '  "blocked_reasons": '
	wrtbak_firstboot_blocked_reasons_json "$wrtbak_identity_ok" "$wrtbak_default_route" "$wrtbak_dns" "$wrtbak_time" "$wrtbak_done_status"
	printf '\n'
	printf '}\n'

	rm -f "$wrtbak_identity_tmp" "$wrtbak_remote_tmp" "$wrtbak_network_tmp" "$wrtbak_done_tmp"
}

wrtbak_firstboot_target_arg() {
	wrtbak_target=$1
	[ -n "$wrtbak_target" ] || wrtbak_target=default
	printf '%s\n' "$wrtbak_target"
}

wrtbak_firstboot_logical_path_for_actual() {
	wrtbak_actual_path=$1
	wrtbak_root=${WRTBAK_ROOT:-/}

	case "$wrtbak_root" in
		""|"/")
			printf '%s\n' "$wrtbak_actual_path"
			return 0
			;;
	esac

	case "$wrtbak_actual_path" in
		"${wrtbak_root%/}"/*)
			printf '/%s\n' "${wrtbak_actual_path#"${wrtbak_root%/}/"}"
			return 0
			;;
		*)
			printf '%s\n' "$wrtbak_actual_path"
			return 0
			;;
	esac
}

wrtbak_firstboot_candidates_json() {
	wrtbak_target=$(wrtbak_firstboot_target_arg "$1")
	wrtbak_identity_tmp=$(mktemp "${TMPDIR:-/tmp}/wrtbak-firstboot-candidates-identity.XXXXXX") || return 1
	wrtbak_remote_tmp=$(mktemp "${TMPDIR:-/tmp}/wrtbak-firstboot-candidates-remote.XXXXXX") || {
		rm -f "$wrtbak_identity_tmp"
		return 1
	}

	if ! wrtbak_identity_current_json >"$wrtbak_identity_tmp"; then
		rm -f "$wrtbak_identity_tmp" "$wrtbak_remote_tmp"
		wrtbak_firstboot_error_json firstboot-candidates identity_unusable "current device identity is unusable" ""
		return 1
	fi
	if ! wrtbak_remote_list "$wrtbak_target" >"$wrtbak_remote_tmp"; then
		wrtbak_code=$(wrtbak_jsonfilter_value "$wrtbak_remote_tmp" '@.code' "remote_unreachable")
		wrtbak_message=$(wrtbak_jsonfilter_value "$wrtbak_remote_tmp" '@.message' "remote listing failed")
		wrtbak_detail=$(wrtbak_jsonfilter_value "$wrtbak_remote_tmp" '@.detail' "")
		rm -f "$wrtbak_identity_tmp" "$wrtbak_remote_tmp"
		wrtbak_firstboot_error_json firstboot-candidates "$wrtbak_code" "$wrtbak_message" "$wrtbak_detail"
		return 1
	fi

	printf '{\n'
	printf '  "ok": true,\n'
	printf '  "operation": "firstboot-candidates",\n'
	printf '  "target": '; wrtbak_json_string "$wrtbak_target"; printf ',\n'
	printf '  "identity": '; cat "$wrtbak_identity_tmp"; printf ',\n'
	printf '  "write_policy": "current_device_only",\n'
	printf '  "remote": '; cat "$wrtbak_remote_tmp"; printf '\n'
	printf '}\n'
	rm -f "$wrtbak_identity_tmp" "$wrtbak_remote_tmp"
}

wrtbak_firstboot_download_result_json() {
	wrtbak_download_file=$1
	wrtbak_local_path=$(wrtbak_jsonfilter_value "$wrtbak_download_file" '@.local_path' "")
	wrtbak_logical_path=$(wrtbak_firstboot_logical_path_for_actual "$wrtbak_local_path")
	wrtbak_size=$(wrtbak_jsonfilter_value "$wrtbak_download_file" '@.size' "0")

	printf '{\n'
	printf '    "ok": true,\n'
	printf '    "operation": "remote-download",\n'
	printf '    "target": '; wrtbak_json_string "$(wrtbak_jsonfilter_value "$wrtbak_download_file" '@.target' "")"; printf ',\n'
	printf '    "driver": '; wrtbak_json_string "$(wrtbak_jsonfilter_value "$wrtbak_download_file" '@.driver' "")"; printf ',\n'
	printf '    "remote_path": '; wrtbak_json_string "$(wrtbak_jsonfilter_value "$wrtbak_download_file" '@.remote_path' "")"; printf ',\n'
	printf '    "path": '; wrtbak_json_string "$wrtbak_logical_path"; printf ',\n'
	printf '    "local_path": '; wrtbak_json_string "$wrtbak_local_path"; printf ',\n'
	printf '    "sidecar_path": '; wrtbak_json_string "$(wrtbak_jsonfilter_value "$wrtbak_download_file" '@.sidecar_path' "")"; printf ',\n'
	printf '    "filename": '; wrtbak_json_string "$(wrtbak_jsonfilter_value "$wrtbak_download_file" '@.filename' "")"; printf ',\n'
	printf '    "format": '; wrtbak_json_string "$(wrtbak_jsonfilter_value "$wrtbak_download_file" '@.format' "")"; printf ',\n'
	printf '    "size": %s,\n' "$wrtbak_size"
	printf '    "remote_modified": '; wrtbak_json_string "$(wrtbak_jsonfilter_value "$wrtbak_download_file" '@.remote_modified' "")"; printf ',\n'
	printf '    "remote_etag": '; wrtbak_json_string "$(wrtbak_jsonfilter_value "$wrtbak_download_file" '@.remote_etag' "")"; printf ',\n'
	printf '    "sha256": '; wrtbak_json_string "$(wrtbak_jsonfilter_value "$wrtbak_download_file" '@.sha256' "")"; printf '\n'
	printf '  }'
}

wrtbak_firstboot_prepare_json() {
	wrtbak_target=$1
	wrtbak_remote_path=$2

	case "$wrtbak_remote_path" in
		*/devices/*/wrtbak/*/*.wrtbak|devices/*/wrtbak/*/*.wrtbak|*/devices/*/wrtbak/*/*.sysupgrade.tar.gz|devices/*/wrtbak/*/*.sysupgrade.tar.gz)
			;;
		*)
			wrtbak_firstboot_error_json firstboot-prepare legacy_backup_read_only "legacy or cross-device backups are read-only in firstboot restore" "$wrtbak_remote_path"
			return 1
			;;
	esac

	wrtbak_download_tmp=$(mktemp "${TMPDIR:-/tmp}/wrtbak-firstboot-download.XXXXXX") || return 1
	wrtbak_prepare_tmp=$(mktemp "${TMPDIR:-/tmp}/wrtbak-firstboot-prepare.XXXXXX") || {
		rm -f "$wrtbak_download_tmp"
		return 1
	}
	wrtbak_plan_tmp=$(mktemp "${TMPDIR:-/tmp}/wrtbak-firstboot-plan.XXXXXX") || {
		rm -f "$wrtbak_download_tmp" "$wrtbak_prepare_tmp"
		return 1
	}
	wrtbak_download_view_tmp=$(mktemp "${TMPDIR:-/tmp}/wrtbak-firstboot-download-view.XXXXXX") || {
		rm -f "$wrtbak_download_tmp" "$wrtbak_prepare_tmp" "$wrtbak_plan_tmp"
		return 1
	}

	if ! wrtbak_remote_download "$wrtbak_target" "$wrtbak_remote_path" 0 >"$wrtbak_download_tmp"; then
		wrtbak_code=$(wrtbak_jsonfilter_value "$wrtbak_download_tmp" '@.code' "remote_download_failed")
		wrtbak_message=$(wrtbak_jsonfilter_value "$wrtbak_download_tmp" '@.message' "remote download failed")
		wrtbak_detail=$(wrtbak_jsonfilter_value "$wrtbak_download_tmp" '@.detail' "$wrtbak_remote_path")
		rm -f "$wrtbak_download_tmp" "$wrtbak_prepare_tmp" "$wrtbak_plan_tmp" "$wrtbak_download_view_tmp"
		wrtbak_firstboot_error_json firstboot-prepare "$wrtbak_code" "$wrtbak_message" "$wrtbak_detail"
		return 1
	fi

	wrtbak_firstboot_download_result_json "$wrtbak_download_tmp" >"$wrtbak_download_view_tmp"
	wrtbak_input=$(wrtbak_jsonfilter_value "$wrtbak_download_view_tmp" '@.path' "")
	if [ -z "$wrtbak_input" ]; then
		rm -f "$wrtbak_download_tmp" "$wrtbak_prepare_tmp" "$wrtbak_plan_tmp" "$wrtbak_download_view_tmp"
		wrtbak_firstboot_error_json firstboot-prepare remote_download_failed "download result did not include a local path" "$wrtbak_remote_path"
		return 1
	fi
	wrtbak_actual_input=$(wrtbak_root_path "$wrtbak_input")

	if ! wrtbak_restore_prepare "$wrtbak_input" >"$wrtbak_prepare_tmp"; then
		wrtbak_code=$(wrtbak_jsonfilter_value "$wrtbak_prepare_tmp" '@.code' "invalid_archive")
		wrtbak_message=$(wrtbak_jsonfilter_value "$wrtbak_prepare_tmp" '@.message' "restore prepare failed")
		rm -f "$wrtbak_download_tmp" "$wrtbak_prepare_tmp" "$wrtbak_plan_tmp" "$wrtbak_download_view_tmp"
		wrtbak_firstboot_error_json firstboot-prepare "$wrtbak_code" "$wrtbak_message" "$wrtbak_input"
		return 1
	fi
	if ! wrtbak_agent_restore_plan_json "$wrtbak_actual_input" >"$wrtbak_plan_tmp"; then
		rm -f "$wrtbak_download_tmp" "$wrtbak_prepare_tmp" "$wrtbak_plan_tmp" "$wrtbak_download_view_tmp"
		wrtbak_firstboot_error_json firstboot-prepare invalid_archive "restore plan failed" "$wrtbak_input"
		return 1
	fi

	printf '{\n'
	printf '  "ok": true,\n'
	printf '  "operation": "firstboot-prepare",\n'
	printf '  "download": '; cat "$wrtbak_download_view_tmp"; printf ',\n'
	printf '  "prepare": '; cat "$wrtbak_prepare_tmp"; printf ',\n'
	printf '  "plan": '; cat "$wrtbak_plan_tmp"; printf '\n'
	printf '}\n'
	rm -f "$wrtbak_download_tmp" "$wrtbak_prepare_tmp" "$wrtbak_plan_tmp" "$wrtbak_download_view_tmp"
}

wrtbak_firstboot_write_json_atomic() {
	wrtbak_path=$1
	wrtbak_tmp="$wrtbak_path.tmp.$$"

	umask 077
	cat >"$wrtbak_tmp" || {
		rm -f "$wrtbak_tmp"
		return 1
	}
	mv -f "$wrtbak_tmp" "$wrtbak_path"
}

wrtbak_firstboot_remote_path_for_input() {
	wrtbak_input=$1
	wrtbak_sidecar_actual=$(wrtbak_root_path "$wrtbak_input.remote.json")

	if [ -f "$wrtbak_sidecar_actual" ] && [ ! -L "$wrtbak_sidecar_actual" ]; then
		wrtbak_jsonfilter_value "$wrtbak_sidecar_actual" '@.remote_path' ""
	fi
}

wrtbak_firstboot_write_done_marker() {
	wrtbak_device_uid=$1
	wrtbak_remote_path=$2
	wrtbak_prebackup=$3
	wrtbak_restore_receipt=$4
	wrtbak_done_actual=$(wrtbak_root_path "$(wrtbak_firstboot_done_logical_path)")

	mkdir -p "$(dirname -- "$wrtbak_done_actual")" || return 1
	{
		printf '{\n'
		printf '  "ok": true,\n'
		printf '  "device_uid": '; wrtbak_json_string "$wrtbak_device_uid"; printf ',\n'
		printf '  "backup_remote_path": '; wrtbak_json_string "$wrtbak_remote_path"; printf ',\n'
		printf '  "prebackup_path": '; wrtbak_json_string "$wrtbak_prebackup"; printf ',\n'
		printf '  "restore_receipt": '; wrtbak_json_string "$wrtbak_restore_receipt"; printf ',\n'
		printf '  "created_at": '; wrtbak_json_string "$(wrtbak_created_at)"; printf '\n'
		printf '}\n'
	} | wrtbak_firstboot_write_json_atomic "$wrtbak_done_actual"
}

wrtbak_firstboot_write_completion_receipt() {
	wrtbak_device_uid=$1
	wrtbak_remote_path=$2
	wrtbak_prebackup=$3
	wrtbak_apply_stage=$4
	wrtbak_receipts_actual=$(wrtbak_root_path "$(wrtbak_firstboot_receipts_logical_dir)")

	mkdir -p "$wrtbak_receipts_actual" || return 1
	wrtbak_receipt_logical="$(wrtbak_firstboot_receipts_logical_dir)/$(date -u +%Y%m%dT%H%M%SZ)-restore.json"
	wrtbak_receipt_actual=$(wrtbak_root_path "$wrtbak_receipt_logical")
	{
		printf '{\n'
		printf '  "ok": true,\n'
		printf '  "operation": "firstboot-apply",\n'
		printf '  "stage": '; wrtbak_json_string "$wrtbak_apply_stage"; printf ',\n'
		printf '  "device_uid": '; wrtbak_json_string "$wrtbak_device_uid"; printf ',\n'
		printf '  "backup_remote_path": '; wrtbak_json_string "$wrtbak_remote_path"; printf ',\n'
		printf '  "prebackup_path": '; wrtbak_json_string "$wrtbak_prebackup"; printf ',\n'
		printf '  "created_at": '; wrtbak_json_string "$(wrtbak_created_at)"; printf '\n'
		printf '}\n'
	} | wrtbak_firstboot_write_json_atomic "$wrtbak_receipt_actual" || return 1
	printf '%s\n' "$wrtbak_receipt_logical"
}

wrtbak_firstboot_apply_json() {
	wrtbak_input=$1
	wrtbak_prebackup=$2
	wrtbak_confirm=$3

	if [ "$wrtbak_confirm" != "RESTORE" ]; then
		wrtbak_firstboot_error_json firstboot-apply confirmation_required "confirmation must be RESTORE" ""
		return 1
	fi

	wrtbak_plan_tmp=$(mktemp "${TMPDIR:-/tmp}/wrtbak-firstboot-apply-plan.XXXXXX") || return 1
	wrtbak_apply_tmp=$(mktemp "${TMPDIR:-/tmp}/wrtbak-firstboot-apply.XXXXXX") || {
		rm -f "$wrtbak_plan_tmp"
		return 1
	}
	wrtbak_done_tmp=$(mktemp "${TMPDIR:-/tmp}/wrtbak-firstboot-apply-done.XXXXXX") || {
		rm -f "$wrtbak_plan_tmp" "$wrtbak_apply_tmp"
		return 1
	}
	wrtbak_actual_input=$(wrtbak_root_path "$wrtbak_input")

	if ! wrtbak_agent_restore_plan_json "$wrtbak_actual_input" >"$wrtbak_plan_tmp"; then
		rm -f "$wrtbak_plan_tmp" "$wrtbak_apply_tmp" "$wrtbak_done_tmp"
		wrtbak_firstboot_error_json firstboot-apply invalid_archive "restore plan failed" "$wrtbak_input"
		return 1
	fi

	wrtbak_can_apply=$(wrtbak_jsonfilter_value "$wrtbak_plan_tmp" '@.can_apply' "false")
	if [ "$wrtbak_can_apply" != "true" ]; then
		wrtbak_reason=$(wrtbak_jsonfilter_value "$wrtbak_plan_tmp" '@.reason' "identity_unusable")
		rm -f "$wrtbak_plan_tmp" "$wrtbak_apply_tmp" "$wrtbak_done_tmp"
		wrtbak_firstboot_error_json firstboot-apply "$wrtbak_reason" "restore archive does not belong to this device" "$wrtbak_input"
		return 1
	fi

	if ! wrtbak_restore_apply "$wrtbak_input" all all "$wrtbak_prebackup" RESTORE 0 >"$wrtbak_apply_tmp"; then
		wrtbak_code=$(wrtbak_jsonfilter_value "$wrtbak_apply_tmp" '@.code' "restore_failed")
		wrtbak_message=$(wrtbak_jsonfilter_value "$wrtbak_apply_tmp" '@.message' "restore apply failed")
		rm -f "$wrtbak_plan_tmp" "$wrtbak_apply_tmp" "$wrtbak_done_tmp"
		wrtbak_firstboot_error_json firstboot-apply "$wrtbak_code" "$wrtbak_message" "$wrtbak_input"
		return 1
	fi

	wrtbak_device_uid=$(wrtbak_jsonfilter_value "$wrtbak_plan_tmp" '@.current_uid' "")
	wrtbak_remote_path=$(wrtbak_firstboot_remote_path_for_input "$wrtbak_input")
	wrtbak_receipt_logical=$(wrtbak_firstboot_write_completion_receipt "$wrtbak_device_uid" "$wrtbak_remote_path" "$wrtbak_prebackup" complete)
	wrtbak_firstboot_write_done_marker "$wrtbak_device_uid" "$wrtbak_remote_path" "$wrtbak_prebackup" "$wrtbak_receipt_logical"
	wrtbak_firstboot_done_marker_json "$wrtbak_device_uid" >"$wrtbak_done_tmp"

	printf '{\n'
	printf '  "ok": true,\n'
	printf '  "operation": "firstboot-apply",\n'
	printf '  "plan": '; cat "$wrtbak_plan_tmp"; printf ',\n'
	printf '  "apply": '; cat "$wrtbak_apply_tmp"; printf ',\n'
	printf '  "done_marker": '; cat "$wrtbak_done_tmp"; printf ',\n'
	printf '  "completion_receipt": '; wrtbak_json_string "$wrtbak_receipt_logical"; printf '\n'
	printf '}\n'

	rm -f "$wrtbak_plan_tmp" "$wrtbak_apply_tmp" "$wrtbak_done_tmp"
}

wrtbak_firstboot_complete_json() {
	wrtbak_identity_tmp=$(mktemp "${TMPDIR:-/tmp}/wrtbak-firstboot-complete-identity.XXXXXX") || return 1
	if wrtbak_identity_current_json >"$wrtbak_identity_tmp" 2>/dev/null; then
		wrtbak_current_uid=$(wrtbak_jsonfilter_value "$wrtbak_identity_tmp" '@.uid' "")
	else
		wrtbak_current_uid=
	fi

	printf '{\n'
	printf '  "ok": true,\n'
	printf '  "operation": "firstboot-complete",\n'
	printf '  "done_marker": '
	wrtbak_firstboot_done_marker_json "$wrtbak_current_uid"
	printf '\n'
	printf '}\n'
	rm -f "$wrtbak_identity_tmp"
}
