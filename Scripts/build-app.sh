#!/bin/bash
# Wraps the SwiftPM executable into a .app bundle.
#
# SwiftPM alone produces a bare binary; macOS needs an Info.plist and a bundle
# layout before the window server, the keychain and notifications behave. This
# keeps the project buildable with `swift build` alone — no Xcode project to
# keep in sync — while still producing something you can double-click.
set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Invoices Retriever.app"

cd "$ROOT"
echo "→ Building ($CONFIGURATION)…"
swift build -c "$CONFIGURATION" --product InvoicesRetriever
swift build -c "$CONFIGURATION" --product irctl

BIN="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/InvoicesRetriever" "$APP/Contents/MacOS/InvoicesRetriever"
cp "$BIN/irctl" "$APP/Contents/MacOS/irctl"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# SwiftPM emits resource bundles next to the binary; the app must carry them.
for bundle in "$BIN"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

echo "→ Bundle: $APP"

# Pick a signing identity, in order of what it is good for.
#
# Any stable identity solves the daily annoyance: macOS decides who may read a
# keychain item from the signature of the application that created it, and an
# ad-hoc signature is derived from the binary, so every rebuild looks like a
# different application and asks again.
if [ -z "${IR_SIGNING_IDENTITY:-}" ]; then
    # find-identity prints:  1) <SHA1> "Name of the identity"
    # Pull out the quoted names first, then choose among them, rather than
    # building a regular expression out of a name containing spaces.
    NAMES="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(.*\)".*/\1/p')"
    for CANDIDATE in "Developer ID Application" "Apple Development" "Invoices Retriever Development"; do
        # `|| true`: not finding the first candidate is the normal case, and
        # with `set -e -o pipefail` a bare grep miss would end the script.
        MATCH="$(printf '%s\n' "$NAMES" | grep -F "$CANDIDATE" | head -1 || true)"
        if [ -n "$MATCH" ]; then
            IR_SIGNING_IDENTITY="$MATCH"
            # Only a Developer ID is fit to hand to someone else.
            case "$CANDIDATE" in "Developer ID Application") ;; *) IR_LOCAL_IDENTITY=1 ;; esac
            break
        fi
    done
fi

if [ -n "${IR_SIGNING_IDENTITY:-}" ]; then
    echo "→ Signing with ${IR_SIGNING_IDENTITY}…"
    # A self-signed local certificate has no timestamp authority behind it, and
    # the hardened runtime is only meaningful for something being distributed.
    if [ -n "${IR_LOCAL_IDENTITY:-}" ]; then
        codesign --force --deep \
            --entitlements "$ROOT/Resources/InvoicesRetriever.entitlements" \
            --sign "$IR_SIGNING_IDENTITY" "$APP"
        codesign --verify --strict "$APP"
        echo "→ Signed with the local development identity, which is stable across"
        echo "  builds — so the keychain stops asking. Not for distribution."
        exit 0
    fi

    codesign --force --deep --options runtime --timestamp \
        --entitlements "$ROOT/Resources/InvoicesRetriever.entitlements" \
        --sign "$IR_SIGNING_IDENTITY" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
    echo "→ Signed. Notarise with:"
    echo "    ditto -c -k --keepParent \"$APP\" build/InvoicesRetriever.zip"
    echo "    xcrun notarytool submit build/InvoicesRetriever.zip --keychain-profile <profile> --wait"
    echo "    xcrun stapler staple \"$APP\""
else
    # An unsigned build is fine for development, and saying so beats a silent
    # Gatekeeper refusal later.
    codesign --force --deep --sign - "$APP" 2>/dev/null || true
    echo "→ Ad-hoc signed (development only)."
    echo "  Set IR_SIGNING_IDENTITY to a Developer ID Application certificate for a distributable build."
    echo
    echo "  Note: an ad-hoc signature changes with every build, so macOS treats each"
    echo "  build as a different application and asks again for keychain access to"
    echo "  saved credentials. To stop that while working on the app, run once:"
    echo
    echo "      ./Scripts/dev-signing-identity.sh"
fi
