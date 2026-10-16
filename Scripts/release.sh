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
# release ZIP, signs it for Sparkle, writes the appcast, and creates a draft
# GitHub release. Every step that changes something is confirmed first.
#
# The ZIP has the same name in every release, so once the draft is published,
# DOWNLOAD_URL below serves it as the stable download. The appcast links to
# the release's own copy instead, so its item stays valid after later
# releases. Its release notes are the page at RELEASE_NOTES_URL, which is
# kept by hand.
#
# Signing needs the Sparkle tools from Scripts/build_sparkle.sh and the
# Sparkle key, stored in the login keychain under SPARKLE_ACCOUNT.
#
# Products are left in build/nvmm-release:
#   Nvmm.zip
#   Nvmm.zip.sha256
#   appcast.xml

set -euo pipefail

# Keep the original standard input available for prompts, so a step that reads
# standard input cannot consume the answers.
exec 3<&0

APP_NAME="Nvmm"
BUNDLE_ID="com.mowglii.Nvmm"
RELEASE_BRANCH="main"
RELEASES_URL="https://github.com/sfsam/Nvmm/releases"
DOWNLOAD_URL="${RELEASES_URL}/latest/download/Nvmm.zip"
RELEASE_NOTES_URL="https://mowglii.com/nvmm/releasenotes.html"
SPARKLE_ACCOUNT="nvmm"
SPARKLE_NAMESPACE="http://www.andymatuschak.org/xml-namespaces/sparkle"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_SRC="${APP_SRC:-${HOME}/Desktop/${APP_NAME}.app}"
RELEASE_DIR="${RELEASE_DIR:-${REPO_DIR}/build/nvmm-release}"
GH="${GH:-gh}"
SPARKLE_BIN="${SPARKLE_BIN:-${REPO_DIR}/build/sparkle/bin}"
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

require_command "$GH"
require_command "$DITTO"
require_command git
require_command codesign
require_command spctl
require_command stapler
require_command shasum
require_command curl
require_command xmllint
require_command "${SPARKLE_BIN}/sign_update"
require_command "${SPARKLE_BIN}/generate_keys"

ZIP="${RELEASE_DIR}/${APP_NAME}.zip"
CHECKSUM="${ZIP}.sha256"
APPCAST="${RELEASE_DIR}/appcast.xml"

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

APP_FEED_URL="$(plist_value "$APP_INFO_PLIST" SUFeedURL)"
APP_PUBLIC_KEY="$(plist_value "$APP_INFO_PLIST" SUPublicEDKey)"
APP_MINIMUM_SYSTEM="$(plist_value "$APP_INFO_PLIST" LSMinimumSystemVersion)"

# Every copy of this release rejects an update signed with any key other than
# the one it was built with, so the two must match before going further.
step "Checking the Sparkle key"
KEYCHAIN_PUBLIC_KEY="$("${SPARKLE_BIN}/generate_keys" \
    --account "$SPARKLE_ACCOUNT" -p)"
if [ -z "$APP_PUBLIC_KEY" ] || \
   [ "$APP_PUBLIC_KEY" != "$KEYCHAIN_PUBLIC_KEY" ]; then
    error "SUPublicEDKey does not match the ${SPARKLE_ACCOUNT} key."
    exit 1
fi
printf "    Public key: %s\n" "$APP_PUBLIC_KEY"

# Sparkle offers an update only when its build number is higher, so a
# release that forgot to raise it would never be offered. Only a 404 means
# there is no live appcast yet; any other failure stops the release rather
# than skip the check.
step "Checking the build number against ${APP_FEED_URL}"
if ! [[ "$APP_BUILD_VERSION" =~ ^[0-9]+$ ]]; then
    error "CFBundleVersion must be a whole number, not ${APP_BUILD_VERSION}."
    exit 1
fi

if ! LIVE_RESPONSE="$(curl -sSL -w '\n%{http_code}' "$APP_FEED_URL")"
then
    error "Could not fetch ${APP_FEED_URL}."
    exit 1
fi
LIVE_STATUS="${LIVE_RESPONSE##*$'\n'}"
LIVE_FEED="${LIVE_RESPONSE%$'\n'*}"

