#!/bin/sh

wrtbak_manifest_write() {
	wrtbak_inventory=$1
	wrtbak_manifest=$2
	wrtbak_profile=$3
	wrtbak_backup_id=$4
	wrtbak_created=$5

	wrtbak_hostname_value=$(wrtbak_hostname)
	wrtbak_management_ip_value=$(wrtbak_management_ip)
	wrtbak_board_model_value=$(wrtbak_board_model)
	wrtbak_board_name_value=$(wrtbak_board_name)
	wrtbak_distribution_value=$(wrtbak_release_value DISTRIB_ID OpenWrt)
	wrtbak_version_value=$(wrtbak_release_value DISTRIB_RELEASE unknown)
	wrtbak_revision_value=$(wrtbak_release_value DISTRIB_REVISION unknown)
	wrtbak_target_value=$(wrtbak_release_value DISTRIB_TARGET unknown)
	wrtbak_arch_value=$(wrtbak_release_value DISTRIB_ARCH unknown)
	wrtbak_kernel_value=$(wrtbak_kernel_version)
	wrtbak_default_mode_value=$(wrtbak_config_option default_mode review-required)
	wrtbak_tab=$(printf '\t')

	{
		printf '{\n'
		printf '  "schema": '; wrtbak_json_string "wrtbak/v1"; printf ',\n'
		printf '  "profile": '; wrtbak_json_string "$wrtbak_profile"; printf ',\n'
		printf '  "backup_id": '; wrtbak_json_string "$wrtbak_backup_id"; printf ',\n'
		printf '  "created_at": '; wrtbak_json_string "$wrtbak_created"; printf ',\n'
		printf '  "tool_version": '; wrtbak_json_string "$WRTBAK_VERSION"; printf ',\n'
		printf '  "device": {\n'
		printf '    "label": '; wrtbak_json_string "$wrtbak_hostname_value"; printf ',\n'
		printf '    "hostname": '; wrtbak_json_string "$wrtbak_hostname_value"; printf ',\n'
		printf '    "management_ip": '; wrtbak_json_string "$wrtbak_management_ip_value"; printf ',\n'
		printf '    "market_model": '; wrtbak_json_string "$wrtbak_board_model_value"; printf ',\n'
		printf '    "board_model": '; wrtbak_json_string "$wrtbak_board_model_value"; printf ',\n'
		printf '    "board_name": '; wrtbak_json_string "$wrtbak_board_name_value"; printf ',\n'
		printf '    "target": '; wrtbak_json_string "$wrtbak_target_value"; printf ',\n'
		printf '    "arch": '; wrtbak_json_string "$wrtbak_arch_value"; printf '\n'
		printf '  },\n'
		printf '  "firmware": {\n'
		printf '    "distribution": '; wrtbak_json_string "$wrtbak_distribution_value"; printf ',\n'
		printf '    "version": '; wrtbak_json_string "$wrtbak_version_value"; printf ',\n'
		printf '    "revision": '; wrtbak_json_string "$wrtbak_revision_value"; printf ',\n'
		printf '    "kernel": '; wrtbak_json_string "$wrtbak_kernel_value"; printf '\n'
		printf '  },\n'
		printf '  "restore": {\n'
		printf '    "default_mode": '; wrtbak_json_string "$wrtbak_default_mode_value"; printf ',\n'
		printf '    "restart_services": [\n'
		printf '      "network",\n'
		printf '      "firewall",\n'
		printf '      "dnsmasq",\n'
		printf '      "odhcpd",\n'
		printf '      "dropbear"\n'
		printf '    ],\n'
		printf '    "reboot_recommended": true,\n'
		printf '    "requires_confirmation": true\n'
		printf '  },\n'
		printf '  "files": ['

		wrtbak_first=1
		if [ -s "$wrtbak_inventory" ]; then
			while IFS="$wrtbak_tab" read -r wrtbak_type wrtbak_path wrtbak_archive_path wrtbak_mode wrtbak_size wrtbak_sha256; do
				if [ "$wrtbak_first" -eq 1 ]; then
					printf '\n'
					wrtbak_first=0
				else
					printf ',\n'
				fi
				printf '    {\n'
				printf '      "path": '; wrtbak_json_string "$wrtbak_path"; printf ',\n'
				printf '      "archive_path": '; wrtbak_json_string "$wrtbak_archive_path"; printf ',\n'
				printf '      "type": '; wrtbak_json_string "$wrtbak_type"; printf ',\n'
				printf '      "mode": '; wrtbak_json_string "$wrtbak_mode"
				if [ "$wrtbak_type" = "file" ]; then
					printf ',\n'
					printf '      "size": %s,\n' "$wrtbak_size"
					printf '      "sha256": '; wrtbak_json_string "$wrtbak_sha256"; printf '\n'
				else
					printf '\n'
				fi
				printf '    }'
			done < "$wrtbak_inventory"
		fi

		if [ "$wrtbak_first" -eq 1 ]; then
			printf '\n'
		else
			printf '\n'
		fi
		printf '  ]\n'
		printf '}\n'
	} > "$wrtbak_manifest"
}
