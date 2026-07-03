#!/bin/sh

wrtbak_proxy_error_json() {
	wrtbak_operation=$1
	wrtbak_proxy=$2
	wrtbak_code=$3
	wrtbak_message=$4
	wrtbak_detail=${5:-}

	printf '{\n'
	printf '  "ok": false,\n'
	printf '  "operation": '; wrtbak_json_string "$wrtbak_operation"; printf ',\n'
	printf '  "proxy": '; wrtbak_json_string "$wrtbak_proxy"; printf ',\n'
	printf '  "code": '; wrtbak_json_string "$wrtbak_code"; printf ',\n'
	printf '  "message": '; wrtbak_json_string "$wrtbak_message"; printf ',\n'
	printf '  "detail": '; wrtbak_json_string "$wrtbak_detail"; printf '\n'
	printf '}\n'
}

wrtbak_proxy_validate_name() {
	case "$1" in
		nikki|dae)
			printf '%s\n' "$1"
			return 0
			;;
	esac
	return 1
}

wrtbak_proxy_target_path() {
	case "$1" in
		nikki) printf '%s\n' '/etc/nikki/profiles/final.yaml' ;;
		dae) printf '%s\n' '/etc/dae/final.yaml' ;;
		*) return 1 ;;
	esac
}

wrtbak_proxy_service_name() {
	case "$1" in
		nikki)
			printf '%s\n' nikki
			;;
		dae)
			for wrtbak_proxy_service in dae daed luci_daed; do
				if [ -x "$(wrtbak_root_path "/etc/init.d/$wrtbak_proxy_service")" ]; then
					printf '%s\n' "$wrtbak_proxy_service"
					return 0
				fi
			done
			printf '%s\n' dae
			;;
		*)
			return 1
			;;
	esac
}

wrtbak_proxy_cache_dir() {
	printf '%s\n' "$(wrtbak_root_path /tmp/wrtbak/proxy-cache)"
}

wrtbak_proxy_rollback_root() {
	printf '%s\n' "$(wrtbak_root_path /overlay/wrtbak/proxy-rollback)"
}

wrtbak_proxy_receipt_path() {
	printf '%s\n' "$(wrtbak_root_path "/overlay/wrtbak/proxy-receipts/$1.json")"
}

wrtbak_proxy_bool_json() {
	if wrtbak_bool_enabled "$1"; then
		printf 'true'
	else
		printf 'false'
	fi
}

wrtbak_proxy_status_json() {
	wrtbak_proxy_enabled=$(wrtbak_main_option proxy_artifacts_enabled 0)
	wrtbak_proxy_mode=$(wrtbak_main_option proxy_update_mode review-required)
	wrtbak_proxy_site=$(wrtbak_main_option site "")
	printf '{\n'
	printf '  "ok": true,\n'
	printf '  "operation": "proxy-status",\n'
	printf '  "enabled": '; wrtbak_proxy_bool_json "$wrtbak_proxy_enabled"; printf ',\n'
	printf '  "mode": '; wrtbak_json_string "$wrtbak_proxy_mode"; printf ',\n'
	printf '  "site": '; wrtbak_json_string "$wrtbak_proxy_site"; printf '\n'
	printf '}\n'
}

wrtbak_proxy_target_prepare() {
	wrtbak_proxy_target=$(wrtbak_remote_resolve_target "$1") || return 1
	wrtbak_remote_require_enabled "$wrtbak_proxy_target" "$2" || return 2
	case "$wrtbak_proxy_target" in
		webdav)
			wrtbak_remote_load_webdav_config || return 3
			command -v curl >/dev/null 2>&1 || return 4
			wrtbak_proxy_driver=curl
			;;
		s3)
			wrtbak_remote_load_s3_config || return 3
			command -v rclone >/dev/null 2>&1 || return 4
			wrtbak_proxy_driver=rclone
			;;
		*)
			return 1
			;;
	esac
	wrtbak_proxy_base=$(wrtbak_remote_target_base "$wrtbak_proxy_target") || return 3
	return 0
}

wrtbak_proxy_site_name() {
	wrtbak_site=$(wrtbak_main_option site "")
	if [ -n "$wrtbak_site" ]; then
		wrtbak_remote_normalize_name "$wrtbak_site"
	fi
}