case "$LIVE_STATUS" in
    200)
        if ! ITEM_COUNT="$(xmllint --xpath 'count(//item)' - \
            <<<"$LIVE_FEED")"; then
            error "The live appcast is not valid XML."
            exit 1
        fi
        LIVE_BUILD=""
        for ((i = 1; i <= ITEM_COUNT; i++)); do
            BUILD="$(xmllint --xpath "normalize-space((//item)[$i]/*[
                local-name()='version' and
                namespace-uri()='${SPARKLE_NAMESPACE}'])" - <<<"$LIVE_FEED")"
            if ! [[ "$BUILD" =~ ^[0-9]+$ ]]; then
                error "Live appcast item ${i} has build '${BUILD}'."
                exit 1
            fi
            if [ -z "$LIVE_BUILD" ] || [ "$BUILD" -gt "$LIVE_BUILD" ]; then
                LIVE_BUILD="$BUILD"
            fi
        done
        if [ -z "$LIVE_BUILD" ]; then
            error "The live appcast has no items."
            exit 1
        fi
        if [ "$APP_BUILD_VERSION" -le "$LIVE_BUILD" ]; then
            error "Build ${APP_BUILD_VERSION} is not above ${LIVE_BUILD}."
            exit 1
        fi
        printf "    Live build: %s\n" "$LIVE_BUILD"
        ;;
    404)
        printf "    No live appcast found, so there is nothing to compare.\n"
        confirm "Is this the first release with an appcast?"
        ;;
    *)
        error "Fetching ${APP_FEED_URL} returned HTTP ${LIVE_STATUS}."
        exit 1
        ;;
esac

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
(cd "$RELEASE_DIR" && shasum -a 256 "${APP_NAME}.zip" \
    > "${APP_NAME}.zip.sha256")
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

step "Signing ${ZIP} for Sparkle"
SIGNATURE="$("${SPARKLE_BIN}/sign_update" --account "$SPARKLE_ACCOUNT" \
    -p "$ZIP")"
"${SPARKLE_BIN}/sign_update" --account "$SPARKLE_ACCOUNT" \
    --verify "$ZIP" "$SIGNATURE"
LENGTH="$(stat -f %z "$ZIP")"

# The appcast holds only this release. Sparkle needs nothing older, since
# every earlier version updates straight to the newest.
step "Writing ${APPCAST}"
PUB_DATE="$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")"
cat > "$APPCAST" <<APPCAST_XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="${SPARKLE_NAMESPACE}">
  <channel>
    <title>${APP_NAME}</title>
    <item>
      <title>${APP_NAME} ${APP_MARKETING_VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${APP_BUILD_VERSION}</sparkle:version>
      <sparkle:shortVersionString>${APP_MARKETING_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${APP_MINIMUM_SYSTEM}</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>${RELEASE_NOTES_URL}</sparkle:releaseNotesLink>
      <enclosure url="${RELEASES_URL}/download/${VERSION}/${APP_NAME}.zip" length="${LENGTH}" type="application/octet-stream" sparkle:edSignature="${SIGNATURE}"/>
    </item>
  </channel>
</rss>
APPCAST_XML
xmllint --noout "$APPCAST"
cat "$APPCAST"

# Publishing ---------------------------------------------------------------

run_confirmed \
    "Create the draft GitHub release" \
    "$GH" release create "$VERSION" "$ZIP" "$CHECKSUM" \
    --title "${APP_NAME} ${VERSION}" \
    --verify-tag \
    --generate-notes \
    --draft

printf "\n${GREEN}Released %s %s (build %s).${NC}\n" \
    "$APP_NAME" "$VERSION" "$APP_BUILD_VERSION"
printf "    Local:    %s\n" "$RELEASE_DIR"
printf "\nReview the draft release, then publish it:\n"
printf "    gh release edit %s --draft=false\n" "$VERSION"
printf "\nOnce published, the stable download serves it:\n"
printf "    %s\n" "$DOWNLOAD_URL"
printf "\nUpdate the release notes, which Sparkle shows with the update:\n"
printf "    %s\n" "$RELEASE_NOTES_URL"
printf "\nThen upload the appcast, which offers the update through Sparkle:\n"
printf "    %s\n" "$APPCAST"
printf "    to %s\n" "$APP_FEED_URL"
