#!/bin/bash
#
# Nvmm
# build_sparkle.sh
#
# Builds a stripped Sparkle.framework from source and installs it at
# Frameworks/Sparkle.framework, where it is committed. Also builds the
# sign_update and generate_keys tools into build/sparkle/bin for releases.
#
# Syntax: build_sparkle.sh TAG
# Where TAG is a Sparkle 2 release tag (e.g. 2.10.0).
#
# Nvmm is not sandboxed, is English-only, and ships a signed ZIP of the app,
# so the framework leaves out the XPC services, localizations, package
# installs, deltas, DSA signatures, and the legacy SUUpdater interface.
#
# The framework is left ad-hoc signed. The app's build re-signs it, with its
# helpers, once it is embedded.

set -euo pipefail

if [ "$#" -ne 1 ]; then
    printf "Syntax: build_sparkle.sh TAG\n" >&2
    exit 1
fi

TAG="$1"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="${REPO_DIR}/build/sparkle"
SRC_DIR="${WORK_DIR}/src"
FRAMEWORK_DEST="${REPO_DIR}/Frameworks/Sparkle.framework"
LICENSE_DEST="${REPO_DIR}/Frameworks/Sparkle-LICENSE.txt"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/bin"

git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" \
    https://github.com/sparkle-project/Sparkle.git "$SRC_DIR"

COMMON=(
    -project "${SRC_DIR}/Sparkle.xcodeproj"
    -configuration Release
    ARCHS=arm64
    ONLY_ACTIVE_ARCH=NO
    MACOSX_DEPLOYMENT_TARGET=15.7
    DEVELOPMENT_TEAM=
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY=-
)

xcodebuild "${COMMON[@]}" -scheme Sparkle \
    -derivedDataPath "${WORK_DIR}/framework" \
    SPARKLE_EMBED_INSTALLER_LAUNCHER_XPC_SERVICE=0 \
    SPARKLE_EMBED_DOWNLOADER_XPC_SERVICE=0 \
    SPARKLE_BUILD_LEGACY_SUUPDATER=0 \
    SPARKLE_BUILD_LEGACY_DSA_SUPPORT=0 \
    SPARKLE_BUILD_LEGACY_DELTA_SUPPORT=0 \
    SPARKLE_BUILD_BZIP2_DELTA_SUPPORT=0 \
    SPARKLE_BUILD_PACKAGE_SUPPORT=0 \
    SPARKLE_COPY_LOCALIZATIONS=0 \
    build

# The tools are built as configured upstream, since generate_keys and
# sign_update are not shipped.
for tool in sign_update generate_keys; do
    xcodebuild "${COMMON[@]}" -scheme "$tool" \
        -derivedDataPath "${WORK_DIR}/tools" build
    cp "${WORK_DIR}/tools/Build/Products/Release/${tool}" "${WORK_DIR}/bin/"
done

BUILT="${WORK_DIR}/framework/Build/Products/Release/Sparkle.framework"
VERSION="$(/usr/libexec/PlistBuddy \
    -c "Print :CFBundleShortVersionString" "${BUILT}/Resources/Info.plist")"
if [ "$VERSION" != "$TAG" ]; then
    printf "Error: built Sparkle %s, expected %s.\n" "$VERSION" "$TAG" >&2
    exit 1
fi

rm -rf "$FRAMEWORK_DEST"
mkdir -p "$(dirname "$FRAMEWORK_DEST")"
ditto "$BUILT" "$FRAMEWORK_DEST"
cp "${SRC_DIR}/LICENSE" "$LICENSE_DEST"

printf "Installed Sparkle %s at %s\n" "$VERSION" "$FRAMEWORK_DEST"
printf "Tools are in %s\n" "${WORK_DIR}/bin"