wrtbak_proxy_expected_manifest_rows() {
	wrtbak_proxy_name=$1
	wrtbak_base=$2
	wrtbak_uid=$(wrtbak_identity_current_uid) || return 1
	wrtbak_site=$(wrtbak_proxy_site_name)

	wrtbak_device_manifest=$(wrtbak_join_remote_path "$wrtbak_base" proxy devices "$wrtbak_uid" "$wrtbak_proxy_name" latest.json) || return 1
	printf '1\tdevice\t%s\n' "$wrtbak_device_manifest"

	if [ -n "$wrtbak_site" ]; then
		wrtbak_site_manifest=$(wrtbak_join_remote_path "$wrtbak_base" proxy sites "$wrtbak_site" "$wrtbak_proxy_name" latest.json) || return 1
		printf '2\tsite\t%s\n' "$wrtbak_site_manifest"
	fi

	wrtbak_shared_manifest=$(wrtbak_join_remote_path "$wrtbak_base" proxy shared "$wrtbak_proxy_name" latest.json) || return 1
	printf '3\tshared\t%s\n' "$wrtbak_shared_manifest"
}

wrtbak_proxy_path_allowed() {
	wrtbak_proxy_name=$1
	wrtbak_base=$2
	wrtbak_path=$(wrtbak_normalize_remote_path "$3") || return 1
	wrtbak_expected=$(mktemp "${TMPDIR:-/tmp}/wrtbak-proxy-expected.XXXXXX") || return 1
	wrtbak_proxy_expected_manifest_rows "$wrtbak_proxy_name" "$wrtbak_base" >"$wrtbak_expected" || {
		rm -f "$wrtbak_expected"
		return 1
	}
	awk -F '	' -v path="$wrtbak_path" '$3 == path { found = 1 } END { exit found ? 0 : 1 }' "$wrtbak_expected"
	wrtbak_allowed_status=$?
	rm -f "$wrtbak_expected"
	return "$wrtbak_allowed_status"
}

wrtbak_proxy_cache_path_for() {
	wrtbak_remote_path=$(wrtbak_normalize_remote_path "$1") || return 1
	wrtbak_cache_dir=$(wrtbak_proxy_cache_dir)
	mkdir -p "$wrtbak_cache_dir" || return 1
	chmod 700 "$wrtbak_cache_dir" 2>/dev/null || true
	wrtbak_hash=$(printf '%s' "$wrtbak_remote_path" | sha256sum | awk '{ print substr($1, 1, 12) }')
	wrtbak_base=$(basename -- "$wrtbak_remote_path")
	printf '%s/%s-%s\n' "$wrtbak_cache_dir" "$wrtbak_hash" "$wrtbak_base"
}

wrtbak_proxy_download_to_cache() {
	wrtbak_proxy_target_name=$1
	wrtbak_proxy_remote_path=$2
	wrtbak_proxy_local_path=$(wrtbak_proxy_cache_path_for "$wrtbak_proxy_remote_path") || return 1
	wrtbak_proxy_part="$wrtbak_proxy_local_path.part.$$"
	rm -f "$wrtbak_proxy_part"
	if ! wrtbak_remote_download_driver "$wrtbak_proxy_target_name" "$wrtbak_proxy_remote_path" "$wrtbak_proxy_part"; then
		rm -f "$wrtbak_proxy_part"
		return 1
	fi
	if ! mv -f "$wrtbak_proxy_part" "$wrtbak_proxy_local_path"; then
		rm -f "$wrtbak_proxy_part"
		return 1
	fi
	printf '%s\n' "$wrtbak_proxy_local_path"
}

wrtbak_proxy_manifest_value() {
	wrtbak_manifest=$1
	wrtbak_expr=$2
	wrtbak_jsonfilter_value "$wrtbak_manifest" "$wrtbak_expr" ""
}

