#!/bin/sh

wrtbak_schedule_begin_marker() {
	printf '# wrtbak auto backup begin\n'
}

wrtbak_schedule_end_marker() {
	printf '# wrtbak auto backup end\n'
}

wrtbak_schedule_cron_file() {
	printf '%s\n' "${WRTBAK_CRON_FILE:-$(wrtbak_root_path /etc/crontabs/root)}"
}

wrtbak_schedule_log_file() {
	printf '%s\n' "$(wrtbak_main_option schedule_log_file /tmp/wrtbak/remote-schedule.log)"
}

wrtbak_schedule_json_bool() {
	if wrtbak_bool_enabled "$1"; then
		printf 'true'
	else
		printf 'false'
	fi
}

wrtbak_schedule_error_json() {
	wrtbak_schedule_operation=$1
	wrtbak_schedule_code=$2
	wrtbak_schedule_message=$3
	printf '{\n'
	printf '  "ok": false,\n'
	printf '  "operation": '; wrtbak_json_string "$wrtbak_schedule_operation"; printf ',\n'
	printf '  "code": '; wrtbak_json_string "$wrtbak_schedule_code"; printf ',\n'
	printf '  "message": '; wrtbak_json_string "$wrtbak_schedule_message"; printf '\n'
	printf '}\n'
}

wrtbak_schedule_set_error() {
	wrtbak_schedule_error_code=$1
	wrtbak_schedule_error_message=$2
	return 1
}

wrtbak_schedule_decimal() {
	wrtbak_schedule_number=$(printf '%s' "$1" | sed 's/^0*//')
	[ -n "$wrtbak_schedule_number" ] || wrtbak_schedule_number=0
	printf '%s\n' "$wrtbak_schedule_number"
}

wrtbak_schedule_validate_range() {
	wrtbak_schedule_value=$1
	wrtbak_schedule_min=$2
	wrtbak_schedule_max=$3
	wrtbak_schedule_field=$4
	case "$wrtbak_schedule_value" in
		''|*[!0-9]*) wrtbak_schedule_set_error invalid_config "$wrtbak_schedule_field must be numeric" || return 1 ;;
	esac
	wrtbak_schedule_num=$(wrtbak_schedule_decimal "$wrtbak_schedule_value")
	if [ "$wrtbak_schedule_num" -lt "$wrtbak_schedule_min" ] || [ "$wrtbak_schedule_num" -gt "$wrtbak_schedule_max" ]; then
		wrtbak_schedule_set_error invalid_config "$wrtbak_schedule_field is out of range" || return 1
	fi
	return 0
}

wrtbak_schedule_selected_items() {
	wrtbak_known_item_rows | awk -F'|' 'BEGIN { first = 1 } $8 == "true" { if (!first) printf ","; printf "%s", $1; first = 0 }'
}

wrtbak_schedule_validate_safe_profile() {
	case "$1" in
		''|*[!A-Za-z0-9._-]*|?????????????????????????????????????????????????????????????????*)
			wrtbak_schedule_set_error invalid_config "profile may only contain letters, numbers, dot, underscore, and dash" || return 1
			;;
	esac
}

wrtbak_schedule_validate_safe_items() {
	case "$1" in
		''|*[!A-Za-z0-9._,-]*|?????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????*)
			wrtbak_schedule_set_error invalid_config "items may only contain ids separated by commas" || return 1
			;;
	esac
}

wrtbak_schedule_load() {
	wrtbak_schedule_enabled=$(wrtbak_schedule_option enabled 0)
	wrtbak_schedule_frequency=$(wrtbak_schedule_option frequency daily)
	wrtbak_schedule_time=$(wrtbak_schedule_option time 03:30)
	wrtbak_schedule_weekday=$(wrtbak_schedule_option weekday 0)
	wrtbak_schedule_day_of_month=$(wrtbak_schedule_option day_of_month 1)
	wrtbak_schedule_profile=$(wrtbak_schedule_option profile auto)
	wrtbak_schedule_items=$(wrtbak_schedule_option items all)
	wrtbak_schedule_format=$(wrtbak_schedule_option format wrtbak)
	wrtbak_schedule_max_backups=$(wrtbak_schedule_option max_backups 0)
	wrtbak_schedule_target=$(wrtbak_schedule_option target default)
}

