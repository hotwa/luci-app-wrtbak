#!/bin/sh

wrtbak_package_manager() {
	if command -v apk >/dev/null 2>&1; then
		printf 'apk\n'
	elif command -v opkg >/dev/null 2>&1; then
		printf 'opkg\n'
	else
		printf 'none\n'
	fi
}

wrtbak_installed_packages() {
	wrtbak_pm=$(wrtbak_package_manager)
	case "$wrtbak_pm" in
		apk)
			apk info 2>/dev/null | sort -u
			;;
		opkg)
			opkg list-installed 2>/dev/null | awk '{ print $1 }' | sort -u
			;;
		*)
			return 0
			;;
	esac
}

wrtbak_package_is_installed() {
	wrtbak_pkg=$1
	grep -Fx "$wrtbak_pkg" "$wrtbak_installed_file" >/dev/null 2>&1
}

wrtbak_any_package_installed() {
	wrtbak_packages=$1
	[ -n "$wrtbak_packages" ] || return 1

	wrtbak_old_ifs=$IFS
	IFS=,
	for wrtbak_pkg in $wrtbak_packages; do
		IFS=$wrtbak_old_ifs
		[ -n "$wrtbak_pkg" ] || continue
		if wrtbak_package_is_installed "$wrtbak_pkg"; then
			return 0
		fi
		IFS=,
	done
	IFS=$wrtbak_old_ifs
	return 1
}

wrtbak_path_exists() {
	[ -e "$(wrtbak_root_path "$1")" ]
}

wrtbak_any_path_exists() {
	wrtbak_paths=$1
	for wrtbak_path in $wrtbak_paths; do
		if wrtbak_path_exists "$wrtbak_path"; then
			return 0
		fi
	done
	return 1
}

wrtbak_known_item_rows() {
	cat <<'EOF'
core-system|OpenWrt system|core||/etc/config/system|system|false|true|Hostname, timezone, and base system settings
network|Network, PPPoE, DHCP, DNS, firewall|core||/etc/config/network /etc/config/dhcp /etc/config/firewall|network firewall dnsmasq odhcpd|true|true|LAN/WAN, PPPoE credentials, DHCP, DNS, and firewall rules
wireless|Wi-Fi|core||/etc/config/wireless|network|true|true|Wireless radio and SSID settings
dropbear|Dropbear SSH|access|dropbear|/etc/config/dropbear /etc/dropbear/authorized_keys /etc/dropbear/dropbear_rsa_host_key /etc/dropbear/dropbear_ecdsa_host_key /etc/dropbear/dropbear_ed25519_host_key|dropbear|true|true|SSH access policy, authorized keys, and host identity
ddns-go|DDNS-Go|plugin|luci-app-ddns-go,ddns-go|/etc/config/ddns-go /etc/ddns-go /etc/ddns-go.yaml|ddns-go|true|true|DDNS-Go configuration and tokens
nikki|Nikki proxy|plugin|luci-app-nikki,nikki|/etc/config/nikki /etc/nikki|nikki|true|true|Nikki proxy profiles, rules, and runtime configuration
mosdns|MosDNS|plugin|luci-app-mosdns,mosdns|/etc/config/mosdns /etc/mosdns|mosdns|false|true|MosDNS resolver configuration and rule files
tailscale|Tailscale|plugin|luci-app-tailscale-community,luci-app-tailscale,tailscale|/etc/config/tailscale /etc/tailscale /etc/tailscale/tailscaled.state|tailscale|true|true|Tailscale settings and node state
wireguard|WireGuard|vpn|luci-app-wireguard,wireguard-tools,kmod-wireguard|/etc/config/network /etc/config/firewall /etc/wireguard|network firewall|true|true|WireGuard interfaces, peers, keys, and related firewall settings
EOF
}

wrtbak_installed_luci_apps() {
	grep '^luci-app-' "$wrtbak_installed_file" 2>/dev/null | sort -u
}

