#!/bin/sh

WRTBAK_VERSION="0.1.0"
: "${WRTBAK_ROOT:=/}"
: "${WRTBAK_LIBDIR:=/usr/lib/wrtbak}"

wrtbak_die() {
	echo "wrtbak: $*" >&2
	exit 1
}

wrtbak_warn() {
	echo "wrtbak: $*" >&2
}

wrtbak_abs_path() {
	case "$1" in
		/*) printf '%s\n' "$1" ;;
		*) printf '%s/%s\n' "$(pwd)" "$1" ;;
	esac
}

wrtbak_strip_leading_slash() {
	wrtbak_path=$1
	while [ "${wrtbak_path#/}" != "$wrtbak_path" ]; do
		wrtbak_path=${wrtbak_path#/}
	done
	printf '%s\n' "$wrtbak_path"
}

wrtbak_root_path() {
	wrtbak_rel=$(wrtbak_strip_leading_slash "$1")
	wrtbak_root=${WRTBAK_ROOT:-/}
	case "$wrtbak_root" in
		""|"/")
			if [ -n "$wrtbak_rel" ]; then
				printf '/%s\n' "$wrtbak_rel"
			else
				printf '/\n'
			fi
			;;
		*)
			if [ -n "$wrtbak_rel" ]; then
				printf '%s/%s\n' "${wrtbak_root%/}" "$wrtbak_rel"
			else
				printf '%s\n' "${wrtbak_root%/}"
			fi
			;;
	esac
}

wrtbak_default_paths_file() {
	printf '%s/paths.default\n' "${WRTBAK_LIBDIR%/}"
}

wrtbak_paths_file() {
	printf '%s\n' "${WRTBAK_PATHS_FILE:-$(wrtbak_default_paths_file)}"
}

wrtbak_mkdir_parent() {
	wrtbak_parent=$(dirname -- "$1")
	mkdir -p "$wrtbak_parent" || wrtbak_die "cannot create directory $wrtbak_parent"
}

wrtbak_cleanup_tmp_dir() {
	if [ -n "${wrtbak_tmp:-}" ] && [ -d "$wrtbak_tmp" ]; then
		rm -rf "$wrtbak_tmp"
	fi
}

wrtbak_set_tmp_cleanup() {
	wrtbak_tmp=$1
	trap 'wrtbak_cleanup_tmp_dir' EXIT
	trap 'wrtbak_cleanup_tmp_dir; exit 1' HUP INT TERM
}

wrtbak_clear_tmp_cleanup() {
	wrtbak_cleanup_tmp_dir
	wrtbak_tmp=
	trap - EXIT HUP INT TERM
}

wrtbak_has_c0_control() {
	case "$1" in
		*'
'*)
			return 0
			;;
	esac

	printf '%s' "$1" | LC_ALL=C grep '[[:cntrl:]]' >/dev/null 2>&1
}

wrtbak_json_escape() {
	if wrtbak_has_c0_control "$1"; then
		wrtbak_die "JSON string contains control characters"
	fi

	printf '%s' "$1" | awk 'BEGIN { ORS = "" } {
		if (NR > 1) {
			printf "\\n"
		}
		gsub(/\\/, "\\\\")
		gsub(/"/, "\\\"")
		gsub(/\r/, "\\r")
		gsub(/\t/, "\\t")
		printf "%s", $0
	}'
}

wrtbak_json_string() {
	printf '"'
	wrtbak_json_escape "$1"
	printf '"'
}

wrtbak_read_uci_option() {
	wrtbak_file=$1
	wrtbak_option=$2
	wrtbak_default=$3
	wrtbak_value=

	if [ -r "$wrtbak_file" ]; then
		wrtbak_value=$(
			awk -v opt="$wrtbak_option" '
				$1 == "option" && $2 == opt {
					$1 = ""
					$2 = ""
					sub(/^[ \t]+/, "")
					if (substr($0, 1, 1) == "\047" && substr($0, length($0), 1) == "\047") {
						print substr($0, 2, length($0) - 2)
						exit
					}
					if (substr($0, 1, 1) == "\"" && substr($0, length($0), 1) == "\"") {
						print substr($0, 2, length($0) - 2)
						exit
					}
					print
					exit
				}
			' "$wrtbak_file"
		)
	fi

	if [ -n "$wrtbak_value" ]; then
		printf '%s\n' "$wrtbak_value"
	else
		printf '%s\n' "$wrtbak_default"
	fi
}

wrtbak_config_option() {
	wrtbak_option=$1
	wrtbak_default=$2
	wrtbak_config=${WRTBAK_CONFIG:-$(wrtbak_root_path /etc/config/wrtbak)}
	wrtbak_read_uci_option "$wrtbak_config" "$wrtbak_option" "$wrtbak_default"
}

wrtbak_release_value() {
	wrtbak_key=$1
	wrtbak_default=$2
	wrtbak_release=$(wrtbak_root_path /etc/openwrt_release)
	wrtbak_value=

	if [ -r "$wrtbak_release" ]; then
		wrtbak_value=$(sed -n "s/^$wrtbak_key=//p" "$wrtbak_release" | sed -n '1p')
		wrtbak_value=$(printf '%s' "$wrtbak_value" | sed "s/^'//;s/'$//;s/^\"//;s/\"$//")
	fi

	if [ -n "$wrtbak_value" ]; then
		printf '%s\n' "$wrtbak_value"
	else
		printf '%s\n' "$wrtbak_default"
	fi
}

wrtbak_jsonfilter_value() {
	wrtbak_file=$1
	wrtbak_expr=$2
	wrtbak_default=$3
	wrtbak_value=

	if [ -r "$wrtbak_file" ] && command -v jsonfilter >/dev/null 2>&1; then
		wrtbak_value=$(jsonfilter -i "$wrtbak_file" -e "$wrtbak_expr" 2>/dev/null | sed -n '1p')
	fi

	if [ -n "$wrtbak_value" ]; then
		printf '%s\n' "$wrtbak_value"
	else
		printf '%s\n' "$wrtbak_default"
	fi
}

wrtbak_hostname() {
	wrtbak_system=$(wrtbak_root_path /etc/config/system)
	wrtbak_name=$(wrtbak_read_uci_option "$wrtbak_system" hostname "")

	if [ -z "$wrtbak_name" ] && [ "${WRTBAK_ROOT:-/}" = "/" ] && [ -r /proc/sys/kernel/hostname ]; then
		wrtbak_name=$(cat /proc/sys/kernel/hostname)
	fi

	if [ -n "$wrtbak_name" ]; then
		printf '%s\n' "$wrtbak_name"
	else
		printf 'unknown\n'
	fi
}

wrtbak_management_ip() {
	wrtbak_network=$(wrtbak_root_path /etc/config/network)
	wrtbak_read_uci_option "$wrtbak_network" ipaddr "unknown"
}

wrtbak_board_model() {
	wrtbak_board=$(wrtbak_root_path /etc/board.json)
	wrtbak_jsonfilter_value "$wrtbak_board" '@.model.name' "unknown"
}

wrtbak_board_name() {
	wrtbak_board=$(wrtbak_root_path /etc/board.json)
	wrtbak_jsonfilter_value "$wrtbak_board" '@.model.id' "unknown"
}

wrtbak_kernel_version() {
	if [ "${WRTBAK_ROOT:-/}" = "/" ]; then
		uname -r
	else
		printf 'unknown\n'
	fi
}

wrtbak_created_at() {
	date -u '+%Y-%m-%dT%H:%M:%SZ'
}

wrtbak_compact_timestamp() {
	date -u '+%Y%m%dT%H%M%SZ'
}

wrtbak_safe_id() {
	wrtbak_safe=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-')
	wrtbak_safe=$(printf '%s' "$wrtbak_safe" | sed 's/^-*//;s/-*$//')
	if [ -n "$wrtbak_safe" ]; then
		printf '%s\n' "$wrtbak_safe"
	else
		printf 'backup\n'
	fi
}

wrtbak_mode_of() {
	wrtbak_mode=$(stat -c '%a' "$1") || wrtbak_die "cannot stat mode for $1"
	printf '0%s\n' "$wrtbak_mode"
}

wrtbak_size_of() {
	stat -c '%s' "$1" || wrtbak_die "cannot stat size for $1"
}

wrtbak_sha256_of() {
	sha256sum "$1" | awk '{ print $1 }'
}

wrtbak_is_safe_member() {
	case "$1" in
		""|/*|../*|*/../*|*/..|..|.|./*|*/./*|*//*)
			return 1
			;;
	esac

	case "$1" in
		*[[:space:]]*)
			return 1
			;;
	esac

	if wrtbak_has_c0_control "$1"; then
		return 1
	fi

	case "/$1/" in
		*/-*)
			return 1
			;;
	esac

	return 0
}

wrtbak_require_safe_member() {
	if ! wrtbak_is_safe_member "$1"; then
		wrtbak_die "unsafe archive member: $1"
	fi
}