wrtbak_schedule_validate() {
	wrtbak_schedule_error_code=
	wrtbak_schedule_error_message=
	case "$wrtbak_schedule_frequency" in
		daily|weekly|monthly) ;;
		*) wrtbak_schedule_set_error invalid_config "frequency must be daily, weekly, or monthly" || return 1 ;;
	esac
	case "$wrtbak_schedule_time" in
		[0-9][0-9]:[0-9][0-9]) ;;
		*) wrtbak_schedule_set_error invalid_config "time must use HH:MM" || return 1 ;;
	esac
	wrtbak_schedule_hour=${wrtbak_schedule_time%:*}
	wrtbak_schedule_minute=${wrtbak_schedule_time#*:}
	wrtbak_schedule_validate_range "$wrtbak_schedule_hour" 0 23 time || return 1
	wrtbak_schedule_validate_range "$wrtbak_schedule_minute" 0 59 time || return 1
	wrtbak_schedule_validate_range "$wrtbak_schedule_weekday" 0 6 weekday || return 1
	wrtbak_schedule_validate_range "$wrtbak_schedule_day_of_month" 1 31 day_of_month || return 1
	wrtbak_schedule_validate_range "$wrtbak_schedule_max_backups" 0 999 max_backups || return 1
	wrtbak_schedule_validate_safe_profile "$wrtbak_schedule_profile" || return 1
	case "$wrtbak_schedule_format" in
		wrtbak|sysupgrade) ;;
		*) wrtbak_schedule_set_error invalid_config "format must be wrtbak or sysupgrade" || return 1 ;;
	esac
	case "$wrtbak_schedule_items" in
		current)
			wrtbak_schedule_resolved_items=$(wrtbak_schedule_selected_items)
			;;
		*)
			wrtbak_schedule_resolved_items=$wrtbak_schedule_items
			;;
	esac
	wrtbak_schedule_validate_safe_items "$wrtbak_schedule_resolved_items" || return 1
	wrtbak_schedule_resolved_target=$(wrtbak_remote_resolve_target "$wrtbak_schedule_target") || {
		wrtbak_schedule_set_error invalid_config "unknown remote target" || return 1
	}
	if ! wrtbak_bool_enabled "$(wrtbak_remote_option "$wrtbak_schedule_resolved_target" enabled 0)"; then
		wrtbak_schedule_set_error target_disabled "$wrtbak_schedule_resolved_target remote target is disabled" || return 1
	fi
	case "$wrtbak_schedule_resolved_target" in
		webdav)
			wrtbak_remote_load_webdav_config || { wrtbak_schedule_set_error invalid_config "WebDAV target is incomplete" || return 1; }
			wrtbak_schedule_dependency=curl
			;;
		s3)
			wrtbak_remote_load_s3_config || { wrtbak_schedule_set_error invalid_config "S3 target is incomplete" || return 1; }
			wrtbak_schedule_dependency=rclone
			;;
	esac
	if ! command -v "$wrtbak_schedule_dependency" >/dev/null 2>&1; then
		wrtbak_schedule_set_error missing_dependency "$wrtbak_schedule_dependency is not installed" || return 1
	fi
	return 0
}

wrtbak_schedule_quote_arg() {
	printf "'%s'" "$1"
}

wrtbak_schedule_cron_fields() {
	wrtbak_schedule_hour=$(wrtbak_schedule_decimal "${wrtbak_schedule_time%:*}")
	wrtbak_schedule_minute=$(wrtbak_schedule_decimal "${wrtbak_schedule_time#*:}")
	case "$wrtbak_schedule_frequency" in
		daily)
			printf '%s %s * * *\n' "$wrtbak_schedule_minute" "$wrtbak_schedule_hour"
			;;
		weekly)
			printf '%s %s * * %s\n' "$wrtbak_schedule_minute" "$wrtbak_schedule_hour" "$(wrtbak_schedule_decimal "$wrtbak_schedule_weekday")"
			;;
		monthly)
			printf '%s %s %s * *\n' "$wrtbak_schedule_minute" "$wrtbak_schedule_hour" "$(wrtbak_schedule_decimal "$wrtbak_schedule_day_of_month")"
			;;
	esac
}

wrtbak_schedule_command() {
	printf '/usr/bin/wrtbak remote-upload --target %s --profile %s --items %s --format %s --prune-max %s --json >> %s 2>&1\n' \
		"$(wrtbak_schedule_quote_arg "$wrtbak_schedule_target")" \
		"$(wrtbak_schedule_quote_arg "$wrtbak_schedule_profile")" \
		"$(wrtbak_schedule_quote_arg "$wrtbak_schedule_resolved_items")" \
		"$(wrtbak_schedule_quote_arg "$wrtbak_schedule_format")" \
		"$(wrtbak_schedule_quote_arg "$wrtbak_schedule_max_backups")" \
		"$(wrtbak_schedule_quote_arg "$(wrtbak_schedule_log_file)")"
}

