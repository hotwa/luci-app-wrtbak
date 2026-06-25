#!/bin/sh

wrtbak_agent_check_json() {
	wrtbak_check_name=$1
	wrtbak_check_ok=$2
	wrtbak_check_detail=$3

	printf '    {\n'
	printf '      "name": '; wrtbak_json_string "$wrtbak_check_name"; printf ',\n'
	printf '      "ok": '; wrtbak_json_bool "$wrtbak_check_ok"; printf ',\n'
	printf '      "detail": '; wrtbak_json_string "$wrtbak_check_detail"; printf '\n'
	printf '    }'
}

wrtbak_agent_recent_backups() {
	wrtbak_agent_dir=$1
	wrtbak_agent_output=$2

	: > "$wrtbak_agent_output"
	[ -d "$wrtbak_agent_dir" ] || return 0

	find "$wrtbak_agent_dir" -maxdepth 1 -type f \( -name '*.wrtbak' -o -name '*.sysupgrade.tar.gz' \) -print 2>/dev/null | sort | tail -n 5 > "$wrtbak_agent_output"
}

wrtbak_agent_recent_backups_json() {
	wrtbak_agent_list=$1

	printf '['
	wrtbak_agent_first=1
	while IFS= read -r wrtbak_agent_path || [ -n "$wrtbak_agent_path" ]; do
		[ -n "$wrtbak_agent_path" ] || continue
		wrtbak_agent_filename=$(basename -- "$wrtbak_agent_path")
		wrtbak_agent_format=wrtbak
		case "$wrtbak_agent_filename" in
			*.sysupgrade.tar.gz)
				wrtbak_agent_format=sysupgrade
				;;
		esac
		wrtbak_agent_size=$(wrtbak_size_of "$wrtbak_agent_path")
		if [ "$wrtbak_agent_first" -eq 1 ]; then
			printf '\n'
			wrtbak_agent_first=0
		else
			printf ',\n'
		fi
		printf '    {\n'
		printf '      "path": '; wrtbak_json_string "$wrtbak_agent_path"; printf ',\n'
		printf '      "filename": '; wrtbak_json_string "$wrtbak_agent_filename"; printf ',\n'
		printf '      "format": '; wrtbak_json_string "$wrtbak_agent_format"; printf ',\n'
		printf '      "size": %s\n' "$wrtbak_agent_size"
		printf '    }'
	done < "$wrtbak_agent_list"

	if [ "$wrtbak_agent_first" -eq 1 ]; then
		printf ']'
	else
		printf '\n  ]'
	fi
}

wrtbak_agent_item_counts() {
	wrtbak_agent_installed=$1
	wrtbak_installed_file=$wrtbak_agent_installed
	wrtbak_agent_detected=0
	wrtbak_agent_installed_count=0
	wrtbak_agent_selected=0
	wrtbak_agent_unknown_luci="$wrtbak_agent_installed.unknown-luci"

	wrtbak_known_item_rows | while IFS='|' read -r wrtbak_id wrtbak_label wrtbak_category wrtbak_packages wrtbak_paths wrtbak_services wrtbak_sensitive wrtbak_selected wrtbak_description; do
		printf 'known\t%s\t%s\t%s\t%s\n' "$wrtbak_id" "$wrtbak_packages" "$wrtbak_paths" "$wrtbak_selected"
	done > "$wrtbak_agent_installed.known"

	while IFS='	' read -r wrtbak_kind wrtbak_id wrtbak_packages wrtbak_paths wrtbak_selected; do
		[ "$wrtbak_kind" = "known" ] || continue
		wrtbak_agent_detected=$((wrtbak_agent_detected + 1))
		if [ "$wrtbak_selected" = "true" ]; then
			wrtbak_agent_selected=$((wrtbak_agent_selected + 1))
		fi
		if [ -z "$wrtbak_packages" ] || wrtbak_any_package_installed "$wrtbak_packages" || wrtbak_any_path_exists "$wrtbak_paths"; then
			wrtbak_agent_installed_count=$((wrtbak_agent_installed_count + 1))
		fi
	done < "$wrtbak_agent_installed.known"

	wrtbak_installed_luci_apps > "$wrtbak_agent_unknown_luci"
	while IFS= read -r wrtbak_agent_pkg || [ -n "$wrtbak_agent_pkg" ]; do
		[ -n "$wrtbak_agent_pkg" ] || continue
		if wrtbak_luci_app_is_known "$wrtbak_agent_pkg"; then
			continue
		fi
		wrtbak_agent_detected=$((wrtbak_agent_detected + 1))
		wrtbak_agent_installed_count=$((wrtbak_agent_installed_count + 1))
	done < "$wrtbak_agent_unknown_luci"

	printf '%s %s %s\n' "$wrtbak_agent_detected" "$wrtbak_agent_installed_count" "$wrtbak_agent_selected"
}

