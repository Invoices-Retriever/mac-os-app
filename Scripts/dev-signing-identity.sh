#!/bin/bash
# Creates a stable local code-signing identity, so development builds stop
# asking for keychain access on every launch.
#
# Why this exists: an ad-hoc signature (`codesign -s -`) is derived from the
# binary, so it changes with every build. macOS decides who may read a keychain
# item from the signature of the application that created it, so every rebuild
# looks like a different application and asks again. That is not the app being
# careless with credentials — it is the correct behaviour for an application
# macOS has no stable way to recognise.
#
# A self-signed certificate gives one identity that survives rebuilds. It is
# local, it grants nothing outside this machine, and it is not a substitute for
# a Developer ID: releases are signed and notarised, and this is only so that
# working on the app is not tedious.
#
# To undo it:
#   security delete-certificate -c "Invoices Retriever Development"
set -euo pipefail

NAME="Invoices Retriever Development"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# An Apple-issued certificate, if there is one, is better than anything this
# script can make: it is already trusted, already stable, and already there.
EXISTING="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '"(Developer ID Application|Apple Development)[^"]*"' | head -1)"
if [ -n "$EXISTING" ]; then
    echo "✓ You already have a stable signing identity: $EXISTING"
    echo "  build-app.sh picks it up on its own; nothing to do."
    exit 0
fi

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "✓ '$NAME' already exists — build-app.sh will use it."
    exit 0
fi

echo "→ Creating a self-signed code-signing certificate: $NAME"
echo "  macOS will ask for your login password to store the private key."
echo

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# A throwaway password, not an empty one: an empty PKCS#12 password makes the
# Security framework's importer fail MAC verification. It never leaves this
# function and the bundle is deleted on exit.
PASSPHRASE="$(head -c 24 /dev/urandom | base64)"

openssl pkcs12 -export -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -passout "pass:$PASSPHRASE" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null \
  || openssl pkcs12 -export -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -passout "pass:$PASSPHRASE" 2>/dev/null

# -T /usr/bin/codesign lets codesign use the key without asking every time.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSPHRASE" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# Without this the key is still guarded by a per-use prompt, which would just
# move the annoyance rather than remove it.
# A self-signed certificate is not an identity until it is trusted for code
# signing; without this, `find-identity -p codesigning` will not list it.
sudo security add-trusted-cert -d -r trustRoot \
    -p codeSign -k /Library/Keychains/System.keychain "$WORK/cert.pem" 2>/dev/null || {
    echo "  (could not mark the certificate as trusted for code signing —"
    echo "   it needs an administrator password; run this script again with sudo"
    echo "   available, or use an Apple Development certificate instead)"
}

security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || {
    echo "  (could not set the key partition list automatically —"
    echo "   codesign may ask once per build until you answer 'Always Allow')"
}

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "✓ Created. ./Scripts/build-app.sh will sign with it from now on."
    echo
    echo "  The first launch after switching identity still asks once for each"
    echo "  saved credential, because the items were created by a differently"
    echo "  signed build. Answer 'Always Allow' and it stops for good."
else
    echo "✗ The certificate was not created. Builds stay ad-hoc signed."
    exit 1
fi