wrtbak_schedule_cron_line() {
	printf '%s %s\n' "$(wrtbak_schedule_cron_fields)" "$(wrtbak_schedule_command)"
}

wrtbak_schedule_strip_block() {
	wrtbak_schedule_input=$1
	wrtbak_schedule_output=$2
	wrtbak_schedule_begin=$(wrtbak_schedule_begin_marker)
	wrtbak_schedule_end=$(wrtbak_schedule_end_marker)
	if [ -r "$wrtbak_schedule_input" ]; then
		awk -v begin="$wrtbak_schedule_begin" -v end="$wrtbak_schedule_end" '
			$0 == begin { in_block = 1; next }
			$0 == end { in_block = 0; next }
			!in_block { print }
		' "$wrtbak_schedule_input" > "$wrtbak_schedule_output"
	else
		: > "$wrtbak_schedule_output"
	fi
}

wrtbak_schedule_block_installed() {
	wrtbak_schedule_file=$(wrtbak_schedule_cron_file)
	[ -r "$wrtbak_schedule_file" ] || return 1
	grep -Fx "$(wrtbak_schedule_begin_marker)" "$wrtbak_schedule_file" >/dev/null 2>&1 && grep -Fx "$(wrtbak_schedule_end_marker)" "$wrtbak_schedule_file" >/dev/null 2>&1
}

wrtbak_schedule_current_command() {
	wrtbak_schedule_file=$(wrtbak_schedule_cron_file)
	[ -r "$wrtbak_schedule_file" ] || return 0
	awk -v begin="$(wrtbak_schedule_begin_marker)" -v end="$(wrtbak_schedule_end_marker)" '
		$0 == begin { in_block = 1; next }
		$0 == end { in_block = 0; next }
		in_block && $0 !~ /^#/ && length($0) { print; exit }
	' "$wrtbak_schedule_file"
}

wrtbak_schedule_reload_cron() {
	[ "${WRTBAK_SKIP_CRON_RELOAD:-0}" = "1" ] && return 0
	[ "${WRTBAK_ROOT:-/}" = "/" ] || return 0
	if [ -x /etc/init.d/cron ]; then
		/etc/init.d/cron reload >/dev/null 2>&1 || /etc/init.d/cron restart >/dev/null 2>&1 || true
	fi
}

