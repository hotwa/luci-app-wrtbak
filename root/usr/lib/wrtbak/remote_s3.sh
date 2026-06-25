#!/bin/sh

wrtbak_s3_make_config() {
	wrtbak_dir=$1
	wrtbak_endpoint=$2
	wrtbak_region=$3
	wrtbak_access_key=$4
	wrtbak_secret_key=$5
	wrtbak_force_path_style=$6
	wrtbak_config="$wrtbak_dir/rclone.conf"

	{
		printf '[wrtbak_remote]\n'
		printf 'type = s3\n'
		printf 'provider = Minio\n'
		printf 'env_auth = false\n'
		printf 'access_key_id = %s\n' "$wrtbak_access_key"
		printf 'secret_access_key = %s\n' "$wrtbak_secret_key"
		printf 'endpoint = %s\n' "$wrtbak_endpoint"
		printf 'region = %s\n' "$wrtbak_region"
		if wrtbak_bool_enabled "$wrtbak_force_path_style"; then
			printf 'force_path_style = true\n'
		else
			printf 'force_path_style = false\n'
		fi
	} > "$wrtbak_config" || return 1
	chmod 600 "$wrtbak_config" || return 1
	printf '%s\n' "$wrtbak_config"
}

wrtbak_s3_rclone() {
	wrtbak_config=$1
	shift
	rclone --config "$wrtbak_config" "$@"
}

wrtbak_s3_remote_ref() {
	wrtbak_bucket=$1
	wrtbak_path=$2
	wrtbak_path=$(wrtbak_normalize_remote_path "$wrtbak_path") || return 1
	if [ -n "$wrtbak_path" ]; then
		printf 'wrtbak_remote:%s/%s\n' "$wrtbak_bucket" "$wrtbak_path"
	else
		printf 'wrtbak_remote:%s\n' "$wrtbak_bucket"
	fi
}

wrtbak_s3_probe() {
	wrtbak_endpoint=$1
	wrtbak_region=$2
	wrtbak_bucket=$3
	wrtbak_access_key=$4
	wrtbak_secret_key=$5
	wrtbak_root_path=$6
	wrtbak_force_path_style=$7
	wrtbak_device_id=$8
	wrtbak_tmp=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-s3.XXXXXX") || return 1
	wrtbak_config=$(wrtbak_s3_make_config "$wrtbak_tmp" "$wrtbak_endpoint" "$wrtbak_region" "$wrtbak_access_key" "$wrtbak_secret_key" "$wrtbak_force_path_style") || {
		rm -rf "$wrtbak_tmp"
		return 1
	}
	wrtbak_probe_file="$wrtbak_tmp/probe"
	printf 'probe' > "$wrtbak_probe_file" || {
		rm -rf "$wrtbak_tmp"
		return 1
	}

	wrtbak_remote_path=$(wrtbak_join_remote_path "$wrtbak_root_path" wrtbak "$wrtbak_device_id" ".probe") || {
		rm -rf "$wrtbak_tmp"
		return 1
	}
	wrtbak_remote_file_ref=$(wrtbak_s3_remote_ref "$wrtbak_bucket" "$wrtbak_remote_path") || {
		rm -rf "$wrtbak_tmp"
		return 1
	}

	if ! wrtbak_s3_rclone "$wrtbak_config" copyto "$wrtbak_probe_file" "$wrtbak_remote_file_ref" >/dev/null; then
		rm -rf "$wrtbak_tmp"
		return 1
	fi
	if ! wrtbak_s3_rclone "$wrtbak_config" size "$wrtbak_remote_file_ref" | grep 'Total size: 5 ' >/dev/null 2>&1; then
		rm -rf "$wrtbak_tmp"
		return 1
	fi
	wrtbak_s3_rclone "$wrtbak_config" deletefile "$wrtbak_remote_file_ref" >/dev/null 2>&1 || true
	rm -rf "$wrtbak_tmp"
	printf '%s\n' "$wrtbak_remote_path"
}

