#!/bin/sh

wrtbak_remote_normalize_name() {
	wrtbak_name=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
	wrtbak_name=$(printf '%s' "$wrtbak_name" | sed 's/[^a-z0-9._-]/-/g;s/-\{1,\}/-/g;s/^-//;s/-$//')
	if [ -n "$wrtbak_name" ]; then
		printf '%s\n' "$wrtbak_name"
	else
		printf 'unknown\n'
	fi
}

wrtbak_normalize_remote_path() {
	wrtbak_path=$1
	wrtbak_result=

	while [ "${wrtbak_path#/}" != "$wrtbak_path" ]; do
		wrtbak_path=${wrtbak_path#/}
	done
	while [ "${wrtbak_path%/}" != "$wrtbak_path" ]; do
		wrtbak_path=${wrtbak_path%/}
	done

	[ -n "$wrtbak_path" ] || {
		printf '\n'
		return 0
	}

	case "$wrtbak_path" in
		*//*)
			return 1
			;;
	esac

	wrtbak_old_ifs=$IFS
	IFS=/
	for wrtbak_segment in $wrtbak_path; do
		IFS=$wrtbak_old_ifs
		case "$wrtbak_segment" in
			""|"."|"..")
				return 1
				;;
		esac
		if wrtbak_has_c0_control "$wrtbak_segment"; then
			return 1
		fi
		if [ -n "$wrtbak_result" ]; then
			wrtbak_result="$wrtbak_result/$wrtbak_segment"
		else
			wrtbak_result=$wrtbak_segment
		fi
		IFS=/
	done
	IFS=$wrtbak_old_ifs

	printf '%s\n' "$wrtbak_result"
}

wrtbak_join_remote_path() {
	wrtbak_joined=
	for wrtbak_part in "$@"; do
		wrtbak_part=$(wrtbak_normalize_remote_path "$wrtbak_part") || return 1
		[ -n "$wrtbak_part" ] || continue
		if [ -n "$wrtbak_joined" ]; then
			wrtbak_joined="$wrtbak_joined/$wrtbak_part"
		else
			wrtbak_joined=$wrtbak_part
		fi
	done
	printf '%s\n' "$wrtbak_joined"
}

wrtbak_hash8() {
	printf '%s' "$1" | sha256sum | awk '{ print substr($1, 1, 8) }'
}

wrtbak_remote_board_label() {
	wrtbak_label=$(wrtbak_board_model)
	if [ "$wrtbak_label" = "unknown" ]; then
		wrtbak_board=$(wrtbak_root_path /etc/board.json)
		if [ -r "$wrtbak_board" ]; then
			wrtbak_label=$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$wrtbak_board" | sed -n '1p')
		fi
	fi
	if [ -z "$wrtbak_label" ] || [ "$wrtbak_label" = "unknown" ]; then
		wrtbak_label=$(wrtbak_board_name)
	fi
	printf '%s\n' "${wrtbak_label:-unknown}"
}

wrtbak_mac_lower() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

wrtbak_mac_is_multicast() {
	wrtbak_octet=$(printf '%s' "$1" | cut -d: -f1)
	wrtbak_nibble=$(printf '%s' "$wrtbak_octet" | cut -c2)
	case "$wrtbak_nibble" in
		1|3|5|7|9|b|d|f)
			return 0
			;;
	esac
	return 1
}

wrtbak_mac_is_local_admin() {
	wrtbak_octet=$(printf '%s' "$1" | cut -d: -f1)
	wrtbak_nibble=$(printf '%s' "$wrtbak_octet" | cut -c2)
	case "$wrtbak_nibble" in
		2|3|6|7|a|b|e|f)
			return 0
			;;
	esac
	return 1
}

wrtbak_mac_is_usable() {
	case "$1" in
		""|"00:00:00:00:00:00")
			return 1
			;;
	esac
	case "$1" in
		??:??:??:??:??:??)
			;;
		*)
			return 1
			;;
	esac
	! wrtbak_mac_is_multicast "$1"
}

