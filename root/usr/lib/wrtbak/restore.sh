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

wrtbak_restore_path_has_dotdot() {
	case "$1" in
		*"/../"*|*"/.."|../*|..)
			return 0
			;;
	esac
	return 1
}

wrtbak_restore_input_format() {
	case "$1" in
		/tmp/wrtbak/restore-cache/*.sysupgrade.tar.gz|/tmp/wrtbak/downloads/*.sysupgrade.tar.gz)
			printf 'sysupgrade\n'
			return 0
			;;
		/tmp/wrtbak/restore-cache/*.wrtbak|/tmp/wrtbak/downloads/*.wrtbak)
			printf 'wrtbak\n'
			return 0
			;;
	esac
	return 1
}

wrtbak_restore_expected_format_allowed() {
	wrtbak_expected=$1
	wrtbak_format=$2
	case " $wrtbak_expected " in
		*" $wrtbak_format "*)
			return 0
			;;
	esac
	return 1
}

wrtbak_restore_has_symlink_component() {
	wrtbak_check_path=$1
	wrtbak_check_dir=$(dirname -- "$wrtbak_check_path") || return 0

	while [ "$wrtbak_check_dir" != "/" ] && [ -n "$wrtbak_check_dir" ]; do
		[ -L "$wrtbak_check_dir" ] && return 0
		wrtbak_parent=$(dirname -- "$wrtbak_check_dir") || return 0
		[ "$wrtbak_parent" != "$wrtbak_check_dir" ] || break
		wrtbak_check_dir=$wrtbak_parent
	done
	return 1
}

wrtbak_restore_validate_regular_file_path() {
	wrtbak_operation=$1
	wrtbak_code=$2
	wrtbak_message=$3
	wrtbak_logical_path=$4
	wrtbak_actual_path=$5

	if wrtbak_restore_has_symlink_component "$wrtbak_actual_path" || [ -L "$wrtbak_actual_path" ] || [ ! -f "$wrtbak_actual_path" ]; then
		wrtbak_restore_invalid_json "$wrtbak_operation" "$wrtbak_code" "$wrtbak_message" "$wrtbak_logical_path"
		return 1
	fi
}

wrtbak_restore_validate_input_path() {
	wrtbak_operation=$1
	wrtbak_input=$2
	wrtbak_expected=$3

	case "$wrtbak_input" in
		/*)
			;;
		*)
			wrtbak_restore_invalid_json "$wrtbak_operation" invalid_input_path "invalid restore input path" "$wrtbak_input"
			return 1
			;;
	esac

	if wrtbak_restore_path_has_dotdot "$wrtbak_input"; then
		wrtbak_restore_invalid_json "$wrtbak_operation" invalid_input_path "invalid restore input path" "$wrtbak_input"
		return 1
	fi

	wrtbak_format=$(wrtbak_restore_input_format "$wrtbak_input" 2>/dev/null || true)
	if [ -z "$wrtbak_format" ] || ! wrtbak_restore_expected_format_allowed "$wrtbak_expected" "$wrtbak_format"; then
		wrtbak_restore_invalid_json "$wrtbak_operation" invalid_input_path "invalid restore input path" "$wrtbak_input"
		return 1
	fi

	wrtbak_actual=$(wrtbak_root_path "$wrtbak_input")
	wrtbak_restore_validate_regular_file_path "$wrtbak_operation" invalid_input_path "invalid restore input path" "$wrtbak_input" "$wrtbak_actual" || return 1

	wrtbak_restore_validated_format=$wrtbak_format
}

wrtbak_restore_validate_prebackup_path() {
	wrtbak_operation=$1
	wrtbak_prebackup=$2

	case "$wrtbak_prebackup" in
		/tmp/wrtbak/pre-restore-*.wrtbak)
			;;
		*)
			wrtbak_restore_invalid_json "$wrtbak_operation" invalid_prebackup "invalid prebackup path" "$wrtbak_prebackup"
			return 1
			;;
	esac

	if wrtbak_restore_path_has_dotdot "$wrtbak_prebackup"; then
		wrtbak_restore_invalid_json "$wrtbak_operation" invalid_prebackup "invalid prebackup path" "$wrtbak_prebackup"
		return 1
	fi

	wrtbak_actual=$(wrtbak_root_path "$wrtbak_prebackup")
	wrtbak_restore_validate_regular_file_path "$wrtbak_operation" invalid_prebackup "invalid prebackup path" "$wrtbak_prebackup" "$wrtbak_actual" || return 1
}

wrtbak_restore_receipt_value() {
	wrtbak_receipt_file=$1
	wrtbak_receipt_key=$2
	wrtbak_receipt_default=${3:-}
	wrtbak_jsonfilter_value "$wrtbak_receipt_file" "@.$wrtbak_receipt_key" "$wrtbak_receipt_default"
}

wrtbak_restore_date_seconds() {
	wrtbak_date_value=$1
	date -u -d "$wrtbak_date_value" '+%s' 2>/dev/null || return 1
}

wrtbak_restore_validate_receipt() {
	wrtbak_prebackup=$1
	wrtbak_restore_validate_prebackup_path "${wrtbak_restore_receipt_operation:-restore-apply}" "$wrtbak_prebackup" || return 1

	wrtbak_receipt_path="$wrtbak_prebackup.receipt.json"
	wrtbak_receipt_actual=$(wrtbak_root_path "$wrtbak_receipt_path")
	if [ ! -f "$wrtbak_receipt_actual" ] || [ -L "$wrtbak_receipt_actual" ]; then
		wrtbak_restore_invalid_json "$wrtbak_restore_receipt_operation" invalid_prebackup "invalid prebackup receipt" "$wrtbak_receipt_path"
		return 1
	fi

	wrtbak_receipt_recorded_path=$(wrtbak_restore_receipt_value "$wrtbak_receipt_actual" path "")
	wrtbak_receipt_format=$(wrtbak_restore_receipt_value "$wrtbak_receipt_actual" format "")
	wrtbak_receipt_size=$(wrtbak_restore_receipt_value "$wrtbak_receipt_actual" size "")
	wrtbak_receipt_sha=$(wrtbak_restore_receipt_value "$wrtbak_receipt_actual" sha256 "")
	wrtbak_receipt_created=$(wrtbak_restore_receipt_value "$wrtbak_receipt_actual" created_at "")
	wrtbak_receipt_device=$(wrtbak_restore_receipt_value "$wrtbak_receipt_actual" host_device_id "")
	wrtbak_current_device=$(wrtbak_effective_device_id)
	wrtbak_prebackup_actual=$(wrtbak_root_path "$wrtbak_prebackup")

	if [ "$wrtbak_receipt_recorded_path" != "$wrtbak_prebackup" ] || [ "$wrtbak_receipt_format" != "wrtbak" ] || [ -z "$wrtbak_receipt_size" ] || [ -z "$wrtbak_receipt_sha" ] || [ -z "$wrtbak_receipt_created" ]; then
		wrtbak_restore_invalid_json "$wrtbak_restore_receipt_operation" invalid_prebackup "invalid prebackup receipt" "$wrtbak_receipt_path"
		return 1
	fi

	if [ "$wrtbak_receipt_device" != "$wrtbak_current_device" ]; then
		wrtbak_restore_invalid_json "$wrtbak_restore_receipt_operation" invalid_prebackup "prebackup belongs to a different device" "$wrtbak_prebackup"
		return 1
	fi

	wrtbak_actual_size=$(wrtbak_size_of "$wrtbak_prebackup_actual" 2>/dev/null || true)
	wrtbak_actual_sha=$(wrtbak_sha256_of "$wrtbak_prebackup_actual" 2>/dev/null || true)
	if [ "$wrtbak_actual_size" != "$wrtbak_receipt_size" ] || [ "$wrtbak_actual_sha" != "$wrtbak_receipt_sha" ]; then
		wrtbak_restore_invalid_json "$wrtbak_restore_receipt_operation" invalid_prebackup "prebackup archive does not match receipt" "$wrtbak_prebackup"
		return 1
	fi

	wrtbak_created_seconds=$(wrtbak_restore_date_seconds "$wrtbak_receipt_created" || true)
	wrtbak_now_seconds=$(date -u '+%s')
	if [ -z "$wrtbak_created_seconds" ] || [ "$wrtbak_created_seconds" -gt "$wrtbak_now_seconds" ]; then
		wrtbak_restore_invalid_json "$wrtbak_restore_receipt_operation" invalid_prebackup "prebackup receipt timestamp is invalid" "$wrtbak_prebackup"
		return 1
	fi
	wrtbak_age=$((wrtbak_now_seconds - wrtbak_created_seconds))
	if [ "$wrtbak_age" -ge 86400 ]; then
		wrtbak_restore_invalid_json "$wrtbak_restore_receipt_operation" invalid_prebackup "prebackup receipt is stale" "$wrtbak_prebackup"
		return 1
	fi
}

wrtbak_restore_json_file_array() {
	wrtbak_file=$1

	printf '['
	wrtbak_restore_array_first=1
	while IFS= read -r wrtbak_value || [ -n "$wrtbak_value" ]; do
		[ -n "$wrtbak_value" ] || continue
		if [ "$wrtbak_restore_array_first" -eq 1 ]; then
			wrtbak_restore_array_first=0
		else
			printf ', '
		fi
		wrtbak_json_string "$wrtbak_value"
	done < "$wrtbak_file"
	printf ']'
}

wrtbak_restore_json_file_object_array() {
	wrtbak_file=$1
	printf '['
	wrtbak_first=1
	while IFS='|' read -r wrtbak_a wrtbak_b || [ -n "$wrtbak_a" ]; do
		[ -n "$wrtbak_a" ] || continue
		if [ "$wrtbak_first" -eq 1 ]; then
			wrtbak_first=0
		else
			printf ', '
		fi
		printf '{'
		printf '"service": '; wrtbak_json_string "$wrtbak_a"; printf ', '
		printf '"error": '; wrtbak_json_string "$wrtbak_b"
		printf '}'
	done < "$wrtbak_file"
	printf ']'
}

wrtbak_restore_supported_device_uid_algorithm() {
	wrtbak_identity_algorithm
}

wrtbak_restore_account_file_excluded() {
	case "$1" in
		/etc/passwd|/etc/shadow|/etc/group|/etc/gshadow)
			return 0
			;;
	esac
	return 1
}

wrtbak_restore_skipped_files_json() {
	wrtbak_file=$1
	printf '['
	wrtbak_first=1
	while IFS='|' read -r wrtbak_path wrtbak_reason || [ -n "$wrtbak_path" ]; do
		[ -n "$wrtbak_path" ] || continue
		if [ "$wrtbak_first" -eq 1 ]; then
			printf '\n'
			wrtbak_first=0
		else
			printf ',\n'
		fi
		printf '    {\n'
		printf '      "path": '; wrtbak_json_string "$wrtbak_path"; printf ',\n'
		printf '      "reason": '; wrtbak_json_string "$wrtbak_reason"; printf '\n'
		printf '    }'
	done < "$wrtbak_file"

	if [ "$wrtbak_first" -eq 1 ]; then
		printf ']'
	else
		printf '\n  ]'
	fi
}

wrtbak_restore_identity_evaluate() {
	wrtbak_manifest=$1
	wrtbak_restore_supported_algorithm=$(wrtbak_restore_supported_device_uid_algorithm)
	wrtbak_restore_manifest_uid=$(wrtbak_jsonfilter_value "$wrtbak_manifest" '@.device.uid' "")
	wrtbak_restore_manifest_uid_algorithm=$(wrtbak_jsonfilter_value "$wrtbak_manifest" '@.device.uid_algorithm' "")
	wrtbak_restore_manifest_alias=$(wrtbak_jsonfilter_value "$wrtbak_manifest" '@.device.alias' "")
	wrtbak_restore_current_uid=
	wrtbak_restore_current_uid_algorithm=
	wrtbak_restore_current_alias=
	wrtbak_restore_current_identity_status=unusable
	wrtbak_restore_identity_match=false
	wrtbak_restore_can_apply=false
	wrtbak_restore_reason=

	if wrtbak_identity_load_current >/dev/null 2>&1; then
		wrtbak_restore_current_uid=$wrtbak_identity_uid
		wrtbak_restore_current_uid_algorithm=$wrtbak_identity_uid_algorithm
		wrtbak_restore_current_alias=$wrtbak_identity_alias_value
		wrtbak_restore_current_identity_status=$wrtbak_identity_status
	fi

	if [ -z "$wrtbak_restore_manifest_uid" ]; then
		wrtbak_restore_reason=missing_device_uid
	elif [ -z "$wrtbak_restore_manifest_uid_algorithm" ]; then
		wrtbak_restore_reason=missing_device_uid_algorithm
	elif [ "$wrtbak_restore_manifest_uid_algorithm" != "$wrtbak_restore_supported_algorithm" ]; then
		wrtbak_restore_reason=unsupported_device_uid_algorithm
	elif [ -z "$wrtbak_restore_current_uid" ] || [ "$wrtbak_restore_current_uid_algorithm" != "$wrtbak_restore_supported_algorithm" ]; then
		wrtbak_restore_reason=identity_unusable
	elif [ "$wrtbak_restore_current_uid" != "$wrtbak_restore_manifest_uid" ]; then
		wrtbak_restore_reason=invalid_device_uid
	else
		wrtbak_restore_identity_match=true
		wrtbak_restore_can_apply=true
	fi
}

wrtbak_restore_require_manifest_identity() {
	wrtbak_manifest=$1
	wrtbak_restore_identity_evaluate "$wrtbak_manifest"
	if [ "$wrtbak_restore_can_apply" = true ]; then
		return 0
	fi
	wrtbak_restore_invalid_json restore-apply "$wrtbak_restore_reason" "restore archive does not belong to this device" "$wrtbak_restore_manifest_uid"
	return 1
}

wrtbak_restore_firmware_label() {
	printf '%s %s\n' "$(wrtbak_release_value DISTRIB_ID OpenWrt)" "$(wrtbak_release_value DISTRIB_RELEASE unknown)"
}

wrtbak_restore_manifest_firmware_label() {
	wrtbak_manifest=$1
	wrtbak_distribution=$(wrtbak_agent_manifest_string "$wrtbak_manifest" firmware.distribution OpenWrt)
	wrtbak_version=$(wrtbak_agent_manifest_string "$wrtbak_manifest" firmware.version unknown)
	printf '%s %s\n' "$wrtbak_distribution" "$wrtbak_version"
}

wrtbak_restore_path_matches_item_path() {
	wrtbak_target=$1
	wrtbak_item_path=$2

	[ "$wrtbak_target" = "$wrtbak_item_path" ] && return 0
	wrtbak_restore_item_path_is_directory "$wrtbak_item_path" || return 1
	case "$wrtbak_target" in
		"$wrtbak_item_path"/*)
			return 0
			;;
	esac
	return 1
}

wrtbak_restore_item_path_is_directory() {
	wrtbak_item_path=$1

	case "$wrtbak_item_path" in
		/etc/ddns-go|/etc/nikki|/etc/mosdns|/etc/tailscale|/etc/wireguard)
			return 0
			;;
	esac
	return 1
}

wrtbak_restore_item_known() {
	wrtbak_lookup_id=$1
	wrtbak_known_item_rows | awk -F'|' -v id="$wrtbak_lookup_id" '$1 == id { found = 1 } END { exit found ? 0 : 1 }'
}

wrtbak_restore_validate_selected_items() {
	wrtbak_items_value=$1
	[ "$wrtbak_items_value" = "all" ] && return 0

	wrtbak_old_ifs=$IFS
	IFS=,
	for wrtbak_item in $wrtbak_items_value; do
		IFS=$wrtbak_old_ifs
		wrtbak_item=$(printf '%s' "$wrtbak_item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
		[ -n "$wrtbak_item" ] || {
			IFS=,
			continue
		}
		if ! wrtbak_restore_item_known "$wrtbak_item"; then
			wrtbak_restore_invalid_json restore-apply invalid_items "unknown restore item" "$wrtbak_item"
			IFS=$wrtbak_old_ifs
			return 1
		fi
		IFS=,
	done
	IFS=$wrtbak_old_ifs
}

wrtbak_restore_annotate_path() {
	wrtbak_target=$1
	wrtbak_items_out=$2
	wrtbak_sensitive_out=$3

	: > "$wrtbak_items_out"
	printf 'false\n' > "$wrtbak_sensitive_out"
	wrtbak_known_item_rows | while IFS='|' read -r wrtbak_id wrtbak_label wrtbak_category wrtbak_packages wrtbak_paths wrtbak_restore_item_services wrtbak_sensitive wrtbak_selected wrtbak_description; do
		for wrtbak_item_path in $wrtbak_paths; do
			if wrtbak_restore_path_matches_item_path "$wrtbak_target" "$wrtbak_item_path"; then
				printf '%s\n' "$wrtbak_id" >> "$wrtbak_items_out"
				if [ "$wrtbak_sensitive" = "true" ]; then
					printf 'true\n' > "$wrtbak_sensitive_out"
				fi
				break
			fi
		done
	done
	sort -u "$wrtbak_items_out" -o "$wrtbak_items_out"
}

wrtbak_restore_collect_tree_plan() {
	wrtbak_tree_root=$1
	wrtbak_archive_prefix=$2
	wrtbak_action=$3
	wrtbak_paths_out=$4
	wrtbak_summary_out=$5
	wrtbak_work=$6
	wrtbak_dirs="$wrtbak_work/plan-dirs.list"
	wrtbak_files="$wrtbak_work/plan-files.list"
	wrtbak_file_count=0
	wrtbak_total_bytes=0

	: > "$wrtbak_paths_out"

	(cd "$wrtbak_tree_root" && find . -mindepth 1 -type d -print | sort) > "$wrtbak_dirs" || return 1
	while IFS= read -r wrtbak_rel || [ -n "$wrtbak_rel" ]; do
		[ -n "$wrtbak_rel" ] || continue
		wrtbak_child=${wrtbak_rel#./}
		if [ -z "$wrtbak_archive_prefix" ]; then
			case "$wrtbak_child" in
				*/*)
					;;
				*)
					continue
					;;
			esac
		fi
		if [ -n "$wrtbak_archive_prefix" ]; then
			wrtbak_archive_path="$wrtbak_archive_prefix/$wrtbak_child"
		else
			wrtbak_archive_path="$wrtbak_child"
		fi
		printf '/%s|%s|directory|0||%s\n' "$wrtbak_child" "$wrtbak_archive_path" "$wrtbak_action" >> "$wrtbak_paths_out"
	done < "$wrtbak_dirs"

	(cd "$wrtbak_tree_root" && find . -type f -print | sort) > "$wrtbak_files" || return 1
	while IFS= read -r wrtbak_rel || [ -n "$wrtbak_rel" ]; do
		[ -n "$wrtbak_rel" ] || continue
		wrtbak_child=${wrtbak_rel#./}
		wrtbak_source="$wrtbak_tree_root/$wrtbak_child"
		wrtbak_size=$(wrtbak_size_of "$wrtbak_source")
		wrtbak_sha=$(wrtbak_sha256_of "$wrtbak_source")
		if [ -n "$wrtbak_archive_prefix" ]; then
			wrtbak_archive_path="$wrtbak_archive_prefix/$wrtbak_child"
		else
			wrtbak_archive_path="$wrtbak_child"
		fi
		printf '/%s|%s|file|%s|%s|%s\n' "$wrtbak_child" "$wrtbak_archive_path" "$wrtbak_size" "$wrtbak_sha" "$wrtbak_action" >> "$wrtbak_paths_out"
		wrtbak_file_count=$((wrtbak_file_count + 1))
		wrtbak_total_bytes=$((wrtbak_total_bytes + wrtbak_size))
	done < "$wrtbak_files"

	printf '%s %s\n' "$wrtbak_file_count" "$wrtbak_total_bytes" > "$wrtbak_summary_out"
}