wrtbak_proxy_manifest_validate() {
	wrtbak_proxy_name=$1
	wrtbak_manifest=$2
	wrtbak_expected_target=$(wrtbak_proxy_target_path "$wrtbak_proxy_name") || return 1

	[ -r "$wrtbak_manifest" ] && [ ! -L "$wrtbak_manifest" ] || return 1
	[ "$(wrtbak_proxy_manifest_value "$wrtbak_manifest" '@.schema')" = "wrtbak/proxy-artifact/v1" ] || return 1
	[ "$(wrtbak_proxy_manifest_value "$wrtbak_manifest" '@.proxy')" = "$wrtbak_proxy_name" ] || return 1
	[ "$(wrtbak_proxy_manifest_value "$wrtbak_manifest" '@.target_path')" = "$wrtbak_expected_target" ] || return 1
	wrtbak_artifact_path=$(wrtbak_proxy_manifest_value "$wrtbak_manifest" '@.artifact_path')
	wrtbak_sha=$(wrtbak_proxy_manifest_value "$wrtbak_manifest" '@.sha256')
	wrtbak_size=$(wrtbak_proxy_manifest_value "$wrtbak_manifest" '@.size')
	[ -n "$wrtbak_artifact_path" ] || return 1
	wrtbak_normalize_remote_path "$wrtbak_artifact_path" >/dev/null || return 1
	case "$wrtbak_sha" in
		????????????????????????????????????????????????????????????????) ;;
		*) return 1 ;;
	esac
	case "$wrtbak_size" in
		""|*[!0-9]*) return 1 ;;
	esac
	return 0
}

wrtbak_proxy_current_sha() {
	wrtbak_proxy_name=$1
	wrtbak_target=$(wrtbak_root_path "$(wrtbak_proxy_target_path "$wrtbak_proxy_name")")
	if [ -f "$wrtbak_target" ] && [ ! -L "$wrtbak_target" ]; then
		wrtbak_sha256_of "$wrtbak_target" 2>/dev/null || true
	fi
}

wrtbak_proxy_print_candidate_object() {
	wrtbak_scope=$1
	wrtbak_manifest_path=$2
	wrtbak_manifest_local=$3
	wrtbak_current_sha=$4
	wrtbak_sha=$(wrtbak_proxy_manifest_value "$wrtbak_manifest_local" '@.sha256')
	wrtbak_size=$(wrtbak_proxy_manifest_value "$wrtbak_manifest_local" '@.size')
	wrtbak_artifact_path=$(wrtbak_proxy_manifest_value "$wrtbak_manifest_local" '@.artifact_path')
	wrtbak_created_at=$(wrtbak_proxy_manifest_value "$wrtbak_manifest_local" '@.created_at')
	if [ -n "$wrtbak_current_sha" ] && [ "$wrtbak_current_sha" = "$wrtbak_sha" ]; then
		wrtbak_update=false
	else
		wrtbak_update=true
	fi
	printf '{'
	printf '"scope":'; wrtbak_json_string "$wrtbak_scope"; printf ','
	printf '"manifest_path":'; wrtbak_json_string "$wrtbak_manifest_path"; printf ','
	printf '"artifact_path":'; wrtbak_json_string "$wrtbak_artifact_path"; printf ','
	printf '"sha256":'; wrtbak_json_string "$wrtbak_sha"; printf ','
	printf '"size":%s,' "$wrtbak_size"
	printf '"created_at":'; wrtbak_json_string "$wrtbak_created_at"; printf ','
	printf '"update_available":%s' "$wrtbak_update"
	printf '}'
}