wrtbak_first_stable_mac_from_group() {
	wrtbak_want_local=$1
	wrtbak_sys_class=$(wrtbak_root_path /sys/class/net)
	[ -d "$wrtbak_sys_class" ] || return 1

	for wrtbak_iface in $(ls "$wrtbak_sys_class" 2>/dev/null | sort); do
		[ "$wrtbak_iface" != "lo" ] || continue
		wrtbak_addr_file="$wrtbak_sys_class/$wrtbak_iface/address"
		[ -r "$wrtbak_addr_file" ] || continue
		wrtbak_mac=$(wrtbak_mac_lower "$(sed -n '1p' "$wrtbak_addr_file")")
		wrtbak_mac_is_usable "$wrtbak_mac" || continue
		if wrtbak_mac_is_local_admin "$wrtbak_mac"; then
			wrtbak_is_local=1
		else
			wrtbak_is_local=0
		fi
		if [ "$wrtbak_is_local" = "$wrtbak_want_local" ]; then
			printf '%s\n' "$wrtbak_mac"
			return 0
		fi
	done
	return 1
}

wrtbak_first_stable_mac() {
	wrtbak_first_stable_mac_from_group 0 || wrtbak_first_stable_mac_from_group 1
}

wrtbak_device_id_source() {
	wrtbak_machine_id=$(wrtbak_root_path /etc/machine-id)
	if [ -r "$wrtbak_machine_id" ]; then
		wrtbak_id_source=$(sed -n '1p' "$wrtbak_machine_id")
		if [ -n "$wrtbak_id_source" ]; then
			printf '%s\n' "$wrtbak_id_source"
			return 0
		fi
	fi

	wrtbak_mac=$(wrtbak_first_stable_mac 2>/dev/null || true)
	if [ -n "$wrtbak_mac" ]; then
		printf '%s\n' "$wrtbak_mac"
		return 0
	fi

	printf '%s-%s\n' "$(wrtbak_remote_board_label)" "$(wrtbak_hostname)"
}

wrtbak_generated_device_id() {
	wrtbak_host=$(wrtbak_remote_normalize_name "$(wrtbak_hostname)")
	wrtbak_board=$(wrtbak_remote_normalize_name "$(wrtbak_remote_board_label)")
	wrtbak_hash=$(wrtbak_hash8 "$(wrtbak_device_id_source)")
	wrtbak_prefix="$wrtbak_host-$wrtbak_board"
	wrtbak_max_prefix_len=$((64 - 1 - 8))

	if [ "${#wrtbak_prefix}" -gt "$wrtbak_max_prefix_len" ]; then
		wrtbak_prefix=$(printf '%s' "$wrtbak_prefix" | cut -c "1-$wrtbak_max_prefix_len" | sed 's/-$//')
	fi
	printf '%s-%s\n' "$wrtbak_prefix" "$wrtbak_hash"
}

wrtbak_effective_device_id() {
	wrtbak_stored=$(wrtbak_main_option device_id "")
	if [ -n "$wrtbak_stored" ]; then
		wrtbak_remote_normalize_name "$wrtbak_stored"
	else
		wrtbak_generated_device_id
	fi
}

wrtbak_command_available_bool() {
	if command -v "$1" >/dev/null 2>&1; then
		printf 'true'
	else
		printf 'false'
	fi
}

wrtbak_remote_bool_json() {
	if wrtbak_bool_enabled "$1"; then
		printf 'true'
	else
		printf 'false'
	fi
}

wrtbak_remote_secret_json() {
	if wrtbak_secret_is_set "$1"; then
		printf 'true'
	else
		printf 'false'
	fi
}

wrtbak_remote_error_json() {
	wrtbak_operation=$1
	wrtbak_target=$2
	wrtbak_code=$3
	wrtbak_message=$4
	wrtbak_detail=${5:-}

	printf '{\n'
	printf '  "ok": false,\n'
	printf '  "operation": '; wrtbak_json_string "$wrtbak_operation"; printf ',\n'
	printf '  "target": '; wrtbak_json_string "$wrtbak_target"; printf ',\n'
	printf '  "code": '; wrtbak_json_string "$wrtbak_code"; printf ',\n'
	printf '  "message": '; wrtbak_json_string "$wrtbak_message"; printf ',\n'
	printf '  "detail": '; wrtbak_json_string "$wrtbak_detail"; printf '\n'
	printf '}\n'
}