wrtbak_restore_plan_paths_json() {
	wrtbak_paths_file=$1
	wrtbak_work=$2

	printf '['
	wrtbak_restore_plan_first=1
	while IFS='|' read -r wrtbak_path wrtbak_archive_path wrtbak_type wrtbak_size wrtbak_sha wrtbak_action; do
		[ -n "$wrtbak_path" ] || continue
		wrtbak_items="$wrtbak_work/items.$$"
		wrtbak_sensitive="$wrtbak_work/sensitive.$$"
		wrtbak_restore_annotate_path "$wrtbak_path" "$wrtbak_items" "$wrtbak_sensitive"
		wrtbak_sensitive_value=$(sed -n '1p' "$wrtbak_sensitive")
		if [ "$wrtbak_restore_plan_first" -eq 1 ]; then
			printf '\n'
			wrtbak_restore_plan_first=0
		else
			printf ',\n'
		fi
		printf '      {\n'
		printf '        "path": '; wrtbak_json_string "$wrtbak_path"; printf ',\n'
		printf '        "archive_path": '; wrtbak_json_string "$wrtbak_archive_path"; printf ',\n'
		printf '        "type": '; wrtbak_json_string "$wrtbak_type"; printf ',\n'
		printf '        "size": %s,\n' "${wrtbak_size:-0}"
		printf '        "sha256": '; wrtbak_json_string "$wrtbak_sha"; printf ',\n'
		printf '        "items": '; wrtbak_restore_json_file_array "$wrtbak_items"; printf ',\n'
		printf '        "sensitive": '; wrtbak_json_bool "$wrtbak_sensitive_value"; printf ',\n'
		printf '        "selected": true,\n'
		printf '        "action": '; wrtbak_json_string "$wrtbak_action"; printf '\n'
		printf '      }'
	done < "$wrtbak_paths_file"

	if [ "$wrtbak_restore_plan_first" -eq 1 ]; then
		printf ']'
	else
		printf '\n    ]'
	fi
}

