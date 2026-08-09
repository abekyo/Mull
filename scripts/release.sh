#!/bin/bash
#
# Cut a distributable Mull.dmg: build Release, sign with Developer ID, notarize,
# staple, verify.
#
# The point of this script is that a build which cannot be distributed should
# fail HERE, in the first two seconds, and say why — not twenty minutes later
# inside notarytool, and not silently, producing a .dmg that looks fine and
# throws "Apple could not verify Mull" on every machine but this one.
#
#     ./scripts/release.sh
#
# Requires, all set in Local.xcconfig (see Local.xcconfig.example):
#     MULL_DEVELOPER_ID_IDENTITY   a "Developer ID Application" certificate
#     MULL_TEAM_ID                 the 10-character Apple team ID
#     MULL_NOTARY_PROFILE          a stored notarytool credential profile
#
# Set MULL_SKIP_NOTARIZE=1 to stop after the .dmg is built. That path exists to
# exercise the pipeline without a certificate; it prints a loud banner because
# what it produces is NOT distributable.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

# Everything is built and packaged OUTSIDE the repository, and that is not a
# tidiness preference — it is the only way this works when the checkout lives in
# a synced folder (iCloud Drive, Dropbox, Google Drive).
#
# Those sync daemons stamp com.apple.FinderInfo on directories they manage, and
# codesign refuses to sign or verify anything carrying it:
#
#     resource fork, Finder information, or similar detritus not allowed
#
# `xattr -cr` does not fix it. Measured on this repo, the daemon re-applies the
# attribute within three seconds of it being cleared, so the clear-then-sign
# window is a race that signing loses at random. Building somewhere the daemon
# does not manage removes the race instead of narrowing it.
WORK="${TMPDIR:-/tmp}/mull-release"
BUILD_DIR="$WORK/build"
APP="$BUILD_DIR/Build/Products/Release/Mull.app"
STAGE="$WORK/dmg-stage"
OUT_DIR="${MULL_OUTPUT_DIR:-$HOME/Library/Caches/mull-release}"
DMG="$OUT_DIR/Mull.dmg"

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mrelease: %s\033[0m\n' "$*" >&2; exit 1; }

# --- Read the machine-specific values -------------------------------------
#
# Local.xcconfig is the single place these live (Signing.xcconfig #include?s it
# for the Xcode build). Parsing it here rather than duplicating the values into
# the environment keeps one source; an env var still wins if you export one.
read_cfg() {
    local key="$1"
    [ -f "$ROOT/Local.xcconfig" ] || return 0
    sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$ROOT/Local.xcconfig" \
        | tail -1 | sed 's/[[:space:]]*$//'
}

IDENTITY="${MULL_DEVELOPER_ID_IDENTITY:-$(read_cfg MULL_DEVELOPER_ID_IDENTITY)}"
TEAM_ID="${MULL_TEAM_ID:-$(read_cfg MULL_TEAM_ID)}"
NOTARY_PROFILE="${MULL_NOTARY_PROFILE:-$(read_cfg MULL_NOTARY_PROFILE)}"
SKIP_NOTARIZE="${MULL_SKIP_NOTARIZE:-0}"

# --- Preflight ------------------------------------------------------------
#
# Every check below is something that otherwise surfaces as a confusing failure
# much later, so they all run before the first build second is spent.

log "Preflight"

command -v xcodegen >/dev/null || fail "xcodegen not found — brew install xcodegen"

# The output directory has the same sync problem as the repo, and a .dmg that
# picks up FinderInfo after signing fails Gatekeeper on the user's machine while
# looking perfectly fine here. Catch an overridden MULL_OUTPUT_DIR now.
mkdir -p "$OUT_DIR"
if xattr -l "$OUT_DIR" 2>/dev/null | grep -q 'com.apple.\(FinderInfo\|fileprovider\)'; then
    fail "output directory is managed by a file-sync daemon (iCloud Drive, Dropbox, …):
    $OUT_DIR
  It stamps com.apple.FinderInfo on its contents, which invalidates the signature
  on the .dmg. Set MULL_OUTPUT_DIR to a path outside any synced folder."
fi

if [ "$SKIP_NOTARIZE" != "1" ]; then
    [ -n "$IDENTITY" ] || fail \
"MULL_DEVELOPER_ID_IDENTITY is not set.

  Notarization requires a 'Developer ID Application' certificate. An Apple
  Development certificate cannot be substituted — Apple rejects the submission.

  Create one at developer.apple.com (Certificates > +), then:
      security find-identity -v | grep 'Developer ID Application'
  and put the hash in Local.xcconfig (see Local.xcconfig.example).

  To build an unnotarized .dmg anyway (not distributable):
      MULL_SKIP_NOTARIZE=1 ./scripts/release.sh"

    # Refuse a certificate that is real but of the wrong kind. This is the
    # single most expensive mistake available here: it builds, it signs, it
    # notarizes for twenty minutes, and then it is rejected.
    CERT_LINE="$(security find-identity -v | grep -F "$IDENTITY" || true)"
    [ -n "$CERT_LINE" ] || fail "no certificate in the keychain matches MULL_DEVELOPER_ID_IDENTITY ($IDENTITY)"
    case "$CERT_LINE" in
        *"Developer ID Application"*) : ;;
        *) fail "MULL_DEVELOPER_ID_IDENTITY points at a certificate that is not a Developer ID Application cert:
    ${CERT_LINE#*\" }
  Apple will reject a notarization signed with this. Use a Developer ID Application certificate." ;;
    esac

    [ -n "$TEAM_ID" ] || fail "MULL_TEAM_ID is not set (needed by notarytool)"
    [ -n "$NOTARY_PROFILE" ] || fail "MULL_NOTARY_PROFILE is not set — create one with 'xcrun notarytool store-credentials'"
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || fail \
"notarytool cannot use the credential profile '$NOTARY_PROFILE'.

  Create it once with an app-specific password from appleid.apple.com:
      xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\
          --apple-id \"you@example.com\" --team-id \"$TEAM_ID\" \\
          --password \"<app-specific-password>\""
else
    printf '\033[1;33m%s\033[0m\n' \
"  MULL_SKIP_NOTARIZE=1 — the .dmg will NOT be notarized.
  Gatekeeper will refuse it on any machine but this one. Do not publish it."
fi

# --- Build ----------------------------------------------------------------

log "Generating the Xcode project"
xcodegen generate

log "Building Release"
rm -rf "$BUILD_DIR"
# CODE_SIGNING_ALLOWED=NO: the signing below is done by this script, inside-out,
# with the flags notarization wants. Letting xcodebuild sign first is not just
# redundant, it fails outright — its CodeSign step runs before anything can strip
# extended attributes, and a checkout under a file-provider-synced directory
# (iCloud Drive, Dropbox) picks up com.apple.FinderInfo on the GRDB resource
# bundle, which codesign rejects as "resource fork, Finder information, or
# similar detritus not allowed".
#
# PIPESTATUS, not the pipeline's status: piping into grep otherwise reports
# grep's success and a failed build sails on to produce an unsigned .dmg.
set +e
xcodebuild \
    -project Mull.xcodeproj \
    -scheme Mull \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGNING_ALLOWED=NO \
    build \
    | grep -E '^(\*\*|error:)'
build_status=${PIPESTATUS[0]}
set -e
[ "$build_status" -eq 0 ] || fail "xcodebuild failed (status $build_status)"

[ -d "$APP" ] || fail "build produced no app at $APP"

# --- Sign -----------------------------------------------------------------

# Without a Developer ID (the MULL_SKIP_NOTARIZE path) sign ad-hoc instead of
# skipping: the hardened-runtime verification below is the check worth keeping
# honest, and it can only read a flag off something that was actually signed.
# A secure timestamp needs a real certificate, so it is only passed with one.
if [ -n "$IDENTITY" ]; then
    SIGN_ID="$IDENTITY"
    log "Signing with Developer ID"
else
    SIGN_ID="-"
    log "Signing ad-hoc (no Developer ID)"
fi

# One place that knows whether a secure timestamp is available, so no call site
# has to. (An empty array expanded under `set -u` is an error in the bash 3.2
# that macOS ships, which is why this is a function and not a flags array.)
sign() {
    local target="$1"; shift
    if [ -n "$IDENTITY" ]; then
        codesign --force --timestamp --sign "$SIGN_ID" "$@" "$target"
    else
        codesign --force --sign "$SIGN_ID" "$@" "$target"
    fi
}

# Belt and braces. $WORK is outside any synced tree so nothing should be
# stamped here, but the app was copied out of a build system that may have
# carried attributes along with it.
xattr -cr "$APP"

# Inside-out, deliberately, instead of `codesign --deep`: --deep applies the
# app's entitlements to every nested binary, and the helper is a plain CLI tool
# that should not inherit the app's Apple Events entitlement. The helper also
# has to be signed BEFORE the bundle containing it, or the outer signature seals
# a hash that is already stale.
if [ -d "$APP/Contents/Frameworks" ]; then
    while IFS= read -r item; do
        sign "$item" --options runtime
    done < <(find "$APP/Contents/Frameworks" -type f -name '*.dylib')
fi

if [ -e "$APP/Contents/Helpers/MullMCP" ]; then
    sign "$APP/Contents/Helpers/MullMCP" --options runtime
else
    fail "Contents/Helpers/MullMCP is missing — the app would ship with a Connect button that points at nothing"
fi

sign "$APP" --options runtime --entitlements "$ROOT/Mull/Resources/Mull.entitlements"

# --- Verify the signature before spending a notarization on it -------------

# Not piped into sed: a pipeline reports sed's exit status, so `set -e` would
# sail straight past a failed verification. This step existing at all is the
# point — it is the last place a bad signature is cheap to find.
log "Verifying the signature"
if ! codesign --verify --deep --strict --verbose=2 "$APP" 2>&1; then
    fail "signature verification failed — see the codesign output above"
fi

# The hardened runtime is the requirement people forget, and its absence is
# invisible until Apple says no. Read it back off the built artifact rather
# than trusting that the build setting took.
for target in "$APP" "$APP/Contents/Helpers/MullMCP"; do
    flags="$(codesign -dv "$target" 2>&1 | sed -n 's/.*flags=\([^ ]*\).*/\1/p')"
    case "$flags" in
        *runtime*) log "hardened runtime: on  ($(basename "$target"))" ;;
        *) fail "hardened runtime is NOT enabled on $(basename "$target") (flags=$flags) — notarization would be rejected" ;;
    esac