wrtbak_remote_resolve_target() {
	wrtbak_target=$1
	if [ "$wrtbak_target" = "default" ]; then
		wrtbak_target=$(wrtbak_main_option default_target webdav)
	fi
	case "$wrtbak_target" in
		webdav|s3)
			printf '%s\n' "$wrtbak_target"
			return 0
			;;
	esac
	return 1
}

wrtbak_remote_load_webdav_config() {
	wrtbak_remote_webdav_enabled=$(wrtbak_remote_option webdav enabled 0)
	wrtbak_remote_webdav_driver=$(wrtbak_remote_option webdav driver curl)
	wrtbak_remote_webdav_url=$(wrtbak_remote_option webdav url "")
	wrtbak_remote_webdav_username=$(wrtbak_remote_option webdav username "")
	wrtbak_remote_webdav_password=$(wrtbak_remote_option webdav password "")
	wrtbak_remote_webdav_path=$(wrtbak_normalize_remote_path "$(wrtbak_remote_option webdav path "")") || return 1

	[ "$wrtbak_remote_webdav_driver" = "curl" ] || return 1
	[ -n "$wrtbak_remote_webdav_url" ] || return 1
	[ -n "$wrtbak_remote_webdav_username" ] || return 1
	[ -n "$wrtbak_remote_webdav_password" ] || return 1
	return 0
}

wrtbak_remote_load_s3_config() {
	wrtbak_remote_s3_enabled=$(wrtbak_remote_option s3 enabled 0)
	wrtbak_remote_s3_driver=$(wrtbak_remote_option s3 driver rclone)
	wrtbak_remote_s3_endpoint=$(wrtbak_remote_option s3 endpoint "")
	wrtbak_remote_s3_region=$(wrtbak_remote_option s3 region us-east-1)
	wrtbak_remote_s3_bucket=$(wrtbak_remote_option s3 bucket "")
	wrtbak_remote_s3_access_key=$(wrtbak_remote_option s3 access_key "")
	wrtbak_remote_s3_secret_key=$(wrtbak_remote_option s3 secret_key "")
	wrtbak_remote_s3_path=$(wrtbak_normalize_remote_path "$(wrtbak_remote_option s3 path "")") || return 1
	wrtbak_remote_s3_force_path_style=$(wrtbak_remote_option s3 force_path_style 1)

	[ "$wrtbak_remote_s3_driver" = "rclone" ] || return 1
	[ -n "$wrtbak_remote_s3_endpoint" ] || return 1
	[ -n "$wrtbak_remote_s3_bucket" ] || return 1
	[ -n "$wrtbak_remote_s3_access_key" ] || return 1
	[ -n "$wrtbak_remote_s3_secret_key" ] || return 1
	return 0
}

wrtbak_remote_require_enabled() {
	wrtbak_target=$1
	if ! wrtbak_bool_enabled "$(wrtbak_remote_option "$wrtbak_target" enabled 0)"; then
		wrtbak_remote_error_json "$2" "$wrtbak_target" target_disabled "$wrtbak_target remote target is disabled" ""
		return 1
	fi
	return 0
}

wrtbak_remote_require_dependency() {
	wrtbak_dependency=$1
	wrtbak_operation=$2
	wrtbak_target=$3
	if ! command -v "$wrtbak_dependency" >/dev/null 2>&1; then
		wrtbak_remote_error_json "$wrtbak_operation" "$wrtbak_target" missing_dependency "$wrtbak_dependency is not installed" ""
		return 1
	fi
	return 0
}