wrtbak_restore_collect_restore_plan_paths() {
	wrtbak_rootfs=$1
	wrtbak_paths_out=$2
	wrtbak_skipped_out=$3
	wrtbak_summary_out=$4
	wrtbak_work=$5
	wrtbak_dirs="$wrtbak_work/restore-plan-dirs.list"
	wrtbak_files="$wrtbak_work/restore-plan-files.list"
	wrtbak_tab=$(printf '\t')
	wrtbak_file_count=0
	wrtbak_dir_count=0
	wrtbak_total_bytes=0

	: > "$wrtbak_paths_out"
	: > "$wrtbak_skipped_out"

	(cd "$wrtbak_rootfs" && find . -mindepth 1 -type d -print | sort) > "$wrtbak_dirs" || wrtbak_die "cannot scan restore directories"
	while IFS= read -r wrtbak_rel || [ -n "$wrtbak_rel" ]; do
		[ -n "$wrtbak_rel" ] || continue
		wrtbak_child=${wrtbak_rel#./}
		printf '/%s%sdirectory%s\n' "$wrtbak_child" "$wrtbak_tab" "$wrtbak_tab" >> "$wrtbak_paths_out"
		wrtbak_dir_count=$((wrtbak_dir_count + 1))
	done < "$wrtbak_dirs"

	(cd "$wrtbak_rootfs" && find . -type f -print | sort) > "$wrtbak_files" || wrtbak_die "cannot scan restore files"
	while IFS= read -r wrtbak_rel || [ -n "$wrtbak_rel" ]; do
		[ -n "$wrtbak_rel" ] || continue
		wrtbak_child=${wrtbak_rel#./}
		wrtbak_path="/$wrtbak_child"
		if wrtbak_restore_account_file_excluded "$wrtbak_path"; then
			printf '%s|account_file_excluded\n' "$wrtbak_path" >> "$wrtbak_skipped_out"
			continue
		fi
		wrtbak_size=$(wrtbak_size_of "$wrtbak_rootfs/$wrtbak_child")
		printf '%s%sfile%s%s\n' "$wrtbak_path" "$wrtbak_tab" "$wrtbak_tab" "$wrtbak_size" >> "$wrtbak_paths_out"
		wrtbak_file_count=$((wrtbak_file_count + 1))
		wrtbak_total_bytes=$((wrtbak_total_bytes + wrtbak_size))
	done < "$wrtbak_files"

	printf '%s %s %s\n' "$wrtbak_file_count" "$wrtbak_dir_count" "$wrtbak_total_bytes" > "$wrtbak_summary_out"
}

wrtbak_agent_restore_plan_json() {
	wrtbak_agent_archive=$1

	[ -n "$wrtbak_agent_archive" ] || wrtbak_die "missing input file"
	[ -r "$wrtbak_agent_archive" ] || wrtbak_die "input not readable: $wrtbak_agent_archive"

	wrtbak_tmp=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-restore-plan.XXXXXX") || wrtbak_die "cannot create temporary directory"
	wrtbak_set_tmp_cleanup "$wrtbak_tmp"
	wrtbak_agent_members="$wrtbak_tmp/members.list"
	wrtbak_agent_metadata="$wrtbak_tmp/metadata.list"
	wrtbak_agent_extract="$wrtbak_tmp/extract"
	wrtbak_agent_paths="$wrtbak_tmp/paths.tsv"
	wrtbak_agent_skipped="$wrtbak_tmp/skipped.tsv"
	wrtbak_agent_summary="$wrtbak_tmp/summary.txt"
	wrtbak_agent_services="$wrtbak_tmp/restart-services.txt"

	mkdir -p "$wrtbak_agent_extract" || wrtbak_die "cannot create extract directory"
	wrtbak_validate_archive_metadata "$wrtbak_agent_archive" "$wrtbak_agent_members" "$wrtbak_agent_metadata"
	if ! tar xzf "$wrtbak_agent_archive" -C "$wrtbak_agent_extract"; then
		wrtbak_die "cannot extract $wrtbak_agent_archive"
	fi
	[ -f "$wrtbak_agent_extract/manifest.json" ] || wrtbak_die "manifest.json missing after extract"
	[ -d "$wrtbak_agent_extract/rootfs" ] || wrtbak_die "rootfs/ missing after extract"
	wrtbak_validate_tree "$wrtbak_agent_extract/rootfs" rootfs "$wrtbak_tmp"

	wrtbak_agent_manifest="$wrtbak_agent_extract/manifest.json"
	wrtbak_agent_validate_manifest "$wrtbak_agent_manifest"
	wrtbak_restore_identity_evaluate "$wrtbak_agent_manifest"
	wrtbak_restore_collect_restore_plan_paths "$wrtbak_agent_extract/rootfs" "$wrtbak_agent_paths" "$wrtbak_agent_skipped" "$wrtbak_agent_summary" "$wrtbak_tmp"
	set -- $(cat "$wrtbak_agent_summary")
	wrtbak_agent_file_count=$1
	wrtbak_agent_dir_count=$2
	wrtbak_agent_total_bytes=$3
	wrtbak_agent_restore_services "$wrtbak_agent_manifest" "$wrtbak_agent_services"

	printf '{\n'
	printf '  "archive": '; wrtbak_json_string "$wrtbak_agent_archive"; printf ',\n'
	printf '  "schema": '; wrtbak_json_string "$(wrtbak_agent_manifest_string "$wrtbak_agent_manifest" schema unknown)"; printf ',\n'
	printf '  "profile": '; wrtbak_json_string "$(wrtbak_agent_manifest_string "$wrtbak_agent_manifest" profile unknown)"; printf ',\n'
	printf '  "backup_id": '; wrtbak_json_string "$(wrtbak_agent_manifest_string "$wrtbak_agent_manifest" backup_id unknown)"; printf ',\n'
	printf '  "created_at": '; wrtbak_json_string "$(wrtbak_agent_manifest_string "$wrtbak_agent_manifest" created_at unknown)"; printf ',\n'
	printf '  "tool_version": '; wrtbak_json_string "$(wrtbak_agent_manifest_string "$wrtbak_agent_manifest" tool_version unknown)"; printf ',\n'
	printf '  "current_device_uid": '; wrtbak_json_string "$wrtbak_restore_current_uid"; printf ',\n'
	printf '  "current_uid": '; wrtbak_json_string "$wrtbak_restore_current_uid"; printf ',\n'
	printf '  "manifest_device_uid": '; wrtbak_json_string "$wrtbak_restore_manifest_uid"; printf ',\n'
	printf '  "manifest_uid": '; wrtbak_json_string "$wrtbak_restore_manifest_uid"; printf ',\n'
	printf '  "manifest_device_uid_algorithm": '; wrtbak_json_string "$wrtbak_restore_manifest_uid_algorithm"; printf ',\n'
	printf '  "manifest_uid_algorithm": '; wrtbak_json_string "$wrtbak_restore_manifest_uid_algorithm"; printf ',\n'
	printf '  "manifest_device_alias": '; wrtbak_json_string "$wrtbak_restore_manifest_alias"; printf ',\n'
	printf '  "alias": '; wrtbak_json_string "$wrtbak_restore_manifest_alias"; printf ',\n'
	printf '  "identity_match": '; wrtbak_json_bool "$wrtbak_restore_identity_match"; printf ',\n'
	printf '  "can_apply": '; wrtbak_json_bool "$wrtbak_restore_can_apply"; printf ',\n'
	printf '  "reason": '; wrtbak_json_string "$wrtbak_restore_reason"; printf ',\n'
	printf '  "file_count": %s,\n' "$wrtbak_agent_file_count"
	printf '  "directory_count": %s,\n' "$wrtbak_agent_dir_count"
	printf '  "total_file_bytes": %s,\n' "$wrtbak_agent_total_bytes"
	printf '  "restart_services": '
	wrtbak_agent_string_file_array_json "$wrtbak_agent_services"
	printf ',\n'
	printf '  "reboot_recommended": '; wrtbak_json_bool "$(wrtbak_agent_restore_bool "$wrtbak_agent_manifest" reboot_recommended true)"; printf ',\n'
	printf '  "requires_confirmation": '; wrtbak_json_bool "$(wrtbak_agent_restore_bool "$wrtbak_agent_manifest" requires_confirmation true)"; printf ',\n'
	printf '  "skipped_files": '
	wrtbak_restore_skipped_files_json "$wrtbak_agent_skipped"
	printf ',\n'
	printf '  "paths": '
	wrtbak_agent_restore_paths_json "$wrtbak_agent_paths"
	printf '\n'
	printf '}\n'

	wrtbak_clear_tmp_cleanup
}

wrtbak_restore_sysupgrade_validate_metadata() {
	wrtbak_archive=$1
	wrtbak_members=$2
	wrtbak_metadata=$3

	[ -r "$wrtbak_archive" ] || wrtbak_die "archive not readable: $wrtbak_archive"
	tar tzf "$wrtbak_archive" > "$wrtbak_members" || wrtbak_die "not a readable gzip tar archive: $wrtbak_archive"
	tar tvzf "$wrtbak_archive" > "$wrtbak_metadata" || wrtbak_die "not a readable gzip tar archive: $wrtbak_archive"
	wrtbak_validate_member_list "$wrtbak_members"
	wrtbak_validate_tar_metadata "$wrtbak_metadata"
}

wrtbak_restore_emit_wrtbak_prepare() {
	wrtbak_input=$1
	wrtbak_archive=$2
	wrtbak_archive_size=$3
	wrtbak_archive_sha=$4

	wrtbak_tmp=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-restore-prepare.XXXXXX") || {
		wrtbak_restore_invalid_json restore-prepare invalid_archive "cannot create temporary directory" ""
		return 1
	}
	wrtbak_set_tmp_cleanup "$wrtbak_tmp"
	wrtbak_members="$wrtbak_tmp/members.list"
	wrtbak_metadata="$wrtbak_tmp/metadata.list"
	wrtbak_extract="$wrtbak_tmp/extract"
	wrtbak_paths="$wrtbak_tmp/paths.tsv"
	wrtbak_summary="$wrtbak_tmp/summary.txt"
	wrtbak_services="$wrtbak_tmp/services.txt"
	wrtbak_err="$wrtbak_tmp/error.txt"
	mkdir -p "$wrtbak_extract" || {
		wrtbak_clear_tmp_cleanup
		wrtbak_restore_invalid_json restore-prepare invalid_archive "cannot create extract directory" ""
		return 1
	}

	if ! (
		wrtbak_validate_archive_metadata "$wrtbak_archive" "$wrtbak_members" "$wrtbak_metadata" &&
		tar xzf "$wrtbak_archive" -C "$wrtbak_extract" &&
		[ -f "$wrtbak_extract/manifest.json" ] &&
		[ -d "$wrtbak_extract/rootfs" ] &&
		wrtbak_validate_tree "$wrtbak_extract/rootfs" rootfs "$wrtbak_tmp" &&
		wrtbak_agent_validate_manifest "$wrtbak_extract/manifest.json"
	) 2>"$wrtbak_err"; then
		wrtbak_detail=$(sed -n '1p' "$wrtbak_err")
		wrtbak_clear_tmp_cleanup
		wrtbak_restore_invalid_json restore-prepare invalid_archive "restore archive is not valid" "$wrtbak_detail"
		return 1
	fi

	wrtbak_manifest="$wrtbak_extract/manifest.json"
	wrtbak_restore_collect_tree_plan "$wrtbak_extract/rootfs" rootfs write "$wrtbak_paths" "$wrtbak_summary" "$wrtbak_tmp"
	set -- $(cat "$wrtbak_summary")
	wrtbak_file_count=$1
	wrtbak_total_bytes=$2
	wrtbak_agent_restore_services "$wrtbak_manifest" "$wrtbak_services"

	printf '{\n'
	printf '  "ok": true,\n'
	printf '  "operation": "restore-prepare",\n'
	printf '  "input": '; wrtbak_json_string "$wrtbak_input"; printf ',\n'
	printf '  "format": "wrtbak",\n'
	printf '  "archive": {\n'
	printf '    "filename": '; wrtbak_json_string "$(basename -- "$wrtbak_input")"; printf ',\n'
	printf '    "size": %s,\n' "$wrtbak_archive_size"
	printf '    "sha256": '; wrtbak_json_string "$wrtbak_archive_sha"; printf '\n'
	printf '  },\n'
	printf '  "current_device": {\n'
	printf '    "device_id": '; wrtbak_json_string "$(wrtbak_effective_device_id)"; printf ',\n'
	printf '    "hostname": '; wrtbak_json_string "$(wrtbak_hostname)"; printf ',\n'
	printf '    "board": '; wrtbak_json_string "$(wrtbak_board_model)"; printf ',\n'
	printf '    "firmware": '; wrtbak_json_string "$(wrtbak_restore_firmware_label)"; printf '\n'
	printf '  },\n'
	printf '  "source_device": {\n'
	printf '    "device_id": '; wrtbak_json_string "$(wrtbak_agent_manifest_string "$wrtbak_manifest" device.hostname source-device)"; printf ',\n'
	printf '    "hostname": '; wrtbak_json_string "$(wrtbak_agent_manifest_string "$wrtbak_manifest" device.hostname unknown)"; printf ',\n'
	printf '    "board": '; wrtbak_json_string "$(wrtbak_agent_manifest_string "$wrtbak_manifest" device.board_model unknown)"; printf ',\n'
	printf '    "firmware": '; wrtbak_json_string "$(wrtbak_restore_manifest_firmware_label "$wrtbak_manifest")"; printf '\n'
	printf '  },\n'
	printf '  "manifest": {\n'
	printf '    "schema": '; wrtbak_json_string "$(wrtbak_agent_manifest_string "$wrtbak_manifest" schema unknown)"; printf ',\n'
	printf '    "profile": '; wrtbak_json_string "$(wrtbak_agent_manifest_string "$wrtbak_manifest" profile unknown)"; printf ',\n'
	printf '    "created_at": '; wrtbak_json_string "$(wrtbak_agent_manifest_string "$wrtbak_manifest" created_at unknown)"; printf '\n'
	printf '  },\n'
	printf '  "compatibility": {\n'
	printf '    "blocking": false,\n'
	printf '    "warnings": []\n'
	printf '  },\n'
	printf '  "plan": {\n'
	printf '    "file_count": %s,\n' "$wrtbak_file_count"
	printf '    "total_bytes": %s,\n' "$wrtbak_total_bytes"
	printf '    "paths": '
	wrtbak_restore_plan_paths_json "$wrtbak_paths" "$wrtbak_tmp"
	printf ',\n'
	printf '    "restart_services": '; wrtbak_restore_json_file_array "$wrtbak_services"; printf ',\n'
	printf '    "reboot_recommended": '; wrtbak_json_bool "$(wrtbak_agent_restore_bool "$wrtbak_manifest" reboot_recommended true)"; printf ',\n'
	printf '    "requires_confirmation": '; wrtbak_json_bool "$(wrtbak_agent_restore_bool "$wrtbak_manifest" requires_confirmation true)"; printf '\n'
	printf '  }\n'
	printf '}\n'

	wrtbak_clear_tmp_cleanup
}

wrtbak_restore_emit_sysupgrade_prepare() {
	wrtbak_input=$1
	wrtbak_archive=$2
	wrtbak_archive_size=$3
	wrtbak_archive_sha=$4

	wrtbak_tmp=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-restore-sysupgrade.XXXXXX") || {
		wrtbak_restore_invalid_json restore-prepare invalid_archive "cannot create temporary directory" ""
		return 1
	}
	wrtbak_set_tmp_cleanup "$wrtbak_tmp"
	wrtbak_members="$wrtbak_tmp/members.list"
	wrtbak_metadata="$wrtbak_tmp/metadata.list"
	wrtbak_extract="$wrtbak_tmp/extract"
	wrtbak_paths="$wrtbak_tmp/paths.tsv"
	wrtbak_summary="$wrtbak_tmp/summary.txt"
	wrtbak_services="$wrtbak_tmp/services.txt"
	wrtbak_err="$wrtbak_tmp/error.txt"
	mkdir -p "$wrtbak_extract" || {
		wrtbak_clear_tmp_cleanup
		wrtbak_restore_invalid_json restore-prepare invalid_archive "cannot create extract directory" ""
		return 1
	}

	if ! (
		wrtbak_restore_sysupgrade_validate_metadata "$wrtbak_archive" "$wrtbak_members" "$wrtbak_metadata" &&
		tar xzf "$wrtbak_archive" -C "$wrtbak_extract" &&
		wrtbak_validate_tree "$wrtbak_extract" sysupgrade "$wrtbak_tmp"
	) 2>"$wrtbak_err"; then
		wrtbak_detail=$(sed -n '1p' "$wrtbak_err")
		wrtbak_clear_tmp_cleanup
		wrtbak_restore_invalid_json restore-prepare invalid_archive "sysupgrade archive is not valid" "$wrtbak_detail"
		return 1
	fi

	wrtbak_manifest="$wrtbak_extract/etc/backup/wrtbak-manifest.json"
	wrtbak_manifest_present=false
	wrtbak_manifest_schema=
	wrtbak_manifest_path=
	: > "$wrtbak_services"
	if [ -f "$wrtbak_manifest" ]; then
		if ! wrtbak_agent_validate_manifest "$wrtbak_manifest" 2>"$wrtbak_err"; then
			wrtbak_detail=$(sed -n '1p' "$wrtbak_err")
			wrtbak_clear_tmp_cleanup
			wrtbak_restore_invalid_json restore-prepare invalid_archive "sysupgrade manifest is not valid" "$wrtbak_detail"
			return 1
		fi
		wrtbak_manifest_present=true
		wrtbak_manifest_schema=$(wrtbak_agent_manifest_string "$wrtbak_manifest" schema unknown)
		wrtbak_manifest_path=etc/backup/wrtbak-manifest.json
		wrtbak_agent_restore_services "$wrtbak_manifest" "$wrtbak_services"
	fi

	wrtbak_restore_collect_tree_plan "$wrtbak_extract" "" sysupgrade-restore "$wrtbak_paths" "$wrtbak_summary" "$wrtbak_tmp"
	set -- $(cat "$wrtbak_summary")
	wrtbak_file_count=$1
	wrtbak_total_bytes=$2

	printf '{\n'
	printf '  "ok": true,\n'
	printf '  "operation": "restore-prepare",\n'
	printf '  "input": '; wrtbak_json_string "$wrtbak_input"; printf ',\n'
	printf '  "format": "sysupgrade",\n'
	printf '  "archive": {\n'
	printf '    "filename": '; wrtbak_json_string "$(basename -- "$wrtbak_input")"; printf ',\n'
	printf '    "size": %s,\n' "$wrtbak_archive_size"
	printf '    "sha256": '; wrtbak_json_string "$wrtbak_archive_sha"; printf '\n'
	printf '  },\n'
	printf '  "manifest": {\n'
	printf '    "present": '; wrtbak_json_bool "$wrtbak_manifest_present"
	if [ "$wrtbak_manifest_present" = true ]; then
		printf ',\n'
		printf '    "schema": '; wrtbak_json_string "$wrtbak_manifest_schema"; printf ',\n'
		printf '    "path": '; wrtbak_json_string "$wrtbak_manifest_path"; printf '\n'
	else
		printf ',\n'
		printf '    "schema": "",\n'
		printf '    "path": ""\n'
	fi
	printf '  },\n'
	printf '  "compatibility": {\n'
	printf '    "blocking": false,\n'
	if [ "$wrtbak_manifest_present" = true ]; then
		printf '    "warnings": []\n'
	else
		printf '    "warnings": [\n'
		printf '      {\n'
		printf '        "code": "manifest_missing",\n'
		printf '        "severity": "warning",\n'
		printf '        "message": "Sysupgrade archive does not include a wrtbak manifest."\n'
		printf '      }\n'
		printf '    ]\n'
	fi
	printf '  },\n'
	printf '  "plan": {\n'
	printf '    "file_count": %s,\n' "$wrtbak_file_count"
	printf '    "total_bytes": %s,\n' "$wrtbak_total_bytes"
	printf '    "paths": '
	wrtbak_restore_plan_paths_json "$wrtbak_paths" "$wrtbak_tmp"
	printf ',\n'
	printf '    "restart_services": '; wrtbak_restore_json_file_array "$wrtbak_services"; printf ',\n'
	printf '    "reboot_recommended": true,\n'
	printf '    "requires_confirmation": true\n'
	printf '  }\n'
	printf '}\n'

	wrtbak_clear_tmp_cleanup
}

