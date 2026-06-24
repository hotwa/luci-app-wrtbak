#!/bin/sh

wrtbak_archive_has_rootfs_member() {
	wrtbak_member_file=$1

	grep -q '^rootfs/' "$wrtbak_member_file" && return 0
	grep -qx 'rootfs' "$wrtbak_member_file" && return 0
	grep -qx 'rootfs/' "$wrtbak_member_file" && return 0
	return 1
}

wrtbak_validate_member_list() {
	wrtbak_member_file=$1

	while IFS= read -r wrtbak_member || [ -n "$wrtbak_member" ]; do
		wrtbak_require_safe_member "$wrtbak_member"
	done < "$wrtbak_member_file"
}

wrtbak_validate_tar_metadata() {
	wrtbak_metadata_file=$1

	while IFS= read -r wrtbak_line || [ -n "$wrtbak_line" ]; do
		[ -n "$wrtbak_line" ] || continue
		wrtbak_type=$(printf '%.1s' "$wrtbak_line")
		case "$wrtbak_type" in
			-|d)
				;;
			*)
				wrtbak_die "unsupported tar member type: $wrtbak_type"
				;;
		esac
	done < "$wrtbak_metadata_file"
}

wrtbak_validate_archive_metadata() {
	wrtbak_archive=$1
	wrtbak_member_file=$2
	wrtbak_metadata_file=$3

	[ -r "$wrtbak_archive" ] || wrtbak_die "archive not readable: $wrtbak_archive"
	tar tzf "$wrtbak_archive" > "$wrtbak_member_file" || wrtbak_die "not a readable gzip tar archive: $wrtbak_archive"
	tar tvzf "$wrtbak_archive" > "$wrtbak_metadata_file" || wrtbak_die "not a readable gzip tar archive: $wrtbak_archive"
	wrtbak_validate_member_list "$wrtbak_member_file"
	wrtbak_validate_tar_metadata "$wrtbak_metadata_file"
	grep -qx 'manifest.json' "$wrtbak_member_file" || wrtbak_die "manifest.json missing"
	wrtbak_archive_has_rootfs_member "$wrtbak_member_file" || wrtbak_die "rootfs/ missing"
}

