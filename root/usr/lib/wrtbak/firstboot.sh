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
