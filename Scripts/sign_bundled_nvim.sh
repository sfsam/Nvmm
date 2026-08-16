#!/bin/sh
#
# Nvmm
# sign_bundled_nvim.sh
#
# Signs the Mach-O files copied from the staged Neovim payload.

set -eu

if [ "${CODE_SIGNING_ALLOWED:-NO}" != "YES" ]; then
  exit 0
fi

identity=${EXPANDED_CODE_SIGN_IDENTITY:-}
if [ -z "$identity" ]; then
  exit 0
fi

staged="$SRCROOT/build/nvim"
manifest="$staged/MachO-files.txt"
contents="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH"
nvim="$BUILT_PRODUCTS_DIR/$EXECUTABLE_FOLDER_PATH/nvim"
entitlements="$SRCROOT/Config/Neovim.entitlements"
indexer="$SRCROOT/Scripts/index_nvim_macho.sh"

if [ ! -f "$manifest" ]; then
  "$indexer" "$staged"
fi

if [ ! -f "$entitlements" ]; then
  echo "error: missing Neovim entitlements: $entitlements" >&2
  exit 1
fi

if [ ! -x "$nvim" ]; then
  echo "error: missing bundled Neovim executable: $nvim" >&2
  exit 1
fi

if ! LC_ALL=C sort -cu "$manifest"; then
  echo "error: Neovim Mach-O manifest is not sorted and unique" >&2
  exit 1
fi

sign_without_entitlements() {
  file=$1

  if [ "$CONFIGURATION" = "Release" ] && [ "$identity" != "-" ]; then
    /usr/bin/codesign --force --sign "$identity" --options runtime \
      --timestamp "$file"
  else
    /usr/bin/codesign --force --sign "$identity" --options runtime \
      --timestamp=none "$file"
  fi
}

found_nvim=0
while IFS= read -r relative; do
  case "/$relative/" in
    *//*|*/../*|*/./*)
      echo "error: invalid Neovim Mach-O path: $relative" >&2
      exit 1
      ;;
  esac

  case "$relative" in
    bin/nvim)
      if [ "$found_nvim" -ne 0 ]; then
        echo "error: duplicate nvim entry in Mach-O manifest" >&2
        exit 1
      fi
      found_nvim=1
      ;;
    lib/*|share/*)
      source_file="$staged/$relative"
      bundled_file="$contents/$relative"

      if [ ! -f "$source_file" ]; then
        echo "error: missing staged Mach-O file: $source_file" >&2
        exit 1
      fi

      if [ ! -f "$bundled_file" ]; then
        echo "error: missing bundled Mach-O file: $bundled_file" >&2
        exit 1
      fi

      case "$(/usr/bin/file -b "$source_file")" in
        Mach-O*) ;;
        *)
          echo "error: manifest entry is not Mach-O: $relative" >&2
          exit 1
          ;;
      esac

      sign_without_entitlements "$bundled_file"
      ;;
    *)
      echo "error: unsupported Neovim Mach-O path: $relative" >&2
      exit 1
      ;;
  esac
done < "$manifest"

if [ "$found_nvim" -ne 1 ]; then
  echo "error: Neovim Mach-O manifest does not contain bin/nvim" >&2
  exit 1
fi

if [ "$CONFIGURATION" = "Release" ] && [ "$identity" != "-" ]; then
  /usr/bin/codesign --force --sign "$identity" --options runtime \
    --timestamp --entitlements "$entitlements" "$nvim"
else
  /usr/bin/codesign --force --sign "$identity" --options runtime \
    --timestamp=none --entitlements "$entitlements" "$nvim"
fi
