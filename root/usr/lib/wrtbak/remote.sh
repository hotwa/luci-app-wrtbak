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

wrtbak_remote_lock_path() {
	printf '%s\n' "${WRTBAK_REMOTE_LOCK:-$(wrtbak_root_path /tmp/wrtbak/remote.lock)}"
}

wrtbak_remote_lock_acquire() {
	wrtbak_lock=$(wrtbak_remote_lock_path)
	mkdir -p "$(dirname -- "$wrtbak_lock")" || return 1
	wrtbak_wait=0
	while [ "$wrtbak_wait" -le 5 ]; do
		if mkdir "$wrtbak_lock" 2>/dev/null; then
			wrtbak_remote_lock_held=$wrtbak_lock
			return 0
		fi
		wrtbak_wait=$((wrtbak_wait + 1))
		[ "$wrtbak_wait" -le 5 ] || break
		sleep 1
	done
	return 1
}

wrtbak_remote_lock_release() {
	if [ -n "${wrtbak_remote_lock_held:-}" ]; then
		rmdir "$wrtbak_remote_lock_held" 2>/dev/null || true
		wrtbak_remote_lock_held=
	fi
}

wrtbak_history_file() {
	wrtbak_history=$(wrtbak_main_option history_file /overlay/wrtbak/remote-history.jsonl)
	wrtbak_root_path "$wrtbak_history"
}

wrtbak_history_append() {
	wrtbak_operation=$1
	wrtbak_target=$2
	wrtbak_ok=$3
	wrtbak_code=$4
	wrtbak_message=$5
	wrtbak_remote_path=${6:-}
	wrtbak_history=$(wrtbak_history_file)
	wrtbak_max=$(wrtbak_main_option history_max_entries 20)
	case "$wrtbak_max" in
		''|*[!0-9]*) wrtbak_max=20 ;;
	esac
	mkdir -p "$(dirname -- "$wrtbak_history")" || return 0
	{
		printf '{'
		printf '"timestamp":'; wrtbak_json_string "$(wrtbak_created_at)"; printf ','
		printf '"operation":'; wrtbak_json_string "$wrtbak_operation"; printf ','
		printf '"target":'; wrtbak_json_string "$wrtbak_target"; printf ','
		printf '"ok":%s,' "$wrtbak_ok"
		printf '"code":'; wrtbak_json_string "$wrtbak_code"; printf ','
		printf '"remote_path":'; wrtbak_json_string "$wrtbak_remote_path"; printf ','
		printf '"message":'; wrtbak_json_string "$wrtbak_message"
		printf '}\n'
	} >> "$wrtbak_history" || return 0
	if [ "$wrtbak_max" -gt 0 ]; then
		wrtbak_tmp_history="$wrtbak_history.tmp.$$"
		tail -n "$wrtbak_max" "$wrtbak_history" > "$wrtbak_tmp_history" 2>/dev/null && mv "$wrtbak_tmp_history" "$wrtbak_history"
		rm -f "$wrtbak_tmp_history" 2>/dev/null || true
	fi
}

wrtbak_remote_format_for_path() {
	case "$1" in
		*.sysupgrade.tar.gz) printf 'sysupgrade\n' ;;
		*.wrtbak) printf 'wrtbak\n' ;;
		*) return 1 ;;
	esac
}

wrtbak_restore_cache_dir() { printf '%s\n' "$(wrtbak_root_path /tmp/wrtbak/restore-cache)"; }

wrtbak_remote_safe_basename() { printf '%s' "$(basename -- "$1")" | tr -c 'A-Za-z0-9._-' '-'; }

wrtbak_remote_cache_path_for() {
	wrtbak_cache_remote_path=$(wrtbak_normalize_remote_path "$1") || return 1
	wrtbak_cache_dir=$(wrtbak_restore_cache_dir)
	mkdir -p "$wrtbak_cache_dir" || return 1
	chmod 700 "$wrtbak_cache_dir" || return 1
	wrtbak_cache_hash=$(printf '%s' "$wrtbak_cache_remote_path" | sha256sum | awk '{ print substr($1, 1, 12) }')
	wrtbak_cache_basename=$(wrtbak_remote_safe_basename "$wrtbak_cache_remote_path")
	printf '%s/%s-%s\n' "$wrtbak_cache_dir" "$wrtbak_cache_hash" "$wrtbak_cache_basename"
}

wrtbak_remote_json_unescape() {
	sed 's/\\"/"/g;s/\\\\/\\/g'
}

wrtbak_remote_sidecar_string_field() {
	wrtbak_sidecar_field=$1
	wrtbak_sidecar_file=$2
	awk -v field="$wrtbak_sidecar_field" '
		$0 ~ "\"" field "\"" {
			line = $0
			sub("^[[:space:]]*\"" field "\"[[:space:]]*:[[:space:]]*\"", "", line)
			sub("\"[,]?[[:space:]]*$", "", line)
			print line
			exit
		}
	' "$wrtbak_sidecar_file" | wrtbak_remote_json_unescape
}

wrtbak_remote_sidecar_number_field() {
	wrtbak_sidecar_field=$1
	wrtbak_sidecar_file=$2
	awk -v field="$wrtbak_sidecar_field" '
		$0 ~ "\"" field "\"" {
			line = $0
			sub("^[[:space:]]*\"" field "\"[[:space:]]*:[[:space:]]*", "", line)
			sub("[^0-9].*$", "", line)
			print line
			exit
		}
	' "$wrtbak_sidecar_file"
}

