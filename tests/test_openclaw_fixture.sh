#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/wrtbak-openclaw.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
root="$work_dir/root"
mkdir -p "$root/etc/config" "$root/etc/init.d" "$root/srv/openclaw/data/.openclaw" "$root/bin"
cat > "$root/etc/config/openclaw" <<'EOF'
config openclaw 'main'
	option install_root '/srv'
EOF
printf 'secret\n' > "$root/srv/openclaw/data/.openclaw/credentials"
printf '#!/bin/sh\n' > "$root/srv/openclaw/data/.openclaw/skill.sh"
chmod 700 "$root/srv/openclaw/data/.openclaw/skill.sh"
for excluded in node_modules cache logs tmp pid lock sockets runtime; do
	mkdir -p "$root/srv/openclaw/data/.openclaw/$excluded"
	printf x > "$root/srv/openclaw/data/.openclaw/$excluded/drop"
done
ln -s /etc/passwd "$root/srv/openclaw/data/.openclaw/escape"

libdir="$repo_dir/root/usr/lib/wrtbak"
PATH="$root/bin:$PATH" WRTBAK_ROOT="$root" WRTBAK_LIBDIR="$libdir" \
	sh -c '. "$0/common.sh"; . "$0/config.sh"; . "$0/items.sh"; wrtbak_item_paths_by_id openclaw' "$libdir" > "$work_dir/paths"
grep -Fx /etc/config/openclaw "$work_dir/paths"
grep -Fx /srv/openclaw/data/.openclaw "$work_dir/paths"
[ "$(wc -l < "$work_dir/paths")" -eq 2 ]

PATH="$root/bin:$PATH" WRTBAK_ROOT="$root" WRTBAK_LIBDIR="$libdir" \
	sh -c '. "$0/common.sh"; . "$0/config.sh"; . "$0/items.sh"; . "$0/backup.sh"; mkdir -p "$1/stage"; : > "$1/inventory"; : > "$1/seen"; wrtbak_collect_openclaw_directory /srv/openclaw/data/.openclaw "$(wrtbak_root_path /srv/openclaw/data/.openclaw)" "$1/stage" "$1/inventory" "$1/seen" "$1"' "$libdir" "$work_dir" \
	>/dev/null
! grep -E '/(node_modules|cache|logs|tmp|pid|lock|sockets|runtime)/' "$work_dir/inventory"
! grep -F '/escape' "$work_dir/inventory"
grep -F '/skill.sh' "$work_dir/inventory"

cat > "$root/etc/init.d/openclaw" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >> "${WRTBAK_ROOT}/openclaw-service.log"
EOF
chmod +x "$root/etc/init.d/openclaw"
cat > "$root/bin/id" <<'EOF'
#!/bin/sh
case "$1:$2" in
  -u:openclaw) echo 123 ;;
  -g:openclaw) echo 123 ;;
  *) exit 1 ;;
esac
EOF
cat > "$root/bin/chown" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$root/bin/id" "$root/bin/chown"
PATH="$root/bin:$PATH" WRTBAK_ROOT="$root" WRTBAK_LIBDIR="$libdir" \
	sh -c '. "$0/common.sh"; . "$0/config.sh"; . "$0/items.sh"; . "$0/restore.sh"; printf openclaw > "$1/services"; wrtbak_restore_stop_openclaw "$1/services"; wrtbak_restore_handle_services "$1/services" 1 "$1/restarted" "$1/blocked" "$1/errors"; wrtbak_restore_fix_openclaw_state' "$libdir" "$work_dir" >/dev/null
[ "$(tr '\n' ' ' < "$root/openclaw-service.log")" = "stop start " ]
[ "$(stat -c '%a' "$root/srv/openclaw/data/.openclaw/skill.sh")" = 700 ]
[ "$(stat -c '%a' "$root/srv/openclaw/data/.openclaw/credentials")" = 600 ]

echo "openclaw dynamic path and exclusion fixture passed"