wrtbak_remote_test() {
	wrtbak_target=$(wrtbak_remote_resolve_target "$1") || {
		wrtbak_remote_error_json remote-test "$1" invalid_config "unknown remote target" ""
		return 1
	}

	case "$wrtbak_target" in
		webdav)
			if ! wrtbak_remote_load_webdav_config; then
				wrtbak_remote_error_json remote-test "$wrtbak_target" invalid_config "WebDAV target is incomplete" ""
				return 1
			fi
			wrtbak_remote_require_dependency curl remote-test "$wrtbak_target" || return 1
			wrtbak_device_id=$(wrtbak_effective_device_id)
			wrtbak_remote_path=$(wrtbak_webdav_probe "$wrtbak_remote_webdav_url" "$wrtbak_remote_webdav_username" "$wrtbak_remote_webdav_password" "$wrtbak_remote_webdav_path" "$wrtbak_device_id") || {
				wrtbak_remote_error_json remote-test "$wrtbak_target" command_failed "WebDAV probe failed" ""
				return 1
			}
			printf '{\n'
			printf '  "ok": true,\n'
			printf '  "operation": "remote-test",\n'
			printf '  "target": "webdav",\n'
			printf '  "driver": "curl",\n'
			printf '  "remote_path": '; wrtbak_json_string "$wrtbak_remote_path"; printf '\n'
			printf '}\n'
			;;
		s3)
			if ! wrtbak_remote_load_s3_config; then
				wrtbak_remote_error_json remote-test "$wrtbak_target" invalid_config "S3 target is incomplete" ""
				return 1
			fi
			wrtbak_remote_require_dependency rclone remote-test "$wrtbak_target" || return 1
			wrtbak_device_id=$(wrtbak_effective_device_id)
			wrtbak_remote_path=$(wrtbak_s3_probe "$wrtbak_remote_s3_endpoint" "$wrtbak_remote_s3_region" "$wrtbak_remote_s3_bucket" "$wrtbak_remote_s3_access_key" "$wrtbak_remote_s3_secret_key" "$wrtbak_remote_s3_path" "$wrtbak_remote_s3_force_path_style" "$wrtbak_device_id") || {
				wrtbak_remote_error_json remote-test "$wrtbak_target" command_failed "S3 probe failed" ""
				return 1
			}
			printf '{\n'
			printf '  "ok": true,\n'
			printf '  "operation": "remote-test",\n'
			printf '  "target": "s3",\n'
			printf '  "driver": "rclone",\n'
			printf '  "remote_path": '; wrtbak_json_string "$wrtbak_remote_path"; printf '\n'
			printf '}\n'
			;;
		*)
			wrtbak_remote_error_json remote-test "$wrtbak_target" invalid_config "unknown remote target" ""
			return 1
			;;
	esac
}

wrtbak_remote_list_emit_json() {
	wrtbak_target=$1
	wrtbak_driver=$2
	wrtbak_tsv=$3
	printf '{\n'
	printf '  "ok": true,\n'
	printf '  "operation": "remote-list",\n'
	printf '  "target": '; wrtbak_json_string "$wrtbak_target"; printf ',\n'
	printf '  "driver": '; wrtbak_json_string "$wrtbak_driver"; printf ',\n'
	printf '  "backups": [\n'
	wrtbak_first=1
	while IFS='	' read -r wrtbak_path wrtbak_filename wrtbak_format wrtbak_size wrtbak_modified || [ -n "$wrtbak_path" ]; do
		[ -n "$wrtbak_path" ] || continue
		if [ "$wrtbak_first" -eq 1 ]; then
			wrtbak_first=0
		else
			printf ',\n'
		fi
		printf '    {\n'
		printf '      "path": '; wrtbak_json_string "$wrtbak_path"; printf ',\n'
		printf '      "filename": '; wrtbak_json_string "$wrtbak_filename"; printf ',\n'
		printf '      "format": '; wrtbak_json_string "$wrtbak_format"; printf ',\n'
		printf '      "size": '
		case "$wrtbak_size" in
			""|*[!0-9]*)
				printf 'null'
				;;
			*)
				printf '%s' "$wrtbak_size"
				;;
		esac
		printf ',\n'
		printf '      "modified": '; wrtbak_json_string "$wrtbak_modified"; printf '\n'
		printf '    }'
	done < "$wrtbak_tsv"
	printf '\n'
	printf '  ]\n'
	printf '}\n'
}

