#!/bin/sh
#
# Nvmm
# index_nvim_macho.sh
#
# Records every Mach-O in a staged Neovim payload. Builds consume this manifest
# instead of classifying the complete runtime tree each time.

set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 staged-neovim-directory" >&2
  exit 2
fi

root=${1%/}
manifest="$root/MachO-files.txt"
temporary="$manifest.tmp.$$"

cleanup() {
  rm -f "$temporary"
}

trap cleanup EXIT HUP INT TERM

for directory in "$root/bin" "$root/lib" "$root/share"; do
  if [ ! -d "$directory" ]; then
    echo "error: missing staged Neovim directory: $directory" >&2
    exit 1
  fi
done

find "$root/bin" "$root/lib" "$root/share" -type f -print |
  LC_ALL=C sort |
  while IFS= read -r file; do
    case "$(/usr/bin/file -b "$file")" in
      Mach-O*) printf '%s\n' "${file#"$root"/}" ;;
    esac
  done > "$temporary"

if ! grep -qx 'bin/nvim' "$temporary"; then
  echo "error: staged Neovim executable is not a Mach-O file" >&2
  exit 1
fi

if [ ! -s "$temporary" ]; then
  echo "error: staged Neovim contains no Mach-O files" >&2
  exit 1
fi

mv "$temporary" "$manifest"
trap - EXIT HUP INT TERM

echo "Indexed staged Neovim Mach-O files in $manifest"