done

# --- Package --------------------------------------------------------------
#
# A plain read-only .dmg with an /Applications symlink: the gesture every Mac
# user already knows, and nothing to learn. No background art, no window
# geometry — that is DESIGN work, and it is frozen (CLAUDE.md §9).

log "Building the disk image"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Mull.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create \
    -volname "Mull" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null

rm -rf "$STAGE"

sign "$DMG"

if [ "$SKIP_NOTARIZE" = "1" ]; then
    log "Done (unnotarized): $DMG"
    printf '\033[1;33m%s\033[0m\n' "  Not distributable. Gatekeeper will refuse this on other machines."
    exit 0
fi

# --- Notarize -------------------------------------------------------------

log "Submitting to Apple for notarization (this takes minutes, not seconds)"
xcrun notarytool submit "$DMG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --team-id "$TEAM_ID" \
    --wait

# Stapling attaches the ticket to the .dmg so a first launch works offline.
log "Stapling the ticket"
xcrun stapler staple "$DMG"

# --- Final gate -----------------------------------------------------------
#
# spctl is what Gatekeeper itself will run. If this does not say "accepted",
# users will see the refusal dialog, whatever the earlier steps reported.

log "Gatekeeper assessment"
if ! spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" 2>&1; then
    fail "Gatekeeper rejected the .dmg — users would see the refusal dialog. Do not publish this."
fi

log "Done: $DMG"