wrtbak_remote_list() {
	wrtbak_target=$(wrtbak_remote_resolve_target "$1") || {
		wrtbak_remote_error_json remote-list "$1" invalid_config "unknown remote target" ""
		return 1
	}
	wrtbak_remote_require_enabled "$wrtbak_target" remote-list || return 1

	case "$wrtbak_target" in
		webdav)
			if ! wrtbak_remote_load_webdav_config; then
				wrtbak_remote_error_json remote-list "$wrtbak_target" invalid_config "WebDAV target is incomplete" ""
				return 1
			fi
			wrtbak_remote_require_dependency curl remote-list "$wrtbak_target" || return 1
			wrtbak_device_id=$(wrtbak_effective_device_id)
			wrtbak_tsv=$(mktemp "${TMPDIR:-/tmp}/wrtbak-webdav-list.XXXXXX") || {
				wrtbak_remote_error_json remote-list "$wrtbak_target" command_failed "cannot create temporary file" ""
				return 1
			}
			if ! wrtbak_webdav_list_raw "$wrtbak_remote_webdav_url" "$wrtbak_remote_webdav_username" "$wrtbak_remote_webdav_password" "$wrtbak_remote_webdav_path" "$wrtbak_device_id" > "$wrtbak_tsv"; then
				rm -f "$wrtbak_tsv"
				wrtbak_remote_error_json remote-list "$wrtbak_target" unsupported_list "WebDAV listing failed" ""
				return 1
			fi
			wrtbak_remote_list_emit_json "$wrtbak_target" curl "$wrtbak_tsv"
			rm -f "$wrtbak_tsv"
			;;
		s3)
			if ! wrtbak_remote_load_s3_config; then
				wrtbak_remote_error_json remote-list "$wrtbak_target" invalid_config "S3 target is incomplete" ""
				return 1
			fi
			wrtbak_remote_require_dependency rclone remote-list "$wrtbak_target" || return 1
			wrtbak_device_id=$(wrtbak_effective_device_id)
			wrtbak_tsv=$(mktemp "${TMPDIR:-/tmp}/wrtbak-s3-list.XXXXXX") || {
				wrtbak_remote_error_json remote-list "$wrtbak_target" command_failed "cannot create temporary file" ""
				return 1
			}
			if ! wrtbak_s3_list_raw "$wrtbak_remote_s3_endpoint" "$wrtbak_remote_s3_region" "$wrtbak_remote_s3_bucket" "$wrtbak_remote_s3_access_key" "$wrtbak_remote_s3_secret_key" "$wrtbak_remote_s3_path" "$wrtbak_remote_s3_force_path_style" "$wrtbak_device_id" > "$wrtbak_tsv"; then
				rm -f "$wrtbak_tsv"
				wrtbak_remote_error_json remote-list "$wrtbak_target" command_failed "S3 listing failed" ""
				return 1
			fi
			wrtbak_remote_list_emit_json "$wrtbak_target" rclone "$wrtbak_tsv"
			rm -f "$wrtbak_tsv"
			;;
		*)
			wrtbak_remote_error_json remote-list "$wrtbak_target" invalid_config "unknown remote target" ""
			return 1
			;;
	esac
}

wrtbak_remote_status_target_json() {
	wrtbak_target=$1
	wrtbak_enabled=$(wrtbak_remote_option "$wrtbak_target" enabled 0)
	wrtbak_driver_default=

	case "$wrtbak_target" in
		webdav)
			wrtbak_driver_default=curl
			wrtbak_driver=$(wrtbak_remote_option "$wrtbak_target" driver "$wrtbak_driver_default")
			wrtbak_path=$(wrtbak_normalize_remote_path "$(wrtbak_remote_option "$wrtbak_target" path "")" 2>/dev/null || printf '')
			wrtbak_password=$(wrtbak_remote_option "$wrtbak_target" password "")
			printf '    "webdav": {\n'
			printf '      "enabled": '; wrtbak_remote_bool_json "$wrtbak_enabled"; printf ',\n'
			printf '      "driver": '; wrtbak_json_string "$wrtbak_driver"; printf ',\n'
			printf '      "url": '; wrtbak_json_string "$(wrtbak_remote_option "$wrtbak_target" url "")"; printf ',\n'
			printf '      "username": '; wrtbak_json_string "$(wrtbak_remote_option "$wrtbak_target" username "")"; printf ',\n'
			printf '      "password_set": '; wrtbak_remote_secret_json "$wrtbak_password"; printf ',\n'
			printf '      "path": '; wrtbak_json_string "$wrtbak_path"; printf '\n'
			printf '    }'
			;;
		s3)
			wrtbak_driver_default=rclone
			wrtbak_driver=$(wrtbak_remote_option "$wrtbak_target" driver "$wrtbak_driver_default")
			wrtbak_path=$(wrtbak_normalize_remote_path "$(wrtbak_remote_option "$wrtbak_target" path "")" 2>/dev/null || printf '')
			wrtbak_access_key=$(wrtbak_remote_option "$wrtbak_target" access_key "")
			wrtbak_secret_key=$(wrtbak_remote_option "$wrtbak_target" secret_key "")
			printf '    "s3": {\n'
			printf '      "enabled": '; wrtbak_remote_bool_json "$wrtbak_enabled"; printf ',\n'
			printf '      "driver": '; wrtbak_json_string "$wrtbak_driver"; printf ',\n'
			printf '      "endpoint": '; wrtbak_json_string "$(wrtbak_remote_option "$wrtbak_target" endpoint "")"; printf ',\n'
			printf '      "region": '; wrtbak_json_string "$(wrtbak_remote_option "$wrtbak_target" region us-east-1)"; printf ',\n'
			printf '      "bucket": '; wrtbak_json_string "$(wrtbak_remote_option "$wrtbak_target" bucket "")"; printf ',\n'
			printf '      "access_key_set": '; wrtbak_remote_secret_json "$wrtbak_access_key"; printf ',\n'
			printf '      "secret_key_set": '; wrtbak_remote_secret_json "$wrtbak_secret_key"; printf ',\n'
			printf '      "path": '; wrtbak_json_string "$wrtbak_path"; printf ',\n'
			printf '      "force_path_style": '; wrtbak_remote_bool_json "$(wrtbak_remote_option "$wrtbak_target" force_path_style 1)"; printf '\n'
			printf '    }'
			;;
	esac
}