wrtbak_restore_prepare() {
	wrtbak_input=$1
	wrtbak_restore_validate_input_path restore-prepare "$wrtbak_input" "wrtbak sysupgrade" || return 1
	wrtbak_format=$wrtbak_restore_validated_format
	wrtbak_archive=$(wrtbak_root_path "$wrtbak_input")
	wrtbak_archive_size=$(wrtbak_size_of "$wrtbak_archive")
	wrtbak_archive_sha=$(wrtbak_sha256_of "$wrtbak_archive")

	case "$wrtbak_format" in
		wrtbak)
			wrtbak_restore_emit_wrtbak_prepare "$wrtbak_input" "$wrtbak_archive" "$wrtbak_archive_size" "$wrtbak_archive_sha"
			;;
		sysupgrade)
			wrtbak_restore_emit_sysupgrade_prepare "$wrtbak_input" "$wrtbak_archive" "$wrtbak_archive_size" "$wrtbak_archive_sha"
			;;
	esac
}

wrtbak_restore_receipt_json() {
	wrtbak_output=$1
	wrtbak_operation=$2
	wrtbak_profile=$3
	wrtbak_items=$4
	wrtbak_format=$5
	wrtbak_path=$6
	wrtbak_filename=$7
	wrtbak_size=$8
	wrtbak_sha=$9
	wrtbak_created=${10}
	wrtbak_host_device_id=${11}
	wrtbak_host_hostname=${12}

	{
		printf '{\n'
		printf '  "operation": '; wrtbak_json_string "$wrtbak_operation"; printf ',\n'
		printf '  "profile": '; wrtbak_json_string "$wrtbak_profile"; printf ',\n'
		printf '  "items": '; wrtbak_json_string "$wrtbak_items"; printf ',\n'
		printf '  "format": '; wrtbak_json_string "$wrtbak_format"; printf ',\n'
		printf '  "path": '; wrtbak_json_string "$wrtbak_path"; printf ',\n'
		printf '  "filename": '; wrtbak_json_string "$wrtbak_filename"; printf ',\n'
		printf '  "size": %s,\n' "$wrtbak_size"
		printf '  "sha256": '; wrtbak_json_string "$wrtbak_sha"; printf ',\n'
		printf '  "created_at": '; wrtbak_json_string "$wrtbak_created"; printf ',\n'
		printf '  "host_device_id": '; wrtbak_json_string "$wrtbak_host_device_id"; printf ',\n'
		printf '  "host_hostname": '; wrtbak_json_string "$wrtbak_host_hostname"; printf '\n'
		printf '}\n'
	} > "$wrtbak_output"
}

