#!/bin/sh

wrtbak_validate_profile_name() {
	wrtbak_profile=$1
	[ -n "$wrtbak_profile" ] || wrtbak_die "profile is required"
	[ "${#wrtbak_profile}" -le 64 ] || wrtbak_die "profile is too long"

	case "$wrtbak_profile" in
		*[!A-Za-z0-9._-]*)
			wrtbak_die "profile may only contain letters, numbers, dot, underscore, and dash"
			;;
	esac
}

wrtbak_validate_item_ids() {
	wrtbak_items=$1
	[ -n "$wrtbak_items" ] || wrtbak_die "items are required"
	[ "${#wrtbak_items}" -le 512 ] || wrtbak_die "items list is too long"

	case "$wrtbak_items" in
		*[!A-Za-z0-9._,-]*)
			wrtbak_die "items may only contain ids separated by commas"
			;;
	esac
}

wrtbak_output_dir() {
	wrtbak_dir=$(wrtbak_config_option output_dir /tmp/wrtbak)
	case "$wrtbak_dir" in
		/*)
			printf '%s\n' "$wrtbak_dir"
			;;
		*)
			wrtbak_die "output_dir must be absolute"
			;;
	esac
}

wrtbak_prepare_output_dir() {
	wrtbak_dir=$1
	mkdir -p "$wrtbak_dir" || wrtbak_die "cannot create output directory $wrtbak_dir"
	chmod 700 "$wrtbak_dir" 2>/dev/null || true
}

wrtbak_cleanup_downloads() {
	wrtbak_dir=$1
	find "$wrtbak_dir" -type f \( -name '*.wrtbak' -o -name '*.sysupgrade.tar.gz' \) -mtime +1 -exec rm -f {} \; 2>/dev/null || true
}

wrtbak_print_download_json() {
	wrtbak_path=$1
	wrtbak_filename=$2
	wrtbak_format=$3
	wrtbak_size=$(wrtbak_size_of "$wrtbak_path")

	printf '{\n'
	printf '  "path": '; wrtbak_json_string "$wrtbak_path"; printf ',\n'
	printf '  "filename": '; wrtbak_json_string "$wrtbak_filename"; printf ',\n'
	printf '  "format": '; wrtbak_json_string "$wrtbak_format"; printf ',\n'
	printf '  "size": %s\n' "$wrtbak_size"
	printf '}\n'
}

wrtbak_create_download() {
	wrtbak_profile=$1
	wrtbak_items=$2
	wrtbak_format=$3

	wrtbak_validate_profile_name "$wrtbak_profile"
	wrtbak_validate_item_ids "$wrtbak_items"

	case "$wrtbak_format" in
		wrtbak|sysupgrade)
			;;
		*)
			wrtbak_die "format must be wrtbak or sysupgrade"
			;;
	esac

	wrtbak_dir="$(wrtbak_output_dir)/downloads"
	wrtbak_prepare_output_dir "$wrtbak_dir"
	wrtbak_cleanup_downloads "$wrtbak_dir"

	wrtbak_base="$(wrtbak_safe_id "$wrtbak_profile")-$(wrtbak_compact_timestamp)"
	wrtbak_archive="$wrtbak_dir/$wrtbak_base.wrtbak"
	wrtbak_create_archive "$wrtbak_profile" "$wrtbak_archive" "$wrtbak_items" >/dev/null

	if [ "$wrtbak_format" = "sysupgrade" ]; then
		wrtbak_sysupgrade="$wrtbak_dir/$wrtbak_base.sysupgrade.tar.gz"
		wrtbak_export_sysupgrade "$wrtbak_archive" "$wrtbak_sysupgrade" >/dev/null
		rm -f "$wrtbak_archive"
		wrtbak_print_download_json "$wrtbak_sysupgrade" "$wrtbak_base.sysupgrade.tar.gz" sysupgrade
	else
		wrtbak_print_download_json "$wrtbak_archive" "$wrtbak_base.wrtbak" wrtbak
	fi
}
