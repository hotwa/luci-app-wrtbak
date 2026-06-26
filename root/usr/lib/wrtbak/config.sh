#!/bin/sh

wrtbak_config_file() {
	printf '%s\n' "${WRTBAK_CONFIG:-$(wrtbak_root_path /etc/config/wrtbak)}"
}

wrtbak_uci_get_section_option() {
	wrtbak_config=$1
	wrtbak_type=$2
	wrtbak_name=$3
	wrtbak_option=$4
	wrtbak_default=$5
	wrtbak_value=

	if [ -r "$wrtbak_config" ]; then
		wrtbak_value=$(
			awk -v wanted_type="$wrtbak_type" -v wanted_name="$wrtbak_name" -v wanted_option="$wrtbak_option" '
				function unquote(value) {
					if (substr(value, 1, 1) == "\047" && substr(value, length(value), 1) == "\047") {
						return substr(value, 2, length(value) - 2)
					}
					if (substr(value, 1, 1) == "\"" && substr(value, length(value), 1) == "\"") {
						return substr(value, 2, length(value) - 2)
					}
					return value
				}
				$1 == "config" {
					section_type = $2
					section_name = unquote($3)
					in_section = (section_type == wanted_type && section_name == wanted_name)
					next
				}
				in_section && $1 == "option" && $2 == wanted_option {
					$1 = ""
					$2 = ""
					sub(/^[ \t]+/, "")
					print unquote($0)
					found = 1
					exit
				}
			' "$wrtbak_config"
		)
	fi

	if [ -n "$wrtbak_value" ]; then
		printf '%s\n' "$wrtbak_value"
	else
		printf '%s\n' "$wrtbak_default"
	fi
}

wrtbak_main_option() {
	wrtbak_uci_get_section_option "$(wrtbak_config_file)" wrtbak main "$1" "$2"
}

wrtbak_remote_option() {
	wrtbak_uci_get_section_option "$(wrtbak_config_file)" remote "$1" "$2" "$3"
}

wrtbak_schedule_option() {
	wrtbak_uci_get_section_option "$(wrtbak_config_file)" schedule auto "$1" "$2"
}

wrtbak_bool_enabled() {
	case "$1" in
		1|true|yes|on|enabled)
			return 0
			;;
	esac
	return 1
}

wrtbak_secret_is_set() {
	[ -n "$1" ]
}