wrtbak_restore_prebackup() {
	wrtbak_profile=$1
	wrtbak_items=$2
	wrtbak_format=$3

	if [ "$wrtbak_profile" != "pre-restore" ] || [ "$wrtbak_items" != "all" ] || [ "$wrtbak_format" != "wrtbak" ]; then
		wrtbak_restore_invalid_json restore-prebackup invalid_prebackup "unsupported prebackup arguments" "$wrtbak_profile:$wrtbak_items:$wrtbak_format"
		return 1
	fi

	wrtbak_created=$(wrtbak_created_at)
	wrtbak_stamp=$(wrtbak_compact_timestamp)
	wrtbak_path="/tmp/wrtbak/pre-restore-$wrtbak_stamp.wrtbak"
	wrtbak_actual=$(wrtbak_root_path "$wrtbak_path")
	wrtbak_filename=$(basename -- "$wrtbak_path")
	wrtbak_receipt_path="$wrtbak_path.receipt.json"
	wrtbak_receipt_actual=$(wrtbak_root_path "$wrtbak_receipt_path")
	wrtbak_err="${TMPDIR:-/tmp}/wrtbak-prebackup-error.$$"
	rm -f "$wrtbak_err"

	if ! mkdir -p "$(dirname -- "$wrtbak_actual")" 2>/dev/null; then
		wrtbak_restore_invalid_json restore-prebackup prebackup_failed "failed to create prebackup directory" "$wrtbak_path"
		return 1
	fi
	if ! wrtbak_created_archive=$(wrtbak_create_archive "$wrtbak_profile" "$wrtbak_actual" "$wrtbak_items" 2>"$wrtbak_err"); then
		wrtbak_detail=$(sed -n '1p' "$wrtbak_err" 2>/dev/null || true)
		rm -f "$wrtbak_err"
		wrtbak_restore_invalid_json restore-prebackup prebackup_failed "failed to create pre-restore backup" "$wrtbak_detail"
		return 1
	fi
	rm -f "$wrtbak_err"

	[ "$wrtbak_created_archive" = "$wrtbak_actual" ] || true
	wrtbak_size=$(wrtbak_size_of "$wrtbak_actual" 2>/dev/null) || {
		rm -f "$wrtbak_actual"
		wrtbak_restore_invalid_json restore-prebackup prebackup_failed "failed to stat prebackup archive" "$wrtbak_path"
		return 1
	}
	wrtbak_sha=$(wrtbak_sha256_of "$wrtbak_actual") || {
		rm -f "$wrtbak_actual"
		wrtbak_restore_invalid_json restore-prebackup prebackup_failed "failed to hash prebackup archive" "$wrtbak_path"
		return 1
	}
	wrtbak_host_device_id=$(wrtbak_effective_device_id)
	wrtbak_host_hostname=$(wrtbak_hostname)
	wrtbak_receipt_tmp="$wrtbak_receipt_actual.$$"

	wrtbak_restore_receipt_json "$wrtbak_receipt_tmp" restore-prebackup "$wrtbak_profile" "$wrtbak_items" "$wrtbak_format" "$wrtbak_path" "$wrtbak_filename" "$wrtbak_size" "$wrtbak_sha" "$wrtbak_created" "$wrtbak_host_device_id" "$wrtbak_host_hostname" || {
		rm -f "$wrtbak_receipt_tmp" "$wrtbak_actual"
		wrtbak_restore_invalid_json restore-prebackup prebackup_failed "failed to write prebackup receipt" "$wrtbak_receipt_path"
		return 1
	}
	chmod 600 "$wrtbak_receipt_tmp" 2>/dev/null || true
	mv "$wrtbak_receipt_tmp" "$wrtbak_receipt_actual" || {
		rm -f "$wrtbak_receipt_tmp" "$wrtbak_actual"
		wrtbak_restore_invalid_json restore-prebackup prebackup_failed "failed to write prebackup receipt" "$wrtbak_receipt_path"
		return 1
	}

	printf '{\n'
	printf '  "ok": true,\n'
	printf '  "operation": "restore-prebackup",\n'
	printf '  "profile": '; wrtbak_json_string "$wrtbak_profile"; printf ',\n'
	printf '  "items": '; wrtbak_json_string "$wrtbak_items"; printf ',\n'
	printf '  "format": '; wrtbak_json_string "$wrtbak_format"; printf ',\n'
	printf '  "path": '; wrtbak_json_string "$wrtbak_path"; printf ',\n'
	printf '  "filename": '; wrtbak_json_string "$wrtbak_filename"; printf ',\n'
	printf '  "size": %s,\n' "$wrtbak_size"
	printf '  "sha256": '; wrtbak_json_string "$wrtbak_sha"; printf ',\n'
	printf '  "created_at": '; wrtbak_json_string "$wrtbak_created"; printf ',\n'
	printf '  "receipt_path": '; wrtbak_json_string "$wrtbak_receipt_path"; printf ',\n'
	printf '  "host_device_id": '; wrtbak_json_string "$wrtbak_host_device_id"; printf ',\n'
	printf '  "host_hostname": '; wrtbak_json_string "$wrtbak_host_hostname"; printf '\n'
	printf '}\n'
}

