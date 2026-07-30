#!/bin/sh
#
# Nvmm
# download_nvim.sh
#
# Downloads a prebuilt Neovim release and stages it under build/nvim, ready to
# be copied into the app bundle by the "Bundle Neovim" build phase.
#
# Syntax: download_nvim.sh [tag]
# Where tag is a Neovim release tag (e.g. stable, nightly, v0.12.0). Defaults
# to stable. Neovim 0.12 or newer is required.
#
# Staged layout:
#   build/nvim/bin
#   build/nvim/lib
#   build/nvim/share
#   build/nvim/Neovim-LICENSE.txt

set -e

ARCHIVE="nvim.tar.gz"
TAG="${1-stable}"

# Resolve the repository root regardless of where the script is invoked from.
cd "$(dirname "$0")/.."
mkdir -p build
cd build

rm -rf nvim
mkdir nvim

# Apple Silicon build. Edit for the Intel release if required.
curl -fL -o "${ARCHIVE}" \
    "https://github.com/neovim/neovim/releases/download/${TAG}/nvim-macos-arm64.tar.gz"
xattr -c "${ARCHIVE}"
tar xzf "${ARCHIVE}" -C nvim --strip-components 1
rm -f "${ARCHIVE}"

curl -fL -o nvim/Neovim-LICENSE.txt \
    "https://raw.githubusercontent.com/neovim/neovim/${TAG}/LICENSE.txt"

echo "Staged Neovim in build/nvim"