wrtbak_proxy_candidates_json() {
	wrtbak_target_input=$1
	wrtbak_proxy_name=$(wrtbak_proxy_validate_name "$2") || {
		wrtbak_proxy_error_json proxy-candidates "$2" invalid_proxy "proxy must be nikki or dae" ""
		return 1
	}
	if ! wrtbak_bool_enabled "$(wrtbak_main_option proxy_artifacts_enabled 0)"; then
		wrtbak_proxy_error_json proxy-candidates "$wrtbak_proxy_name" disabled "proxy artifacts are disabled" ""
		return 1
	fi
	wrtbak_proxy_target_prepare "$wrtbak_target_input" proxy-candidates || {
		wrtbak_proxy_error_json proxy-candidates "$wrtbak_proxy_name" invalid_config "remote target is not ready" "$wrtbak_target_input"
		return 1
	}
	if ! wrtbak_identity_load_current; then
		wrtbak_proxy_error_json proxy-candidates "$wrtbak_proxy_name" identity_unusable "device identity is unusable" ""
		return 1
	fi
	wrtbak_rows=$(mktemp "${TMPDIR:-/tmp}/wrtbak-proxy-rows.XXXXXX") || return 1
	wrtbak_candidates=$(mktemp "${TMPDIR:-/tmp}/wrtbak-proxy-candidates.XXXXXX") || {
		rm -f "$wrtbak_rows"
		return 1
	}
	: >"$wrtbak_candidates"
	wrtbak_proxy_expected_manifest_rows "$wrtbak_proxy_name" "$wrtbak_proxy_base" >"$wrtbak_rows" || {
		rm -f "$wrtbak_rows" "$wrtbak_candidates"
		wrtbak_proxy_error_json proxy-candidates "$wrtbak_proxy_name" identity_unusable "device identity is unusable" ""
		return 1
	}
	wrtbak_current_sha=$(wrtbak_proxy_current_sha "$wrtbak_proxy_name")
	while IFS='	' read -r wrtbak_priority wrtbak_scope wrtbak_manifest_path || [ -n "$wrtbak_manifest_path" ]; do
		[ -n "$wrtbak_manifest_path" ] || continue
		wrtbak_manifest_local=$(wrtbak_proxy_download_to_cache "$wrtbak_proxy_target" "$wrtbak_manifest_path" 2>/dev/null || printf '')
		[ -n "$wrtbak_manifest_local" ] || continue
		wrtbak_proxy_manifest_validate "$wrtbak_proxy_name" "$wrtbak_manifest_local" || continue
		printf '%s\t%s\t%s\n' "$wrtbak_priority" "$wrtbak_scope" "$wrtbak_manifest_path" >>"$wrtbak_candidates"
	done < "$wrtbak_rows"

	if [ ! -s "$wrtbak_candidates" ]; then
		rm -f "$wrtbak_rows" "$wrtbak_candidates"
		wrtbak_proxy_error_json proxy-candidates "$wrtbak_proxy_name" no_candidates "no proxy artifacts were found" ""
		return 1
	fi

	wrtbak_first_row=$(sort -n "$wrtbak_candidates" | sed -n '1p')
	wrtbak_first_scope=$(printf '%s\n' "$wrtbak_first_row" | cut -f2)
	wrtbak_first_manifest=$(printf '%s\n' "$wrtbak_first_row" | cut -f3)
	wrtbak_first_local=$(wrtbak_proxy_cache_path_for "$wrtbak_first_manifest")

	printf '{\n'
	printf '  "ok": true,\n'
	printf '  "operation": "proxy-candidates",\n'
	printf '  "target": '; wrtbak_json_string "$wrtbak_proxy_target"; printf ',\n'
	printf '  "proxy": '; wrtbak_json_string "$wrtbak_proxy_name"; printf ',\n'
	printf '  "site": '; wrtbak_json_string "$(wrtbak_proxy_site_name)"; printf ',\n'
	printf '  "device_uid": '; wrtbak_json_string "$wrtbak_identity_uid"; printf ',\n'
	printf '  "selected": '
	wrtbak_proxy_print_candidate_object "$wrtbak_first_scope" "$wrtbak_first_manifest" "$wrtbak_first_local" "$wrtbak_current_sha"
	printf ',\n'
	printf '  "candidates": ['
	wrtbak_first=1
	sort -n "$wrtbak_candidates" | while IFS='	' read -r wrtbak_priority wrtbak_scope wrtbak_manifest_path || [ -n "$wrtbak_manifest_path" ]; do
		[ -n "$wrtbak_manifest_path" ] || continue
		wrtbak_manifest_local=$(wrtbak_proxy_cache_path_for "$wrtbak_manifest_path")
		if [ "$wrtbak_first" -eq 1 ]; then
			wrtbak_first=0
		else
			printf ', '
		fi
		wrtbak_proxy_print_candidate_object "$wrtbak_scope" "$wrtbak_manifest_path" "$wrtbak_manifest_local" "$wrtbak_current_sha"
	done
	printf ']\n'
	printf '}\n'
	rm -f "$wrtbak_rows" "$wrtbak_candidates"
}

