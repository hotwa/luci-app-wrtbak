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
		/tmp/wrtbak/restore-cache/*.wrtbak|/tmp/wrtbak/downloads/*.wrtbak|/tmp/wrtbak/pre-restore-*.wrtbak)
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
	if [ -L "$wrtbak_actual" ] || [ ! -f "$wrtbak_actual" ]; then
		wrtbak_restore_invalid_json "$wrtbak_operation" invalid_input_path "invalid restore input path" "$wrtbak_input"
		return 1
	fi

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
	if [ -L "$wrtbak_actual" ] || [ ! -f "$wrtbak_actual" ]; then
		wrtbak_restore_invalid_json "$wrtbak_operation" invalid_prebackup "invalid prebackup path" "$wrtbak_prebackup"
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
	case "$wrtbak_target" in
		"$wrtbak_item_path"/*)
			return 0
			;;
	esac
	return 1
}

wrtbak_restore_annotate_path() {
	wrtbak_target=$1
	wrtbak_items_out=$2
	wrtbak_sensitive_out=$3

	: > "$wrtbak_items_out"
	printf 'false\n' > "$wrtbak_sensitive_out"
	wrtbak_known_item_rows | while IFS='|' read -r wrtbak_id wrtbak_label wrtbak_category wrtbak_packages wrtbak_paths wrtbak_services wrtbak_sensitive wrtbak_selected wrtbak_description; do
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

	wrtbak_mkdir_parent "$wrtbak_actual"
	if ! wrtbak_created_archive=$(wrtbak_create_archive "$wrtbak_profile" "$wrtbak_actual" 2>"$wrtbak_err"); then
		wrtbak_detail=$(sed -n '1p' "$wrtbak_err" 2>/dev/null || true)
		rm -f "$wrtbak_err"
		wrtbak_restore_invalid_json restore-prebackup prebackup_failed "failed to create pre-restore backup" "$wrtbak_detail"
		return 1
	fi
	rm -f "$wrtbak_err"

	[ "$wrtbak_created_archive" = "$wrtbak_actual" ] || true
	wrtbak_size=$(wrtbak_size_of "$wrtbak_actual")
	wrtbak_sha=$(wrtbak_sha256_of "$wrtbak_actual")
	wrtbak_host_device_id=$(wrtbak_effective_device_id)
	wrtbak_host_hostname=$(wrtbak_hostname)
	wrtbak_receipt_tmp="$wrtbak_receipt_actual.$$"

	wrtbak_restore_receipt_json "$wrtbak_receipt_tmp" restore-prebackup "$wrtbak_profile" "$wrtbak_items" "$wrtbak_format" "$wrtbak_path" "$wrtbak_filename" "$wrtbak_size" "$wrtbak_sha" "$wrtbak_created" "$wrtbak_host_device_id" "$wrtbak_host_hostname" || {
		rm -f "$wrtbak_receipt_tmp"
		wrtbak_restore_invalid_json restore-prebackup prebackup_failed "failed to write prebackup receipt" "$wrtbak_receipt_path"
		return 1
	}
	chmod 600 "$wrtbak_receipt_tmp" 2>/dev/null || true
	mv "$wrtbak_receipt_tmp" "$wrtbak_receipt_actual" || {
		rm -f "$wrtbak_receipt_tmp"
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

wrtbak_restore_apply() {
	wrtbak_input=$1
	wrtbak_mode=$2
	wrtbak_items=$3
	wrtbak_prebackup=$4
	wrtbak_confirm=$5
	wrtbak_restart_services=$6

	wrtbak_restore_validate_input_path restore-apply "$wrtbak_input" "wrtbak" || return 1
	wrtbak_restore_validate_prebackup_path restore-apply "$wrtbak_prebackup" || return 1
	wrtbak_restore_error_json restore-apply not_implemented "restore-apply is not implemented" "$wrtbak_mode:$wrtbak_items:$wrtbak_confirm:$wrtbak_restart_services"
	return 1
}

wrtbak_restore_sysupgrade() {
	wrtbak_input=$1
	wrtbak_prebackup=$2
	wrtbak_confirm=$3
	wrtbak_execute=$4

	wrtbak_restore_validate_input_path restore-sysupgrade "$wrtbak_input" "sysupgrade" || return 1
	wrtbak_restore_validate_prebackup_path restore-sysupgrade "$wrtbak_prebackup" || return 1
	wrtbak_restore_error_json restore-sysupgrade not_implemented "restore-sysupgrade is not implemented" "$wrtbak_confirm:$wrtbak_execute"
	return 1
}
