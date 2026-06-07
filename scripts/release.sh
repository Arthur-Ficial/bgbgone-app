#!/bin/zsh
# release.sh — full release pipeline for bgbgone-app.
# Tests → build → sign → notarise → zip → gh release → update Homebrew tap.
#
# Modes:
#   DRY_RUN=1  — does everything up to (but not including) git push, gh release
#                create, or homebrew-tap update. Leaves the .zip, .icns,
#                SHA256SUMS, and rendered cask under ./dist/ so you can inspect
#                them before committing to the actual release.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="bgbgone-app"
VERSION="$(tr -d '\n' < "$ROOT_DIR/.version")"
TAG="v${VERSION}"
ARCH="$(uname -m)"
DIST_DIR="$ROOT_DIR/dist"
DRY_RUN="${DRY_RUN:-0}"

SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Franz Enzenhofer (7D2YX5DQ6M)}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-notarytool}"
ENTITLEMENTS="${ENTITLEMENTS:-$ROOT_DIR/bgbgone-app.entitlements}"

# --- Sparkle appcast publishing -------------------------------------------------
SPARKLE_VERSION="2.9.2"
SPARKLE_DIST="$ROOT_DIR/.build/sparkle-dist"

# Locate generate_appcast (Sparkle's signing/appcast tool); fetch the distribution
# tarball on demand if it isn't already cached under .build/.
resolve_generate_appcast() {
    local tool="$SPARKLE_DIST/bin/generate_appcast"
    if [[ ! -x "$tool" ]]; then
        print "==> Fetching Sparkle ${SPARKLE_VERSION} tools" >&2
        mkdir -p "$SPARKLE_DIST"
        curl -fsSL -o "$SPARKLE_DIST/Sparkle.tar.xz" \
            "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" >&2
        tar -xf "$SPARKLE_DIST/Sparkle.tar.xz" -C "$SPARKLE_DIST" >&2
    fi
    [[ -x "$tool" ]] || { print "error: generate_appcast not found" >&2; return 1; }
    print -- "$tool"
}

# Generate the EdDSA-signed appcast for this release and publish it to the gh-pages
# branch (served at SUFeedURL). Run AFTER `gh release create` so the enclosure URLs
# resolve to the just-uploaded GitHub Release assets.
publish_appcast() {
    local gen; gen="$(resolve_generate_appcast)" || return 1
    local staging; staging="$(mktemp -d)"
    cp "$APP_ZIP" "$staging/"
    # Versions/signatures come from the app bundle inside the zip. Feed the EdDSA private
    # key from pass via stdin (--ed-key-file -) rather than the Keychain, which isn't
    # reliably reachable from a non-interactive shell (errSecUserCanceled / -128).
    pass show apple/bgbgone-sparkle-ed-private \
        | "$gen" --ed-key-file - \
            --download-url-prefix "https://github.com/Arthur-Ficial/${APP_NAME}/releases/download/${TAG}/" \
            "$staging"
    local appcast="$staging/appcast.xml"
    [[ -f "$appcast" ]] || { print "ERROR: appcast.xml not generated" >&2; rm -rf "$staging"; return 1; }

    local pages; pages="$(mktemp -d)"
    local remote; remote="$(git -C "$ROOT_DIR" remote get-url origin)"
    git clone --quiet "$remote" "$pages"
    if git -C "$pages" rev-parse --verify origin/gh-pages >/dev/null 2>&1; then
        git -C "$pages" checkout --quiet gh-pages
    else
        git -C "$pages" checkout --quiet --orphan gh-pages
        git -C "$pages" rm -rqf . >/dev/null 2>&1 || true
    fi
    cp "$appcast" "$pages/appcast.xml"
    git -C "$pages" add appcast.xml
    git -C "$pages" -c user.name="Arthur Ficial" -c user.email="arti.ficial@fullstackoptimization.com" \
        commit -q -m "appcast: ${TAG}"
    git -C "$pages" push --quiet origin gh-pages
    rm -rf "$pages" "$staging"

    # Enable GitHub Pages from gh-pages (idempotent; needs the branch to exist first).
    gh api "repos/Arthur-Ficial/${APP_NAME}/pages" >/dev/null 2>&1 || \
        gh api "repos/Arthur-Ficial/${APP_NAME}/pages" -X POST \
            -f 'source[branch]=gh-pages' -f 'source[path]=/' >/dev/null 2>&1 || true
    print "==> Appcast published → https://arthur-ficial.github.io/${APP_NAME}/appcast.xml"
}

print "==> Release $TAG${DRY_RUN:+ (DRY RUN)}"

BRANCH="$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD)"
if [[ "$DRY_RUN" == "0" ]]; then
    [[ "$BRANCH" == "main" ]] || { print "ERROR: not on main (currently: $BRANCH)" >&2; exit 1 }
    git -C "$ROOT_DIR" diff-index --quiet HEAD -- || { print "ERROR: uncommitted changes." >&2; exit 1 }
    git -C "$ROOT_DIR" tag --list "$TAG" | grep -q "^${TAG}$" \
        && { print "ERROR: Tag $TAG already exists. Bump .version." >&2; exit 1 } || true
    security find-identity -v -p codesigning | grep -q "Developer ID Application" \
        || { print "ERROR: No Developer ID Application cert." >&2; exit 1 }
fi

print "==> Tests"
swift test --package-path "$ROOT_DIR"

print "==> Build + sign + notarise + dist"
SIGN_IDENTITY="$SIGN_IDENTITY" KEYCHAIN_PROFILE="$KEYCHAIN_PROFILE" ENTITLEMENTS="$ENTITLEMENTS" \
    "$ROOT_DIR/scripts/build-dist.sh"

