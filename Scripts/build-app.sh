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

if [ -n "${IR_SIGNING_IDENTITY:-}" ]; then
    echo "→ Signing with $IR_SIGNING_IDENTITY…"
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
    echo "  saved credentials. That is a property of unsigned builds, not of the app —"
    echo "  a Developer ID signature keeps one identity across releases and the prompt"
    echo "  stops. Answering \"Always Allow\" holds until the next rebuild."
fi