wrtbak_remote_schedule_status_json() {
	printf '  "schedule": {\n'
	printf '    "enabled": '; wrtbak_remote_bool_json "$(wrtbak_schedule_option enabled 0)"; printf ',\n'
	printf '    "frequency": '; wrtbak_json_string "$(wrtbak_schedule_option frequency daily)"; printf ',\n'
	printf '    "time": '; wrtbak_json_string "$(wrtbak_schedule_option time 03:30)"; printf ',\n'
	printf '    "weekday": '; wrtbak_json_string "$(wrtbak_schedule_option weekday 0)"; printf ',\n'
	printf '    "day_of_month": '; wrtbak_json_string "$(wrtbak_schedule_option day_of_month 1)"; printf ',\n'
	printf '    "profile": '; wrtbak_json_string "$(wrtbak_schedule_option profile auto)"; printf ',\n'
	printf '    "items": '; wrtbak_json_string "$(wrtbak_schedule_option items all)"; printf ',\n'
	printf '    "format": '; wrtbak_json_string "$(wrtbak_schedule_option format wrtbak)"; printf ',\n'
	printf '    "max_backups": '; wrtbak_json_string "$(wrtbak_schedule_option max_backups 0)"; printf ',\n'
	printf '    "cron_installed": false,\n'
	printf '    "cron_command": ""\n'
	printf '  }'
}

wrtbak_remote_status_json() {
	wrtbak_stored_device_id=$(wrtbak_main_option device_id "")
	wrtbak_generated_device_id=$(wrtbak_generated_device_id)
	if [ -n "$wrtbak_stored_device_id" ]; then
		wrtbak_device_id=$(wrtbak_remote_normalize_name "$wrtbak_stored_device_id")
	else
		wrtbak_device_id=$wrtbak_generated_device_id
	fi

	printf '{\n'
	printf '  "ok": true,\n'
	printf '  "operation": "remote-status",\n'
	printf '  "device_id": '; wrtbak_json_string "$wrtbak_device_id"; printf ',\n'
	printf '  "generated_device_id": '; wrtbak_json_string "$wrtbak_generated_device_id"; printf ',\n'
	printf '  "default_target": '; wrtbak_json_string "$(wrtbak_main_option default_target webdav)"; printf ',\n'
	printf '  "dependencies": {\n'
	printf '    "curl": '; wrtbak_command_available_bool curl; printf ',\n'
	printf '    "rclone": '; wrtbak_command_available_bool rclone; printf '\n'
	printf '  },\n'
	printf '  "targets": {\n'
	wrtbak_remote_status_target_json webdav
	printf ',\n'
	wrtbak_remote_status_target_json s3
	printf '\n'
	printf '  },\n'
	wrtbak_remote_schedule_status_json
	printf '\n'
	printf '}\n'
}
