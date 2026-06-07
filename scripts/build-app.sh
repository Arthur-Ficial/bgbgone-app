#!/bin/zsh
# build-app.sh — produce build/bgbgone-app.app
#
# Strategy: build the Swift app binary, copy it into the bundle, embed the
# bgbgone CLI helper built from the pinned `vendor/bgbgone` submodule, sign.
# The helper is a declared, version-locked dependency (BGBGONE_VERSION) — NOT
# whatever happens to be on the dev machine's PATH. Distribution builds set
# SIGN_IDENTITY + KEYCHAIN_PROFILE; dev builds use ad-hoc ("-") signing.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="bgbgone-app"
APP_BUNDLE="$ROOT_DIR/build/${APP_NAME}.app"
VERSION="$(tr -d '\n' < "$ROOT_DIR/.version")"
ICON_SOURCE="$ROOT_DIR/Resources/AppIcon.icns"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
ENTITLEMENTS="${ENTITLEMENTS:-$ROOT_DIR/bgbgone-app.entitlements}"

# The bgbgone CLI version this app build is pinned to and tested against. Must
# match vendor/bgbgone/.version (the submodule is pinned to the v$BGBGONE_VERSION
# tag commit). The embedded binary's --version is asserted against this below.
BGBGONE_VERSION="1.2.23"
SUBMODULE_DIR="$ROOT_DIR/vendor/bgbgone"

# Sparkle auto-update framework, embedded at Contents/Frameworks/Sparkle.framework.
# Resolved from the SwiftPM-downloaded XCFramework (the exact build the app links
# against), with the downloaded distribution tarball as a fallback.
SPARKLE_VERSION="2.9.2"
resolve_sparkle_framework() {
    local fw
    fw="$(/usr/bin/find "$ROOT_DIR/build/artifacts" -type d -path '*Sparkle.xcframework/macos*/Sparkle.framework' 2>/dev/null | head -1)"
    [[ -z "$fw" ]] && fw="$(/usr/bin/find "$ROOT_DIR/.build" -type d -path '*Sparkle.xcframework/macos*/Sparkle.framework' 2>/dev/null | head -1)"
    [[ -z "$fw" && -d "$ROOT_DIR/.build/sparkle-dist/Sparkle.framework" ]] && fw="$ROOT_DIR/.build/sparkle-dist/Sparkle.framework"
    [[ -n "$fw" && -d "$fw" ]] || return 1
    print -- "$fw"
}

# Build (or locate) the version-locked bgbgone helper to embed.
#   1. BGBGONE_HELPER_PATH override — a prebuilt binary (CI cache / cross-build).
#   2. Otherwise build the pinned vendor/bgbgone submodule from source.
# No PATH/Homebrew scavenging: a stale system bgbgone must never end up bundled.
resolve_helper() {
    if [[ -n "${BGBGONE_HELPER_PATH:-}" && -x "${BGBGONE_HELPER_PATH}" ]]; then
        print -- "${BGBGONE_HELPER_PATH}"; return 0
    fi
    # Ensure the submodule is checked out (clean clones / CI without --recursive).
    if [[ ! -f "$SUBMODULE_DIR/.version" ]]; then
        print "==> Initialising vendor/bgbgone submodule" >&2
        git -C "$ROOT_DIR" submodule update --init vendor/bgbgone >&2
    fi
    print "==> Building pinned bgbgone v${BGBGONE_VERSION} from vendor/bgbgone" >&2
    make -C "$SUBMODULE_DIR" build >&2
    local built="$SUBMODULE_DIR/.build/release/bgbgone"
    [[ -x "$built" ]] || { print "error: submodule build did not produce $built" >&2; return 1; }
    print -- "$built"
}

codesign_path() {
    local target="$1"; shift || true
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        codesign --force --sign "$SIGN_IDENTITY" "$@" "$target"
    else
        codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$@" "$target"
    fi
}

# Sparkle ships nested code (XPC services + the Updater/Autoupdate helper) inside the
# framework. Each must be signed inside-out BEFORE the outer app is signed; signing the
# app alone does not reach them, and notarisation rejects unsigned nested Mach-O.
sign_sparkle() {
    local fw="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    [[ -d "$fw" ]] || return 0
    local V="$fw/Versions/Current"
    local nested
    for nested in \
        "$V/XPCServices/Downloader.xpc" \
        "$V/XPCServices/Installer.xpc" \
        "$V/Updater.app" \
        "$V/Autoupdate"; do
        [[ -e "$nested" ]] && codesign_path "$nested"
    done
    codesign_path "$fw"
}