wrtbak_s3_list_raw() {
	wrtbak_endpoint=$1
	wrtbak_region=$2
	wrtbak_bucket=$3
	wrtbak_access_key=$4
	wrtbak_secret_key=$5
	wrtbak_root_path=$6
	wrtbak_force_path_style=$7
	wrtbak_device_id=$8
	wrtbak_tmp=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-s3-list.XXXXXX") || return 1
	wrtbak_config=$(wrtbak_s3_make_config "$wrtbak_tmp" "$wrtbak_endpoint" "$wrtbak_region" "$wrtbak_access_key" "$wrtbak_secret_key" "$wrtbak_force_path_style") || {
		rm -rf "$wrtbak_tmp"
		return 1
	}
	wrtbak_device_prefix=$(wrtbak_join_remote_path "$wrtbak_root_path" wrtbak "$wrtbak_device_id") || {
		rm -rf "$wrtbak_tmp"
		return 1
	}
	wrtbak_remote_prefix_ref=$(wrtbak_s3_remote_ref "$wrtbak_bucket" "$wrtbak_device_prefix") || {
		rm -rf "$wrtbak_tmp"
		return 1
	}
	wrtbak_json="$wrtbak_tmp/lsjson.json"

	if ! wrtbak_s3_rclone "$wrtbak_config" lsjson "$wrtbak_remote_prefix_ref" > "$wrtbak_json" 2>/dev/null; then
		rm -rf "$wrtbak_tmp"
		return 1
	fi

	tr '\n' ' ' < "$wrtbak_json" | sed 's/{/\
{/g' | while IFS= read -r wrtbak_block || [ -n "$wrtbak_block" ]; do
		wrtbak_path=$(printf '%s\n' "$wrtbak_block" | sed -n 's/.*"Path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
		[ -n "$wrtbak_path" ] || continue
		case "$wrtbak_path" in
			"$wrtbak_device_prefix"/*)
				wrtbak_remote_path=$wrtbak_path
				;;
			*)
				wrtbak_remote_path=$(wrtbak_join_remote_path "$wrtbak_device_prefix" "$wrtbak_path") || continue
				;;
		esac
		case "$wrtbak_remote_path" in
			*.sysupgrade.tar.gz)
				wrtbak_format=sysupgrade
				;;
			*.wrtbak)
				wrtbak_format=wrtbak
				;;
			*)
				continue
				;;
		esac
		wrtbak_filename=$(printf '%s\n' "$wrtbak_block" | sed -n 's/.*"Name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
		[ -n "$wrtbak_filename" ] || wrtbak_filename=${wrtbak_remote_path##*/}
		wrtbak_size=$(printf '%s\n' "$wrtbak_block" | sed -n 's/.*"Size"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
		wrtbak_modified=$(printf '%s\n' "$wrtbak_block" | sed -n 's/.*"ModTime"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
		printf '%s\t%s\t%s\t%s\t%s\n' "$wrtbak_remote_path" "$wrtbak_filename" "$wrtbak_format" "$wrtbak_size" "$wrtbak_modified"
	done

	rm -rf "$wrtbak_tmp"
}

wrtbak_s3_upload_file() {
	wrtbak_endpoint=$1
	wrtbak_region=$2
	wrtbak_bucket=$3
	wrtbak_access_key=$4
	wrtbak_secret_key=$5
	wrtbak_force_path_style=$6
	wrtbak_local_file=$7
	wrtbak_remote_path=$8
	wrtbak_tmp=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-s3-upload.XXXXXX") || return 1
	wrtbak_config=$(wrtbak_s3_make_config "$wrtbak_tmp" "$wrtbak_endpoint" "$wrtbak_region" "$wrtbak_access_key" "$wrtbak_secret_key" "$wrtbak_force_path_style") || {
		rm -rf "$wrtbak_tmp"
		return 1
	}
	wrtbak_remote_file_ref=$(wrtbak_s3_remote_ref "$wrtbak_bucket" "$wrtbak_remote_path") || {
		rm -rf "$wrtbak_tmp"
		return 1
	}
	wrtbak_local_size=$(wrtbak_size_of "$wrtbak_local_file") || {
		rm -rf "$wrtbak_tmp"
		return 1
	}

	if ! wrtbak_s3_rclone "$wrtbak_config" copyto "$wrtbak_local_file" "$wrtbak_remote_file_ref" >/dev/null; then
		rm -rf "$wrtbak_tmp"
		return 1
	fi
	if ! wrtbak_s3_rclone "$wrtbak_config" size "$wrtbak_remote_file_ref" | grep "Total size: $wrtbak_local_size " >/dev/null 2>&1; then
		rm -rf "$wrtbak_tmp"
		return 1
	fi
	rm -rf "$wrtbak_tmp"
	return 0
}

wrtbak_s3_delete_path() {
	wrtbak_endpoint=$1
	wrtbak_region=$2
	wrtbak_bucket=$3
	wrtbak_access_key=$4
	wrtbak_secret_key=$5
	wrtbak_force_path_style=$6
	wrtbak_remote_path=$7
	wrtbak_tmp=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-s3-delete.XXXXXX") || return 1
	wrtbak_config=$(wrtbak_s3_make_config "$wrtbak_tmp" "$wrtbak_endpoint" "$wrtbak_region" "$wrtbak_access_key" "$wrtbak_secret_key" "$wrtbak_force_path_style") || {
		rm -rf "$wrtbak_tmp"
		return 1
	}
	wrtbak_remote_file_ref=$(wrtbak_s3_remote_ref "$wrtbak_bucket" "$wrtbak_remote_path") || {
		rm -rf "$wrtbak_tmp"
		return 1
	}
	if ! wrtbak_s3_rclone "$wrtbak_config" deletefile "$wrtbak_remote_file_ref" >/dev/null; then
		rm -rf "$wrtbak_tmp"
		return 1
	fi
	rm -rf "$wrtbak_tmp"
	return 0
}
