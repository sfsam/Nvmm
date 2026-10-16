#!/bin/sh
#
# Nvmm
# sign_sparkle.sh
#
# Signs the embedded Sparkle framework and its helpers with the app's identity.
# Embedding signs only the framework itself, so its nested helpers would keep
# the ad-hoc signature from Scripts/build_sparkle.sh. Nested code is signed
# first, from the inside out.

set -eu

if [ "${CODE_SIGNING_ALLOWED:-NO}" != "YES" ]; then
  exit 0
fi

identity=${EXPANDED_CODE_SIGN_IDENTITY:-}
if [ -z "$identity" ]; then
  exit 0
fi

framework="$BUILT_PRODUCTS_DIR/$FRAMEWORKS_FOLDER_PATH/Sparkle.framework"
version="$framework/Versions/B"

if [ ! -d "$version" ]; then
  echo "error: missing embedded Sparkle framework: $version" >&2
  exit 1
fi

sign() {
  if [ "$CONFIGURATION" = "Release" ] && [ "$identity" != "-" ]; then
    /usr/bin/codesign --force --sign "$identity" --options runtime \
      --timestamp "$1"
  else
    /usr/bin/codesign --force --sign "$identity" --options runtime \
      --timestamp=none "$1"
  fi
}

sign "$version/Autoupdate"
sign "$version/Updater.app"
sign "$framework"