wrtbak_agent_status_json() {
	wrtbak_tmp=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-agent-status.XXXXXX") || wrtbak_die "cannot create temporary directory"
	wrtbak_set_tmp_cleanup "$wrtbak_tmp"
	wrtbak_installed="$wrtbak_tmp/installed.txt"
	wrtbak_recent="$wrtbak_tmp/recent.txt"
	wrtbak_installed_packages > "$wrtbak_installed"
	wrtbak_counts=$(wrtbak_agent_item_counts "$wrtbak_installed")
	set -- $wrtbak_counts
	wrtbak_detected_items=$1
	wrtbak_installed_items=$2
	wrtbak_selected_items=$3
	wrtbak_agent_output_dir=$(wrtbak_output_dir)
	wrtbak_agent_recent_backups "$wrtbak_agent_output_dir" "$wrtbak_recent"
	wrtbak_recent_count=$(wc -l < "$wrtbak_recent" | awk '{ print $1 }')

	printf '{\n'
	printf '  "tool_version": '; wrtbak_json_string "$WRTBAK_VERSION"; printf ',\n'
	printf '  "root": '; wrtbak_json_string "${WRTBAK_ROOT:-/}"; printf ',\n'
	printf '  "libdir": '; wrtbak_json_string "$WRTBAK_LIBDIR"; printf ',\n'
	printf '  "paths_file": '; wrtbak_json_string "$(wrtbak_paths_file)"; printf ',\n'
	printf '  "output_dir": '; wrtbak_json_string "$wrtbak_agent_output_dir"; printf ',\n'
	printf '  "package_manager": '; wrtbak_json_string "$(wrtbak_package_manager)"; printf ',\n'
	printf '  "device": {\n'
	printf '    "hostname": '; wrtbak_json_string "$(wrtbak_hostname)"; printf ',\n'
	printf '    "management_ip": '; wrtbak_json_string "$(wrtbak_management_ip)"; printf ',\n'
	printf '    "board_model": '; wrtbak_json_string "$(wrtbak_board_model)"; printf ',\n'
	printf '    "board_name": '; wrtbak_json_string "$(wrtbak_board_name)"; printf '\n'
	printf '  },\n'
	printf '  "firmware": {\n'
	printf '    "distribution": '; wrtbak_json_string "$(wrtbak_release_value DISTRIB_ID OpenWrt)"; printf ',\n'
	printf '    "version": '; wrtbak_json_string "$(wrtbak_release_value DISTRIB_RELEASE unknown)"; printf ',\n'
	printf '    "revision": '; wrtbak_json_string "$(wrtbak_release_value DISTRIB_REVISION unknown)"; printf ',\n'
	printf '    "target": '; wrtbak_json_string "$(wrtbak_release_value DISTRIB_TARGET unknown)"; printf ',\n'
	printf '    "arch": '; wrtbak_json_string "$(wrtbak_release_value DISTRIB_ARCH unknown)"; printf ',\n'
	printf '    "kernel": '; wrtbak_json_string "$(wrtbak_kernel_version)"; printf '\n'
	printf '  },\n'
	printf '  "counts": {\n'
	printf '    "detected_items": %s,\n' "$wrtbak_detected_items"
	printf '    "installed_items": %s,\n' "$wrtbak_installed_items"
	printf '    "selected_items": %s,\n' "$wrtbak_selected_items"
	printf '    "recent_backups": %s\n' "$wrtbak_recent_count"
	printf '  },\n'
	printf '  "recent_backups": '
	wrtbak_agent_recent_backups_json "$wrtbak_recent"
	printf '\n'
	printf '}\n'

	wrtbak_clear_tmp_cleanup
}