wrtbak_proxy_prepare_json() {
	wrtbak_target_input=$1
	wrtbak_proxy_name=$(wrtbak_proxy_validate_name "$2") || {
		wrtbak_proxy_error_json proxy-prepare "$2" invalid_proxy "proxy must be nikki or dae" ""
		return 1
	}
	wrtbak_requested_path=$(wrtbak_normalize_remote_path "$3") || {
		wrtbak_proxy_error_json proxy-prepare "$wrtbak_proxy_name" invalid_path "manifest path is invalid" "$3"
		return 1
	}
	wrtbak_proxy_target_prepare "$wrtbak_target_input" proxy-prepare || {
		wrtbak_proxy_error_json proxy-prepare "$wrtbak_proxy_name" invalid_config "remote target is not ready" "$wrtbak_target_input"
		return 1
	}
	if ! wrtbak_identity_load_current; then
		wrtbak_proxy_error_json proxy-prepare "$wrtbak_proxy_name" identity_unusable "device identity is unusable" ""
		return 1
	fi
	if ! wrtbak_proxy_path_allowed "$wrtbak_proxy_name" "$wrtbak_proxy_base" "$wrtbak_requested_path"; then
		wrtbak_proxy_error_json proxy-prepare "$wrtbak_proxy_name" path_not_allowed "proxy manifest path is not allowed" "$wrtbak_requested_path"
		return 1
	fi
	wrtbak_manifest_local=$(wrtbak_proxy_download_to_cache "$wrtbak_proxy_target" "$wrtbak_requested_path") || {
		wrtbak_proxy_error_json proxy-prepare "$wrtbak_proxy_name" download_failed "manifest download failed" "$wrtbak_requested_path"
		return 1
	}
	if ! wrtbak_proxy_manifest_validate "$wrtbak_proxy_name" "$wrtbak_manifest_local"; then
		wrtbak_proxy_error_json proxy-prepare "$wrtbak_proxy_name" invalid_manifest "proxy manifest is invalid" "$wrtbak_requested_path"
		return 1
	fi
	wrtbak_artifact_path=$(wrtbak_proxy_manifest_value "$wrtbak_manifest_local" '@.artifact_path')
	wrtbak_artifact_local=$(wrtbak_proxy_download_to_cache "$wrtbak_proxy_target" "$wrtbak_artifact_path") || {
		wrtbak_proxy_error_json proxy-prepare "$wrtbak_proxy_name" download_failed "artifact download failed" "$wrtbak_artifact_path"
		return 1
	}
	wrtbak_expected_sha=$(wrtbak_proxy_manifest_value "$wrtbak_manifest_local" '@.sha256')
	wrtbak_expected_size=$(wrtbak_proxy_manifest_value "$wrtbak_manifest_local" '@.size')
	wrtbak_actual_sha=$(wrtbak_sha256_of "$wrtbak_artifact_local")
	wrtbak_actual_size=$(stat -c '%s' "$wrtbak_artifact_local")
	if [ "$wrtbak_expected_sha" != "$wrtbak_actual_sha" ] || [ "$wrtbak_expected_size" != "$wrtbak_actual_size" ]; then
		wrtbak_proxy_error_json proxy-prepare "$wrtbak_proxy_name" checksum_mismatch "artifact checksum or size does not match manifest" "$wrtbak_artifact_path"
		return 1
	fi

	printf '{\n'
	printf '  "ok": true,\n'
	printf '  "operation": "proxy-prepare",\n'
	printf '  "target": '; wrtbak_json_string "$wrtbak_proxy_target"; printf ',\n'
	printf '  "proxy": '; wrtbak_json_string "$wrtbak_proxy_name"; printf ',\n'
	printf '  "manifest": {\n'
	printf '    "scope": '; wrtbak_json_string "$(wrtbak_proxy_manifest_value "$wrtbak_manifest_local" '@.scope')"; printf ',\n'
	printf '    "remote_path": '; wrtbak_json_string "$wrtbak_requested_path"; printf ',\n'
	printf '    "artifact_path": '; wrtbak_json_string "$wrtbak_artifact_path"; printf ',\n'
	printf '    "target_path": '; wrtbak_json_string "$(wrtbak_proxy_manifest_value "$wrtbak_manifest_local" '@.target_path')"; printf ',\n'
	printf '    "sha256": '; wrtbak_json_string "$wrtbak_expected_sha"; printf ',\n'
	printf '    "size": %s,\n' "$wrtbak_expected_size"
	printf '    "local_path": '; wrtbak_json_string "$wrtbak_manifest_local"; printf '\n'
	printf '  },\n'
	printf '  "artifact": {\n'
	printf '    "local_path": '; wrtbak_json_string "$wrtbak_artifact_local"; printf ',\n'
	printf '    "sha256": '; wrtbak_json_string "$wrtbak_actual_sha"; printf ',\n'
	printf '    "size": %s\n' "$wrtbak_actual_size"
	printf '  }\n'
	printf '}\n'
}

