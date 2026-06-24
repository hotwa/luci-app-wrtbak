#!/bin/sh

wrtbak_archive_has_rootfs() {
	wrtbak_archive=$1
	tar tzf "$wrtbak_archive" | grep -q '^rootfs/' && return 0
	tar tzf "$wrtbak_archive" | grep -qx 'rootfs' && return 0
	tar tzf "$wrtbak_archive" | grep -qx 'rootfs/' && return 0
	return 1
}

wrtbak_inspect_archive() {
	wrtbak_archive=$1

	[ -r "$wrtbak_archive" ] || wrtbak_die "archive not readable: $wrtbak_archive"
	tar tzf "$wrtbak_archive" >/dev/null || wrtbak_die "not a readable gzip tar archive: $wrtbak_archive"
	tar tzf "$wrtbak_archive" | grep -qx 'manifest.json' || wrtbak_die "manifest.json missing"
	wrtbak_archive_has_rootfs "$wrtbak_archive" || wrtbak_die "rootfs/ missing"

	printf 'archive: %s\n' "$wrtbak_archive"
	printf 'manifest.json: present\n'
	printf 'rootfs: present\n'
	printf 'entries:\n'
	tar tzf "$wrtbak_archive"
}

wrtbak_validate_member_list() {
	wrtbak_member_file=$1

	while IFS= read -r wrtbak_member || [ -n "$wrtbak_member" ]; do
		if ! wrtbak_is_safe_member "$wrtbak_member"; then
			wrtbak_die "unsafe archive member: $wrtbak_member"
		fi
	done < "$wrtbak_member_file"
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

wrtbak_stage_top_entries() {
	wrtbak_stage=$1
	(cd "$wrtbak_stage" && find . -mindepth 1 -maxdepth 1 -print | sed 's#^\./##' | sort)
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
	wrtbak_members="$wrtbak_tmp/members.list"
	wrtbak_extract="$wrtbak_tmp/extract"
	wrtbak_stage="$wrtbak_tmp/stage"
	wrtbak_out_tmp="$wrtbak_tmp/sysupgrade.tar.gz"

	mkdir -p "$wrtbak_extract" "$wrtbak_stage" || wrtbak_die "cannot create staging directory"
	if ! tar tzf "$wrtbak_input" > "$wrtbak_members"; then
		rm -rf "$wrtbak_tmp"
		wrtbak_die "not a readable gzip tar archive: $wrtbak_input"
	fi
	wrtbak_validate_member_list "$wrtbak_members"
	grep -qx 'manifest.json' "$wrtbak_members" || {
		rm -rf "$wrtbak_tmp"
		wrtbak_die "manifest.json missing"
	}
	grep -q '^rootfs/' "$wrtbak_members" || grep -qx 'rootfs' "$wrtbak_members" || grep -qx 'rootfs/' "$wrtbak_members" || {
		rm -rf "$wrtbak_tmp"
		wrtbak_die "rootfs/ missing"
	}

	if ! tar xzf "$wrtbak_input" -C "$wrtbak_extract"; then
		rm -rf "$wrtbak_tmp"
		wrtbak_die "cannot extract $wrtbak_input"
	fi
	[ -f "$wrtbak_extract/manifest.json" ] || {
		rm -rf "$wrtbak_tmp"
		wrtbak_die "manifest.json missing after extract"
	}
	[ -d "$wrtbak_extract/rootfs" ] || {
		rm -rf "$wrtbak_tmp"
		wrtbak_die "rootfs/ missing after extract"
	}

	wrtbak_copy_rootfs_for_sysupgrade "$wrtbak_extract/rootfs" "$wrtbak_stage" "$wrtbak_tmp"
	mkdir -p "$wrtbak_stage/etc/backup" || wrtbak_die "cannot create sysupgrade manifest directory"
	cp "$wrtbak_extract/manifest.json" "$wrtbak_stage/etc/backup/wrtbak-manifest.json" || wrtbak_die "cannot copy manifest"

	wrtbak_entries=$(wrtbak_stage_top_entries "$wrtbak_stage")
	[ -n "$wrtbak_entries" ] || {
		rm -rf "$wrtbak_tmp"
		wrtbak_die "sysupgrade stage is empty"
	}

	if ! (cd "$wrtbak_stage" && tar -czf "$wrtbak_out_tmp" $wrtbak_entries); then
		rm -rf "$wrtbak_tmp"
		wrtbak_die "failed to create sysupgrade archive"
	fi

	mv "$wrtbak_out_tmp" "$wrtbak_output_abs" || {
		rm -rf "$wrtbak_tmp"
		wrtbak_die "cannot write $wrtbak_output_abs"
	}
	rm -rf "$wrtbak_tmp"
	printf '%s\n' "$wrtbak_output_abs"
}
