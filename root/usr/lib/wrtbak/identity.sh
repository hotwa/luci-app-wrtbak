#!/bin/sh

wrtbak_identity_algorithm() {
	printf '%s\n' 'wrtbak-board-mac-sha256-10/v1'
}

wrtbak_identity_override_algorithm() {
	printf '%s\n' 'wrtbak-uid-override/v1'
}

wrtbak_identity_test_hooks_allowed() {
	[ "${WRTBAK_ALLOW_TEST_HOOKS:-0}" = "1" ]
}

wrtbak_identity_slugify() {
	printf '%s' "$1" \
		| tr '[:upper:]' '[:lower:]' \
		| sed 's/[^a-z0-9][^a-z0-9]*/-/g;s/^-//;s/-$//'
}

wrtbak_identity_uid_slug() {
	printf '%s' "$1" | cut -c 1-53 | sed 's/-$//'
}

wrtbak_identity_trim() {
	printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

wrtbak_identity_normalize_mac() {
	wrtbak_identity_mac=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d ':.-')
	printf '%s\n' "$wrtbak_identity_mac" | awk '
		length($0) == 12 && $0 !~ /[^0-9a-f]/ {
			print
			ok = 1
		}
		END { exit ok ? 0 : 1 }
	'
}

wrtbak_identity_mac_is_valid() {
	wrtbak_identity_mac=$(wrtbak_identity_normalize_mac "$1") || return 1

	case "$wrtbak_identity_mac" in
		000000000000|ffffffffffff)
			return 1
			;;
	esac

	wrtbak_identity_first_octet=$(printf '%s' "$wrtbak_identity_mac" | cut -c 1-2)
	wrtbak_identity_low_nibble=$(printf '%s' "$wrtbak_identity_first_octet" | cut -c 2)
	case "$wrtbak_identity_low_nibble" in
		1|3|5|7|9|b|d|f)
			return 1
			;;
	esac

	return 0
}

wrtbak_identity_json_board_name() {
	wrtbak_identity_json=$1
	printf '%s\n' "$wrtbak_identity_json" | sed -n 's/.*"board_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p'
}

wrtbak_identity_board_source() {
	if wrtbak_identity_test_hooks_allowed && [ -n "${WRTBAK_FAKE_BOARD_NAME:-}" ]; then
		printf '%s\n' "$WRTBAK_FAKE_BOARD_NAME"
		return 0
	fi

	wrtbak_identity_board_file=$(wrtbak_root_path /tmp/sysinfo/board_name)
	if [ -r "$wrtbak_identity_board_file" ]; then
		wrtbak_identity_board=$(sed -n '1p' "$wrtbak_identity_board_file")
		wrtbak_identity_board_trimmed=$(wrtbak_identity_trim "$wrtbak_identity_board")
		if [ -n "$wrtbak_identity_board_trimmed" ]; then
			printf '%s\n' "$wrtbak_identity_board_trimmed"
			return 0
		fi
	fi

	if command -v ubus >/dev/null 2>&1; then
		wrtbak_identity_board_json=$(ubus call system board 2>/dev/null || true)
		wrtbak_identity_board=$(wrtbak_identity_json_board_name "$wrtbak_identity_board_json")
		wrtbak_identity_board_trimmed=$(wrtbak_identity_trim "$wrtbak_identity_board")
		if [ -n "$wrtbak_identity_board_trimmed" ]; then
			printf '%s\n' "$wrtbak_identity_board_trimmed"
			return 0
		fi
	fi

	wrtbak_identity_compatible_file=$(wrtbak_root_path /proc/device-tree/compatible)
	if [ -r "$wrtbak_identity_compatible_file" ]; then
		wrtbak_identity_board=$(tr '\000' '\n' < "$wrtbak_identity_compatible_file" | sed -n '1p')
		wrtbak_identity_board_trimmed=$(wrtbak_identity_trim "$wrtbak_identity_board")
		if [ -n "$wrtbak_identity_board_trimmed" ]; then
			printf '%s\n' "$wrtbak_identity_board_trimmed"
			return 0
		fi
	fi

	return 1
}

wrtbak_identity_iface_is_virtual() {
	case "$1" in
		lo|tailscale*|wg*|tun*|docker*|veth*|ppp*|ifb*|phy*|mon*)
			return 0
			;;
	esac
	return 1
}

wrtbak_identity_mac_candidate() {
	wrtbak_identity_mac=$(wrtbak_identity_normalize_mac "$1") || return 1
	wrtbak_identity_mac_is_valid "$wrtbak_identity_mac" || return 1
	printf '%s\t%s\n' "$wrtbak_identity_mac" "$2"
}

wrtbak_identity_iface_mac_candidate() {
	wrtbak_identity_iface=$1
	wrtbak_identity_addr_file=$(wrtbak_root_path "/sys/class/net/$wrtbak_identity_iface/address")
	[ -r "$wrtbak_identity_addr_file" ] || return 1
	wrtbak_identity_mac=$(sed -n '1p' "$wrtbak_identity_addr_file")
	wrtbak_identity_mac_candidate "$wrtbak_identity_mac" "$wrtbak_identity_iface"
}