wrtbak_validate_tree() {
	wrtbak_tree_root=$1
	wrtbak_tree_label=$2
	wrtbak_work=$3
	wrtbak_tree_list="$wrtbak_work/$wrtbak_tree_label.tree.list"
	wrtbak_bad_type="$wrtbak_work/$wrtbak_tree_label.bad-type"

	find "$wrtbak_tree_root" ! -type f ! -type d -print | sed -n '1p' > "$wrtbak_bad_type" || wrtbak_die "cannot inspect $wrtbak_tree_label"
	if [ -s "$wrtbak_bad_type" ]; then
		wrtbak_die "$wrtbak_tree_label contains unsupported file type: $(sed -n '1p' "$wrtbak_bad_type")"
	fi

	(cd "$wrtbak_tree_root" && find . -mindepth 1 -print | sort) > "$wrtbak_tree_list" || wrtbak_die "cannot scan $wrtbak_tree_label"
	while IFS= read -r wrtbak_rel || [ -n "$wrtbak_rel" ]; do
		case "$wrtbak_rel" in
			./*)
				wrtbak_member=${wrtbak_rel#./}
				;;
			*)
				wrtbak_member=$wrtbak_rel
				;;
		esac
		wrtbak_require_safe_member "$wrtbak_member"
	done < "$wrtbak_tree_list"
}

wrtbak_write_stage_tar_list() {
	wrtbak_stage=$1
	wrtbak_tar_list=$2

	(cd "$wrtbak_stage" && find . -mindepth 1 -maxdepth 1 -print | sed 's#^\./##' | sort) > "$wrtbak_tar_list" || wrtbak_die "cannot create tar file list"
	[ -s "$wrtbak_tar_list" ] || wrtbak_die "sysupgrade stage is empty"
}

wrtbak_inspect_archive() {
	wrtbak_archive=$1

	wrtbak_tmp=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-inspect.XXXXXX") || wrtbak_die "cannot create temporary directory"
	wrtbak_set_tmp_cleanup "$wrtbak_tmp"
	wrtbak_members="$wrtbak_tmp/members.list"
	wrtbak_metadata="$wrtbak_tmp/metadata.list"

	wrtbak_validate_archive_metadata "$wrtbak_archive" "$wrtbak_members" "$wrtbak_metadata"

	printf 'archive: %s\n' "$wrtbak_archive"
	printf 'manifest.json: present\n'
	printf 'rootfs: present\n'
	printf 'entries:\n'
	cat "$wrtbak_members"

	wrtbak_clear_tmp_cleanup
}

wrtbak_copy_rootfs_for_sysupgrade() {
	wrtbak_source_root=$1
	wrtbak_stage=$2
	wrtbak_work=$3
	wrtbak_dirs="$wrtbak_work/sysupgrade-dirs.list"
	wrtbak_files="$wrtbak_work/sysupgrade-files.list"

	(cd "$wrtbak_source_root" && find . -type d -print | sort) > "$wrtbak_dirs" || wrtbak_die "cannot scan rootfs"
	while IFS= read -r wrtbak_rel; do
		[ "$wrtbak_rel" = "." ] && continue
		wrtbak_child_rel=${wrtbak_rel#./}
		wrtbak_source_dir="$wrtbak_source_root/$wrtbak_child_rel"
		wrtbak_dest_dir="$wrtbak_stage/$wrtbak_child_rel"
		mkdir -p "$wrtbak_dest_dir" || wrtbak_die "cannot create $wrtbak_dest_dir"
		wrtbak_mode=$(wrtbak_mode_of "$wrtbak_source_dir")
		chmod "$wrtbak_mode" "$wrtbak_dest_dir" 2>/dev/null || true
	done < "$wrtbak_dirs"

	(cd "$wrtbak_source_root" && find . -type f -print | sort) > "$wrtbak_files" || wrtbak_die "cannot scan rootfs"
	while IFS= read -r wrtbak_rel; do
		wrtbak_child_rel=${wrtbak_rel#./}
		wrtbak_source_file="$wrtbak_source_root/$wrtbak_child_rel"
		wrtbak_dest_file="$wrtbak_stage/$wrtbak_child_rel"
		wrtbak_mkdir_parent "$wrtbak_dest_file"
		cp -p "$wrtbak_source_file" "$wrtbak_dest_file" || wrtbak_die "cannot copy $wrtbak_child_rel"
	done < "$wrtbak_files"
}

wrtbak_export_sysupgrade() {
	wrtbak_input=$1
	wrtbak_output=$2

	[ -n "$wrtbak_input" ] || wrtbak_die "missing input file"
	[ -n "$wrtbak_output" ] || wrtbak_die "missing output file"
	[ -r "$wrtbak_input" ] || wrtbak_die "input not readable: $wrtbak_input"

	wrtbak_output_abs=$(wrtbak_abs_path "$wrtbak_output")
	wrtbak_output_dir=$(dirname -- "$wrtbak_output_abs")
	mkdir -p "$wrtbak_output_dir" || wrtbak_die "cannot create output directory $wrtbak_output_dir"

	wrtbak_tmp=$(mktemp -d "$wrtbak_output_dir/.wrtbak-export.XXXXXX") || wrtbak_die "cannot create temporary directory"
	wrtbak_set_tmp_cleanup "$wrtbak_tmp"
	wrtbak_members="$wrtbak_tmp/members.list"
	wrtbak_metadata="$wrtbak_tmp/metadata.list"
	wrtbak_extract="$wrtbak_tmp/extract"
	wrtbak_stage="$wrtbak_tmp/stage"
	wrtbak_tar_list="$wrtbak_tmp/sysupgrade-tar.list"
	wrtbak_out_tmp="$wrtbak_tmp/sysupgrade.tar.gz"

	mkdir -p "$wrtbak_extract" "$wrtbak_stage" || wrtbak_die "cannot create staging directory"
	wrtbak_validate_archive_metadata "$wrtbak_input" "$wrtbak_members" "$wrtbak_metadata"

	if ! tar xzf "$wrtbak_input" -C "$wrtbak_extract"; then
		wrtbak_die "cannot extract $wrtbak_input"
	fi
	[ -f "$wrtbak_extract/manifest.json" ] || wrtbak_die "manifest.json missing after extract"
	[ -d "$wrtbak_extract/rootfs" ] || wrtbak_die "rootfs/ missing after extract"

	wrtbak_validate_tree "$wrtbak_extract/rootfs" rootfs "$wrtbak_tmp"
	wrtbak_copy_rootfs_for_sysupgrade "$wrtbak_extract/rootfs" "$wrtbak_stage" "$wrtbak_tmp"
	mkdir -p "$wrtbak_stage/etc/backup" || wrtbak_die "cannot create sysupgrade manifest directory"
	cp "$wrtbak_extract/manifest.json" "$wrtbak_stage/etc/backup/wrtbak-manifest.json" || wrtbak_die "cannot copy manifest"
	wrtbak_validate_tree "$wrtbak_stage" sysupgrade-stage "$wrtbak_tmp"
	wrtbak_write_stage_tar_list "$wrtbak_stage" "$wrtbak_tar_list"

	if ! (cd "$wrtbak_stage" && tar -czf "$wrtbak_out_tmp" -T "$wrtbak_tar_list"); then
		wrtbak_die "failed to create sysupgrade archive"
	fi

	mv "$wrtbak_out_tmp" "$wrtbak_output_abs" || wrtbak_die "cannot write $wrtbak_output_abs"
	wrtbak_clear_tmp_cleanup
	printf '%s\n' "$wrtbak_output_abs"
}
