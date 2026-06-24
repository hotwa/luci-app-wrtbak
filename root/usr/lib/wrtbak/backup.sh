#!/bin/sh

wrtbak_normalize_path_line() {
	wrtbak_line=$(printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

	case "$wrtbak_line" in
		""|\#*)
			return 1
			;;
		/*)
			;;
		*)
			wrtbak_warn "skipping non-absolute path $wrtbak_line"
			return 1
			;;
	esac

	case "$wrtbak_line" in
		*"/../"*|*"/.."|*/./*|"/.")
			wrtbak_warn "skipping unsafe path $wrtbak_line"
			return 1
			;;
	esac

	printf '%s\n' "$wrtbak_line"
}

wrtbak_seen_archive_path() {
	wrtbak_seen_file=$1
	wrtbak_archive_path=$2
	grep -Fx "$wrtbak_archive_path" "$wrtbak_seen_file" >/dev/null 2>&1
}

wrtbak_mark_archive_path_seen() {
	printf '%s\n' "$2" >> "$1"
}

wrtbak_inventory_add() {
	wrtbak_inventory=$1
	wrtbak_type=$2
	wrtbak_path=$3
	wrtbak_archive_path=$4
	wrtbak_mode=$5
	wrtbak_size=$6
	wrtbak_sha=$7

	printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$wrtbak_type" \
		"$wrtbak_path" \
		"$wrtbak_archive_path" \
		"$wrtbak_mode" \
		"$wrtbak_size" \
		"$wrtbak_sha" >> "$wrtbak_inventory"
}

wrtbak_collect_directory_entry() {
	wrtbak_target_path=$1
	wrtbak_source_dir=$2
	wrtbak_stage=$3
	wrtbak_inventory=$4
	wrtbak_seen=$5
	wrtbak_archive_path="rootfs/$(wrtbak_strip_leading_slash "$wrtbak_target_path")"
	wrtbak_require_safe_member "$wrtbak_archive_path"

	if wrtbak_seen_archive_path "$wrtbak_seen" "$wrtbak_archive_path"; then
		return 0
	fi

	wrtbak_dest="$wrtbak_stage/$wrtbak_archive_path"
	mkdir -p "$wrtbak_dest" || wrtbak_die "cannot create $wrtbak_dest"
	wrtbak_mode=$(wrtbak_mode_of "$wrtbak_source_dir")
	chmod "$wrtbak_mode" "$wrtbak_dest" 2>/dev/null || true
	wrtbak_inventory_add "$wrtbak_inventory" directory "$wrtbak_target_path" "$wrtbak_archive_path" "$wrtbak_mode" "" ""
	wrtbak_mark_archive_path_seen "$wrtbak_seen" "$wrtbak_archive_path"
}

wrtbak_collect_file_entry() {
	wrtbak_target_path=$1
	wrtbak_source_file=$2
	wrtbak_stage=$3
	wrtbak_inventory=$4
	wrtbak_seen=$5
	wrtbak_archive_path="rootfs/$(wrtbak_strip_leading_slash "$wrtbak_target_path")"
	wrtbak_require_safe_member "$wrtbak_archive_path"

	if wrtbak_seen_archive_path "$wrtbak_seen" "$wrtbak_archive_path"; then
		return 0
	fi

	wrtbak_dest="$wrtbak_stage/$wrtbak_archive_path"
	wrtbak_mkdir_parent "$wrtbak_dest"
	cp -p "$wrtbak_source_file" "$wrtbak_dest" || wrtbak_die "cannot copy $wrtbak_source_file"
	wrtbak_mode=$(wrtbak_mode_of "$wrtbak_source_file")
	wrtbak_size=$(wrtbak_size_of "$wrtbak_source_file")
	wrtbak_sha=$(wrtbak_sha256_of "$wrtbak_source_file")
	wrtbak_inventory_add "$wrtbak_inventory" file "$wrtbak_target_path" "$wrtbak_archive_path" "$wrtbak_mode" "$wrtbak_size" "$wrtbak_sha"
	wrtbak_mark_archive_path_seen "$wrtbak_seen" "$wrtbak_archive_path"
}

wrtbak_collect_directory() {
	wrtbak_collect_dir_target=$1
	wrtbak_collect_dir_source=$2
	wrtbak_collect_dir_stage=$3
	wrtbak_collect_dir_inventory=$4
	wrtbak_collect_dir_seen=$5
	wrtbak_collect_dir_work=$6
	wrtbak_collect_dir_dirs="$wrtbak_collect_dir_work/dirs.list"
	wrtbak_collect_dir_files="$wrtbak_collect_dir_work/files.list"

	(cd "$wrtbak_collect_dir_source" && find . -type d -print | sort) > "$wrtbak_collect_dir_dirs" || wrtbak_die "cannot scan $wrtbak_collect_dir_source"
	while IFS= read -r wrtbak_collect_dir_rel; do
		if [ "$wrtbak_collect_dir_rel" = "." ]; then
			wrtbak_collect_dir_child_target=${wrtbak_collect_dir_target%/}
			wrtbak_collect_dir_child_source=$wrtbak_collect_dir_source
		else
			wrtbak_collect_dir_child_rel=${wrtbak_collect_dir_rel#./}
			wrtbak_collect_dir_child_target="${wrtbak_collect_dir_target%/}/$wrtbak_collect_dir_child_rel"
			wrtbak_collect_dir_child_source="$wrtbak_collect_dir_source/$wrtbak_collect_dir_child_rel"
		fi
		wrtbak_collect_directory_entry "$wrtbak_collect_dir_child_target" "$wrtbak_collect_dir_child_source" "$wrtbak_collect_dir_stage" "$wrtbak_collect_dir_inventory" "$wrtbak_collect_dir_seen"
	done < "$wrtbak_collect_dir_dirs"

	(cd "$wrtbak_collect_dir_source" && find . -type f -print | sort) > "$wrtbak_collect_dir_files" || wrtbak_die "cannot scan $wrtbak_collect_dir_source"
	while IFS= read -r wrtbak_collect_dir_rel; do
		wrtbak_collect_dir_child_rel=${wrtbak_collect_dir_rel#./}
		wrtbak_collect_dir_child_target="${wrtbak_collect_dir_target%/}/$wrtbak_collect_dir_child_rel"
		wrtbak_collect_dir_child_source="$wrtbak_collect_dir_source/$wrtbak_collect_dir_child_rel"
		wrtbak_collect_file_entry "$wrtbak_collect_dir_child_target" "$wrtbak_collect_dir_child_source" "$wrtbak_collect_dir_stage" "$wrtbak_collect_dir_inventory" "$wrtbak_collect_dir_seen"
	done < "$wrtbak_collect_dir_files"
}

wrtbak_collect_path() {
	wrtbak_target_path=$1
	wrtbak_stage=$2
	wrtbak_inventory=$3
	wrtbak_seen=$4
	wrtbak_work=$5
	wrtbak_source=$(wrtbak_root_path "$wrtbak_target_path")

	if [ -L "$wrtbak_source" ]; then
		wrtbak_warn "skipping symlink $wrtbak_target_path"
		return 0
	fi

	if [ -d "$wrtbak_source" ]; then
		wrtbak_collect_directory "$wrtbak_target_path" "$wrtbak_source" "$wrtbak_stage" "$wrtbak_inventory" "$wrtbak_seen" "$wrtbak_work"
	elif [ -f "$wrtbak_source" ]; then
		wrtbak_collect_file_entry "$wrtbak_target_path" "$wrtbak_source" "$wrtbak_stage" "$wrtbak_inventory" "$wrtbak_seen"
	else
		return 0
	fi
}

wrtbak_collect_paths() {
	wrtbak_stage=$1
	wrtbak_inventory=$2
	wrtbak_seen=$3
	wrtbak_work=$4
	wrtbak_paths=$(wrtbak_paths_file)

	[ -r "$wrtbak_paths" ] || wrtbak_die "paths file not readable: $wrtbak_paths"

	while IFS= read -r wrtbak_line || [ -n "$wrtbak_line" ]; do
		wrtbak_path=$(wrtbak_normalize_path_line "$wrtbak_line") || continue
		wrtbak_collect_path "$wrtbak_path" "$wrtbak_stage" "$wrtbak_inventory" "$wrtbak_seen" "$wrtbak_work"
	done < "$wrtbak_paths"
}

wrtbak_write_readme() {
	wrtbak_readme=$1
	wrtbak_profile=$2
	wrtbak_backup_id=$3
	wrtbak_created=$4

	{
		printf 'wrtbak backup archive\n'
		printf '\n'
		printf 'Profile: %s\n' "$wrtbak_profile"
		printf 'Backup ID: %s\n' "$wrtbak_backup_id"
		printf 'Created: %s\n' "$wrtbak_created"
		printf 'Tool version: %s\n' "$WRTBAK_VERSION"
		printf '\n'
		printf 'This archive may contain router secrets. Review manifest.json before restore.\n'
		printf 'Use wrtbak-aware tooling for validation before applying files to a device.\n'
	} > "$wrtbak_readme"
}

wrtbak_create_archive() {
	wrtbak_profile=$1
	wrtbak_output=$2

	[ -n "$wrtbak_profile" ] || wrtbak_die "missing profile"
	[ -n "$wrtbak_output" ] || wrtbak_die "missing output file"

	wrtbak_output_abs=$(wrtbak_abs_path "$wrtbak_output")
	wrtbak_output_dir=$(dirname -- "$wrtbak_output_abs")
	mkdir -p "$wrtbak_output_dir" || wrtbak_die "cannot create output directory $wrtbak_output_dir"

	wrtbak_tmp=$(mktemp -d "$wrtbak_output_dir/.wrtbak-create.XXXXXX") || wrtbak_die "cannot create temporary directory"
	wrtbak_set_tmp_cleanup "$wrtbak_tmp"
	wrtbak_stage="$wrtbak_tmp/stage"
	wrtbak_inventory="$wrtbak_tmp/inventory.tsv"
	wrtbak_seen="$wrtbak_tmp/seen.txt"
	wrtbak_out_tmp="$wrtbak_tmp/archive.tar.gz"
	wrtbak_created=$(wrtbak_created_at)
	wrtbak_backup_id="$(wrtbak_safe_id "$wrtbak_profile")-$(wrtbak_compact_timestamp)"

	mkdir -p "$wrtbak_stage/rootfs" || wrtbak_die "cannot create staging directory"
	: > "$wrtbak_inventory"
	: > "$wrtbak_seen"

	wrtbak_collect_paths "$wrtbak_stage" "$wrtbak_inventory" "$wrtbak_seen" "$wrtbak_tmp"
	wrtbak_manifest_write "$wrtbak_inventory" "$wrtbak_stage/manifest.json" "$wrtbak_profile" "$wrtbak_backup_id" "$wrtbak_created"
	wrtbak_write_readme "$wrtbak_stage/README.txt" "$wrtbak_profile" "$wrtbak_backup_id" "$wrtbak_created"

	if ! (cd "$wrtbak_stage" && tar -czf "$wrtbak_out_tmp" manifest.json README.txt rootfs); then
		wrtbak_die "failed to create archive"
	fi

	mv "$wrtbak_out_tmp" "$wrtbak_output_abs" || {
		wrtbak_die "cannot write $wrtbak_output_abs"
	}
	wrtbak_clear_tmp_cleanup
	printf '%s\n' "$wrtbak_output_abs"
}