wrtbak_identity_primary_mac() {
	if wrtbak_identity_test_hooks_allowed && [ -n "${WRTBAK_FAKE_PRIMARY_MAC:-}" ]; then
		wrtbak_identity_mac_candidate "$WRTBAK_FAKE_PRIMARY_MAC" test-hook && return 0
	fi

	wrtbak_identity_config=$(wrtbak_config_file)
	wrtbak_identity_mac=$(wrtbak_uci_get_section_option "$wrtbak_identity_config" identity identity primary_mac "")
	if [ -n "$wrtbak_identity_mac" ]; then
		wrtbak_identity_mac_candidate "$wrtbak_identity_mac" wrtbak.identity.primary_mac && return 0
	fi

	wrtbak_identity_network=$(wrtbak_root_path /etc/config/network)
	wrtbak_identity_mac=$(wrtbak_uci_get_section_option "$wrtbak_identity_network" interface lan macaddr "")
	if [ -n "$wrtbak_identity_mac" ]; then
		wrtbak_identity_mac_candidate "$wrtbak_identity_mac" network.lan.macaddr && return 0
	fi

	for wrtbak_identity_iface in br-lan eth0 wan lan1; do
		wrtbak_identity_iface_mac_candidate "$wrtbak_identity_iface" && return 0
	done

	wrtbak_identity_sys_class=$(wrtbak_root_path /sys/class/net)
	[ -d "$wrtbak_identity_sys_class" ] || return 1
	for wrtbak_identity_iface in $(ls "$wrtbak_identity_sys_class" 2>/dev/null | sort); do
		wrtbak_identity_iface_is_virtual "$wrtbak_identity_iface" && continue
		wrtbak_identity_iface_mac_candidate "$wrtbak_identity_iface" && return 0
	done

	return 1
}

wrtbak_identity_alias() {
	wrtbak_identity_alias_value=$(wrtbak_uci_get_section_option "$(wrtbak_config_file)" identity identity alias "")
	if [ -z "$wrtbak_identity_alias_value" ]; then
		wrtbak_identity_alias_value=$(wrtbak_main_option device_alias "")
	fi
	if [ -z "$wrtbak_identity_alias_value" ]; then
		wrtbak_identity_alias_value=$(wrtbak_hostname)
	fi
	printf '%s\n' "$wrtbak_identity_alias_value"
}

wrtbak_identity_load_current() {
	wrtbak_identity_uid=
	wrtbak_identity_uid_algorithm=$(wrtbak_identity_algorithm)
	wrtbak_identity_status=unusable
	wrtbak_identity_board_slug=
	wrtbak_identity_mac_hash=
	wrtbak_identity_mac_source=
	wrtbak_identity_alias_value=$(wrtbak_identity_alias)

	if wrtbak_identity_test_hooks_allowed && [ -n "${WRTBAK_FAKE_DEVICE_UID:-}" ]; then
		wrtbak_identity_uid=$WRTBAK_FAKE_DEVICE_UID
		wrtbak_identity_uid_algorithm=$(wrtbak_identity_override_algorithm)
		wrtbak_identity_status=ok
		return 0
	fi

	wrtbak_identity_board=$(wrtbak_identity_board_source 2>/dev/null || true)
	if [ -n "$wrtbak_identity_board" ]; then
		wrtbak_identity_board_slug=$(wrtbak_identity_slugify "$wrtbak_identity_board")
	fi

	wrtbak_identity_mac_row=$(wrtbak_identity_primary_mac 2>/dev/null || true)
	if [ -n "$wrtbak_identity_mac_row" ]; then
		set -- $wrtbak_identity_mac_row
		wrtbak_identity_mac=$1
		wrtbak_identity_mac_source=$2
		wrtbak_identity_mac_hash=$(printf '%s' "$wrtbak_identity_mac" | sha256sum | awk '{ print substr($1, 1, 10) }')
	fi

	if [ -z "$wrtbak_identity_board_slug" ] || [ -z "$wrtbak_identity_mac_hash" ]; then
		return 1
	fi

	wrtbak_identity_uid_slug=$(wrtbak_identity_uid_slug "$wrtbak_identity_board_slug")
	[ -n "$wrtbak_identity_uid_slug" ] || return 1
	wrtbak_identity_uid="$wrtbak_identity_uid_slug-$wrtbak_identity_mac_hash"
	wrtbak_identity_status=ok
	return 0
}

wrtbak_identity_current_json() {
	if wrtbak_identity_load_current; then
		wrtbak_identity_ok=true
	else
		wrtbak_identity_ok=false
	fi

	printf '{\n'
	printf '  "ok": '; wrtbak_json_bool "$wrtbak_identity_ok"; printf ',\n'
	printf '  "status": '; wrtbak_json_string "$wrtbak_identity_status"; printf ',\n'
	if [ -n "$wrtbak_identity_uid" ]; then
		printf '  "uid": '; wrtbak_json_string "$wrtbak_identity_uid"; printf ',\n'
	fi
	printf '  "uid_algorithm": '; wrtbak_json_string "$wrtbak_identity_uid_algorithm"; printf ',\n'
	printf '  "alias": '; wrtbak_json_string "$wrtbak_identity_alias_value"; printf ',\n'
	printf '  "board_slug": '; wrtbak_json_string "$wrtbak_identity_board_slug"; printf ',\n'
	printf '  "mac_hash": '; wrtbak_json_string "$wrtbak_identity_mac_hash"; printf ',\n'
	printf '  "mac_source": '; wrtbak_json_string "$wrtbak_identity_mac_source"; printf '\n'
	printf '}\n'

	[ "$wrtbak_identity_ok" = true ]
}

wrtbak_identity_current_uid() {
	wrtbak_identity_load_current || return 1
	printf '%s\n' "$wrtbak_identity_uid"
}

wrtbak_parse_identity() {
	wrtbak_identity_want_json=0
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--json)
				wrtbak_identity_want_json=1
				shift
				;;
			-h|--help)
				wrtbak_usage
				exit 0
				;;
			*)
				wrtbak_die "unknown identity argument: $1"
				;;
		esac
	done

	[ "$wrtbak_identity_want_json" -eq 1 ] || wrtbak_die "identity requires --json"
	wrtbak_identity_current_json
}
