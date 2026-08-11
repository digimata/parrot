#!/usr/bin/env bash
# parrot installer.
#   curl -fsSL https://github.com/willmather95/parrot/releases/latest/download/install.sh | bash
#
# Fetches the latest arm64 macOS app from GitHub Releases, verifies its
# published SHA-256 checksum, installs the stable signed app identity in
# /Applications. When /usr/local/bin already exists and is writable, it also
# adds an optional CLI shortcut there without requesting administrator access.
#
# Apple Silicon only. Parrot's local inference engines require an M-series Mac.

set -euo pipefail

REPO="willmather95/parrot"
BIN_NAME="parrot"
INSTALL_DIR="/usr/local/bin"
ASSET="parrot-macos-arm64.tar.gz"
CURL_FLAGS=(--fail --silent --show-error --location --retry 3 --retry-delay 1 --retry-all-errors)

red()    { printf "\033[31m%s\033[0m\n" "$*" >&2; }
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
dim()    { printf "\033[2m%s\033[0m\n" "$*"; }

# 1. sanity
if [ "$(uname -s)" != "Darwin" ]; then
    red "parrot is macOS-only (detected $(uname -s))"
    exit 1
fi

ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
    red "parrot requires Apple Silicon (detected $ARCH)"
    red "the on-device inference engine uses the Apple Neural Engine, which Intel Macs don't have."
    exit 1
fi

for cmd in codesign curl ditto shasum tar; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        red "missing dependency: $cmd"
        exit 1
    fi
done

