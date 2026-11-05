#!/bin/sh
# Install the Neotoma plugin and its configuration into Yazi's config directory.
# Existing config files are never overwritten: if one already exists and does
# not mention Neotoma, the snippet to merge into it is printed instead.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
config=${YAZI_CONFIG_HOME:-"${XDG_CONFIG_HOME:-$HOME/.config}/yazi"}

mkdir -p "$config/plugins"
rm -rf "$config/plugins/neotoma.yazi"
cp -R "$here/neotoma.yazi" "$config/plugins/neotoma.yazi"
echo "Installed plugin: $config/plugins/neotoma.yazi"

for name in vfs.toml yazi.toml keymap.toml; do
	target="$config/$name"
	if [ ! -e "$target" ]; then
		cp "$here/config/$name" "$target"
		echo "Created: $target"
	elif grep -q neotoma "$target"; then
		echo "Unchanged (already mentions neotoma): $target"
	else
		echo
		echo "Merge this into $target:"
		echo "----"
		cat "$here/config/$name"
		echo "----"
	fi
done

if ! command -v neotoma >/dev/null 2>&1; then
	echo
	echo "Note: the \`neotoma\` command-line tool is not on PATH."
	echo "Install it, or set \`bin\` in $config/vfs.toml."
fi