wrtbak_proxy_cleanup_cache() {
	case "$1" in
		nikki)
			rm -rf \
				"$(wrtbak_root_path /etc/nikki/run/rule-providers)" \
				"$(wrtbak_root_path /etc/nikki/profiles/rule-providers)"
			rm -f "$(wrtbak_root_path /etc/nikki/run/cache.db)"
			;;
	esac
}

wrtbak_proxy_config_test() {
	wrtbak_proxy_name=$1
	wrtbak_target=$(wrtbak_root_path "$(wrtbak_proxy_target_path "$wrtbak_proxy_name")")
	case "$wrtbak_proxy_name" in
		nikki)
			if command -v mihomo >/dev/null 2>&1; then
				mihomo -t -f "$wrtbak_target" >/dev/null 2>&1 || {
					wrtbak_proxy_health_reason=config_test
					return 1
				}
			fi
			;;
	esac
	return 0
}

wrtbak_proxy_service_command() {
	wrtbak_proxy_service=$1
	wrtbak_proxy_action=$2
	wrtbak_proxy_script=$(wrtbak_root_path "/etc/init.d/$wrtbak_proxy_service")
	[ -x "$wrtbak_proxy_script" ] || return 1
	"$wrtbak_proxy_script" "$wrtbak_proxy_action"
}

wrtbak_proxy_health_check() {
	wrtbak_proxy_name=$1
	wrtbak_proxy_service=$(wrtbak_proxy_service_name "$wrtbak_proxy_name") || return 1
	wrtbak_proxy_health_reason=service_status
	wrtbak_proxy_service_command "$wrtbak_proxy_service" status >/dev/null 2>&1 || return 1
	if command -v logread >/dev/null 2>&1; then
		if logread -e "$wrtbak_proxy_service" 2>/dev/null | tail -n 80 | grep -Eiq 'parse error|panic|invalid|failed|error'; then
			wrtbak_proxy_health_reason=log_failure
			return 1
		fi
	fi
	wrtbak_proxy_health_reason=ok
	return 0
}

wrtbak_proxy_restart() {
	wrtbak_proxy_name=$1
	wrtbak_proxy_service=$(wrtbak_proxy_service_name "$wrtbak_proxy_name") || return 1
	wrtbak_proxy_service_command "$wrtbak_proxy_service" restart >/dev/null 2>&1
}

wrtbak_proxy_stop() {
	wrtbak_proxy_name=$1
	wrtbak_proxy_service=$(wrtbak_proxy_service_name "$wrtbak_proxy_name") || return 1
	wrtbak_proxy_service_command "$wrtbak_proxy_service" stop >/dev/null 2>&1
}