wrtbak_known_package_ids() {
	wrtbak_known_item_rows | while IFS='|' read -r wrtbak_id wrtbak_label wrtbak_category wrtbak_packages wrtbak_paths wrtbak_services wrtbak_sensitive wrtbak_selected wrtbak_description; do
		[ -n "$wrtbak_packages" ] || continue
		wrtbak_old_ifs=$IFS
		IFS=,
		for wrtbak_pkg in $wrtbak_packages; do
			IFS=$wrtbak_old_ifs
			[ -n "$wrtbak_pkg" ] || continue
			printf '%s\t%s\n' "$wrtbak_pkg" "$wrtbak_id"
			IFS=,
		done
		IFS=$wrtbak_old_ifs
	done
}

wrtbak_luci_app_is_known() {
	wrtbak_pkg=$1
	wrtbak_known_package_ids | awk -v pkg="$wrtbak_pkg" '$1 == pkg { found = 1 } END { exit found ? 0 : 1 }'
}

wrtbak_unknown_luci_app_paths() {
	wrtbak_pkg=$1
	wrtbak_suffix=${wrtbak_pkg#luci-app-}

	for wrtbak_path in "/etc/config/$wrtbak_suffix" "/etc/$wrtbak_suffix"; do
		if wrtbak_path_exists "$wrtbak_path"; then
			printf '%s\n' "$wrtbak_path"
		fi
	done
}

wrtbak_json_bool() {
	case "$1" in
		true|1|yes) printf 'true' ;;
		*) printf 'false' ;;
	esac
}

wrtbak_json_word_array() {
	wrtbak_words=$1
	printf '['
	wrtbak_first=1
	for wrtbak_word in $wrtbak_words; do
		if [ "$wrtbak_first" -eq 1 ]; then
			wrtbak_first=0
		else
			printf ', '
		fi
		wrtbak_json_string "$wrtbak_word"
	done
	printf ']'
}

wrtbak_emit_item_json() {
	wrtbak_id=$1
	wrtbak_label=$2
	wrtbak_category=$3
	wrtbak_installed=$4
	wrtbak_known=$5
	wrtbak_sensitive=$6
	wrtbak_selected=$7
	wrtbak_paths=$8
	wrtbak_services=$9
	wrtbak_description=${10}

	printf '    {\n'
	printf '      "id": '; wrtbak_json_string "$wrtbak_id"; printf ',\n'
	printf '      "label": '; wrtbak_json_string "$wrtbak_label"; printf ',\n'
	printf '      "category": '; wrtbak_json_string "$wrtbak_category"; printf ',\n'
	printf '      "installed": '; wrtbak_json_bool "$wrtbak_installed"; printf ',\n'
	printf '      "known": '; wrtbak_json_bool "$wrtbak_known"; printf ',\n'
	printf '      "sensitive": '; wrtbak_json_bool "$wrtbak_sensitive"; printf ',\n'
	printf '      "selected": '; wrtbak_json_bool "$wrtbak_selected"; printf ',\n'
	printf '      "paths": '; wrtbak_json_word_array "$wrtbak_paths"; printf ',\n'
	printf '      "restart_services": '; wrtbak_json_word_array "$wrtbak_services"; printf ',\n'
	printf '      "description": '; wrtbak_json_string "$wrtbak_description"; printf '\n'
	printf '    }'
}

wrtbak_detect_emit_item() {
	if [ "$wrtbak_detect_first" -eq 1 ]; then
		wrtbak_detect_first=0
	else
		printf ',\n'
	fi

	wrtbak_emit_item_json "$@"
}