wrtbak_agent_doctor_json() {
	wrtbak_agent_lib_ok=false
	wrtbak_agent_paths_ok=false
	wrtbak_agent_output_ok=false
	wrtbak_agent_pm_ok=false
	wrtbak_agent_tools_ok=true
	wrtbak_agent_ok=true
	wrtbak_agent_checks="$WRTBAK_LIBDIR/common.sh $WRTBAK_LIBDIR/backup.sh $WRTBAK_LIBDIR/items.sh $WRTBAK_LIBDIR/manifest.sh $WRTBAK_LIBDIR/pack.sh $WRTBAK_LIBDIR/web.sh $WRTBAK_LIBDIR/agent.sh"
	wrtbak_agent_paths=$(wrtbak_paths_file)
	wrtbak_agent_output=$(wrtbak_config_option output_dir /tmp/wrtbak)
	wrtbak_agent_pm=$(wrtbak_package_manager)
	wrtbak_agent_missing_tools=

	for wrtbak_agent_check in $wrtbak_agent_checks; do
		if [ ! -r "$wrtbak_agent_check" ]; then
			wrtbak_agent_lib_detail="missing $wrtbak_agent_check"
			wrtbak_agent_ok=false
			break
		fi
	done
	if [ -z "${wrtbak_agent_lib_detail:-}" ]; then
		wrtbak_agent_lib_ok=true
		wrtbak_agent_lib_detail="all wrtbak libraries are readable"
	fi

	if [ -r "$wrtbak_agent_paths" ]; then
		wrtbak_agent_paths_ok=true
		wrtbak_agent_paths_detail="$wrtbak_agent_paths is readable"
	else
		wrtbak_agent_paths_detail="$wrtbak_agent_paths is not readable"
		wrtbak_agent_ok=false
	fi

	case "$wrtbak_agent_output" in
		/*)
			if [ -d "$wrtbak_agent_output" ]; then
				if [ -w "$wrtbak_agent_output" ]; then
					wrtbak_agent_output_ok=true
					wrtbak_agent_output_detail="$wrtbak_agent_output is writable"
				else
					wrtbak_agent_output_detail="$wrtbak_agent_output is not writable"
					wrtbak_agent_ok=false
				fi
			else
				wrtbak_agent_parent=$(dirname -- "$wrtbak_agent_output")
				if [ -d "$wrtbak_agent_parent" ] && [ -w "$wrtbak_agent_parent" ]; then
					wrtbak_agent_output_ok=true
					wrtbak_agent_output_detail="$wrtbak_agent_output can be created"
				else
					wrtbak_agent_output_detail="$wrtbak_agent_output parent is not writable"
					wrtbak_agent_ok=false
				fi
			fi
			;;
		*)
			wrtbak_agent_output_detail="output_dir must be absolute"
			wrtbak_agent_ok=false
			;;
	esac

	if [ "$wrtbak_agent_pm" != "none" ]; then
		wrtbak_agent_pm_ok=true
		wrtbak_agent_pm_detail="$wrtbak_agent_pm available"
	else
		wrtbak_agent_pm_detail="apk/opkg not found"
		wrtbak_agent_ok=false
	fi

	for wrtbak_agent_tool in tar sha256sum stat find awk sed grep; do
		if ! command -v "$wrtbak_agent_tool" >/dev/null 2>&1; then
			wrtbak_agent_tools_ok=false
			wrtbak_agent_ok=false
			wrtbak_agent_missing_tools="$wrtbak_agent_missing_tools $wrtbak_agent_tool"
		fi
	done
	if [ "$wrtbak_agent_tools_ok" = true ]; then
		wrtbak_agent_tools_detail="archive tools available"
	else
		wrtbak_agent_tools_detail="missing:$wrtbak_agent_missing_tools"
	fi

	printf '{\n'
	printf '  "ok": '; wrtbak_json_bool "$wrtbak_agent_ok"; printf ',\n'
	printf '  "checks": [\n'
	wrtbak_agent_check_json libdir "$wrtbak_agent_lib_ok" "$wrtbak_agent_lib_detail"; printf ',\n'
	wrtbak_agent_check_json paths_file "$wrtbak_agent_paths_ok" "$wrtbak_agent_paths_detail"; printf ',\n'
	wrtbak_agent_check_json output_dir "$wrtbak_agent_output_ok" "$wrtbak_agent_output_detail"; printf ',\n'
	wrtbak_agent_check_json package_manager "$wrtbak_agent_pm_ok" "$wrtbak_agent_pm_detail"; printf ',\n'
	wrtbak_agent_check_json archive_tools "$wrtbak_agent_tools_ok" "$wrtbak_agent_tools_detail"; printf '\n'
	printf '  ]\n'
	printf '}\n'
}

wrtbak_agent_known_row() {
	wrtbak_agent_lookup=$1
	wrtbak_agent_rows=$2

	awk -F'|' -v id="$wrtbak_agent_lookup" '$1 == id { print; found = 1; exit } END { exit found ? 0 : 1 }' "$wrtbak_agent_rows"
}

wrtbak_agent_warning_json() {
	wrtbak_agent_code=$1
	wrtbak_agent_item=$2
	wrtbak_agent_path=$3
	wrtbak_agent_message=$4

	printf '    {\n'
	printf '      "code": '; wrtbak_json_string "$wrtbak_agent_code"; printf ',\n'
	printf '      "item_id": '; wrtbak_json_string "$wrtbak_agent_item"
	if [ -n "$wrtbak_agent_path" ]; then
		printf ',\n'
		printf '      "path": '; wrtbak_json_string "$wrtbak_agent_path"
	fi
	printf ',\n'
	printf '      "message": '; wrtbak_json_string "$wrtbak_agent_message"; printf '\n'
	printf '    }'
}

wrtbak_agent_items_json() {
	wrtbak_agent_items_file=$1
	wrtbak_agent_tab=$(printf '\t')

	printf '['
	wrtbak_agent_first=1
	while IFS="$wrtbak_agent_tab" read -r wrtbak_agent_id wrtbak_agent_label wrtbak_agent_category wrtbak_agent_known wrtbak_agent_sensitive wrtbak_agent_paths wrtbak_agent_services; do
		[ -n "$wrtbak_agent_id" ] || continue
		if [ "$wrtbak_agent_first" -eq 1 ]; then
			printf '\n'
			wrtbak_agent_first=0
		else
			printf ',\n'
		fi
		printf '    {\n'
		printf '      "id": '; wrtbak_json_string "$wrtbak_agent_id"; printf ',\n'
		printf '      "label": '; wrtbak_json_string "$wrtbak_agent_label"; printf ',\n'
		printf '      "category": '; wrtbak_json_string "$wrtbak_agent_category"; printf ',\n'
		printf '      "known": '; wrtbak_json_bool "$wrtbak_agent_known"; printf ',\n'
		printf '      "sensitive": '; wrtbak_json_bool "$wrtbak_agent_sensitive"; printf ',\n'
		printf '      "paths": '; wrtbak_json_word_array "$wrtbak_agent_paths"; printf ',\n'
		printf '      "restart_services": '; wrtbak_json_word_array "$wrtbak_agent_services"; printf '\n'
		printf '    }'
	done < "$wrtbak_agent_items_file"

	if [ "$wrtbak_agent_first" -eq 1 ]; then
		printf ']'
	else
		printf '\n  ]'
	fi
}

wrtbak_agent_paths_json() {
	wrtbak_agent_paths_file=$1
	wrtbak_agent_tab=$(printf '\t')

	printf '['
	wrtbak_agent_first=1
	while IFS="$wrtbak_agent_tab" read -r wrtbak_agent_item wrtbak_agent_path wrtbak_agent_exists wrtbak_agent_type wrtbak_agent_sensitive; do
		[ -n "$wrtbak_agent_item" ] || continue
		if [ "$wrtbak_agent_first" -eq 1 ]; then
			printf '\n'
			wrtbak_agent_first=0
		else
			printf ',\n'
		fi
		printf '    {\n'
		printf '      "item_id": '; wrtbak_json_string "$wrtbak_agent_item"; printf ',\n'
		printf '      "path": '; wrtbak_json_string "$wrtbak_agent_path"; printf ',\n'
		printf '      "exists": '; wrtbak_json_bool "$wrtbak_agent_exists"; printf ',\n'
		printf '      "type": '; wrtbak_json_string "$wrtbak_agent_type"; printf ',\n'
		printf '      "sensitive": '; wrtbak_json_bool "$wrtbak_agent_sensitive"; printf '\n'
		printf '    }'
	done < "$wrtbak_agent_paths_file"

	if [ "$wrtbak_agent_first" -eq 1 ]; then
		printf ']'
	else
		printf '\n  ]'
	fi
}

wrtbak_agent_warnings_json() {
	wrtbak_agent_warnings_file=$1
	wrtbak_agent_tab=$(printf '\t')

	printf '['
	wrtbak_agent_first=1
	while IFS="$wrtbak_agent_tab" read -r wrtbak_agent_code wrtbak_agent_item wrtbak_agent_path wrtbak_agent_message; do
		[ -n "$wrtbak_agent_code" ] || continue
		if [ "$wrtbak_agent_first" -eq 1 ]; then
			printf '\n'
			wrtbak_agent_first=0
		else
			printf ',\n'
		fi
		wrtbak_agent_warning_json "$wrtbak_agent_code" "$wrtbak_agent_item" "$wrtbak_agent_path" "$wrtbak_agent_message"
	done < "$wrtbak_agent_warnings_file"

	if [ "$wrtbak_agent_first" -eq 1 ]; then
		printf ']'
	else
		printf '\n  ]'
	fi
}

wrtbak_agent_plan_path_type() {
	wrtbak_agent_plan_source=$1

	if [ -d "$wrtbak_agent_plan_source" ]; then
		printf 'directory\n'
	elif [ -f "$wrtbak_agent_plan_source" ]; then
		printf 'file\n'
	elif [ -e "$wrtbak_agent_plan_source" ]; then
		printf 'unsupported\n'
	else
		printf 'missing\n'
	fi
}

wrtbak_agent_plan_json() {
	wrtbak_agent_profile=$1
	wrtbak_agent_items=$2
	wrtbak_agent_format=$3

	wrtbak_validate_profile_name "$wrtbak_agent_profile"
	wrtbak_validate_item_ids "$wrtbak_agent_items"
	case "$wrtbak_agent_format" in
		wrtbak|sysupgrade)
			;;
		*)
			wrtbak_die "format must be wrtbak or sysupgrade"
			;;
	esac

	wrtbak_tmp=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-agent-plan.XXXXXX") || wrtbak_die "cannot create temporary directory"
	wrtbak_set_tmp_cleanup "$wrtbak_tmp"
	wrtbak_agent_known="$wrtbak_tmp/known.tsv"
	wrtbak_agent_items_out="$wrtbak_tmp/items.tsv"
	wrtbak_agent_paths_out="$wrtbak_tmp/paths.tsv"
	wrtbak_agent_warnings="$wrtbak_tmp/warnings.tsv"
	wrtbak_agent_row="$wrtbak_tmp/row.tsv"
	wrtbak_known_item_rows > "$wrtbak_agent_known"
	: > "$wrtbak_agent_items_out"
	: > "$wrtbak_agent_paths_out"
	: > "$wrtbak_agent_warnings"
	wrtbak_agent_requested_count=0
	wrtbak_agent_existing_count=0
	wrtbak_agent_missing_count=0
	wrtbak_agent_sensitive_count=0
	wrtbak_agent_tab=$(printf '\t')

	if [ "$wrtbak_agent_items" = "all" ]; then
		wrtbak_agent_items=$(awk -F'|' '{ if ($8 == "true") printf "%s,", $1 }' "$wrtbak_agent_known")
	fi

	wrtbak_old_ifs=$IFS
	IFS=,
	for wrtbak_agent_item in $wrtbak_agent_items; do
		IFS=$wrtbak_old_ifs
		wrtbak_agent_item=$(printf '%s' "$wrtbak_agent_item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
		[ -n "$wrtbak_agent_item" ] || {
			IFS=,
			continue
		}
		wrtbak_agent_requested_count=$((wrtbak_agent_requested_count + 1))

		if wrtbak_agent_known_row "$wrtbak_agent_item" "$wrtbak_agent_known" > "$wrtbak_agent_row"; then
			IFS='|' read -r wrtbak_id wrtbak_label wrtbak_category wrtbak_packages wrtbak_paths wrtbak_services wrtbak_sensitive wrtbak_selected wrtbak_description < "$wrtbak_agent_row"
			wrtbak_agent_known_value=true
		else
			case "$wrtbak_agent_item" in
				luci-app-*)
					wrtbak_id=$wrtbak_agent_item
					wrtbak_label=$wrtbak_agent_item
					wrtbak_category=plugin
					wrtbak_paths=$(wrtbak_unknown_luci_app_paths "$wrtbak_agent_item" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
					wrtbak_services=
					wrtbak_sensitive=true
					wrtbak_agent_known_value=false
					;;
				*)
					wrtbak_die "unknown backup item: $wrtbak_agent_item"
					;;
			esac
		fi

		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$wrtbak_id" "$wrtbak_label" "$wrtbak_category" "$wrtbak_agent_known_value" "$wrtbak_sensitive" "$wrtbak_paths" "$wrtbak_services" >> "$wrtbak_agent_items_out"
		if [ "$wrtbak_sensitive" = "true" ]; then
			wrtbak_agent_sensitive_count=$((wrtbak_agent_sensitive_count + 1))
			printf 'sensitive_item\t%s\t\t%s may contain secrets or access tokens\n' "$wrtbak_id" "$wrtbak_label" >> "$wrtbak_agent_warnings"
		fi

		for wrtbak_agent_path in $wrtbak_paths; do
			wrtbak_agent_source=$(wrtbak_root_path "$wrtbak_agent_path")
			wrtbak_agent_type=$(wrtbak_agent_plan_path_type "$wrtbak_agent_source")
			if [ "$wrtbak_agent_type" = "missing" ]; then
				wrtbak_agent_exists=false
				wrtbak_agent_missing_count=$((wrtbak_agent_missing_count + 1))
				printf 'missing_path\t%s\t%s\t%s is not present and will be skipped\n' "$wrtbak_id" "$wrtbak_agent_path" "$wrtbak_agent_path" >> "$wrtbak_agent_warnings"
			else
				wrtbak_agent_exists=true
				wrtbak_agent_existing_count=$((wrtbak_agent_existing_count + 1))
			fi
			printf '%s\t%s\t%s\t%s\t%s\n' "$wrtbak_id" "$wrtbak_agent_path" "$wrtbak_agent_exists" "$wrtbak_agent_type" "$wrtbak_sensitive" >> "$wrtbak_agent_paths_out"
		done
		IFS=,
	done
	IFS=$wrtbak_old_ifs

	printf '{\n'
	printf '  "profile": '; wrtbak_json_string "$wrtbak_agent_profile"; printf ',\n'
	printf '  "format": '; wrtbak_json_string "$wrtbak_agent_format"; printf ',\n'
	printf '  "items": '
	wrtbak_agent_items_json "$wrtbak_agent_items_out"
	printf ',\n'
	printf '  "paths": '
	wrtbak_agent_paths_json "$wrtbak_agent_paths_out"
	printf ',\n'
	printf '  "summary": {\n'
	printf '    "requested_items": %s,\n' "$wrtbak_agent_requested_count"
	printf '    "existing_paths": %s,\n' "$wrtbak_agent_existing_count"
	printf '    "missing_paths": %s,\n' "$wrtbak_agent_missing_count"
	printf '    "sensitive_items": %s\n' "$wrtbak_agent_sensitive_count"
	printf '  },\n'
	printf '  "warnings": '
	wrtbak_agent_warnings_json "$wrtbak_agent_warnings"
	printf '\n'
	printf '}\n'

	wrtbak_clear_tmp_cleanup
}

wrtbak_agent_manifest_string() {
	wrtbak_agent_manifest=$1
	wrtbak_agent_key=$2
	wrtbak_agent_default=$3
	wrtbak_agent_value=$(wrtbak_agent_jsonfilter_first "$wrtbak_agent_manifest" "@.$wrtbak_agent_key" "$wrtbak_agent_key" "$wrtbak_agent_default")

	if [ -n "$wrtbak_agent_value" ]; then
		printf '%s\n' "$wrtbak_agent_value"
	else
		printf '%s\n' "$wrtbak_agent_default"
	fi
}

wrtbak_agent_require_jsonfilter() {
	command -v jsonfilter >/dev/null 2>&1 || wrtbak_die "jsonfilter is required for restore-plan manifest validation"
}

wrtbak_agent_jsonfilter_first() {
	wrtbak_agent_manifest=$1
	wrtbak_agent_expr=$2
	wrtbak_agent_label=$3
	wrtbak_agent_default=${4:-}

	wrtbak_agent_require_jsonfilter
	wrtbak_agent_jsonfilter_out=$(mktemp "${TMPDIR:-/tmp}/wrtbak-jsonfilter.XXXXXX") || wrtbak_die "cannot create temporary file"
	if ! jsonfilter -i "$wrtbak_agent_manifest" -e "$wrtbak_agent_expr" > "$wrtbak_agent_jsonfilter_out" 2>/dev/null; then
		rm -f "$wrtbak_agent_jsonfilter_out"
		wrtbak_die "manifest.json is not valid JSON or missing $wrtbak_agent_label"
	fi
	wrtbak_agent_value=$(sed -n '1p' "$wrtbak_agent_jsonfilter_out")
	rm -f "$wrtbak_agent_jsonfilter_out"

	if [ -n "$wrtbak_agent_value" ]; then
		printf '%s\n' "$wrtbak_agent_value"
	else
		printf '%s\n' "$wrtbak_agent_default"
	fi
}

wrtbak_agent_restore_bool() {
	wrtbak_agent_manifest=$1
	wrtbak_agent_key=$2
	wrtbak_agent_default=$3
	wrtbak_agent_value=$(wrtbak_agent_jsonfilter_first "$wrtbak_agent_manifest" "@.restore.$wrtbak_agent_key" "restore.$wrtbak_agent_key" "$wrtbak_agent_default")

	case "$wrtbak_agent_value" in
		true|false)
			printf '%s\n' "$wrtbak_agent_value"
			;;
		*)
			wrtbak_die "manifest.json restore.$wrtbak_agent_key must be boolean"
			;;
	esac
}

wrtbak_agent_jsonfilter_to_file() {
	wrtbak_agent_manifest=$1
	wrtbak_agent_expr=$2
	wrtbak_agent_output=$3
	wrtbak_agent_label=$4

	wrtbak_agent_require_jsonfilter
	if ! jsonfilter -i "$wrtbak_agent_manifest" -e "$wrtbak_agent_expr" > "$wrtbak_agent_output" 2>/dev/null; then
		wrtbak_die "manifest.json is not valid JSON or missing $wrtbak_agent_label"
	fi
}

wrtbak_agent_validate_manifest() {
	wrtbak_agent_manifest=$1

	wrtbak_agent_require_jsonfilter

	wrtbak_agent_schema=$(wrtbak_agent_manifest_string "$wrtbak_agent_manifest" schema "")
	[ "$wrtbak_agent_schema" = "wrtbak/v1" ] || wrtbak_die "unsupported manifest schema: ${wrtbak_agent_schema:-missing}"

	for wrtbak_agent_key in profile backup_id created_at tool_version; do
		wrtbak_agent_value=$(wrtbak_agent_manifest_string "$wrtbak_agent_manifest" "$wrtbak_agent_key" "")
		[ -n "$wrtbak_agent_value" ] || wrtbak_die "manifest.json missing $wrtbak_agent_key"
	done

	wrtbak_agent_restore_services "$wrtbak_agent_manifest" "${wrtbak_tmp:-${TMPDIR:-/tmp}}/wrtbak-restore-services-check.$$"
	wrtbak_agent_restore_bool "$wrtbak_agent_manifest" reboot_recommended true >/dev/null
	wrtbak_agent_restore_bool "$wrtbak_agent_manifest" requires_confirmation true >/dev/null
}

wrtbak_agent_restore_services() {
	wrtbak_agent_manifest=$1
	wrtbak_agent_output=$2

	: > "$wrtbak_agent_output"
	wrtbak_agent_jsonfilter_to_file "$wrtbak_agent_manifest" '@.restore.restart_services[*]' "$wrtbak_agent_output" restore.restart_services
	if [ ! -s "$wrtbak_agent_output" ]; then
		wrtbak_die "manifest.json missing restore.restart_services"
	fi
}

wrtbak_agent_string_file_array_json() {
	wrtbak_agent_file=$1

	printf '['
	wrtbak_agent_first=1
	while IFS= read -r wrtbak_agent_value || [ -n "$wrtbak_agent_value" ]; do
		[ -n "$wrtbak_agent_value" ] || continue
		if [ "$wrtbak_agent_first" -eq 1 ]; then
			wrtbak_agent_first=0
		else
			printf ', '
		fi
		wrtbak_json_string "$wrtbak_agent_value"
	done < "$wrtbak_agent_file"
	printf ']'
}

wrtbak_agent_collect_restore_paths() {
	wrtbak_agent_rootfs=$1
	wrtbak_agent_paths_out=$2
	wrtbak_agent_summary_out=$3
	wrtbak_agent_work=$4
	wrtbak_agent_dirs="$wrtbak_agent_work/restore-dirs.list"
	wrtbak_agent_files="$wrtbak_agent_work/restore-files.list"
	wrtbak_agent_file_count=0
	wrtbak_agent_dir_count=0
	wrtbak_agent_total_bytes=0

	: > "$wrtbak_agent_paths_out"
	(cd "$wrtbak_agent_rootfs" && find . -mindepth 1 -type d -print | sort) > "$wrtbak_agent_dirs" || wrtbak_die "cannot scan restore directories"
	while IFS= read -r wrtbak_agent_rel || [ -n "$wrtbak_agent_rel" ]; do
		[ -n "$wrtbak_agent_rel" ] || continue
		wrtbak_agent_child=${wrtbak_agent_rel#./}
		wrtbak_agent_path="/$wrtbak_agent_child"
		printf '%s\tdirectory\t\n' "$wrtbak_agent_path" >> "$wrtbak_agent_paths_out"
		wrtbak_agent_dir_count=$((wrtbak_agent_dir_count + 1))
	done < "$wrtbak_agent_dirs"

	(cd "$wrtbak_agent_rootfs" && find . -type f -print | sort) > "$wrtbak_agent_files" || wrtbak_die "cannot scan restore files"
	while IFS= read -r wrtbak_agent_rel || [ -n "$wrtbak_agent_rel" ]; do
		[ -n "$wrtbak_agent_rel" ] || continue
		wrtbak_agent_child=${wrtbak_agent_rel#./}
		wrtbak_agent_path="/$wrtbak_agent_child"
		wrtbak_agent_size=$(wrtbak_size_of "$wrtbak_agent_rootfs/$wrtbak_agent_child")
		printf '%s\tfile\t%s\n' "$wrtbak_agent_path" "$wrtbak_agent_size" >> "$wrtbak_agent_paths_out"
		wrtbak_agent_file_count=$((wrtbak_agent_file_count + 1))
		wrtbak_agent_total_bytes=$((wrtbak_agent_total_bytes + wrtbak_agent_size))
	done < "$wrtbak_agent_files"

	printf '%s %s %s\n' "$wrtbak_agent_file_count" "$wrtbak_agent_dir_count" "$wrtbak_agent_total_bytes" > "$wrtbak_agent_summary_out"
}

wrtbak_agent_restore_paths_json() {
	wrtbak_agent_paths_file=$1
	wrtbak_agent_tab=$(printf '\t')

	printf '['
	wrtbak_agent_first=1
	while IFS="$wrtbak_agent_tab" read -r wrtbak_agent_path wrtbak_agent_type wrtbak_agent_size; do
		[ -n "$wrtbak_agent_path" ] || continue
		if [ "$wrtbak_agent_first" -eq 1 ]; then
			printf '\n'
			wrtbak_agent_first=0
		else
			printf ',\n'
		fi
		printf '    {\n'
		printf '      "path": '; wrtbak_json_string "$wrtbak_agent_path"; printf ',\n'
		printf '      "type": '; wrtbak_json_string "$wrtbak_agent_type"
		if [ "$wrtbak_agent_type" = "file" ]; then
			printf ',\n'
			printf '      "size": %s\n' "$wrtbak_agent_size"
		else
			printf '\n'
		fi
		printf '    }'
	done < "$wrtbak_agent_paths_file"

	if [ "$wrtbak_agent_first" -eq 1 ]; then
		printf ']'
	else
		printf '\n  ]'
	fi
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
	wrtbak_agent_collect_restore_paths "$wrtbak_agent_extract/rootfs" "$wrtbak_agent_paths" "$wrtbak_agent_summary" "$wrtbak_tmp"
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
	printf '  "file_count": %s,\n' "$wrtbak_agent_file_count"
	printf '  "directory_count": %s,\n' "$wrtbak_agent_dir_count"
	printf '  "total_file_bytes": %s,\n' "$wrtbak_agent_total_bytes"
	printf '  "restart_services": '
	wrtbak_agent_string_file_array_json "$wrtbak_agent_services"
	printf ',\n'
	printf '  "reboot_recommended": '; wrtbak_json_bool "$(wrtbak_agent_restore_bool "$wrtbak_agent_manifest" reboot_recommended true)"; printf ',\n'
	printf '  "requires_confirmation": '; wrtbak_json_bool "$(wrtbak_agent_restore_bool "$wrtbak_agent_manifest" requires_confirmation true)"; printf ',\n'
	printf '  "paths": '
	wrtbak_agent_restore_paths_json "$wrtbak_agent_paths"
	printf '\n'
	printf '}\n'

	wrtbak_clear_tmp_cleanup
}
