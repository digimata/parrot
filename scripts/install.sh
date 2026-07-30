#!/bin/sh
# parrot installer.
#   curl -fsSL https://digimata.github.io/parrot/install.sh | sh
#
# Fetches the latest arm64 macOS binary from GitHub Releases, checks it against
# the published SHA-256, and drops it in /usr/local/bin.
#
# Pin a specific release with PARROT_VERSION (piping to sh leaves no way to pass
# arguments, so an env var is the only mechanism):
#   PARROT_VERSION=v0.0.5 curl -fsSL https://digimata.github.io/parrot/install.sh | sh
#
# Apple Silicon only — WhisperKit uses the Apple Neural Engine via CoreML,
# which only ships on M-series chips.
#
# POSIX sh only: this is documented as `| sh`, so the shebang above is bypassed
# in the common path. Don't reintroduce bashisms (`set -o pipefail`, arrays).

set -eu

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

for cmd in curl tar shasum; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        red "missing dependency: $cmd"
        exit 1
    fi
done

# 2. resolve release
if [ -n "${PARROT_VERSION:-}" ]; then
    TAG="$PARROT_VERSION"
    dim "→ using pinned release ${TAG} (PARROT_VERSION)"
else
    dim "→ resolving latest release..."
    # Capture the response first rather than piping curl into grep: in a pipeline
    # the exit status is grep's, so a failed download would slip through.
    if ! RELEASE_JSON=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest"); then
        red "couldn't reach the GitHub releases API"
        exit 1
    fi
    TAG=$(printf '%s\n' "$RELEASE_JSON" \
        | grep -E '"tag_name"' \
        | head -1 \
        | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
    if [ -z "${TAG:-}" ]; then
        red "couldn't determine latest release tag"
        exit 1
    fi
    dim "  ${TAG}"
fi

URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 3. download tarball + checksum
dim "→ downloading ${ASSET}..."
if ! curl -fsSL "$URL" -o "$TMP/${ASSET}"; then
    red "download failed: ${URL}"
    red "if you pinned PARROT_VERSION, check that ${TAG} exists and has a ${ASSET} asset."
    exit 1
fi

dim "→ downloading ${ASSET}.sha256..."
if ! curl -fsSL "${URL}.sha256" -o "$TMP/${ASSET}.sha256"; then
    red "no ${ASSET}.sha256 published for ${TAG} — refusing to install unverified."
    red "every release ships one, so its absence is itself a reason to stop."
    exit 1
fi

# 4. verify checksum BEFORE extracting
dim "→ verifying checksum..."
if ! (cd "$TMP" && shasum -a 256 -c "${ASSET}.sha256" >/dev/null 2>&1); then
    red "CHECKSUM MISMATCH — the download does not match the published SHA-256."
    red "expected: $(cut -d' ' -f1 <"$TMP/${ASSET}.sha256")"
    red "actual:   $(shasum -a 256 "$TMP/${ASSET}" | cut -d' ' -f1)"
    red "refusing to install. this means a corrupted download or a tampered artifact."
    exit 1
fi
DIGEST=$(shasum -a 256 "$TMP/${ASSET}" | cut -d' ' -f1)
green "✓ sha256 ${DIGEST}"

# 5. build provenance (advisory)
#
# Deliberately not fail-closed. `gh attestation verify` requires the user to be
# logged in even for a public repo, and returns the same exit code for "no
# attestation exists", "your token expired", and a genuine verification failure
# (cli/cli#9338) — so blocking on it would break installs for reasons unrelated
# to tampering. The checksum above is the check that fails closed.
# PARROT_REQUIRE_ATTESTATION=1 makes any verification failure fatal.
if command -v gh >/dev/null 2>&1; then
    dim "→ verifying build provenance..."
    if gh attestation verify "$TMP/${ASSET}" --repo "${REPO}" >/dev/null 2>&1; then
        green "✓ provenance verified — built by ${REPO} in GitHub Actions"
    elif [ -n "${PARROT_REQUIRE_ATTESTATION:-}" ]; then
        red "provenance verification FAILED and PARROT_REQUIRE_ATTESTATION is set."
        red "re-run without it, or diagnose with:"
        red "  gh attestation verify <file> --repo ${REPO}"
        exit 1
    else
        red "note: could not verify build provenance for ${TAG}."
        red "  this is expected for releases published before attestations were added,"
        red "  and also happens if gh isn't logged in. it is NOT proof of tampering."
        red "  the sha256 above still matched. to investigate:"
        red "    gh attestation verify <file> --repo ${REPO}"
    fi
else
    dim "  gh not installed — skipping provenance check. to verify by hand later:"
    dim "    gh attestation verify ${ASSET} --repo ${REPO}"
fi

# 6. inspect the archive BEFORE extracting
dim "→ inspecting archive..."
MEMBERS=$(tar -tzf "$TMP/${ASSET}")
if printf '%s\n' "$MEMBERS" | grep -qE '^/|(^|/)\.\.(/|$)'; then
    red "archive contains an absolute or parent-relative path — refusing to extract:"
    printf '%s\n' "$MEMBERS" >&2
    exit 1
fi
if [ "$MEMBERS" != "$BIN_NAME" ]; then
    red "archive should contain exactly one member (${BIN_NAME}), got:"
    printf '%s\n' "$MEMBERS" >&2
    exit 1
fi

dim "→ extracting..."
tar -xzf "$TMP/${ASSET}" -C "$TMP"

if [ ! -f "$TMP/${BIN_NAME}" ]; then
    red "archive did not contain ${BIN_NAME}"
    exit 1
fi

chmod +x "$TMP/${BIN_NAME}"

# 7. quarantine
#
# curl does not set com.apple.quarantine — it's applied by apps that opt into
# LSFileQuarantineEnabled (browsers, Mail). This is a no-op in the `curl | sh`
# path, and only does anything for a tarball downloaded via a browser.
if xattr -p com.apple.quarantine "$TMP/${BIN_NAME}" >/dev/null 2>&1; then
    dim "→ removing com.apple.quarantine (the archive was downloaded by a quarantining app)"
    xattr -d com.apple.quarantine "$TMP/${BIN_NAME}" 2>/dev/null || true
else
    dim "  no quarantine attribute to remove"
fi

# 8. install
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