wrtbak_restore_manifest_files_table() {
	wrtbak_manifest=$1
	wrtbak_output=$2
	wrtbak_tmp_dir=$3
	wrtbak_objects="$wrtbak_tmp_dir/manifest-files.objects"

	awk '
		function skip_ws(pos,    c) {
			while (pos <= length(json)) {
				c = substr(json, pos, 1)
				if (c != " " && c != "\t" && c != "\n" && c != "\r") {
					break
				}
				pos++
			}
			return pos
		}
		function read_string(pos,    c, out, escaped) {
			out = ""
			escaped = 0
			for (pos = pos + 1; pos <= length(json); pos++) {
				c = substr(json, pos, 1)
				if (escaped) {
					out = out c
					escaped = 0
					continue
				}
				if (c == "\\") {
					escaped = 1
					continue
				}
				if (c == "\"") {
					json_string_value = out
					return pos
				}
				out = out c
			}
			return 0
		}
		function top_level_files_start(    pos, c, end, key, after_key, after_colon, object_depth, array_depth) {
			object_depth = 0
			array_depth = 0
			for (pos = 1; pos <= length(json); pos++) {
				c = substr(json, pos, 1)
				if (c == "\"") {
					end = read_string(pos)
					if (end == 0) {
						return 0
					}
					key = json_string_value
					after_key = skip_ws(end + 1)
					if (object_depth == 1 && array_depth == 0 && substr(json, after_key, 1) == ":") {
						after_colon = skip_ws(after_key + 1)
						if (key == "files") {
							if (substr(json, after_colon, 1) == "[") {
								return after_colon
							}
							return 0
						}
					}
					pos = end
					continue
				}
				if (c == "{") {
					object_depth++
				} else if (c == "}") {
					object_depth--
				} else if (c == "[") {
					array_depth++
				} else if (c == "]") {
					array_depth--
				}
			}
			return 0
		}
		{
			json = json $0 "\n"
		}
		END {
			start = top_level_files_start()
			if (start == 0) {
				exit 1
			}
			in_string = 0
			escape = 0
			array_depth = 0
			object_depth = 0
			object = ""
			for (i = start; i <= length(json); i++) {
				c = substr(json, i, 1)
				if (escape) {
					if (object_depth > 0) {
						object = object c
					}
					escape = 0
					continue
				}
				if (c == "\\") {
					if (object_depth > 0) {
						object = object c
					}
					if (in_string) {
						escape = 1
					}
					continue
				}
				if (c == "\"") {
					in_string = !in_string
					if (object_depth > 0) {
						object = object c
					}
					continue
				}
				if (in_string && object_depth > 0) {
					object = object c
					continue
				}
				if (!in_string && object_depth > 0) {
					object = object c
					if (c == "{") {
						object_depth++
					} else if (c == "}") {
						object_depth--
						if (object_depth == 0) {
							gsub(/\n/, " ", object)
							gsub(/\r/, " ", object)
							print object
							object = ""
						}
					}
					continue
				}
				if (!in_string) {
					if (c == "[") {
						array_depth++
						continue
					}
					if (c == "]") {
						if (array_depth == 1) {
							exit 0
						}
						array_depth--
						continue
					}
					if (array_depth == 1 && c == "{") {
						object_depth = 1
						object = "{"
						continue
					}
				}
			}
			exit 1
		}
	' "$wrtbak_manifest" > "$wrtbak_objects" || return 1

	: > "$wrtbak_output"
	while IFS= read -r wrtbak_object || [ -n "$wrtbak_object" ]; do
		[ -n "$wrtbak_object" ] || continue
		wrtbak_archive_path=$(printf '%s\n' "$wrtbak_object" | sed -n 's/.*"archive_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
		wrtbak_type=$(printf '%s\n' "$wrtbak_object" | sed -n 's/.*"type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
		wrtbak_size=$(printf '%s\n' "$wrtbak_object" | sed -n 's/.*"size"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
		wrtbak_sha=$(printf '%s\n' "$wrtbak_object" | sed -n 's/.*"sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
		[ -n "$wrtbak_archive_path" ] || return 1
		[ -n "$wrtbak_type" ] || return 1
		printf '%s|%s|%s|%s\n' "$wrtbak_archive_path" "$wrtbak_size" "$wrtbak_sha" "$wrtbak_type" >> "$wrtbak_output"
	done < "$wrtbak_objects"
	[ -s "$wrtbak_output" ]
}

wrtbak_restore_verify_manifest_files() {
	wrtbak_extract=$1
	wrtbak_table=$2
	wrtbak_err=$3

	if [ ! -s "$wrtbak_table" ]; then
		printf 'manifest files list missing or empty\n' > "$wrtbak_err"
		return 1
	fi

	while IFS='|' read -r wrtbak_archive_path wrtbak_size wrtbak_sha wrtbak_type || [ -n "$wrtbak_archive_path" ]; do
		[ -n "$wrtbak_archive_path" ] || continue
		case "$wrtbak_archive_path" in
			rootfs/*)
				;;
			*)
				printf 'manifest file outside rootfs: %s\n' "$wrtbak_archive_path" > "$wrtbak_err"
				return 1
				;;
		esac
		wrtbak_source="$wrtbak_extract/$wrtbak_archive_path"
		case "$wrtbak_type" in
			directory)
				[ -d "$wrtbak_source" ] || {
					printf 'manifest directory missing: %s\n' "$wrtbak_archive_path" > "$wrtbak_err"
					return 1
				}
				;;
			file)
				[ -f "$wrtbak_source" ] || {
					printf 'manifest file missing: %s\n' "$wrtbak_archive_path" > "$wrtbak_err"
					return 1
				}
				if [ -z "$wrtbak_size" ] || [ -z "$wrtbak_sha" ]; then
					printf 'manifest file missing size or sha256: %s\n' "$wrtbak_archive_path" > "$wrtbak_err"
					return 1
				fi
				if [ -n "$wrtbak_size" ] && [ "$(wrtbak_size_of "$wrtbak_source")" != "$wrtbak_size" ]; then
					printf 'manifest size mismatch: %s\n' "$wrtbak_archive_path" > "$wrtbak_err"
					return 1
				fi
				if [ -n "$wrtbak_sha" ] && [ "$(wrtbak_sha256_of "$wrtbak_source")" != "$wrtbak_sha" ]; then
					printf 'manifest sha256 mismatch: %s\n' "$wrtbak_archive_path" > "$wrtbak_err"
					return 1
				fi
				;;
			*)
				printf 'manifest unsupported file type: %s\n' "$wrtbak_archive_path" > "$wrtbak_err"
				return 1
				;;
		esac
	done < "$wrtbak_table"
}

wrtbak_restore_manifest_has_archive_path() {
	wrtbak_manifest_table=$1
	wrtbak_archive_path=$2
	awk -F'|' -v path="$wrtbak_archive_path" '$1 == path { found = 1 } END { exit found ? 0 : 1 }' "$wrtbak_manifest_table"
}

wrtbak_restore_manifest_has_child_archive_path() {
	wrtbak_manifest_table=$1
	wrtbak_archive_path=$2
	awk -F'|' -v prefix="$wrtbak_archive_path/" 'index($1, prefix) == 1 { found = 1 } END { exit found ? 0 : 1 }' "$wrtbak_manifest_table"
}

wrtbak_restore_verify_archive_manifest_allowlist() {
	wrtbak_archive_table=$1
	wrtbak_manifest_table=$2
	wrtbak_err=$3
	wrtbak_tab=$(printf '\t')

	while IFS="$wrtbak_tab" read -r wrtbak_target wrtbak_type wrtbak_mode wrtbak_size wrtbak_sha wrtbak_archive_path || [ -n "$wrtbak_target" ]; do
		[ -n "$wrtbak_target" ] || continue
		case "$wrtbak_type" in
			file)
				if ! wrtbak_restore_manifest_has_archive_path "$wrtbak_manifest_table" "$wrtbak_archive_path"; then
					printf 'archive file not listed in manifest: %s\n' "$wrtbak_archive_path" > "$wrtbak_err"
					return 1
				fi
				;;
			dir)
				if ! wrtbak_restore_manifest_has_archive_path "$wrtbak_manifest_table" "$wrtbak_archive_path" &&
					! wrtbak_restore_manifest_has_child_archive_path "$wrtbak_manifest_table" "$wrtbak_archive_path"; then
					printf 'archive directory not listed in manifest: %s\n' "$wrtbak_archive_path" > "$wrtbak_err"
					return 1
				fi
				;;
			*)
				printf 'archive unsupported entry type: %s\n' "$wrtbak_archive_path" > "$wrtbak_err"
				return 1
				;;
		esac
	done < "$wrtbak_archive_table"
}

wrtbak_restore_filter_archive_table_by_manifest() {
	wrtbak_archive_table=$1
	wrtbak_manifest_table=$2
	wrtbak_filtered_table=$3
	wrtbak_tab=$(printf '\t')

	: > "$wrtbak_filtered_table"
	while IFS="$wrtbak_tab" read -r wrtbak_target wrtbak_type wrtbak_mode wrtbak_size wrtbak_sha wrtbak_archive_path || [ -n "$wrtbak_target" ]; do
		[ -n "$wrtbak_target" ] || continue
		case "$wrtbak_type" in
			file)
				wrtbak_restore_manifest_has_archive_path "$wrtbak_manifest_table" "$wrtbak_archive_path" || continue
				;;
			dir)
				wrtbak_restore_manifest_has_archive_path "$wrtbak_manifest_table" "$wrtbak_archive_path" || continue
				;;
			*)
				continue
				;;
		esac
		printf '%s%s%s%s%s%s%s%s%s%s%s\n' "$wrtbak_target" "$wrtbak_tab" "$wrtbak_type" "$wrtbak_tab" "$wrtbak_mode" "$wrtbak_tab" "$wrtbak_size" "$wrtbak_tab" "$wrtbak_sha" "$wrtbak_tab" "$wrtbak_archive_path" >> "$wrtbak_filtered_table"
	done < "$wrtbak_archive_table"
}

wrtbak_restore_build_archive_table() {
	wrtbak_rootfs=$1
	wrtbak_output=$2
	wrtbak_work=$3
	wrtbak_dirs="$wrtbak_work/apply-dirs.list"
	wrtbak_files="$wrtbak_work/apply-files.list"
	wrtbak_tab=$(printf '\t')

	: > "$wrtbak_output"
	(cd "$wrtbak_rootfs" && find . -mindepth 1 -type d -print | sort) > "$wrtbak_dirs" || return 1
	while IFS= read -r wrtbak_rel || [ -n "$wrtbak_rel" ]; do
		[ -n "$wrtbak_rel" ] || continue
		wrtbak_child=${wrtbak_rel#./}
		wrtbak_source="$wrtbak_rootfs/$wrtbak_child"
		wrtbak_mode=$(wrtbak_mode_of "$wrtbak_source")
		printf '/%s%sdir%s%s%s-%s-%srootfs/%s\n' "$wrtbak_child" "$wrtbak_tab" "$wrtbak_tab" "$wrtbak_mode" "$wrtbak_tab" "$wrtbak_tab" "$wrtbak_tab" "$wrtbak_child" >> "$wrtbak_output"
	done < "$wrtbak_dirs"

	(cd "$wrtbak_rootfs" && find . -type f -print | sort) > "$wrtbak_files" || return 1
	while IFS= read -r wrtbak_rel || [ -n "$wrtbak_rel" ]; do
		[ -n "$wrtbak_rel" ] || continue
		wrtbak_child=${wrtbak_rel#./}
		wrtbak_source="$wrtbak_rootfs/$wrtbak_child"
		wrtbak_mode=$(wrtbak_mode_of "$wrtbak_source")
		wrtbak_size=$(wrtbak_size_of "$wrtbak_source")
		wrtbak_sha=$(wrtbak_sha256_of "$wrtbak_source")
		printf '/%s%sfile%s%s%s%s%s%s%srootfs/%s\n' "$wrtbak_child" "$wrtbak_tab" "$wrtbak_tab" "$wrtbak_mode" "$wrtbak_tab" "$wrtbak_size" "$wrtbak_tab" "$wrtbak_sha" "$wrtbak_tab" "$wrtbak_child" >> "$wrtbak_output"
	done < "$wrtbak_files"
}

wrtbak_restore_target_matches_selected_path() {
	wrtbak_target=$1
	wrtbak_target_type=$2
	wrtbak_selected_path=$3

	if wrtbak_restore_item_path_is_directory "$wrtbak_selected_path"; then
		if [ "$wrtbak_target" = "$wrtbak_selected_path" ]; then
			[ "$wrtbak_target_type" = "dir" ]
			return
		fi
		case "$wrtbak_target" in
			"$wrtbak_selected_path"/*)
				return 0
				;;
		esac
		return 1
	fi

	[ "$wrtbak_target" = "$wrtbak_selected_path" ] && [ "$wrtbak_target_type" = "file" ]
}

wrtbak_restore_selected_contains() {
	wrtbak_target=$1
	wrtbak_target_type=$2
	wrtbak_selected_paths=$3
	while IFS= read -r wrtbak_selected_path || [ -n "$wrtbak_selected_path" ]; do
		[ -n "$wrtbak_selected_path" ] || continue
		wrtbak_restore_target_matches_selected_path "$wrtbak_target" "$wrtbak_target_type" "$wrtbak_selected_path" && return 0
	done < "$wrtbak_selected_paths"
	return 1
}

wrtbak_restore_target_in_archive() {
	wrtbak_selected_path=$1
	wrtbak_archive_table=$2
	wrtbak_tab=$(printf '\t')
	while IFS="$wrtbak_tab" read -r wrtbak_target wrtbak_type wrtbak_mode wrtbak_size wrtbak_sha wrtbak_archive_path || [ -n "$wrtbak_target" ]; do
		[ -n "$wrtbak_target" ] || continue
		wrtbak_restore_target_matches_selected_path "$wrtbak_target" "$wrtbak_type" "$wrtbak_selected_path" && return 0
	done < "$wrtbak_archive_table"
	return 1
}

wrtbak_restore_filter_apply_table() {
	wrtbak_mode=$1
	wrtbak_selected_paths=$2
	wrtbak_archive_table=$3
	wrtbak_apply_table=$4
	wrtbak_skipped=$5
	wrtbak_missing=$6
	wrtbak_tab=$(printf '\t')

	: > "$wrtbak_apply_table"
	: > "$wrtbak_skipped"
	: > "$wrtbak_missing"

	while IFS="$wrtbak_tab" read -r wrtbak_target wrtbak_type wrtbak_mode_value wrtbak_size wrtbak_sha wrtbak_archive_path || [ -n "$wrtbak_target" ]; do
		[ -n "$wrtbak_target" ] || continue
		if [ "$wrtbak_type" = "file" ] && wrtbak_restore_account_file_excluded "$wrtbak_target"; then
			printf '%s\n' "$wrtbak_target" >> "$wrtbak_skipped"
			continue
		fi
		if [ "$wrtbak_mode" = "all" ] || wrtbak_restore_selected_contains "$wrtbak_target" "$wrtbak_type" "$wrtbak_selected_paths"; then
			printf '%s%s%s%s%s%s%s%s%s%s%s\n' "$wrtbak_target" "$wrtbak_tab" "$wrtbak_type" "$wrtbak_tab" "$wrtbak_mode_value" "$wrtbak_tab" "$wrtbak_size" "$wrtbak_tab" "$wrtbak_sha" "$wrtbak_tab" "$wrtbak_archive_path" >> "$wrtbak_apply_table"
		else
			printf '%s\n' "$wrtbak_target" >> "$wrtbak_skipped"
		fi
	done < "$wrtbak_archive_table"
	sort -u "$wrtbak_apply_table" -o "$wrtbak_apply_table"
	sort -u "$wrtbak_skipped" -o "$wrtbak_skipped"

	while IFS= read -r wrtbak_selected_path || [ -n "$wrtbak_selected_path" ]; do
		[ -n "$wrtbak_selected_path" ] || continue
		if ! wrtbak_restore_target_in_archive "$wrtbak_selected_path" "$wrtbak_archive_table"; then
			printf '%s\n' "$wrtbak_selected_path" >> "$wrtbak_missing"
		fi
	done < "$wrtbak_selected_paths"
	sort -u "$wrtbak_missing" -o "$wrtbak_missing"
}

wrtbak_restore_log_dir() {
	printf '%s\n' "$(wrtbak_root_path /tmp/wrtbak/restore-logs)"
}

wrtbak_restore_fsync_file() {
	wrtbak_file=$1
	if command -v sync >/dev/null 2>&1; then
		sync "$wrtbak_file" 2>/dev/null || true
	fi
}

wrtbak_restore_log_event() {
	wrtbak_event_log=$1
	wrtbak_event_target=$2
	wrtbak_event_status=$3
	wrtbak_event_source=$4
	wrtbak_event_mode=$5
	wrtbak_event_error=${6:-}
	{
		printf '{"timestamp":'; wrtbak_json_string "$(wrtbak_created_at)"
		printf ',"operation":"restore-apply","target_path":'; wrtbak_json_string "$wrtbak_event_target"
		printf ',"status":'; wrtbak_json_string "$wrtbak_event_status"
		printf ',"source_path":'; wrtbak_json_string "$wrtbak_event_source"
		printf ',"mode":'; wrtbak_json_string "$wrtbak_event_mode"
		if [ -n "$wrtbak_event_error" ]; then
			printf ',"error":'; wrtbak_json_string "$wrtbak_event_error"
		fi
		printf '}\n'
	} >> "$wrtbak_event_log"
}

wrtbak_restore_write_one() {
	wrtbak_extract=$1
	wrtbak_target=$2
	wrtbak_type=$3
	wrtbak_mode=$4
	wrtbak_archive_path=$5
	wrtbak_log_dir=$6
	wrtbak_write_log=$7
	wrtbak_logical_mode=$8
	wrtbak_actual=$(wrtbak_root_path "$wrtbak_target")
	wrtbak_source="$wrtbak_extract/$wrtbak_archive_path"

	case "$wrtbak_type" in
		dir)
			if [ -e "$wrtbak_actual" ] && [ ! -d "$wrtbak_actual" ]; then
				wrtbak_restore_log_event "$wrtbak_write_log" "$wrtbak_target" failed "$wrtbak_archive_path" "$wrtbak_logical_mode" "target exists and is not a directory"
				return 1
			fi
			mkdir -p "$wrtbak_actual" || {
				wrtbak_restore_log_event "$wrtbak_write_log" "$wrtbak_target" failed "$wrtbak_archive_path" "$wrtbak_logical_mode" "cannot create directory"
				return 1
			}
			chmod "$wrtbak_mode" "$wrtbak_actual" 2>/dev/null || true
			wrtbak_restore_log_event "$wrtbak_write_log" "$wrtbak_target" written "$wrtbak_archive_path" "$wrtbak_logical_mode"
			;;
		file)
			wrtbak_parent=$(dirname -- "$wrtbak_actual")
			mkdir -p "$wrtbak_parent" || {
				wrtbak_restore_log_event "$wrtbak_write_log" "$wrtbak_target" failed "$wrtbak_archive_path" "$wrtbak_logical_mode" "cannot create parent directory"
				return 1
			}
			if [ -e "$wrtbak_actual" ]; then
				wrtbak_backup_name=$(printf '%s' "$wrtbak_target" | sed 's#^/##;s#/#__#g')
				cp -p "$wrtbak_actual" "$wrtbak_log_dir/previous-$wrtbak_backup_name" 2>/dev/null || true
			fi
			wrtbak_tmp_target="$wrtbak_actual.wrtbak-restore.$$"
			rm -f "$wrtbak_tmp_target"
			cp "$wrtbak_source" "$wrtbak_tmp_target" || {
				rm -f "$wrtbak_tmp_target"
				wrtbak_restore_log_event "$wrtbak_write_log" "$wrtbak_target" failed "$wrtbak_archive_path" "$wrtbak_logical_mode" "cannot copy temporary file"
				return 1
			}
			chmod "$wrtbak_mode" "$wrtbak_tmp_target" 2>/dev/null || true
			wrtbak_restore_fsync_file "$wrtbak_tmp_target"
			mv "$wrtbak_tmp_target" "$wrtbak_actual" || {
				rm -f "$wrtbak_tmp_target"
				wrtbak_restore_log_event "$wrtbak_write_log" "$wrtbak_target" failed "$wrtbak_archive_path" "$wrtbak_logical_mode" "cannot rename temporary file"
				return 1
			}
			wrtbak_restore_log_event "$wrtbak_write_log" "$wrtbak_target" written "$wrtbak_archive_path" "$wrtbak_logical_mode"
			;;
		*)
			wrtbak_restore_log_event "$wrtbak_write_log" "$wrtbak_target" failed "$wrtbak_archive_path" "$wrtbak_logical_mode" "unsupported type"
			return 1
			;;
	esac
}

wrtbak_restore_is_high_risk_service() {
	case "$1" in
		network|firewall|dropbear|tailscale|wireguard|nikki|mosdns)
			return 0
			;;
	esac
	return 1
}

wrtbak_restore_handle_services() {
	wrtbak_services=$1
	wrtbak_restart_flag=$2
	wrtbak_restarted=$3
	wrtbak_blocked=$4
	wrtbak_errors=$5

	: > "$wrtbak_restarted"
	: > "$wrtbak_blocked"
	: > "$wrtbak_errors"
	while IFS= read -r wrtbak_service || [ -n "$wrtbak_service" ]; do
		[ -n "$wrtbak_service" ] || continue
		if wrtbak_restore_is_high_risk_service "$wrtbak_service"; then
			printf '%s\n' "$wrtbak_service" >> "$wrtbak_blocked"
			continue
		fi
		[ "$wrtbak_restart_flag" = "1" ] || continue
		wrtbak_init=$(wrtbak_root_path "/etc/init.d/$wrtbak_service")
		if [ -x "$wrtbak_init" ]; then
			if "$wrtbak_init" restart >/dev/null 2>&1; then
				printf '%s\n' "$wrtbak_service" >> "$wrtbak_restarted"
			else
				printf '%s|restart failed\n' "$wrtbak_service" >> "$wrtbak_errors"
			fi
		else
			printf '%s|init script not found\n' "$wrtbak_service" >> "$wrtbak_errors"
		fi
	done < "$wrtbak_services"
	sort -u "$wrtbak_restarted" -o "$wrtbak_restarted"
	sort -u "$wrtbak_blocked" -o "$wrtbak_blocked"
}

wrtbak_restore_emit_apply_success() {
	wrtbak_input=$1
	wrtbak_mode=$2
	wrtbak_items=$3
	wrtbak_written_count=$4
	wrtbak_skipped_count=$5
	wrtbak_prebackup=$6
	wrtbak_log=$7
	wrtbak_services=$8
	wrtbak_restarted=$9
	wrtbak_blocked=${10}
	wrtbak_errors=${11}
	wrtbak_reboot=${12}
	wrtbak_missing=${13}

	printf '{\n'
	printf '  "ok": true,\n'
	printf '  "operation": "restore-apply",\n'
	printf '  "input": '; wrtbak_json_string "$wrtbak_input"; printf ',\n'
	printf '  "mode": '; wrtbak_json_string "$wrtbak_mode"; printf ',\n'
	printf '  "items": '; wrtbak_json_string "$wrtbak_items"; printf ',\n'
	printf '  "written_count": %s,\n' "$wrtbak_written_count"
	printf '  "skipped_count": %s,\n' "$wrtbak_skipped_count"
	printf '  "prebackup_path": '; wrtbak_json_string "$wrtbak_prebackup"; printf ',\n'
	printf '  "restore_log": '; wrtbak_json_string "$wrtbak_log"; printf ',\n'
	printf '  "restart_services": '; wrtbak_restore_json_file_array "$wrtbak_services"; printf ',\n'
	printf '  "restarted_services": '; wrtbak_restore_json_file_array "$wrtbak_restarted"; printf ',\n'
	printf '  "blocked_restart_services": '; wrtbak_restore_json_file_array "$wrtbak_blocked"; printf ',\n'
	printf '  "restart_errors": '; wrtbak_restore_json_file_object_array "$wrtbak_errors"; printf ',\n'
	printf '  "reboot_recommended": '; wrtbak_json_bool "$wrtbak_reboot"; printf ',\n'
	printf '  "missing_from_archive": '; wrtbak_restore_json_file_array "$wrtbak_missing"; printf '\n'
	printf '}\n'
}

wrtbak_restore_emit_write_failed() {
	wrtbak_input=$1
	wrtbak_written_count=$2
	wrtbak_failed_path=$3
	wrtbak_log=$4
	printf '{\n'
	printf '  "ok": false,\n'
	printf '  "operation": "restore-apply",\n'
	printf '  "code": "write_failed",\n'
	printf '  "message": "restore write failed",\n'
	printf '  "input": '; wrtbak_json_string "$wrtbak_input"; printf ',\n'
	printf '  "written_count": %s,\n' "$wrtbak_written_count"
	printf '  "failed_path": '; wrtbak_json_string "$wrtbak_failed_path"; printf ',\n'
	printf '  "restore_log": '; wrtbak_json_string "$wrtbak_log"; printf '\n'
	printf '}\n'
}

wrtbak_restore_apply() {
	wrtbak_input=$1
	wrtbak_mode=$2
	wrtbak_items=$3
	wrtbak_prebackup=$4
	wrtbak_confirm=$5
	wrtbak_restart_services=$6
	wrtbak_apply_mode=$wrtbak_mode

	if [ "$wrtbak_confirm" != "RESTORE" ]; then
		wrtbak_restore_invalid_json restore-apply missing_confirmation "restore confirmation is required" "$wrtbak_confirm"
		return 1
	fi
	case "$wrtbak_apply_mode" in
		all|selected)
			;;
		*)
			wrtbak_restore_invalid_json restore-apply invalid_mode "restore mode must be all or selected" "$wrtbak_apply_mode"
			return 1
			;;
	esac
	case "$wrtbak_restart_services" in
		0|1)
			;;
		*)
			wrtbak_restore_invalid_json restore-apply invalid_restart_services "restart-services must be 0 or 1" "$wrtbak_restart_services"
			return 1
			;;
	esac
	wrtbak_restore_validate_selected_items "$wrtbak_items" || return 1
	wrtbak_restore_validate_input_path restore-apply "$wrtbak_input" "wrtbak" || return 1
	wrtbak_restore_receipt_operation=restore-apply
	wrtbak_restore_validate_receipt "$wrtbak_prebackup" || return 1

	wrtbak_archive=$(wrtbak_root_path "$wrtbak_input")
	wrtbak_tmp=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-restore-apply.XXXXXX") || {
		wrtbak_restore_invalid_json restore-apply invalid_archive "cannot create temporary directory" ""
		return 1
	}
	wrtbak_set_tmp_cleanup "$wrtbak_tmp"
	wrtbak_members="$wrtbak_tmp/members.list"
	wrtbak_metadata="$wrtbak_tmp/metadata.list"
	wrtbak_extract="$wrtbak_tmp/extract"
	wrtbak_manifest_table="$wrtbak_tmp/manifest-files.tbl"
	wrtbak_archive_table="$wrtbak_tmp/archive.tbl"
	wrtbak_allowed_archive_table="$wrtbak_tmp/archive-allowed.tbl"
	wrtbak_selected_paths="$wrtbak_tmp/selected.paths"
	wrtbak_apply_table="$wrtbak_tmp/apply.tbl"
	wrtbak_skipped="$wrtbak_tmp/skipped.txt"
	wrtbak_missing="$wrtbak_tmp/missing.txt"
	wrtbak_services="$wrtbak_tmp/services.txt"
	wrtbak_restarted="$wrtbak_tmp/restarted.txt"
	wrtbak_blocked="$wrtbak_tmp/blocked.txt"
	wrtbak_restart_errors="$wrtbak_tmp/restart-errors.txt"
	wrtbak_err="$wrtbak_tmp/error.txt"
	mkdir -p "$wrtbak_extract" || {
		wrtbak_clear_tmp_cleanup
		wrtbak_restore_invalid_json restore-apply invalid_archive "cannot create extract directory" ""
		return 1
	}

	if ! (
		wrtbak_validate_archive_metadata "$wrtbak_archive" "$wrtbak_members" "$wrtbak_metadata" &&
		tar xzf "$wrtbak_archive" -C "$wrtbak_extract" &&
		[ -f "$wrtbak_extract/manifest.json" ] &&
		[ -d "$wrtbak_extract/rootfs" ] &&
		wrtbak_validate_tree "$wrtbak_extract/rootfs" rootfs "$wrtbak_tmp" &&
		wrtbak_agent_validate_manifest "$wrtbak_extract/manifest.json"
	) 2>"$wrtbak_err"; then
		wrtbak_detail=$(sed -n '1p' "$wrtbak_err")
		wrtbak_clear_tmp_cleanup
		wrtbak_restore_invalid_json restore-apply invalid_archive "restore archive is not valid" "$wrtbak_detail"
		return 1
	fi

	if ! wrtbak_restore_manifest_files_table "$wrtbak_extract/manifest.json" "$wrtbak_manifest_table" "$wrtbak_tmp"; then
		wrtbak_clear_tmp_cleanup
		wrtbak_restore_invalid_json restore-apply archive_mismatch "restore archive does not match manifest" "manifest files list is invalid"
		return 1
	fi
	if ! wrtbak_restore_verify_manifest_files "$wrtbak_extract" "$wrtbak_manifest_table" "$wrtbak_err"; then
		wrtbak_detail=$(sed -n '1p' "$wrtbak_err")
		wrtbak_clear_tmp_cleanup
		wrtbak_restore_invalid_json restore-apply archive_mismatch "restore archive does not match manifest" "$wrtbak_detail"
		return 1
	fi

	wrtbak_restore_build_archive_table "$wrtbak_extract/rootfs" "$wrtbak_archive_table" "$wrtbak_tmp" || {
		wrtbak_clear_tmp_cleanup
		wrtbak_restore_invalid_json restore-apply invalid_archive "cannot build restore file list" "$wrtbak_input"
		return 1
	}
	if ! wrtbak_restore_verify_archive_manifest_allowlist "$wrtbak_archive_table" "$wrtbak_manifest_table" "$wrtbak_err"; then
		wrtbak_detail=$(sed -n '1p' "$wrtbak_err")
		wrtbak_clear_tmp_cleanup
		wrtbak_restore_invalid_json restore-apply archive_mismatch "restore archive does not match manifest" "$wrtbak_detail"
		return 1
	fi
	if ! wrtbak_restore_require_manifest_identity "$wrtbak_extract/manifest.json"; then
		wrtbak_clear_tmp_cleanup
		return 1
	fi
	wrtbak_restore_filter_archive_table_by_manifest "$wrtbak_archive_table" "$wrtbak_manifest_table" "$wrtbak_allowed_archive_table"
	if [ "$wrtbak_apply_mode" = "selected" ]; then
		wrtbak_write_paths_for_items "$wrtbak_items" "$wrtbak_selected_paths"
	else
		: > "$wrtbak_selected_paths"
	fi
	wrtbak_restore_filter_apply_table "$wrtbak_apply_mode" "$wrtbak_selected_paths" "$wrtbak_allowed_archive_table" "$wrtbak_apply_table" "$wrtbak_skipped" "$wrtbak_missing"

	wrtbak_log_dir=$(wrtbak_restore_log_dir)
	mkdir -p "$wrtbak_log_dir" || {
		wrtbak_clear_tmp_cleanup
		wrtbak_restore_invalid_json restore-apply write_failed "cannot create restore log directory" "$wrtbak_log_dir"
		return 1
	}
	wrtbak_log="/tmp/wrtbak/restore-logs/restore-$(wrtbak_compact_timestamp).jsonl"
	wrtbak_log_actual=$(wrtbak_root_path "$wrtbak_log")
	: > "$wrtbak_log_actual" || {
		wrtbak_clear_tmp_cleanup
		wrtbak_restore_invalid_json restore-apply write_failed "cannot create restore log" "$wrtbak_log"
		return 1
	}

	wrtbak_written_count=0
	wrtbak_failed_path=
	wrtbak_tab=$(printf '\t')
	while IFS="$wrtbak_tab" read -r wrtbak_target wrtbak_type wrtbak_entry_mode wrtbak_size wrtbak_sha wrtbak_archive_path || [ -n "$wrtbak_target" ]; do
		[ -n "$wrtbak_target" ] || continue
		if ! wrtbak_restore_write_one "$wrtbak_extract" "$wrtbak_target" "$wrtbak_type" "$wrtbak_entry_mode" "$wrtbak_archive_path" "$wrtbak_log_dir" "$wrtbak_log_actual" "$wrtbak_apply_mode"; then
			wrtbak_failed_path=$wrtbak_target
			wrtbak_restore_emit_write_failed "$wrtbak_input" "$wrtbak_written_count" "$wrtbak_failed_path" "$wrtbak_log"
			wrtbak_clear_tmp_cleanup
			return 1
		fi
		wrtbak_written_count=$((wrtbak_written_count + 1))
	done < "$wrtbak_apply_table"

	wrtbak_agent_restore_services "$wrtbak_extract/manifest.json" "$wrtbak_services"
	wrtbak_restore_handle_services "$wrtbak_services" "$wrtbak_restart_services" "$wrtbak_restarted" "$wrtbak_blocked" "$wrtbak_restart_errors"
	wrtbak_reboot=$(wrtbak_agent_restore_bool "$wrtbak_extract/manifest.json" reboot_recommended true)
	if [ -s "$wrtbak_blocked" ]; then
		wrtbak_reboot=true
	fi
	wrtbak_skipped_count=$(wc -l < "$wrtbak_skipped" | awk '{ print $1 }')
	wrtbak_restore_emit_apply_success "$wrtbak_input" "$wrtbak_apply_mode" "$wrtbak_items" "$wrtbak_written_count" "$wrtbak_skipped_count" "$wrtbak_prebackup" "$wrtbak_log" "$wrtbak_services" "$wrtbak_restarted" "$wrtbak_blocked" "$wrtbak_restart_errors" "$wrtbak_reboot" "$wrtbak_missing"
	wrtbak_clear_tmp_cleanup
}

wrtbak_restore_sysupgrade_inspect() {
	wrtbak_archive=$1
	wrtbak_extract=$2
	wrtbak_work=$3
	wrtbak_members="$wrtbak_work/sysupgrade-members.list"
	wrtbak_metadata="$wrtbak_work/sysupgrade-metadata.list"
	wrtbak_paths="$wrtbak_work/sysupgrade-paths.tsv"
	wrtbak_summary="$wrtbak_work/sysupgrade-summary.txt"
	wrtbak_err="$wrtbak_work/sysupgrade-error.txt"

	if ! (
		wrtbak_restore_sysupgrade_validate_metadata "$wrtbak_archive" "$wrtbak_members" "$wrtbak_metadata" &&
		tar xzf "$wrtbak_archive" -C "$wrtbak_extract" &&
		wrtbak_validate_tree "$wrtbak_extract" sysupgrade "$wrtbak_work"
	) 2>"$wrtbak_err"; then
		return 1
	fi
	wrtbak_restore_collect_tree_plan "$wrtbak_extract" "" sysupgrade-restore "$wrtbak_paths" "$wrtbak_summary" "$wrtbak_work"
}

wrtbak_restore_sysupgrade() {
	wrtbak_input=$1
	wrtbak_prebackup=$2
	wrtbak_confirm=$3
	wrtbak_execute=$4

	if [ "$wrtbak_confirm" != "RESTORE" ]; then
		wrtbak_restore_invalid_json restore-sysupgrade missing_confirmation "restore confirmation is required" "$wrtbak_confirm"
		return 1
	fi
	case "$wrtbak_execute" in
		0|1)
			;;
		*)
			wrtbak_restore_invalid_json restore-sysupgrade invalid_execute "execute must be 0 or 1" "$wrtbak_execute"
			return 1
			;;
	esac
	wrtbak_restore_validate_input_path restore-sysupgrade "$wrtbak_input" "sysupgrade" || return 1
	wrtbak_restore_receipt_operation=restore-sysupgrade
	wrtbak_restore_validate_receipt "$wrtbak_prebackup" || return 1

	wrtbak_archive=$(wrtbak_root_path "$wrtbak_input")
	wrtbak_archive_size=$(wrtbak_size_of "$wrtbak_archive")
	wrtbak_archive_sha=$(wrtbak_sha256_of "$wrtbak_archive")
	wrtbak_tmp=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-restore-sysupgrade.XXXXXX") || {
		wrtbak_restore_invalid_json restore-sysupgrade invalid_archive "cannot create temporary directory" ""
		return 1
	}
	wrtbak_set_tmp_cleanup "$wrtbak_tmp"
	wrtbak_extract="$wrtbak_tmp/extract"
	mkdir -p "$wrtbak_extract" || {
		wrtbak_clear_tmp_cleanup
		wrtbak_restore_invalid_json restore-sysupgrade invalid_archive "cannot create extract directory" ""
		return 1
	}
	if ! wrtbak_restore_sysupgrade_inspect "$wrtbak_archive" "$wrtbak_extract" "$wrtbak_tmp"; then
		wrtbak_detail=$(sed -n '1p' "$wrtbak_tmp/sysupgrade-error.txt" 2>/dev/null || true)
		wrtbak_clear_tmp_cleanup
		wrtbak_restore_invalid_json restore-sysupgrade invalid_archive "sysupgrade archive is not valid" "$wrtbak_detail"
		return 1
	fi
	wrtbak_manifest="$wrtbak_extract/etc/backup/wrtbak-manifest.json"
	wrtbak_manifest_present=false
	wrtbak_warnings_manifest_missing=true
	if [ -f "$wrtbak_manifest" ]; then
		if ! wrtbak_agent_validate_manifest "$wrtbak_manifest" 2>"$wrtbak_tmp/sysupgrade-error.txt"; then
			wrtbak_detail=$(sed -n '1p' "$wrtbak_tmp/sysupgrade-error.txt" 2>/dev/null || true)
			wrtbak_clear_tmp_cleanup
			wrtbak_restore_invalid_json restore-sysupgrade invalid_archive "sysupgrade manifest is not valid" "$wrtbak_detail"
			return 1
		fi
		wrtbak_manifest_present=true
		wrtbak_warnings_manifest_missing=false
	fi
	set -- $(cat "$wrtbak_tmp/sysupgrade-summary.txt")
	wrtbak_file_count=$1
	wrtbak_total_bytes=$2

	if [ "$wrtbak_execute" = "0" ]; then
		printf '{\n'
		printf '  "ok": true,\n'
		printf '  "operation": "restore-sysupgrade",\n'
		printf '  "execute": false,\n'
		printf '  "status": "preflight_only",\n'
		printf '  "input": '; wrtbak_json_string "$wrtbak_input"; printf ',\n'
		printf '  "prebackup_path": '; wrtbak_json_string "$wrtbak_prebackup"; printf ',\n'
		printf '  "archive": {\n'
		printf '    "filename": '; wrtbak_json_string "$(basename -- "$wrtbak_input")"; printf ',\n'
		printf '    "size": %s,\n' "$wrtbak_archive_size"
		printf '    "sha256": '; wrtbak_json_string "$wrtbak_archive_sha"; printf '\n'
		printf '  },\n'
		printf '  "manifest_present": '; wrtbak_json_bool "$wrtbak_manifest_present"; printf ',\n'
		printf '  "file_count": %s,\n' "$wrtbak_file_count"
		printf '  "total_bytes": %s,\n' "$wrtbak_total_bytes"
		printf '  "compatibility": {\n'
		printf '    "blocking": false,\n'
		if [ "$wrtbak_warnings_manifest_missing" = true ]; then
			printf '    "warnings": [{"code":"manifest_missing","severity":"warning","message":"Sysupgrade archive does not include a wrtbak manifest."}]\n'
		else
			printf '    "warnings": []\n'
		fi
		printf '  },\n'
		printf '  "sysupgrade_command": '; wrtbak_json_string "sysupgrade -r $wrtbak_input"; printf ',\n'
		printf '  "reboot_recommended": true\n'
		printf '}\n'
		wrtbak_clear_tmp_cleanup
		return 0
	fi

	set +e
	sysupgrade -r "$wrtbak_archive"
	wrtbak_exit=$?
	set -e
	if [ "$wrtbak_exit" -eq 0 ]; then
		printf '{\n'
		printf '  "ok": true,\n'
		printf '  "operation": "restore-sysupgrade",\n'
		printf '  "execute": true,\n'
		printf '  "status": "completed",\n'
		printf '  "input": '; wrtbak_json_string "$wrtbak_input"; printf ',\n'
		printf '  "prebackup_path": '; wrtbak_json_string "$wrtbak_prebackup"; printf ',\n'
		printf '  "sysupgrade_exit_code": 0,\n'
		printf '  "reboot_recommended": true\n'
		printf '}\n'
		wrtbak_clear_tmp_cleanup
		return 0
	fi
	printf '{\n'
	printf '  "ok": false,\n'
	printf '  "operation": "restore-sysupgrade",\n'
	printf '  "execute": true,\n'
	printf '  "status": "failed",\n'
	printf '  "code": "sysupgrade_failed",\n'
	printf '  "message": "sysupgrade restore failed",\n'
	printf '  "input": '; wrtbak_json_string "$wrtbak_input"; printf ',\n'
	printf '  "prebackup_path": '; wrtbak_json_string "$wrtbak_prebackup"; printf ',\n'
	printf '  "sysupgrade_exit_code": %s,\n' "$wrtbak_exit"
	printf '  "reboot_recommended": true\n'
	printf '}\n'
	wrtbak_clear_tmp_cleanup
	return 1
}