wrtbak_detect_items_json() {
	wrtbak_tmp=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-detect.XXXXXX") || wrtbak_die "cannot create temporary directory"
	wrtbak_set_tmp_cleanup "$wrtbak_tmp"
	wrtbak_installed_file="$wrtbak_tmp/installed.txt"
	wrtbak_known_rows="$wrtbak_tmp/known-items.tsv"
	wrtbak_unknown_packages="$wrtbak_tmp/unknown-luci-apps.txt"
	wrtbak_installed_packages > "$wrtbak_installed_file"
	wrtbak_known_item_rows > "$wrtbak_known_rows"
	wrtbak_installed_luci_apps > "$wrtbak_unknown_packages"
	wrtbak_pm=$(wrtbak_package_manager)

	printf '{\n'
	printf '  "package_manager": '; wrtbak_json_string "$wrtbak_pm"; printf ',\n'
	printf '  "items": [\n'

	wrtbak_detect_first=1
	while IFS='|' read -r wrtbak_id wrtbak_label wrtbak_category wrtbak_packages wrtbak_paths wrtbak_services wrtbak_sensitive wrtbak_selected wrtbak_description; do
		wrtbak_installed=false
		if [ -z "$wrtbak_packages" ] || wrtbak_any_package_installed "$wrtbak_packages" || wrtbak_any_path_exists "$wrtbak_paths"; then
			wrtbak_installed=true
		fi

		wrtbak_detect_emit_item "$wrtbak_id" "$wrtbak_label" "$wrtbak_category" "$wrtbak_installed" true "$wrtbak_sensitive" "$wrtbak_selected" "$wrtbak_paths" "$wrtbak_services" "$wrtbak_description"
	done < "$wrtbak_known_rows"

	while IFS= read -r wrtbak_pkg || [ -n "$wrtbak_pkg" ]; do
		[ -n "$wrtbak_pkg" ] || continue
		if wrtbak_luci_app_is_known "$wrtbak_pkg"; then
			continue
		fi
		wrtbak_paths=$(wrtbak_unknown_luci_app_paths "$wrtbak_pkg" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
		wrtbak_detect_emit_item "$wrtbak_pkg" "$wrtbak_pkg" plugin true false true false "$wrtbak_paths" "" "Installed LuCI app without a built-in backup rule"
	done < "$wrtbak_unknown_packages"

	printf '\n'
	printf '  ]\n'
	printf '}\n'
	wrtbak_clear_tmp_cleanup
}

wrtbak_item_paths_by_id() {
	wrtbak_lookup_id=$1
	wrtbak_known_rows=$(mktemp "${TMPDIR:-/tmp}/wrtbak-known.XXXXXX") || wrtbak_die "cannot create temporary file"
	wrtbak_known_item_rows > "$wrtbak_known_rows"
	while IFS='|' read -r wrtbak_id wrtbak_label wrtbak_category wrtbak_packages wrtbak_paths wrtbak_services wrtbak_sensitive wrtbak_selected wrtbak_description; do
		if [ "$wrtbak_id" = "$wrtbak_lookup_id" ]; then
			for wrtbak_path in $wrtbak_paths; do
				printf '%s\n' "$wrtbak_path"
			done
			rm -f "$wrtbak_known_rows"
			return 0
		fi
	done < "$wrtbak_known_rows"
	rm -f "$wrtbak_known_rows"

	case "$wrtbak_lookup_id" in
		luci-app-*)
			wrtbak_unknown_luci_app_paths "$wrtbak_lookup_id"
			;;
	esac
}

wrtbak_write_paths_for_items() {
	wrtbak_items=$1
	wrtbak_output=$2
	: > "$wrtbak_output" || wrtbak_die "cannot write selected paths file"

	if [ "$wrtbak_items" = "all" ]; then
		wrtbak_items=$(wrtbak_known_item_rows | awk -F'|' '{ if ($8 == "true") printf "%s,", $1 }')
	fi

	wrtbak_old_ifs=$IFS
	IFS=,
	for wrtbak_item in $wrtbak_items; do
		IFS=$wrtbak_old_ifs
		wrtbak_item=$(printf '%s' "$wrtbak_item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
		[ -n "$wrtbak_item" ] || {
			IFS=,
			continue
		}
		wrtbak_item_paths_by_id "$wrtbak_item" >> "$wrtbak_output"
		IFS=,
	done
	IFS=$wrtbak_old_ifs

	sort -u "$wrtbak_output" -o "$wrtbak_output"
}