wrtbak_schedule_apply() {
	wrtbak_schedule_load
	wrtbak_schedule_file=$(wrtbak_schedule_cron_file)
	wrtbak_schedule_was_installed=false
	if wrtbak_schedule_block_installed; then
		wrtbak_schedule_was_installed=true
	fi
	wrtbak_schedule_tmp=$(mktemp "${TMPDIR:-/tmp}/wrtbak-cron.XXXXXX") || {
		wrtbak_schedule_error_json schedule-apply command_failed "cannot create temporary cron file"
		return 1
	}

	if ! wrtbak_bool_enabled "$wrtbak_schedule_enabled"; then
		wrtbak_schedule_strip_block "$wrtbak_schedule_file" "$wrtbak_schedule_tmp"
		if [ "$wrtbak_schedule_was_installed" = true ]; then
			mkdir -p "$(dirname -- "$wrtbak_schedule_file")" || { rm -f "$wrtbak_schedule_tmp"; wrtbak_schedule_error_json schedule-apply command_failed "cannot create cron directory"; return 1; }
			mv "$wrtbak_schedule_tmp" "$wrtbak_schedule_file" || { rm -f "$wrtbak_schedule_tmp"; wrtbak_schedule_error_json schedule-apply command_failed "cannot update cron file"; return 1; }
			wrtbak_schedule_action=removed
			wrtbak_schedule_reload_cron
		else
			rm -f "$wrtbak_schedule_tmp"
			wrtbak_schedule_action=unchanged
		fi
		printf '{\n'
		printf '  "ok": true,\n'
		printf '  "operation": "schedule-apply",\n'
		printf '  "enabled": false,\n'
		printf '  "action": '; wrtbak_json_string "$wrtbak_schedule_action"; printf ',\n'
		printf '  "cron_installed": false,\n'
		printf '  "cron_file": '; wrtbak_json_string "$wrtbak_schedule_file"; printf ',\n'
		printf '  "cron_command": ""\n'
		printf '}\n'
		return 0
	fi

	if ! wrtbak_schedule_validate; then
		rm -f "$wrtbak_schedule_tmp"
		wrtbak_schedule_error_json schedule-apply "$wrtbak_schedule_error_code" "$wrtbak_schedule_error_message"
		return 1
	fi
	wrtbak_schedule_strip_block "$wrtbak_schedule_file" "$wrtbak_schedule_tmp"
	{
		printf '%s\n' "$(wrtbak_schedule_begin_marker)"
		wrtbak_schedule_cron_line
		printf '%s\n' "$(wrtbak_schedule_end_marker)"
	} >> "$wrtbak_schedule_tmp" || { rm -f "$wrtbak_schedule_tmp"; wrtbak_schedule_error_json schedule-apply command_failed "cannot write cron block"; return 1; }
	mkdir -p "$(dirname -- "$wrtbak_schedule_file")" || { rm -f "$wrtbak_schedule_tmp"; wrtbak_schedule_error_json schedule-apply command_failed "cannot create cron directory"; return 1; }
	mv "$wrtbak_schedule_tmp" "$wrtbak_schedule_file" || { rm -f "$wrtbak_schedule_tmp"; wrtbak_schedule_error_json schedule-apply command_failed "cannot update cron file"; return 1; }
	wrtbak_schedule_reload_cron
	if [ "$wrtbak_schedule_was_installed" = true ]; then
		wrtbak_schedule_action=updated
	else
		wrtbak_schedule_action=installed
	fi
	wrtbak_schedule_command_line=$(wrtbak_schedule_current_command)
	printf '{\n'
	printf '  "ok": true,\n'
	printf '  "operation": "schedule-apply",\n'
	printf '  "enabled": true,\n'
	printf '  "action": '; wrtbak_json_string "$wrtbak_schedule_action"; printf ',\n'
	printf '  "cron_installed": true,\n'
	printf '  "cron_file": '; wrtbak_json_string "$wrtbak_schedule_file"; printf ',\n'
	printf '  "cron_command": '; wrtbak_json_string "$wrtbak_schedule_command_line"; printf '\n'
	printf '}\n'
}

wrtbak_remote_schedule_status_json() {
	wrtbak_schedule_load
	wrtbak_schedule_file=$(wrtbak_schedule_cron_file)
	wrtbak_schedule_installed=false
	if wrtbak_schedule_block_installed; then
		wrtbak_schedule_installed=true
	fi
	wrtbak_schedule_command_line=$(wrtbak_schedule_current_command)
	printf '  "schedule": {\n'
	printf '    "enabled": '; wrtbak_schedule_json_bool "$wrtbak_schedule_enabled"; printf ',\n'
	printf '    "frequency": '; wrtbak_json_string "$wrtbak_schedule_frequency"; printf ',\n'
	printf '    "time": '; wrtbak_json_string "$wrtbak_schedule_time"; printf ',\n'
	printf '    "weekday": '; wrtbak_json_string "$wrtbak_schedule_weekday"; printf ',\n'
	printf '    "day_of_month": '; wrtbak_json_string "$wrtbak_schedule_day_of_month"; printf ',\n'
	printf '    "profile": '; wrtbak_json_string "$wrtbak_schedule_profile"; printf ',\n'
	printf '    "items": '; wrtbak_json_string "$wrtbak_schedule_items"; printf ',\n'
	printf '    "format": '; wrtbak_json_string "$wrtbak_schedule_format"; printf ',\n'
	printf '    "max_backups": '; wrtbak_json_string "$wrtbak_schedule_max_backups"; printf ',\n'
	printf '    "target": '; wrtbak_json_string "$wrtbak_schedule_target"; printf ',\n'
	printf '    "cron_installed": %s,\n' "$wrtbak_schedule_installed"
	printf '    "cron_file": '; wrtbak_json_string "$wrtbak_schedule_file"; printf ',\n'
	printf '    "cron_command": '; wrtbak_json_string "$wrtbak_schedule_command_line"; printf '\n'
	printf '  }'
}

wrtbak_schedule_status_json() {
	printf '{\n'
	printf '  "ok": true,\n'
	printf '  "operation": "schedule-status",\n'
	wrtbak_remote_schedule_status_json
	printf '\n'
	printf '}\n'
}
