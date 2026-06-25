#!/bin/sh

wrtbak_webdav_host() {
	wrtbak_without_scheme=${1#*://}
	wrtbak_host=${wrtbak_without_scheme%%/*}
	wrtbak_host=${wrtbak_host%%:*}
	printf '%s\n' "$wrtbak_host"
}

wrtbak_webdav_base_url() {
	wrtbak_url=$1
	wrtbak_path=$2
	wrtbak_url=${wrtbak_url%/}
	wrtbak_path=$(wrtbak_normalize_remote_path "$wrtbak_path") || return 1
	if [ -n "$wrtbak_path" ]; then
		printf '%s/%s\n' "$wrtbak_url" "$wrtbak_path"
	else
		printf '%s\n' "$wrtbak_url"
	fi
}

wrtbak_webdav_url_for_path() {
	wrtbak_url=$1
	wrtbak_remote_path=$2
	wrtbak_url=${wrtbak_url%/}
	wrtbak_remote_path=$(wrtbak_normalize_remote_path "$wrtbak_remote_path") || return 1
	if [ -n "$wrtbak_remote_path" ]; then
		printf '%s/%s\n' "$wrtbak_url" "$wrtbak_remote_path"
	else
		printf '%s\n' "$wrtbak_url"
	fi
}

wrtbak_webdav_make_netrc() {
	wrtbak_dir=$1
	wrtbak_url=$2
	wrtbak_username=$3
	wrtbak_password=$4
	wrtbak_netrc="$wrtbak_dir/netrc"
	{
		printf 'machine %s\n' "$(wrtbak_webdav_host "$wrtbak_url")"
		printf 'login %s\n' "$wrtbak_username"
		printf 'password %s\n' "$wrtbak_password"
	} > "$wrtbak_netrc" || return 1
	chmod 600 "$wrtbak_netrc" || return 1
	printf '%s\n' "$wrtbak_netrc"
}

wrtbak_webdav_curl() {
	wrtbak_netrc=$1
	shift
	curl -fsS --netrc-file "$wrtbak_netrc" "$@"
}

wrtbak_webdav_mkcol_chain() {
	wrtbak_netrc=$1
	wrtbak_collection_url=$2
	wrtbak_base_url=$3
	wrtbak_relative=${wrtbak_collection_url#"$wrtbak_base_url"}
	wrtbak_relative=${wrtbak_relative#/}
	wrtbak_current=$wrtbak_base_url

	[ -n "$wrtbak_relative" ] || return 0

	wrtbak_old_ifs=$IFS
	IFS=/
	for wrtbak_segment in $wrtbak_relative; do
		IFS=$wrtbak_old_ifs
		[ -n "$wrtbak_segment" ] || {
			IFS=/
			continue
		}
		wrtbak_current="$wrtbak_current/$wrtbak_segment"
		wrtbak_webdav_curl "$wrtbak_netrc" -X MKCOL "$wrtbak_current" >/dev/null 2>&1 || true
		IFS=/
	done
	IFS=$wrtbak_old_ifs
}

wrtbak_webdav_probe() {
	wrtbak_url=$1
	wrtbak_username=$2
	wrtbak_password=$3
	wrtbak_root_path=$4
	wrtbak_device_id=$5
	wrtbak_tmp=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-webdav.XXXXXX") || return 1
	wrtbak_netrc=$(wrtbak_webdav_make_netrc "$wrtbak_tmp" "$wrtbak_url" "$wrtbak_username" "$wrtbak_password") || {
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
	wrtbak_base_url=$(wrtbak_webdav_base_url "$wrtbak_url" "$wrtbak_root_path") || {
		rm -rf "$wrtbak_tmp"
		return 1
	}
	wrtbak_probe_url=$(wrtbak_webdav_url_for_path "$wrtbak_url" "$wrtbak_remote_path") || {
		rm -rf "$wrtbak_tmp"
		return 1
	}
	wrtbak_probe_collection=${wrtbak_probe_url%/*}

	wrtbak_webdav_mkcol_chain "$wrtbak_netrc" "$wrtbak_probe_collection" "$wrtbak_base_url"
	if ! wrtbak_webdav_curl "$wrtbak_netrc" --upload-file "$wrtbak_probe_file" "$wrtbak_probe_url" >/dev/null; then
		rm -rf "$wrtbak_tmp"
		return 1
	fi
	if ! wrtbak_webdav_curl "$wrtbak_netrc" -I "$wrtbak_probe_url" | grep -i '^Content-Length:[[:space:]]*5' >/dev/null 2>&1; then
		rm -rf "$wrtbak_tmp"
		return 1
	fi
	wrtbak_webdav_curl "$wrtbak_netrc" -X DELETE "$wrtbak_probe_url" >/dev/null 2>&1 || true
	rm -rf "$wrtbak_tmp"
	printf '%s\n' "$wrtbak_remote_path"
}

wrtbak_webdav_list_raw() {
	wrtbak_url=$1
	wrtbak_username=$2
	wrtbak_password=$3
	wrtbak_root_path=$4
	wrtbak_device_id=$5
	wrtbak_tmp=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-webdav-list.XXXXXX") || return 1
	wrtbak_netrc=$(wrtbak_webdav_make_netrc "$wrtbak_tmp" "$wrtbak_url" "$wrtbak_username" "$wrtbak_password") || {
		rm -rf "$wrtbak_tmp"
		return 1
	}
	wrtbak_device_prefix=$(wrtbak_join_remote_path "$wrtbak_root_path" wrtbak "$wrtbak_device_id") || {
		rm -rf "$wrtbak_tmp"
		return 1
	}
	wrtbak_collection_url=$(wrtbak_webdav_url_for_path "$wrtbak_url" "$wrtbak_device_prefix") || {
		rm -rf "$wrtbak_tmp"
		return 1
	}
	wrtbak_xml="$wrtbak_tmp/propfind.xml"

	if ! wrtbak_webdav_curl "$wrtbak_netrc" -X PROPFIND -H 'Depth: infinity' "$wrtbak_collection_url" > "$wrtbak_xml" 2>/dev/null; then
		rm -rf "$wrtbak_tmp"
		return 2
	fi

	tr '\n' ' ' < "$wrtbak_xml" | sed 's#</[^>]*response>#\
#g' | while IFS= read -r wrtbak_block || [ -n "$wrtbak_block" ]; do
		wrtbak_href=$(printf '%s\n' "$wrtbak_block" | sed -n 's/.*<[^>]*href>\([^<]*\)<\/[^>]*href>.*/\1/p')
		[ -n "$wrtbak_href" ] || continue
		if printf '%s\n' "$wrtbak_block" | grep '<[^>]*collection' >/dev/null 2>&1; then
			continue
		fi
		case "$wrtbak_href" in
			*"$wrtbak_device_prefix"*)
				wrtbak_suffix=${wrtbak_href#*"$wrtbak_device_prefix"}
				wrtbak_remote_path="$wrtbak_device_prefix$wrtbak_suffix"
				;;
			*)
				continue
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
		wrtbak_filename=${wrtbak_remote_path##*/}
		wrtbak_size=$(printf '%s\n' "$wrtbak_block" | sed -n 's/.*<[^>]*getcontentlength>\([^<]*\)<\/[^>]*getcontentlength>.*/\1/p')
		wrtbak_modified=$(printf '%s\n' "$wrtbak_block" | sed -n 's/.*<[^>]*getlastmodified>\([^<]*\)<\/[^>]*getlastmodified>.*/\1/p')
		printf '%s\t%s\t%s\t%s\t%s\n' "$wrtbak_remote_path" "$wrtbak_filename" "$wrtbak_format" "$wrtbak_size" "$wrtbak_modified"
	done

	rm -rf "$wrtbak_tmp"
}