sign_bundle() {
    xattr -cr "$APP_BUNDLE" 2>/dev/null || true
    if [[ -x "$APP_BUNDLE/Contents/Helpers/bgbgone" ]]; then
        codesign_path "$APP_BUNDLE/Contents/Helpers/bgbgone"
    fi
    sign_sparkle
    if [[ -n "$ENTITLEMENTS" && -f "$ENTITLEMENTS" ]]; then
        codesign_path "$APP_BUNDLE" --entitlements "$ENTITLEMENTS"
    else
        codesign_path "$APP_BUNDLE"
    fi
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
}

print "==> Building ${APP_NAME} ${VERSION}"
swift build -c release --package-path "$ROOT_DIR" --scratch-path "$ROOT_DIR/build"
BIN_DIR="$(swift build -c release --show-bin-path --package-path "$ROOT_DIR" --scratch-path "$ROOT_DIR/build")"
BIN_PATH="${BIN_DIR}/${APP_NAME}"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Helpers"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/${APP_NAME}"
chmod +x "$APP_BUNDLE/Contents/MacOS/${APP_NAME}"
cp "$ROOT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "$APP_BUNDLE/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$APP_BUNDLE/Contents/Info.plist" >/dev/null

# Auto-update guard: a bundled-only app that ships without a feed URL + EdDSA public
# key would either never update or fail to verify updates. Fail the build, don't ship it.
for su_key in SUFeedURL SUPublicEDKey; do
    su_val="$(/usr/libexec/PlistBuddy -c "Print :${su_key}" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
    [[ -n "$su_val" ]] || { print "error: Info.plist missing ${su_key} — refusing to ship an updater pointed at nothing" >&2; exit 1; }
done
print "==> Verified Sparkle Info.plist keys (SUFeedURL, SUPublicEDKey)"

[[ -f "$ICON_SOURCE" ]] && cp "$ICON_SOURCE" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Bundle the 3 built-in demo images directly into Resources/demo/.
# Demo Mode: zero network, zero JSON parsing. The Try Demo button copies
# these to a tmp dir and drops them through the normal pipeline.
DEMO_SRC="$ROOT_DIR/Resources/demo"
DEMO_DEST="$APP_BUNDLE/Contents/Resources/demo"
if [[ -d "$DEMO_SRC" ]]; then
    print "==> Bundling Demo images from Resources/demo/"
    mkdir -p "$DEMO_DEST"
    cp "$DEMO_SRC"/*.jpg "$DEMO_DEST/" 2>/dev/null || true
fi

HELPER_PATH="$(resolve_helper)" || {
    print "error: could not build/locate the bgbgone helper — refusing to ship an app without its version-locked CLI dependency" >&2
    exit 1
}
print "==> Embedding bgbgone helper from ${HELPER_PATH}"
cp "$HELPER_PATH" "$APP_BUNDLE/Contents/Helpers/bgbgone"
chmod +x "$APP_BUNDLE/Contents/Helpers/bgbgone"

# Assert the embedded binary is exactly the pinned version. Turns the old silent
# "bundled a stale binary" failure mode into a hard build error.
EMBEDDED_VERSION="$("$APP_BUNDLE/Contents/Helpers/bgbgone" --version 2>/dev/null || true)"
if [[ "$EMBEDDED_VERSION" != *"v${BGBGONE_VERSION}"* ]]; then
    print "error: embedded bgbgone reports '${EMBEDDED_VERSION}', expected v${BGBGONE_VERSION}" >&2
    exit 1
fi
print "==> Verified embedded bgbgone: ${EMBEDDED_VERSION}"

# Embed Sparkle.framework and point the SwiftPM-built executable at it. The binary
# references Sparkle via @rpath; without an @executable_path/../Frameworks rpath the
# dylib won't resolve at runtime inside the .app.
SPARKLE_FW="$(resolve_sparkle_framework)" || {
    print "error: Sparkle.framework not found — run 'swift build' first so SwiftPM fetches the XCFramework" >&2
    exit 1
}
print "==> Embedding Sparkle.framework v${SPARKLE_VERSION} from ${SPARKLE_FW}"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
cp -R "$SPARKLE_FW" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/${APP_NAME}" 2>/dev/null || true

print "==> Signing bundle (${SIGN_IDENTITY})"
sign_bundle

print "==> Built ${APP_BUNDLE}"
