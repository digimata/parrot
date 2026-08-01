#!/bin/bash
# Build, sign and install parrot locally.
#
# The signing step is what keeps macOS from asking for Accessibility again on
# every rebuild: an adhoc/linker signature has no certificate, so TCC anchors the
# grant to the binary's cdhash and a rebuild invalidates it. Signed with a stable
# identity, the designated requirement becomes
#   identifier "parrot" and certificate leaf = H"..."
# which every later build satisfies.
#
# The identity is a self-signed code-signing certificate in the login keychain,
# trusted for codeSign in the user domain (no admin needed). Create it once:
#
#   openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 \
#     -nodes -subj "/CN=Parrot Local Signing" \
#     -addext "basicConstraints=critical,CA:false" \
#     -addext "keyUsage=critical,digitalSignature" \
#     -addext "extendedKeyUsage=critical,codeSigning"
#   openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout pass:PASS \
#     -name "Parrot Local Signing" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
#   security import id.p12 -k ~/Library/Keychains/login.keychain-db -P PASS -T /usr/bin/codesign -A
#   security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db cert.pem
#
# The legacy PKCS#12 algorithms are required: OpenSSL 3 defaults produce a file
# the macOS Security framework cannot read.

set -euo pipefail

IDENTITY="${PARROT_SIGN_IDENTITY:-Parrot Local Signing}"
TARGET="${PARROT_INSTALL_PATH:-/usr/local/bin/parrot}"
LABEL="com.digimata.parrot"
cd "$(dirname "$0")/.."

if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "no code-signing identity named '$IDENTITY' — see the header of this script" >&2
  exit 1
fi

swift build -c release

# Sign in the build directory: codesign writes a temporary file beside its target
# and /usr/local/bin is root-owned.
codesign -f -s "$IDENTITY" --identifier parrot .build/release/parrot

requirement=$(codesign -d --requirements - .build/release/parrot 2>&1 | tail -1)
case "$requirement" in
  *cdhash*)
    echo "signature still anchored to cdhash — the grant would not survive:" >&2
    echo "  $requirement" >&2
    exit 1
    ;;
esac

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
sleep 1
cat .build/release/parrot > "$TARGET"
chmod 755 "$TARGET"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$LABEL.plist"

echo "installed: $TARGET"
echo "requirement: $requirement"
echo "log: /tmp/parrot.err.log"