wrtbak_remote_sidecar_matches() {
	wrtbak_match_sidecar=$1
	wrtbak_match_local_path=$2
	wrtbak_match_target=$3
	wrtbak_match_driver=$4
	wrtbak_match_remote_path=$5
	wrtbak_match_size=$6
	wrtbak_match_remote_modified=$7
	wrtbak_match_remote_etag=$8

	[ -r "$wrtbak_match_sidecar" ] || return 1
	[ -f "$wrtbak_match_local_path" ] || return 1
	[ "$(wrtbak_remote_sidecar_string_field target "$wrtbak_match_sidecar")" = "$wrtbak_match_target" ] || return 1
	[ "$(wrtbak_remote_sidecar_string_field driver "$wrtbak_match_sidecar")" = "$wrtbak_match_driver" ] || return 1
	[ "$(wrtbak_remote_sidecar_string_field remote_path "$wrtbak_match_sidecar")" = "$wrtbak_match_remote_path" ] || return 1
	[ "$(wrtbak_remote_sidecar_number_field size "$wrtbak_match_sidecar")" = "$wrtbak_match_size" ] || return 1
	wrtbak_match_sidecar_sha=$(wrtbak_remote_sidecar_string_field sha256 "$wrtbak_match_sidecar")
	[ -n "$wrtbak_match_sidecar_sha" ] || return 1
	[ "$(wrtbak_sha256_of "$wrtbak_match_local_path")" = "$wrtbak_match_sidecar_sha" ] || return 1
	if [ -n "$wrtbak_match_remote_modified" ]; then
		[ "$(wrtbak_remote_sidecar_string_field remote_modified "$wrtbak_match_sidecar")" = "$wrtbak_match_remote_modified" ] || return 1
	fi
	if [ -n "$wrtbak_match_remote_etag" ]; then
		[ "$(wrtbak_remote_sidecar_string_field remote_etag "$wrtbak_match_sidecar")" = "$wrtbak_match_remote_etag" ] || return 1
	fi
	return 0
}

wrtbak_remote_write_sidecar() {
	wrtbak_write_sidecar=$1
	wrtbak_write_local_path=$2
	wrtbak_write_target=$3
	wrtbak_write_driver=$4
	wrtbak_write_remote_path=$5
	wrtbak_write_filename=$6
	wrtbak_write_format=$7
	wrtbak_write_size=$8
	wrtbak_write_remote_modified=$9
	shift 9
	wrtbak_write_remote_etag=$1
	wrtbak_write_sha=$(wrtbak_sha256_of "$wrtbak_write_local_path") || return 1
	wrtbak_write_tmp="$wrtbak_write_sidecar.tmp.$$"
	rm -f "$wrtbak_write_tmp" 2>/dev/null || true
	: > "$wrtbak_write_tmp" || return 1
	chmod 600 "$wrtbak_write_tmp" || {
		rm -f "$wrtbak_write_tmp"
		return 1
	}
	{
		printf '{\n'
		printf '  "target": '; wrtbak_json_string "$wrtbak_write_target"; printf ',\n'
		printf '  "driver": '; wrtbak_json_string "$wrtbak_write_driver"; printf ',\n'
		printf '  "remote_path": '; wrtbak_json_string "$wrtbak_write_remote_path"; printf ',\n'
		printf '  "filename": '; wrtbak_json_string "$wrtbak_write_filename"; printf ',\n'
		printf '  "format": '; wrtbak_json_string "$wrtbak_write_format"; printf ',\n'
		printf '  "size": %s,\n' "$wrtbak_write_size"
		printf '  "remote_modified": '; wrtbak_json_string "$wrtbak_write_remote_modified"; printf ',\n'
		printf '  "remote_etag": '; wrtbak_json_string "$wrtbak_write_remote_etag"; printf ',\n'
		printf '  "downloaded_at": '; wrtbak_json_string "$(wrtbak_created_at)"; printf ',\n'
		printf '  "sha256": '; wrtbak_json_string "$wrtbak_write_sha"; printf '\n'
		printf '}\n'
	} > "$wrtbak_write_tmp" || {
		rm -f "$wrtbak_write_tmp"
		return 1
	}
	if ! mv -f "$wrtbak_write_tmp" "$wrtbak_write_sidecar"; then
		rm -f "$wrtbak_write_tmp"
		return 1
	fi
}

wrtbak_remote_download_success_json() {
	wrtbak_success_target=$1
	wrtbak_success_driver=$2
	wrtbak_success_remote_path=$3
	wrtbak_success_local_path=$4
	wrtbak_success_sidecar=$5
	wrtbak_success_filename=$6
	wrtbak_success_format=$7
	wrtbak_success_size=$8
	wrtbak_success_remote_modified=$9
	shift 9
	wrtbak_success_remote_etag=$1
	wrtbak_success_sha=$2
	printf '{\n'
	printf '  "ok": true,\n'
	printf '  "operation": "remote-download",\n'
	printf '  "target": '; wrtbak_json_string "$wrtbak_success_target"; printf ',\n'
	printf '  "driver": '; wrtbak_json_string "$wrtbak_success_driver"; printf ',\n'
	printf '  "remote_path": '; wrtbak_json_string "$wrtbak_success_remote_path"; printf ',\n'
	printf '  "local_path": '; wrtbak_json_string "$wrtbak_success_local_path"; printf ',\n'
	printf '  "sidecar_path": '; wrtbak_json_string "$wrtbak_success_sidecar"; printf ',\n'
	printf '  "filename": '; wrtbak_json_string "$wrtbak_success_filename"; printf ',\n'
	printf '  "format": '; wrtbak_json_string "$wrtbak_success_format"; printf ',\n'
	printf '  "size": %s,\n' "$wrtbak_success_size"
	printf '  "remote_modified": '; wrtbak_json_string "$wrtbak_success_remote_modified"; printf ',\n'
	printf '  "remote_etag": '; wrtbak_json_string "$wrtbak_success_remote_etag"; printf ',\n'
	printf '  "sha256": '; wrtbak_json_string "$wrtbak_success_sha"; printf '\n'
	printf '}\n'
}

