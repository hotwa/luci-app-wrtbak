#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
view_file="$repo_dir/htdocs/luci-static/resources/view/wrtbak/index.js"
menu_file="$repo_dir/root/usr/share/luci/menu.d/luci-app-wrtbak.json"
acl_file="$repo_dir/root/usr/share/rpcd/acl.d/luci-app-wrtbak.json"

test -f "$view_file"
test -f "$menu_file"
test -f "$acl_file"

python3 -m json.tool "$menu_file" >/dev/null
python3 -m json.tool "$acl_file" >/dev/null

grep -Fq '"admin/system/wrtbak"' "$menu_file"
grep -Fq '"path": "wrtbak/index"' "$menu_file"
grep -Fq '"luci-app-wrtbak"' "$acl_file"
grep -Fq '"/usr/bin/wrtbak detect --json"' "$acl_file"
grep -Fq '"/usr/bin/wrtbak create-download *"' "$acl_file"
grep -Fq '"/tmp/wrtbak/*"' "$acl_file"

grep -Fq "fs.exec('/usr/bin/wrtbak', [ 'detect', '--json' ])" "$view_file"
grep -Fq "fs.exec('/usr/bin/wrtbak', [ 'create-download'" "$view_file"
grep -Fq "L.env.cgi_base + '/cgi-download'" "$view_file"
grep -Fq "name: 'path'" "$view_file"
grep -Fq "name: 'filename'" "$view_file"
grep -Fq "Rows per page" "$view_file"
grep -Fq "Previous" "$view_file"
grep -Fq "Next" "$view_file"
grep -Fq "showDownloadResult" "$view_file"
grep -Fq "Download" "$view_file"
grep -Fq "handleSaveApply: null" "$view_file"
grep -Fq "handleSave: null" "$view_file"
grep -Fq "handleReset: null" "$view_file"

echo "LuCI layout test passed"
