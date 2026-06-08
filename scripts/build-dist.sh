#!/bin/zsh
# build-dist.sh — build, sign, notarise, zip for distribution.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="bgbgone-app"
VERSION="$(tr -d '\n' < "$ROOT_DIR/.version")"
ARCH="$(uname -m)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$ROOT_DIR/build/${APP_NAME}.app"
APP_ZIP="$DIST_DIR/${APP_NAME}-v${VERSION}-macos-${ARCH}.zip"
APP_ZIP_STABLE="$DIST_DIR/${APP_NAME}-macos-${ARCH}.zip"
SHA_FILE="$DIST_DIR/SHA256SUMS"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-}"
ENTITLEMENTS="${ENTITLEMENTS:-$ROOT_DIR/bgbgone-app.entitlements}"

SIGN_IDENTITY="$SIGN_IDENTITY" ENTITLEMENTS="$ENTITLEMENTS" "$ROOT_DIR/scripts/build-app.sh"

if [[ "$SIGN_IDENTITY" != "-" && -n "$KEYCHAIN_PROFILE" ]]; then
    KEYCHAIN_PROFILE="$KEYCHAIN_PROFILE" "$ROOT_DIR/scripts/notarize.sh" "$APP_BUNDLE"
fi

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR/homebrew"

# Strip resource forks / extended attributes / quarantine from the archive.
# COPYFILE_DISABLE alone is NOT reliable for `ditto -c -k`: it still serialises
# xattrs (e.g. com.apple.provenance, and Sparkle.framework's resource forks) as
# AppleDouble ._* entries. Finder/Archive-Utility extraction then materialises
# those ._* as literal files inside the embedded framework, breaking its code
# seal → Gatekeeper rejects with "could not verify ... free of malware".
# --norsrc --noextattr --noqtn produces a clean zip; the notarisation staple
# survives because it lives in Contents/CodeResources (a real file, not an xattr).
ditto -c -k --keepParent --norsrc --noextattr --noqtn "$APP_BUNDLE" "$APP_ZIP"
cp "$APP_ZIP" "$APP_ZIP_STABLE"

(
    cd "$DIST_DIR"
    shasum -a 256 "$(basename "$APP_ZIP")" "$(basename "$APP_ZIP_STABLE")" > "$SHA_FILE"
)

APP_SHA="$(shasum -a 256 "$APP_ZIP" | awk '{print $1}')"
"$ROOT_DIR/scripts/render-homebrew-cask.sh" "$VERSION" "$APP_SHA" > "$DIST_DIR/homebrew/${APP_NAME}.rb"

print "==> Created:"
print "    $APP_ZIP"
print "    $SHA_FILE"
print "    $DIST_DIR/homebrew/${APP_NAME}.rb"