wrtbak_remote_device_prefix() {
	wrtbak_target=$1
	case "$wrtbak_target" in
		webdav)
			wrtbak_join_remote_path "$wrtbak_remote_webdav_path" wrtbak "$(wrtbak_effective_device_id)"
			;;
		s3)
			wrtbak_join_remote_path "$wrtbak_remote_s3_path" wrtbak "$(wrtbak_effective_device_id)"
			;;
	esac
}

wrtbak_remote_validate_backup_path() {
	wrtbak_target=$1
	wrtbak_path=$2
	wrtbak_path=$(wrtbak_normalize_remote_path "$wrtbak_path") || return 1
	wrtbak_prefix=$(wrtbak_remote_device_prefix "$wrtbak_target") || return 1
	case "$wrtbak_path" in
		"$wrtbak_prefix"/*)
			;;
		*)
			return 1
			;;
	esac
	printf '%s\n' "$wrtbak_path"
}

wrtbak_remote_stat_driver() {
	wrtbak_stat_target=$1
	wrtbak_stat_remote_path=$2
	case "$wrtbak_stat_target" in
		webdav)
			wrtbak_webdav_stat_file "$wrtbak_remote_webdav_url" "$wrtbak_remote_webdav_username" "$wrtbak_remote_webdav_password" "$wrtbak_stat_remote_path"
			;;
		s3)
			wrtbak_s3_stat_file "$wrtbak_remote_s3_endpoint" "$wrtbak_remote_s3_region" "$wrtbak_remote_s3_bucket" "$wrtbak_remote_s3_access_key" "$wrtbak_remote_s3_secret_key" "$wrtbak_remote_s3_force_path_style" "$wrtbak_stat_remote_path"
			;;
		*)
			return 1
			;;
	esac
}

wrtbak_remote_download_driver() {
	wrtbak_download_target=$1
	wrtbak_download_remote_path=$2
	wrtbak_download_local_path=$3
	case "$wrtbak_download_target" in
		webdav)
			wrtbak_webdav_download_file "$wrtbak_remote_webdav_url" "$wrtbak_remote_webdav_username" "$wrtbak_remote_webdav_password" "$wrtbak_download_remote_path" "$wrtbak_download_local_path"
			;;
		s3)
			wrtbak_s3_download_file "$wrtbak_remote_s3_endpoint" "$wrtbak_remote_s3_region" "$wrtbak_remote_s3_bucket" "$wrtbak_remote_s3_access_key" "$wrtbak_remote_s3_secret_key" "$wrtbak_remote_s3_force_path_style" "$wrtbak_download_remote_path" "$wrtbak_download_local_path"
			;;
		*)
			return 1
			;;
	esac
}

wrtbak_remote_download_into_cache() {
	wrtbak_download_cache_target=$1
	wrtbak_download_cache_driver=$2
	wrtbak_download_cache_remote_path=$3
	wrtbak_download_cache_local_path=$4
	wrtbak_download_cache_sidecar=$5
	wrtbak_download_cache_filename=$6
	wrtbak_download_cache_format=$7
	wrtbak_download_cache_size=$8
	wrtbak_download_cache_remote_modified=$9
	shift 9
	wrtbak_download_cache_remote_etag=$1
	wrtbak_download_part="$wrtbak_download_cache_local_path.part.$$"
	rm -f "$wrtbak_download_part"
	if ! wrtbak_remote_download_driver "$wrtbak_download_cache_target" "$wrtbak_download_cache_remote_path" "$wrtbak_download_part"; then
		rm -f "$wrtbak_download_part"
		return 1
	fi
	wrtbak_download_actual_size=$(stat -c '%s' "$wrtbak_download_part" 2>/dev/null) || {
		rm -f "$wrtbak_download_part"
		return 1
	}
	if [ "$wrtbak_download_actual_size" != "$wrtbak_download_cache_size" ]; then
		rm -f "$wrtbak_download_part"
		return 1
	fi
	if ! mv -f "$wrtbak_download_part" "$wrtbak_download_cache_local_path"; then
		rm -f "$wrtbak_download_part"
		return 1
	fi
	if ! wrtbak_remote_write_sidecar "$wrtbak_download_cache_sidecar" "$wrtbak_download_cache_local_path" "$wrtbak_download_cache_target" "$wrtbak_download_cache_driver" "$wrtbak_download_cache_remote_path" "$wrtbak_download_cache_filename" "$wrtbak_download_cache_format" "$wrtbak_download_cache_size" "$wrtbak_download_cache_remote_modified" "$wrtbak_download_cache_remote_etag"; then
		rm -f "$wrtbak_download_cache_local_path"
		return 1
	fi
	return 0
}

wrtbak_remote_download() {
	wrtbak_target=$(wrtbak_remote_resolve_target "$1") || {
		wrtbak_remote_error_json remote-download "$1" invalid_config "unknown remote target" ""
		return 1
	}
	wrtbak_requested_path=$2
	wrtbak_remote_require_enabled "$wrtbak_target" remote-download || return 1
	case "$wrtbak_target" in
		webdav)
			wrtbak_remote_load_webdav_config || {
				wrtbak_remote_error_json remote-download "$wrtbak_target" invalid_config "WebDAV target is incomplete" ""
				return 1
			}
			wrtbak_remote_require_dependency curl remote-download "$wrtbak_target" || return 1
			wrtbak_download_driver_name=curl
			;;
		s3)
			wrtbak_remote_load_s3_config || {
				wrtbak_remote_error_json remote-download "$wrtbak_target" invalid_config "S3 target is incomplete" ""
				return 1
			}
			wrtbak_remote_require_dependency rclone remote-download "$wrtbak_target" || return 1
			wrtbak_download_driver_name=rclone
			;;
	esac
	wrtbak_path=$(wrtbak_remote_validate_backup_path "$wrtbak_target" "$wrtbak_requested_path") || {
		wrtbak_remote_error_json remote-download "$wrtbak_target" invalid_config "remote path is outside current device prefix" ""
		return 1
	}
	wrtbak_format=$(wrtbak_remote_format_for_path "$wrtbak_path") || {
		wrtbak_remote_error_json remote-download "$wrtbak_target" invalid_format "remote backup suffix is not supported" "$wrtbak_path"
		return 1
	}

	if ! wrtbak_remote_lock_acquire; then
		wrtbak_remote_error_json remote-download "$wrtbak_target" busy "another remote operation is running" ""
		return 1
	fi

	wrtbak_stat_tsv=$(mktemp "${TMPDIR:-/tmp}/wrtbak-remote-stat.XXXXXX") || {
		wrtbak_remote_lock_release
		wrtbak_remote_error_json remote-download "$wrtbak_target" command_failed "cannot create temporary file" ""
		return 1
	}
	if ! wrtbak_remote_stat_driver "$wrtbak_target" "$wrtbak_path" > "$wrtbak_stat_tsv"; then
		rm -f "$wrtbak_stat_tsv"
		wrtbak_history_append remote-download "$wrtbak_target" false command_failed "remote stat failed" "$wrtbak_path"
		wrtbak_remote_lock_release
		wrtbak_remote_error_json remote-download "$wrtbak_target" command_failed "remote metadata lookup failed" ""
		return 1
	fi
	wrtbak_tab=$(printf '\t')
	wrtbak_size=$(awk -F "$wrtbak_tab" 'NR == 1 { print $1 }' "$wrtbak_stat_tsv")
	wrtbak_remote_modified=$(awk -F "$wrtbak_tab" 'NR == 1 { print $2 }' "$wrtbak_stat_tsv")
	wrtbak_remote_etag=$(awk -F "$wrtbak_tab" 'NR == 1 { print $3 }' "$wrtbak_stat_tsv")
	rm -f "$wrtbak_stat_tsv"
	case "$wrtbak_size" in
		""|*[!0-9]*)
			wrtbak_history_append remote-download "$wrtbak_target" false size_unavailable "remote size is unavailable" "$wrtbak_path"
			wrtbak_remote_lock_release
			wrtbak_remote_error_json remote-download "$wrtbak_target" size_unavailable "remote size is unavailable" "$wrtbak_path"
			return 1
			;;
	esac

	wrtbak_filename=$(basename -- "$wrtbak_path")
	wrtbak_download_cache_path=$(wrtbak_remote_cache_path_for "$wrtbak_path") || {
		wrtbak_remote_lock_release
		wrtbak_remote_error_json remote-download "$wrtbak_target" command_failed "cannot prepare restore cache" ""
		return 1
	}
	wrtbak_sidecar="$wrtbak_download_cache_path.remote.json"

	if [ -e "$wrtbak_download_cache_path" ]; then
		if [ ! -f "$wrtbak_download_cache_path" ] || [ ! -r "$wrtbak_sidecar" ]; then
			wrtbak_history_append remote-download "$wrtbak_target" false cache_conflict "restore cache conflict" "$wrtbak_path"
			wrtbak_remote_lock_release
			wrtbak_remote_error_json remote-download "$wrtbak_target" cache_conflict "restore cache exists without a matching sidecar" "$wrtbak_path"
			return 1
		fi
		wrtbak_sidecar_target=$(wrtbak_remote_sidecar_string_field target "$wrtbak_sidecar")
		wrtbak_sidecar_driver=$(wrtbak_remote_sidecar_string_field driver "$wrtbak_sidecar")
		wrtbak_sidecar_remote_path=$(wrtbak_remote_sidecar_string_field remote_path "$wrtbak_sidecar")
		if [ "$wrtbak_sidecar_target" != "$wrtbak_target" ] || [ "$wrtbak_sidecar_driver" != "$wrtbak_download_driver_name" ] || [ "$wrtbak_sidecar_remote_path" != "$wrtbak_path" ]; then
			wrtbak_history_append remote-download "$wrtbak_target" false cache_conflict "restore cache identity mismatch" "$wrtbak_path"
			wrtbak_remote_lock_release
			wrtbak_remote_error_json remote-download "$wrtbak_target" cache_conflict "restore cache sidecar does not match this remote backup" "$wrtbak_path"
			return 1
		fi
		wrtbak_sidecar_sha=$(wrtbak_remote_sidecar_string_field sha256 "$wrtbak_sidecar")
		wrtbak_local_sha=$(wrtbak_sha256_of "$wrtbak_download_cache_path")
		if [ -z "$wrtbak_sidecar_sha" ] || [ "$wrtbak_sidecar_sha" != "$wrtbak_local_sha" ]; then
			wrtbak_history_append remote-download "$wrtbak_target" false cache_conflict "restore cache sha mismatch" "$wrtbak_path"
			wrtbak_remote_lock_release
			wrtbak_remote_error_json remote-download "$wrtbak_target" cache_conflict "restore cache file does not match its sidecar" "$wrtbak_path"
			return 1
		fi
		if wrtbak_remote_sidecar_matches "$wrtbak_sidecar" "$wrtbak_download_cache_path" "$wrtbak_target" "$wrtbak_download_driver_name" "$wrtbak_path" "$wrtbak_size" "$wrtbak_remote_modified" "$wrtbak_remote_etag"; then
			wrtbak_history_append remote-download "$wrtbak_target" true "" "download cache reused" "$wrtbak_path"
			wrtbak_remote_lock_release
			wrtbak_remote_download_success_json "$wrtbak_target" "$wrtbak_download_driver_name" "$wrtbak_path" "$wrtbak_download_cache_path" "$wrtbak_sidecar" "$wrtbak_filename" "$wrtbak_format" "$wrtbak_size" "$wrtbak_remote_modified" "$wrtbak_remote_etag" "$wrtbak_local_sha"
			return 0
		fi
	else
		rm -f "$wrtbak_sidecar"
	fi

	if ! wrtbak_remote_download_into_cache "$wrtbak_target" "$wrtbak_download_driver_name" "$wrtbak_path" "$wrtbak_download_cache_path" "$wrtbak_sidecar" "$wrtbak_filename" "$wrtbak_format" "$wrtbak_size" "$wrtbak_remote_modified" "$wrtbak_remote_etag"; then
		wrtbak_history_append remote-download "$wrtbak_target" false command_failed "download failed" "$wrtbak_path"
		wrtbak_remote_lock_release
		wrtbak_remote_error_json remote-download "$wrtbak_target" command_failed "remote download failed" ""
		return 1
	fi
	wrtbak_sha=$(wrtbak_sha256_of "$wrtbak_download_cache_path")
	wrtbak_history_append remote-download "$wrtbak_target" true "" "download complete" "$wrtbak_path"
	wrtbak_remote_lock_release
	wrtbak_remote_download_success_json "$wrtbak_target" "$wrtbak_download_driver_name" "$wrtbak_path" "$wrtbak_download_cache_path" "$wrtbak_sidecar" "$wrtbak_filename" "$wrtbak_format" "$wrtbak_size" "$wrtbak_remote_modified" "$wrtbak_remote_etag" "$wrtbak_sha"
}

wrtbak_remote_create_local_archive() {
	wrtbak_profile=$1
	wrtbak_items=$2
	wrtbak_format=$3
	wrtbak_validate_profile_name "$wrtbak_profile"
	wrtbak_validate_item_ids "$wrtbak_items"
	case "$wrtbak_format" in
		wrtbak|sysupgrade) ;;
		*) wrtbak_die "format must be wrtbak or sysupgrade" ;;
	esac
	wrtbak_dir=$(wrtbak_output_dir)
	wrtbak_prepare_output_dir "$wrtbak_dir"
	wrtbak_base="$(wrtbak_safe_id "$wrtbak_profile")-$(wrtbak_compact_timestamp)"
	wrtbak_archive="$wrtbak_dir/$wrtbak_base.wrtbak"
	wrtbak_create_archive "$wrtbak_profile" "$wrtbak_archive" "$wrtbak_items" >/dev/null
	if [ "$wrtbak_format" = "sysupgrade" ]; then
		wrtbak_sysupgrade="$wrtbak_dir/$wrtbak_base.sysupgrade.tar.gz"
		wrtbak_export_sysupgrade "$wrtbak_archive" "$wrtbak_sysupgrade" >/dev/null
		rm -f "$wrtbak_archive"
		printf '%s\t%s\n' "$wrtbak_sysupgrade" "$wrtbak_base.sysupgrade.tar.gz"
	else
		printf '%s\t%s\n' "$wrtbak_archive" "$wrtbak_base.wrtbak"
	fi
}


wrtbak_remote_upload_driver() {
	wrtbak_upload_driver_target=$1
	wrtbak_upload_driver_local_file=$2
	wrtbak_upload_driver_remote_path=$3
	case "$wrtbak_upload_driver_target" in
		webdav)
			wrtbak_webdav_upload_file "$wrtbak_remote_webdav_url" "$wrtbak_remote_webdav_username" "$wrtbak_remote_webdav_password" "$wrtbak_remote_webdav_path" "$wrtbak_upload_driver_local_file" "$wrtbak_upload_driver_remote_path"
			;;
		s3)
			wrtbak_s3_upload_file "$wrtbak_remote_s3_endpoint" "$wrtbak_remote_s3_region" "$wrtbak_remote_s3_bucket" "$wrtbak_remote_s3_access_key" "$wrtbak_remote_s3_secret_key" "$wrtbak_remote_s3_force_path_style" "$wrtbak_upload_driver_local_file" "$wrtbak_upload_driver_remote_path"
			;;
		*)
			return 1
			;;
	esac
}

wrtbak_remote_delete_driver() {
	wrtbak_delete_driver_target=$1
	wrtbak_delete_driver_remote_path=$2
	case "$wrtbak_delete_driver_target" in
		webdav)
			wrtbak_webdav_delete_path "$wrtbak_remote_webdav_url" "$wrtbak_remote_webdav_username" "$wrtbak_remote_webdav_password" "$wrtbak_delete_driver_remote_path"
			;;
		s3)
			wrtbak_s3_delete_path "$wrtbak_remote_s3_endpoint" "$wrtbak_remote_s3_region" "$wrtbak_remote_s3_bucket" "$wrtbak_remote_s3_access_key" "$wrtbak_remote_s3_secret_key" "$wrtbak_remote_s3_force_path_style" "$wrtbak_delete_driver_remote_path"
			;;
		*)
			return 1
			;;
	esac
}

wrtbak_remote_list_tsv_unlocked() {
	wrtbak_target=$1
	wrtbak_output=$2
	case "$wrtbak_target" in
		webdav)
			wrtbak_webdav_list_raw "$wrtbak_remote_webdav_url" "$wrtbak_remote_webdav_username" "$wrtbak_remote_webdav_password" "$wrtbak_remote_webdav_path" "$(wrtbak_effective_device_id)" > "$wrtbak_output"
			;;
		s3)
			wrtbak_s3_list_raw "$wrtbak_remote_s3_endpoint" "$wrtbak_remote_s3_region" "$wrtbak_remote_s3_bucket" "$wrtbak_remote_s3_access_key" "$wrtbak_remote_s3_secret_key" "$wrtbak_remote_s3_path" "$wrtbak_remote_s3_force_path_style" "$(wrtbak_effective_device_id)" > "$wrtbak_output"
			;;
		*)
			return 1
			;;
	esac
}

wrtbak_remote_prune_unlocked() {
	wrtbak_target=$1
	wrtbak_max=$2
	wrtbak_result_file=$3
	wrtbak_protected_path=${4:-}
	case "$wrtbak_max" in
		''|*[!0-9]*) return 1 ;;
	esac
	if [ "$wrtbak_max" -eq 0 ]; then
		printf '0\t0\ttrue\t\n' > "$wrtbak_result_file"
		return 0
	fi
	wrtbak_list=$(mktemp "${TMPDIR:-/tmp}/wrtbak-prune-list.XXXXXX") || return 1
	wrtbak_delete_list=$(mktemp "${TMPDIR:-/tmp}/wrtbak-prune-delete.XXXXXX") || {
		rm -f "$wrtbak_list"
		return 1
	}
	: > "$wrtbak_delete_list"
	wrtbak_remote_list_tsv_unlocked "$wrtbak_target" "$wrtbak_list" || {
		rm -f "$wrtbak_list" "$wrtbak_delete_list"
		return 1
	}
	wrtbak_tab=$(printf '\t')
	wrtbak_protected_format=
	if [ -n "$wrtbak_protected_path" ]; then
		wrtbak_protected_format=$(awk -F "$wrtbak_tab" -v path="$wrtbak_protected_path" '$1 == path { print $3; exit }' "$wrtbak_list")
	fi
	for wrtbak_prune_format in wrtbak sysupgrade; do
		wrtbak_rank=0
		wrtbak_effective_max=$wrtbak_max
		if [ "$wrtbak_prune_format" = "$wrtbak_protected_format" ]; then
			wrtbak_effective_max=$((wrtbak_max - 1))
			[ "$wrtbak_effective_max" -ge 0 ] || wrtbak_effective_max=0
		fi
		awk -F "$wrtbak_tab" -v fmt="$wrtbak_prune_format" '$3 == fmt { print }' "$wrtbak_list" | sort -t "$wrtbak_tab" -k5,5r -k1,1r | while IFS="$wrtbak_tab" read -r wrtbak_path wrtbak_filename wrtbak_item_format wrtbak_size wrtbak_modified || [ -n "$wrtbak_path" ]; do
			[ -n "$wrtbak_path" ] || continue
			[ "$wrtbak_path" != "$wrtbak_protected_path" ] || continue
			wrtbak_rank=$((wrtbak_rank + 1))
			if [ "$wrtbak_rank" -gt "$wrtbak_effective_max" ]; then
				printf '%s\n' "$wrtbak_path" >> "$wrtbak_delete_list"
			fi
		done
	done
	wrtbak_deleted=0
	wrtbak_deleted_paths=
	while IFS= read -r wrtbak_delete_path || [ -n "$wrtbak_delete_path" ]; do
		[ -n "$wrtbak_delete_path" ] || continue
		wrtbak_remote_delete_driver "$wrtbak_target" "$wrtbak_delete_path" || {
			rm -f "$wrtbak_list" "$wrtbak_delete_list"
			return 1
		}
		wrtbak_deleted=$((wrtbak_deleted + 1))
		wrtbak_deleted_paths="$wrtbak_deleted_paths$wrtbak_delete_path
"
	done < "$wrtbak_delete_list"
	wrtbak_total=$(grep -c '.' "$wrtbak_list" 2>/dev/null || printf '0')
	wrtbak_kept=$((wrtbak_total - wrtbak_deleted))
	if [ "$wrtbak_deleted" -eq 0 ]; then
		wrtbak_noop=true
	else
		wrtbak_noop=false
	fi
	printf '%s\t%s\t%s\t%s\n' "$wrtbak_deleted" "$wrtbak_kept" "$wrtbak_noop" "$wrtbak_deleted_paths" > "$wrtbak_result_file"
	rm -f "$wrtbak_list" "$wrtbak_delete_list"
}

wrtbak_remote_print_prune_json_fields() {
	wrtbak_result_file=$1
	wrtbak_tab=$(printf '\t')
	IFS="$wrtbak_tab" read -r wrtbak_deleted_count wrtbak_kept_count wrtbak_no_op wrtbak_first_path < "$wrtbak_result_file"
	printf '    "deleted_count": %s,\n' "${wrtbak_deleted_count:-0}"
	printf '    "kept_count": %s,\n' "${wrtbak_kept_count:-0}"
	printf '    "no_op": %s,\n' "${wrtbak_no_op:-true}"
	printf '    "deleted_paths": ['
	wrtbak_first=1
	cut -f4- "$wrtbak_result_file" | tr '\t' '\n' | while IFS= read -r wrtbak_path || [ -n "$wrtbak_path" ]; do
		[ -n "$wrtbak_path" ] || continue
		if [ "$wrtbak_first" -eq 1 ]; then
			wrtbak_first=0
		else
			printf ', '
		fi
		wrtbak_json_string "$wrtbak_path"
	done
	printf ']\n'
}


wrtbak_remote_upload() {
	wrtbak_target=$(wrtbak_remote_resolve_target "$1") || {
		wrtbak_remote_error_json remote-upload "$1" invalid_config "unknown remote target" ""
		return 1
	}
	wrtbak_profile=$2
	wrtbak_items=$3
	wrtbak_format=$4
	wrtbak_prune_max=$5
	wrtbak_remote_require_enabled "$wrtbak_target" remote-upload || return 1
	case "$wrtbak_target" in
		webdav)
			wrtbak_remote_load_webdav_config || {
				wrtbak_remote_error_json remote-upload "$wrtbak_target" invalid_config "WebDAV target is incomplete" ""
				return 1
			}
			wrtbak_remote_require_dependency curl remote-upload "$wrtbak_target" || return 1
			wrtbak_upload_driver_name=curl
			;;
		s3)
			wrtbak_remote_load_s3_config || {
				wrtbak_remote_error_json remote-upload "$wrtbak_target" invalid_config "S3 target is incomplete" ""
				return 1
			}
			wrtbak_remote_require_dependency rclone remote-upload "$wrtbak_target" || return 1
			wrtbak_upload_driver_name=rclone
			;;
	esac
	if ! wrtbak_remote_lock_acquire; then
		wrtbak_remote_error_json remote-upload "$wrtbak_target" busy "another remote operation is running" ""
		return 1
	fi

	wrtbak_created=$(wrtbak_compact_timestamp)
	wrtbak_year=$(printf '%s' "$wrtbak_created" | cut -c1-4)
	wrtbak_local_info=$(wrtbak_remote_create_local_archive "$wrtbak_profile" "$wrtbak_items" "$wrtbak_format") || {
		wrtbak_remote_lock_release
		wrtbak_remote_error_json remote-upload "$wrtbak_target" command_failed "local archive creation failed" ""
		return 1
	}
	wrtbak_local_path=$(printf '%s' "$wrtbak_local_info" | awk -F '	' '{ print $1 }')
	wrtbak_filename=$(printf '%s' "$wrtbak_local_info" | awk -F '	' '{ print $2 }')
	wrtbak_size=$(wrtbak_size_of "$wrtbak_local_path")
	wrtbak_sha=$(wrtbak_sha256_of "$wrtbak_local_path")
	case "$wrtbak_target" in
		webdav)
			wrtbak_remote_path=$(wrtbak_join_remote_path "$wrtbak_remote_webdav_path" wrtbak "$(wrtbak_effective_device_id)" "$wrtbak_format" "$wrtbak_year" "$wrtbak_filename") || {
				wrtbak_remote_lock_release
				wrtbak_remote_error_json remote-upload "$wrtbak_target" invalid_config "cannot build remote path" ""
				return 1
			}
			;;
		s3)
			wrtbak_remote_path=$(wrtbak_join_remote_path "$wrtbak_remote_s3_path" wrtbak "$(wrtbak_effective_device_id)" "$wrtbak_format" "$wrtbak_year" "$wrtbak_filename") || {
				wrtbak_remote_lock_release
				wrtbak_remote_error_json remote-upload "$wrtbak_target" invalid_config "cannot build remote path" ""
				return 1
			}
			;;
	esac
	wrtbak_uploaded_remote_path=$wrtbak_remote_path
	if ! wrtbak_remote_upload_driver "$wrtbak_target" "$wrtbak_local_path" "$wrtbak_uploaded_remote_path"; then
		wrtbak_history_append remote-upload "$wrtbak_target" false command_failed "upload failed" "$wrtbak_uploaded_remote_path"
		wrtbak_remote_lock_release
		wrtbak_remote_error_json remote-upload "$wrtbak_target" command_failed "remote upload failed" ""
		return 1
	fi
	wrtbak_keep_local=$(wrtbak_main_option keep_local_after_upload 0)
	if wrtbak_bool_enabled "$wrtbak_keep_local"; then
		wrtbak_retained=true
	else
		rm -f "$wrtbak_local_path"
		wrtbak_retained=false
	fi
	wrtbak_prune_result=$(mktemp "${TMPDIR:-/tmp}/wrtbak-prune-result.XXXXXX") || {
		wrtbak_remote_lock_release
		wrtbak_remote_error_json remote-upload "$wrtbak_target" command_failed "cannot create prune result" ""
		return 1
	}
	printf '0\t0\ttrue\t\n' > "$wrtbak_prune_result"
	case "$wrtbak_prune_max" in
		''|*[!0-9]*) wrtbak_prune_max=0 ;;
	esac
	if [ "$wrtbak_prune_max" -gt 0 ]; then
		if ! wrtbak_remote_prune_unlocked "$wrtbak_target" "$wrtbak_prune_max" "$wrtbak_prune_result" "$wrtbak_uploaded_remote_path"; then
			wrtbak_history_append remote-upload "$wrtbak_target" false command_failed "upload succeeded but prune failed" "$wrtbak_uploaded_remote_path"
			wrtbak_remote_lock_release
			wrtbak_remote_error_json remote-upload "$wrtbak_target" command_failed "upload succeeded but prune failed" ""
			rm -f "$wrtbak_prune_result"
			return 1
		fi
	fi
	wrtbak_history_append remote-upload "$wrtbak_target" true "" "upload complete" "$wrtbak_uploaded_remote_path"
	wrtbak_remote_lock_release
	printf '{
'
	printf '  "ok": true,
'
	printf '  "operation": "remote-upload",
'
	printf '  "target": '; wrtbak_json_string "$wrtbak_target"; printf ',
'
	printf '  "driver": '; wrtbak_json_string "$wrtbak_upload_driver_name"; printf ',
'
	printf '  "format": '; wrtbak_json_string "$wrtbak_format"; printf ',
'
	printf '  "remote_path": '; wrtbak_json_string "$wrtbak_uploaded_remote_path"; printf ',
'
	printf '  "size": %s,
' "$wrtbak_size"
	printf '  "sha256": '; wrtbak_json_string "$wrtbak_sha"; printf ',
'
	printf '  "local_archive_retained": %s,
' "$wrtbak_retained"
	printf '  "local_archive_path": '; wrtbak_json_string "$wrtbak_local_path"; printf ',
'
	printf '  "prune": {
'
	wrtbak_remote_print_prune_json_fields "$wrtbak_prune_result"
	printf '  }
'
	printf '}
'
	rm -f "$wrtbak_prune_result"
}



wrtbak_remote_delete() {
	wrtbak_target=$(wrtbak_remote_resolve_target "$1") || {
		wrtbak_remote_error_json remote-delete "$1" invalid_config "unknown remote target" ""
		return 1
	}
	wrtbak_path=$2
	wrtbak_remote_require_enabled "$wrtbak_target" remote-delete || return 1
	case "$wrtbak_target" in
		webdav)
			wrtbak_remote_load_webdav_config || {
				wrtbak_remote_error_json remote-delete "$wrtbak_target" invalid_config "WebDAV target is incomplete" ""
				return 1
			}
			wrtbak_remote_require_dependency curl remote-delete "$wrtbak_target" || return 1
			wrtbak_delete_driver_name=curl
			;;
		s3)
			wrtbak_remote_load_s3_config || {
				wrtbak_remote_error_json remote-delete "$wrtbak_target" invalid_config "S3 target is incomplete" ""
				return 1
			}
			wrtbak_remote_require_dependency rclone remote-delete "$wrtbak_target" || return 1
			wrtbak_delete_driver_name=rclone
			;;
	esac
	wrtbak_path=$(wrtbak_remote_validate_backup_path "$wrtbak_target" "$wrtbak_path") || {
		wrtbak_remote_error_json remote-delete "$wrtbak_target" invalid_config "remote path is outside current device prefix" ""
		return 1
	}
	wrtbak_remote_format_for_path "$wrtbak_path" >/dev/null || {
		wrtbak_remote_error_json remote-delete "$wrtbak_target" invalid_format "remote backup suffix is not supported" "$wrtbak_path"
		return 1
	}
	if ! wrtbak_remote_lock_acquire; then
		wrtbak_remote_error_json remote-delete "$wrtbak_target" busy "another remote operation is running" ""
		return 1
	fi
	if ! wrtbak_remote_delete_driver "$wrtbak_target" "$wrtbak_path"; then
		wrtbak_remote_lock_release
		wrtbak_remote_error_json remote-delete "$wrtbak_target" remote_not_found "remote backup was not deleted" ""
		return 1
	fi
	wrtbak_history_append remote-delete "$wrtbak_target" true "" "delete complete" "$wrtbak_path"
	wrtbak_remote_lock_release
	printf '{
'
	printf '  "ok": true,
'
	printf '  "operation": "remote-delete",
'
	printf '  "target": '; wrtbak_json_string "$wrtbak_target"; printf ',
'
	printf '  "driver": '; wrtbak_json_string "$wrtbak_delete_driver_name"; printf ',
'
	printf '  "remote_path": '; wrtbak_json_string "$wrtbak_path"; printf ',
'
	printf '  "deleted": true
'
	printf '}
'
}



wrtbak_remote_prune() {
	wrtbak_target=$(wrtbak_remote_resolve_target "$1") || {
		wrtbak_remote_error_json remote-prune "$1" invalid_config "unknown remote target" ""
		return 1
	}
	wrtbak_requested_max=$2
	wrtbak_remote_require_enabled "$wrtbak_target" remote-prune || return 1
	case "$wrtbak_target" in
		webdav)
			wrtbak_remote_load_webdav_config || {
				wrtbak_remote_error_json remote-prune "$wrtbak_target" invalid_config "WebDAV target is incomplete" ""
				return 1
			}
			wrtbak_remote_require_dependency curl remote-prune "$wrtbak_target" || return 1
			wrtbak_prune_driver_name=curl
			;;
		s3)
			wrtbak_remote_load_s3_config || {
				wrtbak_remote_error_json remote-prune "$wrtbak_target" invalid_config "S3 target is incomplete" ""
				return 1
			}
			wrtbak_remote_require_dependency rclone remote-prune "$wrtbak_target" || return 1
			wrtbak_prune_driver_name=rclone
			;;
	esac
	if ! wrtbak_remote_lock_acquire; then
		wrtbak_remote_error_json remote-prune "$wrtbak_target" busy "another remote operation is running" ""
		return 1
	fi
	wrtbak_result=$(mktemp "${TMPDIR:-/tmp}/wrtbak-prune-result.XXXXXX") || {
		wrtbak_remote_lock_release
		wrtbak_remote_error_json remote-prune "$wrtbak_target" command_failed "cannot create prune result" ""
		return 1
	}
	if ! wrtbak_remote_prune_unlocked "$wrtbak_target" "$wrtbak_requested_max" "$wrtbak_result"; then
		wrtbak_remote_lock_release
		rm -f "$wrtbak_result"
		wrtbak_remote_error_json remote-prune "$wrtbak_target" command_failed "remote prune failed" ""
		return 1
	fi
	wrtbak_history_append remote-prune "$wrtbak_target" true "" "prune complete" ""
	wrtbak_remote_lock_release
	printf '{
'
	printf '  "ok": true,
'
	printf '  "operation": "remote-prune",
'
	printf '  "target": '; wrtbak_json_string "$wrtbak_target"; printf ',
'
	printf '  "driver": '; wrtbak_json_string "$wrtbak_prune_driver_name"; printf ',
'
	printf '  "max": %s,
' "$wrtbak_requested_max"
	wrtbak_remote_print_prune_json_fields "$wrtbak_result"
	printf '}
'
	rm -f "$wrtbak_result"
}