# 2. resolve latest release
dim "→ resolving latest release..."
TAG=$(curl "${CURL_FLAGS[@]}" "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep -E '"tag_name"' \
    | head -1 \
    | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')

if [ -z "${TAG:-}" ]; then
    red "couldn't determine latest release tag"
    exit 1
fi
dim "  ${TAG}"

URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"
CHECKSUM_URL="${URL}.sha256"

# 3. download + extract
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

dim "→ downloading ${ASSET}..."
curl "${CURL_FLAGS[@]}" "$URL" -o "$TMP/${ASSET}"
curl "${CURL_FLAGS[@]}" "$CHECKSUM_URL" -o "$TMP/${ASSET}.sha256"

dim "→ verifying SHA-256..."
IFS=' ' read -r EXPECTED_HASH CHECKSUM_NAME CHECKSUM_EXTRA < "$TMP/${ASSET}.sha256"
if [ "${#EXPECTED_HASH}" -ne 64 ] \
    || [[ "$EXPECTED_HASH" == *[!0-9a-f]* ]] \
    || [ "$CHECKSUM_NAME" != "$ASSET" ] \
    || [ -n "${CHECKSUM_EXTRA:-}" ]; then
    red "release checksum has an unexpected format"
    exit 1
fi
ACTUAL_HASH=$(shasum -a 256 "$TMP/${ASSET}" | awk '{print $1}')
if [ "$ACTUAL_HASH" != "$EXPECTED_HASH" ]; then
    red "release checksum verification failed"
    exit 1
fi
green "✓ release checksum verified"

ARCHIVE_LIST=$(tar -tzf "$TMP/${ASSET}")
if printf '%s\n' "$ARCHIVE_LIST" | grep -E '(^/|(^|/)\.\.(/|$))' >/dev/null; then
    red "release archive contains an unsafe path"
    exit 1
fi
for required_path in parrot Parrot.app/Contents/MacOS/parrot; do
    if ! printf '%s\n' "$ARCHIVE_LIST" | grep -Fx "$required_path" >/dev/null; then
        red "release archive is missing ${required_path}"
        exit 1
    fi
done

dim "→ extracting..."
tar -xzf "$TMP/${ASSET}" -C "$TMP"

APP_SOURCE="$TMP/Parrot.app"
APP_EXECUTABLE="$APP_SOURCE/Contents/MacOS/parrot"
if [ ! -x "$APP_EXECUTABLE" ]; then
    red "archive did not contain an executable Parrot.app"
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_SOURCE"
DESIGNATED_REQUIREMENT=$(codesign -d --requirements - "$APP_SOURCE" 2>&1 || true)
if [[ "$DESIGNATED_REQUIREMENT" != *'identifier "com.digimata.parrot"'* ]]; then
    red "Parrot.app has an unexpected signing identity"
    exit 1
fi

# curl normally does not quarantine files, but remove a propagated quarantine
# attribute before installing this verified, ad-hoc-signed local app.
xattr -dr com.apple.quarantine "$APP_SOURCE" 2>/dev/null || true

# 5. install the app
APP_DIR="/Applications/Parrot.app"
APP_STAGE="/Applications/.Parrot.app.install.$$"
APP_BACKUP="/Applications/.Parrot.app.backup.$$"
AGENT_TARGET="gui/$(id -u)/com.digimata.parrot"
AGENT_WAS_REGISTERED=false
if launchctl print "$AGENT_TARGET" >/dev/null 2>&1; then
    AGENT_WAS_REGISTERED=true
fi
APP_SUDO=""
if [ ! -w "/Applications" ]; then
    APP_SUDO="sudo"
fi

dim "→ staging stable app identity at ${APP_STAGE}..."
$APP_SUDO rm -rf "$APP_STAGE" "$APP_BACKUP"
$APP_SUDO ditto "$APP_SOURCE" "$APP_STAGE"
$APP_SUDO codesign --verify --deep --strict --verbose=2 "$APP_STAGE"

dim "→ installing stable app identity at ${APP_DIR}..."
if [ -e "$APP_DIR" ]; then
    $APP_SUDO mv "$APP_DIR" "$APP_BACKUP"
fi
if ! $APP_SUDO mv "$APP_STAGE" "$APP_DIR"; then
    if [ -e "$APP_BACKUP" ]; then
        if ! $APP_SUDO mv "$APP_BACKUP" "$APP_DIR"; then
            red "couldn't install Parrot or restore the prior app at ${APP_DIR}"
            exit 1
        fi
    fi
    red "couldn't replace ${APP_DIR}; the prior app was restored"
    exit 1
fi
if ! $APP_SUDO codesign --verify --deep --strict --verbose=2 "$APP_DIR"; then
    $APP_SUDO rm -rf "$APP_DIR"
    if [ -e "$APP_BACKUP" ]; then
        if ! $APP_SUDO mv "$APP_BACKUP" "$APP_DIR"; then
            red "installed app failed verification and the prior app could not be restored"
            exit 1
        fi
    fi
    red "installed app failed verification; the prior app was restored"
    exit 1
fi

CLI_LINKED=false
if [ -d "$INSTALL_DIR" ] && [ -w "$INSTALL_DIR" ]; then
    dim "→ adding optional CLI shortcut at ${INSTALL_DIR}/${BIN_NAME}..."
    ln -sf "$APP_DIR/Contents/MacOS/parrot" "${INSTALL_DIR}/${BIN_NAME}"
    CLI_LINKED=true
else
    dim "→ skipping optional CLI shortcut; ${INSTALL_DIR} is not user-writable"
fi

# Updating the files under a long-running launchd job does not update its
# already-mapped process. If Parrot was active, require the newly installed
# binary's transactional installer and fresh-ready verifier before reporting
# success. Keep the prior app until that succeeds so a failed update can be
# rolled back to a functioning daemon.
if [ "$AGENT_WAS_REGISTERED" = true ]; then
    dim "→ restarting the existing Parrot login service..."
    if ! "$APP_DIR/Contents/MacOS/parrot" install --launch-at-login; then
        red "the updated Parrot service did not become ready; restoring the prior app"
        launchctl bootout "$AGENT_TARGET" >/dev/null 2>&1 || true
        $APP_SUDO rm -rf "$APP_DIR"
        if [ -e "$APP_BACKUP" ]; then
            if ! $APP_SUDO mv "$APP_BACKUP" "$APP_DIR"; then
                red "the update failed and the prior app could not be restored"
                exit 1
            fi
            # Use the new install command's stronger readiness verifier while
            # pointing the restored plist back at the prior app executable.
            if ! "$APP_EXECUTABLE" install --launch-at-login; then
                red "the prior app was restored, but its login service could not be restarted"
                red "run: ${APP_DIR}/Contents/MacOS/parrot install --launch-at-login"
                exit 1
            fi
            red "the update failed; the prior app and login service were restored"
        else
            red "the update failed and no prior app backup was available"
        fi
        exit 1
    fi
fi

$APP_SUDO rm -rf "$APP_BACKUP"

dim "→ completing first-run setup..."
if ! "$APP_DIR/Contents/MacOS/parrot" setup; then
    red "Parrot is installed, but setup is not complete"
    red "finish it with: ${APP_DIR}/Contents/MacOS/parrot setup"
    exit 1
fi

dim "→ enabling launch at login..."
if ! "$APP_DIR/Contents/MacOS/parrot" install --launch-at-login; then
    red "Parrot is installed and configured, but the login service could not start"
    red "retry with: ${APP_DIR}/Contents/MacOS/parrot install --launch-at-login"
    exit 1
fi

dim "→ verifying microphone and running service..."
if ! "$APP_DIR/Contents/MacOS/parrot" doctor --live-audio; then
    red "Parrot is installed, but its final verification failed"
    red "diagnose it with: ${APP_DIR}/Contents/MacOS/parrot doctor --live-audio"
    exit 1
fi

green "✓ parrot ${TAG} installed at ${APP_DIR}"
green "✓ permissions, local model, microphone, and login service verified"
if [ "$CLI_LINKED" = false ]; then
    dim "  optional CLI: ${APP_DIR}/Contents/MacOS/parrot"
fi
echo
echo "Parrot is ready. Click a text field and press Control + Fn/Globe to dictate."
