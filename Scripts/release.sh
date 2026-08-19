#!/bin/bash
#
# Nvmm
# release.sh
#
# Publishes an already notarized Nvmm.app as a release. Archive and export the
# app from Xcode first, leaving the notarized bundle at ~/Desktop/Nvmm.app.
#
# Syntax: release.sh VERSION
# Where VERSION is the release version and git tag name (e.g. 1.1.0). It must
# agree with the app's CFBundleShortVersionString; a two-component app version
# such as 1.1 satisfies 1.1.0.
#
# Tag the release commit and push both the branch and the tag before running
# this. The script verifies the exported app against that tag, builds the
# release ZIP, uploads it to S3, and creates a draft GitHub release. Every step
# that changes something is confirmed first.
#
# Products are left in build/release:
#   Nvmm-VERSION.zip
#   Nvmm-VERSION.zip.sha256

set -euo pipefail

# Keep the original standard input available for prompts, so a step that reads
# standard input cannot consume the answers.
exec 3<&0

APP_NAME="Nvmm"
BUNDLE_ID="com.mowglii.Nvmm"
RELEASE_BRANCH="main"
S3_PREFIX="s3://mowglii/nvmm"
PUBLIC_URL="https://mowglii.s3.amazonaws.com/nvmm"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_SRC="${APP_SRC:-${HOME}/Desktop/${APP_NAME}.app}"
RELEASE_DIR="${RELEASE_DIR:-${REPO_DIR}/build/release}"
AWS="${AWS:-aws}"
GH="${GH:-gh}"
DITTO="${DITTO:-ditto}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

error() {
    printf "${RED}Error: %s${NC}\n" "$*" >&2
}

step() {
    printf "\n${YELLOW}==> %s${NC}\n" "$*"
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        error "$1 not found."
        exit 1
    fi
}

print_command() {
    local argument
    local separator="    "

    for argument in "$@"; do
        printf "%s" "$separator"
        if [[ "$argument" =~ ^[a-zA-Z0-9_./:@%+=,-]+$ ]]; then
            printf "%s" "$argument"
        else
            argument="${argument//\\/\\\\}"
            argument="${argument//\"/\\\"}"
            argument="${argument//\$/\\\$}"
            argument="${argument//\`/\\\`}"
            printf '"%s"' "$argument"
        fi
        separator=" "
    done
    printf "\n"
}

confirm() {
    printf "%s [y/N] " "$1"

    local answer
    if ! IFS= read -r answer <&3; then
        answer=""
    fi

    case "$answer" in
        y|Y|yes|YES|Yes)
            return 0
            ;;
        *)
            printf "Cancelled.\n"
            exit 1
            ;;
    esac
}

run_confirmed() {
    local description="$1"
    shift

    step "$description"
    print_command "$@"
    confirm "Run this command?"
    "$@"
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1"
}

# Pad a version to three components so 1.1 and 1.1.0 compare equal.
normalize_version() {
    printf "%s\n" "$1" | awk -F. '{ printf "%d.%d.%d\n", $1, $2, $3 }'
}

if [ "$#" -ne 1 ]; then
    printf "Syntax: release.sh VERSION\n" >&2
    exit 1
fi

VERSION="$1"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    error "VERSION must look like 1.1.0."
    exit 1
fi

require_command "$AWS"
require_command "$GH"
require_command "$DITTO"
require_command git
require_command codesign
require_command spctl
require_command stapler
require_command shasum

RELEASE_BASENAME="${APP_NAME}-${VERSION}"
ZIP="${RELEASE_DIR}/${RELEASE_BASENAME}.zip"
CHECKSUM="${ZIP}.sha256"

# Checking the exported app ------------------------------------------------

step "Checking ${APP_SRC}"

if [ ! -d "$APP_SRC" ]; then
    error "$APP_SRC not found. Archive and export the notarized app first."
    exit 1
fi

APP_INFO_PLIST="${APP_SRC}/Contents/Info.plist"
if [ ! -f "$APP_INFO_PLIST" ]; then
    error "$APP_INFO_PLIST not found."
    exit 1
fi

APP_BUNDLE_ID="$(plist_value "$APP_INFO_PLIST" CFBundleIdentifier)"
APP_MARKETING_VERSION="$(plist_value "$APP_INFO_PLIST" \
    CFBundleShortVersionString)"
APP_BUILD_VERSION="$(plist_value "$APP_INFO_PLIST" CFBundleVersion)"

if [ "$APP_BUNDLE_ID" != "$BUNDLE_ID" ]; then
    error "Expected bundle identifier ${BUNDLE_ID}, found ${APP_BUNDLE_ID}."
    exit 1
fi

if [ "$(normalize_version "$APP_MARKETING_VERSION")" != \
     "$(normalize_version "$VERSION")" ]; then
    error "The app is version ${APP_MARKETING_VERSION}, not ${VERSION}."
    exit 1
fi

printf "    Version: %s (build %s)\n" \
    "$APP_MARKETING_VERSION" "$APP_BUILD_VERSION"

# The bundled Neovim executables and libraries are nested code, so verify the
# whole bundle rather than the app binary alone.
step "Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP_SRC"

