#!/usr/bin/env bash
# parrot installer.
#   curl -fsSL https://digimata.github.io/parrot/install.sh | sh
#
# Fetches the latest arm64 macOS binary from GitHub Releases, drops it
# in /usr/local/bin, and strips the quarantine xattr so Gatekeeper doesn't
# block the unsigned binary.
#
# Apple Silicon only — WhisperKit uses the Apple Neural Engine via CoreML,
# which only ships on M-series chips.

set -euo pipefail

REPO="digimata/parrot"
BIN_NAME="parrot"
INSTALL_DIR="/usr/local/bin"
ASSET="parrot-macos-arm64.tar.gz"

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

for cmd in curl tar; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        red "missing dependency: $cmd"
        exit 1
    fi
done

# 2. resolve latest release
dim "→ resolving latest release..."
TAG=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep -E '"tag_name"' \
    | head -1 \
    | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')

if [ -z "${TAG:-}" ]; then
    red "couldn't determine latest release tag"
    exit 1
fi
dim "  ${TAG}"

URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"

# 3. download + extract
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

dim "→ downloading ${ASSET}..."
curl -fsSL "$URL" -o "$TMP/${ASSET}"

# The release workflow publishes ${ASSET}.sha256 alongside the archive.
# Verify it: this script installs an unsigned binary and strips its
# quarantine flag, so the checksum is the only integrity check there is.
dim "→ verifying checksum..."
curl -fsSL "${URL}.sha256" -o "$TMP/${ASSET}.sha256"
( cd "$TMP" && shasum -a 256 -c "${ASSET}.sha256" >/dev/null ) || {
    red "checksum mismatch for ${ASSET} — refusing to install"
    exit 1
}

dim "→ extracting..."
tar -xzf "$TMP/${ASSET}" -C "$TMP"

if [ ! -f "$TMP/${BIN_NAME}" ]; then
    red "archive did not contain ${BIN_NAME}"
    exit 1
fi

chmod +x "$TMP/${BIN_NAME}"

# 4. strip quarantine so Gatekeeper lets the unsigned binary run
xattr -d com.apple.quarantine "$TMP/${BIN_NAME}" 2>/dev/null || true

# 5. install
SUDO=""
if [ ! -w "$INSTALL_DIR" ]; then
    if [ ! -d "$INSTALL_DIR" ]; then
        dim "→ creating ${INSTALL_DIR} (sudo)..."
        sudo mkdir -p "$INSTALL_DIR"
    fi
    SUDO="sudo"
fi

dim "→ installing to ${INSTALL_DIR}/${BIN_NAME}..."
$SUDO mv "$TMP/${BIN_NAME}" "${INSTALL_DIR}/${BIN_NAME}"
$SUDO chmod +x "${INSTALL_DIR}/${BIN_NAME}"

green "✓ parrot ${TAG} installed at ${INSTALL_DIR}/${BIN_NAME}"
echo
echo "next:"
echo "  parrot setup                       # grant mic + accessibility"
echo "  parrot install --launch-at-login   # (optional) start at login"
echo "  parrot                             # run the daemon"