APP_ZIP="$DIST_DIR/${APP_NAME}-${TAG}-macos-${ARCH}.zip"
# Stable + versioned ZIPs share the same content; build-dist names the versioned one as v${VERSION}.
[[ -f "$APP_ZIP" ]] || APP_ZIP="$DIST_DIR/${APP_NAME}-v${VERSION}-macos-${ARCH}.zip"

if [[ "$SIGN_IDENTITY" != "-" ]]; then
    VERIFY_DIR="$(mktemp -d)"
    ditto -x -k "$APP_ZIP" "$VERIFY_DIR"
    if ! xcrun stapler validate "$VERIFY_DIR/${APP_NAME}.app" >/dev/null 2>&1; then
        print "ERROR: notarisation ticket missing." >&2
        rm -rf "$VERIFY_DIR"; exit 1
    fi
    rm -rf "$VERIFY_DIR"
    print "==> Notarisation verified."
fi

# Post-deploy verification — local checks on the produced ZIP before publishing.
verify_pass() { print "    [PASS] $1"; }
verify_fail() { print "    [FAIL] $1" >&2; FAIL=1; }
FAIL=0

print "==> Post-build verification"
EXTRACT_DIR="$(mktemp -d)"
ditto -x -k "$APP_ZIP" "$EXTRACT_DIR"
EXTRACTED_APP="$EXTRACT_DIR/${APP_NAME}.app"

PLIST_VERSION="$(defaults read "$EXTRACTED_APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)"
[[ "$PLIST_VERSION" == "$VERSION" ]] \
    && verify_pass "Bundle version = $VERSION" || verify_fail "Bundle version = '$PLIST_VERSION', expected '$VERSION'"

if [[ -x "$EXTRACTED_APP/Contents/Helpers/bgbgone" ]]; then
    verify_pass "bgbgone helper embedded"
    # Assert the embedded helper is exactly the pinned submodule version — the app
    # is bundled-only, so the packaged binary IS the one users run.
    PINNED_BGBGONE="$(tr -d '\n' < "$ROOT_DIR/vendor/bgbgone/.version" 2>/dev/null)"
    EMBEDDED_BGBGONE="$("$EXTRACTED_APP/Contents/Helpers/bgbgone" --version 2>/dev/null || true)"
    if [[ -n "$PINNED_BGBGONE" && "$EMBEDDED_BGBGONE" == *"v${PINNED_BGBGONE}"* ]]; then
        verify_pass "embedded bgbgone = v$PINNED_BGBGONE (matches pinned submodule)"
    else
        verify_fail "embedded bgbgone = '$EMBEDDED_BGBGONE', expected v$PINNED_BGBGONE (pinned submodule)"
    fi
else
    verify_fail "bgbgone helper NOT embedded — bundled-only app cannot run without it"
fi

if [[ "$SIGN_IDENTITY" != "-" ]]; then
    spctl --assess --type execute "$EXTRACTED_APP" 2>/dev/null \
        && verify_pass "Gatekeeper accepts the app" \
        || verify_fail "Gatekeeper rejects the app"
fi
rm -rf "$EXTRACT_DIR"

if [[ "$FAIL" -ne 0 ]]; then
    print "ERROR: post-build verification failed; aborting before publish." >&2
    exit 1
fi

if [[ "$DRY_RUN" == "1" ]]; then
    print "==> DRY RUN complete. Artefacts at:"
    print "    $APP_ZIP"
    print "    $DIST_DIR/SHA256SUMS"
    print "    $DIST_DIR/homebrew/${APP_NAME}.rb"
    exit 0
fi

print "==> Tagging $TAG"
git -C "$ROOT_DIR" tag "$TAG"
git -C "$ROOT_DIR" push origin main
git -C "$ROOT_DIR" push origin "$TAG"

print "==> Creating GitHub release"
APP_ZIP_STABLE="$DIST_DIR/${APP_NAME}-macos-${ARCH}.zip"
SHA_FILE="$DIST_DIR/SHA256SUMS"
HOMEBREW_CASK="$DIST_DIR/homebrew/${APP_NAME}.rb"

gh release create "$TAG" \
    --title "${APP_NAME} ${TAG}" \
    --generate-notes \
    "$APP_ZIP" "$APP_ZIP_STABLE" "$SHA_FILE" "$HOMEBREW_CASK"

print "==> Pushing cask to Arthur-Ficial/homebrew-tap"
CASK_B64="$(base64 < "$HOMEBREW_CASK")"
EXISTING_SHA="$(gh api repos/Arthur-Ficial/homebrew-tap/contents/Casks/${APP_NAME}.rb --jq '.sha' 2>/dev/null || true)"
if [[ -n "$EXISTING_SHA" ]]; then
    gh api repos/Arthur-Ficial/homebrew-tap/contents/Casks/${APP_NAME}.rb -X PUT \
        -f message="cask: update ${APP_NAME} to ${TAG}" \
        -f content="$CASK_B64" -f sha="$EXISTING_SHA" --jq '.commit.sha' > /dev/null
else
    gh api repos/Arthur-Ficial/homebrew-tap/contents/Casks/${APP_NAME}.rb -X PUT \
        -f message="cask: add ${APP_NAME} ${TAG}" \
        -f content="$CASK_B64" --jq '.commit.sha' > /dev/null
fi

print "==> Publishing Sparkle appcast"
publish_appcast

print "==> Done. https://github.com/Arthur-Ficial/bgbgone-app/releases/tag/$TAG"