wrtbak_proxy_write_receipt() {
	wrtbak_proxy_name=$1
	wrtbak_manifest=$2
	wrtbak_input=$3
	wrtbak_receipt=$(wrtbak_proxy_receipt_path "$wrtbak_proxy_name")
	wrtbak_mkdir_parent "$wrtbak_receipt"
	wrtbak_tmp="$wrtbak_receipt.tmp.$$"
	{
		printf '{\n'
		printf '  "ok": true,\n'
		printf '  "proxy": '; wrtbak_json_string "$wrtbak_proxy_name"; printf ',\n'
		printf '  "target_path": '; wrtbak_json_string "$(wrtbak_proxy_manifest_value "$wrtbak_manifest" '@.target_path')"; printf ',\n'
		printf '  "artifact_path": '; wrtbak_json_string "$(wrtbak_proxy_manifest_value "$wrtbak_manifest" '@.artifact_path')"; printf ',\n'
		printf '  "sha256": '; wrtbak_json_string "$(wrtbak_proxy_manifest_value "$wrtbak_manifest" '@.sha256')"; printf ',\n'
		printf '  "size": %s,\n' "$(wrtbak_proxy_manifest_value "$wrtbak_manifest" '@.size')"
		printf '  "local_input": '; wrtbak_json_string "$wrtbak_input"; printf ',\n'
		printf '  "applied_at": '; wrtbak_json_string "$(wrtbak_created_at)"; printf '\n'
		printf '}\n'
	} >"$wrtbak_tmp" || {
		rm -f "$wrtbak_tmp"
		return 1
	}
	chmod 600 "$wrtbak_tmp" 2>/dev/null || true
	mv -f "$wrtbak_tmp" "$wrtbak_receipt"
}