SIGNATURE_INFO="$(codesign --display --verbose=2 "$APP_SRC" 2>&1)"
if ! grep -q "^Authority=Developer ID Application:" <<<"$SIGNATURE_INFO"; then
    error "$APP_SRC is not signed with a Developer ID Application certificate."
    exit 1
fi

step "Validating the notarization ticket"
stapler validate "$APP_SRC"

step "Assessing with Gatekeeper"
spctl --assess --type execute --verbose=4 "$APP_SRC"

# Checking the repository --------------------------------------------------

step "Checking the repository"
cd "$REPO_DIR"

# Xcode archives the working tree rather than the tagged commit, so tracked
# changes would ship code that is not in the release. Untracked files cannot
# reach the archive without a tracked change to the project file.
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    error "The working tree has uncommitted changes."
    exit 1
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "$RELEASE_BRANCH" ]; then
    error "HEAD is on ${BRANCH}, not ${RELEASE_BRANCH}."
    exit 1
fi

if ! git rev-parse -q --verify "refs/tags/${VERSION}" >/dev/null; then
    error "Tag ${VERSION} does not exist. Tag the release commit first."
    exit 1
fi

TAG_COMMIT="$(git rev-parse "refs/tags/${VERSION}^{commit}")"
if [ "$TAG_COMMIT" != "$(git rev-parse HEAD)" ]; then
    error "Tag ${VERSION} does not point at HEAD."
    exit 1
fi

# The draft release is created with --verify-tag, so the tag has to be on
# origin already, and it has to be the same commit as the local tag.
git fetch --tags origin
REMOTE_TAG="$(git ls-remote origin \
    "refs/tags/${VERSION}" "refs/tags/${VERSION}^{}")"
if [ -z "$REMOTE_TAG" ]; then
    error "Tag ${VERSION} has not been pushed to origin."
    exit 1
fi

if ! grep -q "^${TAG_COMMIT}" <<<"$REMOTE_TAG"; then
    error "Tag ${VERSION} on origin points at a different commit."
    exit 1
fi

if [ -n "$(git rev-list "origin/${RELEASE_BRANCH}..HEAD")" ]; then
    error "HEAD has not been pushed to origin/${RELEASE_BRANCH}."
    exit 1
fi

printf "    Release commit:\n"
git --no-pager log -1 --format="        %h %s (%an, %ad)" --date=short

confirm "Release this commit as ${VERSION}?"

# Building the release products --------------------------------------------

if [ -e "$RELEASE_DIR" ]; then
    run_confirmed \
        "Remove the previous release products" \
        rm -rf "$RELEASE_DIR"
fi

mkdir -p "$RELEASE_DIR"

# The ZIP is created from the stapled app so that the notarization ticket
# travels with the download and Gatekeeper can validate it offline.
step "Creating ${ZIP}"
"$DITTO" -c -k --sequesterRsrc --keepParent "$APP_SRC" "$ZIP"

step "Generating the SHA-256 checksum"
(cd "$RELEASE_DIR" && shasum -a 256 "${RELEASE_BASENAME}.zip" \
    > "${RELEASE_BASENAME}.zip.sha256")
cat "$CHECKSUM"

# Verify the archive that will actually be published, not just its source.
step "Verifying the app inside the ZIP"
VERIFY_DIR="$(mktemp -d)"
trap 'rm -rf "$VERIFY_DIR"' EXIT
"$DITTO" -x -k "$ZIP" "$VERIFY_DIR"
stapler validate "${VERIFY_DIR}/${APP_NAME}.app"
spctl --assess --type execute --verbose=4 "${VERIFY_DIR}/${APP_NAME}.app"
rm -rf "$VERIFY_DIR"
trap - EXIT

# Publishing ---------------------------------------------------------------

run_confirmed \
    "Log in to AWS" \
    "$AWS" login \
    --no-cli-pager

run_confirmed \
    "Upload the versioned ZIP" \
    "$AWS" s3 cp "$ZIP" "${S3_PREFIX}/${RELEASE_BASENAME}.zip" \
    --acl public-read \
    --content-type application/zip \
    --cache-control "public, max-age=31536000, immutable" \
    --no-cli-pager

run_confirmed \
    "Upload the stable website ZIP" \
    "$AWS" s3 cp "$ZIP" "${S3_PREFIX}/${APP_NAME}.zip" \
    --acl public-read \
    --content-type application/zip \
    --cache-control "no-cache" \
    --no-cli-pager

run_confirmed \
    "Create the draft GitHub release" \
    "$GH" release create "$VERSION" "$ZIP" "$CHECKSUM" \
    --title "${APP_NAME} ${VERSION}" \
    --verify-tag \
    --generate-notes \
    --draft

printf "\n${GREEN}Released %s %s (build %s).${NC}\n" \
    "$APP_NAME" "$VERSION" "$APP_BUILD_VERSION"
printf "    ZIP:      %s/%s.zip\n" "$PUBLIC_URL" "$RELEASE_BASENAME"
printf "    Download: %s/%s.zip\n" "$PUBLIC_URL" "$APP_NAME"
printf "    Local:    %s\n" "$RELEASE_DIR"
printf "\nReview the draft release, then publish it:\n"
printf "    gh release edit %s --draft=false\n" "$VERSION"