wrtbak_proxy_apply_json() {
	wrtbak_proxy_name=$(wrtbak_proxy_validate_name "$1") || {
		wrtbak_proxy_error_json proxy-apply "$1" invalid_proxy "proxy must be nikki or dae" ""
		return 1
	}
	wrtbak_input=$2
	wrtbak_manifest=$3
	wrtbak_confirm=$4
	if [ "$wrtbak_confirm" != "APPLY" ]; then
		wrtbak_proxy_error_json proxy-apply "$wrtbak_proxy_name" confirmation_required "confirmation must be APPLY" ""
		return 1
	fi
	[ -f "$wrtbak_input" ] && [ ! -L "$wrtbak_input" ] || {
		wrtbak_proxy_error_json proxy-apply "$wrtbak_proxy_name" invalid_input "input artifact is not a regular file" "$wrtbak_input"
		return 1
	}
	wrtbak_proxy_manifest_validate "$wrtbak_proxy_name" "$wrtbak_manifest" || {
		wrtbak_proxy_error_json proxy-apply "$wrtbak_proxy_name" invalid_manifest "proxy manifest is invalid" "$wrtbak_manifest"
		return 1
	}
	wrtbak_expected_sha=$(wrtbak_proxy_manifest_value "$wrtbak_manifest" '@.sha256')
	wrtbak_expected_size=$(wrtbak_proxy_manifest_value "$wrtbak_manifest" '@.size')
	wrtbak_actual_sha=$(wrtbak_sha256_of "$wrtbak_input")
	wrtbak_actual_size=$(stat -c '%s' "$wrtbak_input")
	if [ "$wrtbak_expected_sha" != "$wrtbak_actual_sha" ] || [ "$wrtbak_expected_size" != "$wrtbak_actual_size" ]; then
		wrtbak_proxy_error_json proxy-apply "$wrtbak_proxy_name" checksum_mismatch "artifact checksum or size does not match manifest" "$wrtbak_input"
		return 1
	fi

	wrtbak_target_logical=$(wrtbak_proxy_target_path "$wrtbak_proxy_name")
	wrtbak_target=$(wrtbak_root_path "$wrtbak_target_logical")
	wrtbak_mkdir_parent "$wrtbak_target"
	wrtbak_rollback=
	if [ -f "$wrtbak_target" ] && [ ! -L "$wrtbak_target" ]; then
		wrtbak_rollback_dir="$(wrtbak_proxy_rollback_root)/$wrtbak_proxy_name"
		mkdir -p "$wrtbak_rollback_dir" || {
			wrtbak_proxy_error_json proxy-apply "$wrtbak_proxy_name" write_failed "cannot create rollback directory" "$wrtbak_rollback_dir"
			return 1
		}
		wrtbak_rollback="$wrtbak_rollback_dir/$(date -u +%Y%m%dT%H%M%SZ)-$(basename -- "$wrtbak_target")"
		cp -p "$wrtbak_target" "$wrtbak_rollback" || {
			wrtbak_proxy_error_json proxy-apply "$wrtbak_proxy_name" write_failed "cannot create rollback copy" "$wrtbak_target_logical"
			return 1
		}
	fi

	wrtbak_tmp="$wrtbak_target.wrtbak-proxy.$$"
	rm -f "$wrtbak_tmp"
	cp "$wrtbak_input" "$wrtbak_tmp" || {
		rm -f "$wrtbak_tmp"
		wrtbak_proxy_error_json proxy-apply "$wrtbak_proxy_name" write_failed "cannot stage proxy artifact" "$wrtbak_target_logical"
		return 1
	}
	chmod 600 "$wrtbak_tmp" 2>/dev/null || true
	if ! mv -f "$wrtbak_tmp" "$wrtbak_target"; then
		rm -f "$wrtbak_tmp"
		wrtbak_proxy_error_json proxy-apply "$wrtbak_proxy_name" write_failed "cannot install proxy artifact" "$wrtbak_target_logical"
		return 1
	fi

	wrtbak_proxy_cleanup_cache "$wrtbak_proxy_name"
	wrtbak_proxy_health_reason=unknown
	wrtbak_proxy_health_ok=0
	if wrtbak_proxy_config_test "$wrtbak_proxy_name"; then
		wrtbak_proxy_restart "$wrtbak_proxy_name" || true
		if wrtbak_proxy_health_check "$wrtbak_proxy_name"; then
			wrtbak_proxy_health_ok=1
		fi
	fi
	if [ "$wrtbak_proxy_health_ok" -eq 1 ]; then
		wrtbak_proxy_write_receipt "$wrtbak_proxy_name" "$wrtbak_manifest" "$wrtbak_input" || true
		printf '{\n'
		printf '  "ok": true,\n'
		printf '  "operation": "proxy-apply",\n'
		printf '  "proxy": '; wrtbak_json_string "$wrtbak_proxy_name"; printf ',\n'
		printf '  "target_path": '; wrtbak_json_string "$wrtbak_target_logical"; printf ',\n'
		printf '  "sha256": '; wrtbak_json_string "$wrtbak_actual_sha"; printf ',\n'
		printf '  "health": { "ok": true },\n'
		printf '  "rollback_path": '; wrtbak_json_string "$wrtbak_rollback"; printf ',\n'
		printf '  "receipt_path": '; wrtbak_json_string "$(wrtbak_proxy_receipt_path "$wrtbak_proxy_name")"; printf '\n'
		printf '}\n'
		return 0
	fi

	if [ -n "$wrtbak_rollback" ] && [ -f "$wrtbak_rollback" ]; then
		cp -p "$wrtbak_rollback" "$wrtbak_target" || true
		wrtbak_proxy_restart "$wrtbak_proxy_name" || true
		printf '{\n'
		printf '  "ok": false,\n'
		printf '  "operation": "proxy-apply",\n'
		printf '  "proxy": '; wrtbak_json_string "$wrtbak_proxy_name"; printf ',\n'
		printf '  "code": "health_check_failed",\n'
		printf '  "message": "proxy service failed after applying artifact",\n'
		printf '  "health": { "ok": false, "reason": '; wrtbak_json_string "$wrtbak_proxy_health_reason"; printf ' },\n'
		printf '  "rollback": { "ok": true, "action": "restored_previous", "path": '; wrtbak_json_string "$wrtbak_rollback"; printf ' }\n'
		printf '}\n'
		return 1
	fi

	rm -f "$wrtbak_target"
	wrtbak_proxy_stop "$wrtbak_proxy_name" || true
	printf '{\n'
	printf '  "ok": false,\n'
	printf '  "operation": "proxy-apply",\n'
	printf '  "proxy": '; wrtbak_json_string "$wrtbak_proxy_name"; printf ',\n'
	printf '  "code": "health_check_failed",\n'
	printf '  "message": "proxy service failed and no previous config exists",\n'
	printf '  "health": { "ok": false, "reason": '; wrtbak_json_string "$wrtbak_proxy_health_reason"; printf ' },\n'
	printf '  "rollback": { "ok": false, "action": "service_stopped" }\n'
	printf '}\n'
	return 1
}
