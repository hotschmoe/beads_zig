#!/usr/bin/env bash
#
# bz (beads_zig) installer - Multi-platform installer script
#
# One-liner install:
#   curl -fsSL https://raw.githubusercontent.com/hotschmoe/beads_zig/master/install.sh | bash
#
# Options:
#   --version vX.Y.Z   Install specific version (default: latest)
#   --dest DIR         Install to DIR (default: ~/.local/bin)
#   --system           Install to /usr/local/bin (requires sudo)
#   --verify           Run self-test after install
#   --checksum SHA     Provide expected SHA256 checksum
#   --quiet            Suppress non-error output
#   --uninstall        Remove bz and clean up
#   --help             Show this help
#
set -euo pipefail
umask 022

# ============================================================================
# Configuration
# ============================================================================
VERSION="${VERSION:-}"
OWNER="${OWNER:-hotschmoe}"
REPO="${REPO:-beads_zig}"
BINARY_NAME="bz"
DEST_DEFAULT="$HOME/.local/bin"
DEST="${DEST:-$DEST_DEFAULT}"
QUIET=0
VERIFY=0
UNINSTALL=0
CHECKSUM="${CHECKSUM:-}"
LOCK_FILE="/tmp/bz-install.lock"
SYSTEM=0
MAX_RETRIES=3
DOWNLOAD_TIMEOUT=120
INSTALLER_VERSION="1.0.0"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ============================================================================
# Output functions
# ============================================================================
print_banner() {
    [ "$QUIET" -eq 1 ] && return 0
    echo ""
    echo -e "${BOLD}${BLUE}+--------------------------------------------------+${NC}"
    echo -e "${BOLD}${BLUE}|${NC}  ${BOLD}${GREEN}bz installer${NC}                                    ${BOLD}${BLUE}|${NC}"
    echo -e "${BOLD}${BLUE}|${NC}  ${DIM}Local-first issue tracker (beads_zig)${NC}            ${BOLD}${BLUE}|${NC}"
    echo -e "${BOLD}${BLUE}+--------------------------------------------------+${NC}"
    echo ""
}

log_info() {
    [ "$QUIET" -eq 1 ] && return 0
    echo -e "${GREEN}[bz]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[bz]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[bz]${NC} $1" >&2
}

log_step() {
    [ "$QUIET" -eq 1 ] && return 0
    echo -e "${BLUE}->${NC} $1" >&2
}

log_success() {
    [ "$QUIET" -eq 1 ] && return 0
    echo -e "${GREEN}[ok]${NC} $1" >&2
}

die() {
    log_error "$@"
    exit 1
}

# ============================================================================
# Usage / Help
# ============================================================================
usage() {
    cat <<'EOF'
bz installer - Install beads_zig (bz) CLI tool

Usage:
  curl -fsSL https://raw.githubusercontent.com/hotschmoe/beads_zig/master/install.sh | bash
  curl -fsSL .../install.sh | bash -s -- [OPTIONS]

Options:
  --version vX.Y.Z   Install specific version (default: latest)
  --dest DIR         Install to DIR (default: ~/.local/bin)
  --system           Install to /usr/local/bin (requires sudo)
  --checksum SHA     Provide expected SHA256 checksum
  --verify           Run self-test after install
  --quiet            Suppress non-error output
  --uninstall        Remove bz and clean up

Environment Variables:
  BZ_INSTALL_DIR     Override default install directory
  VERSION            Override version to install

Platforms:
  * Linux x86_64
  * Linux ARM64 (aarch64)
  * macOS Intel (x86_64)
  * macOS Apple Silicon (aarch64)
  * Windows x86_64 (via WSL or manual)

Examples:
  # Default install
  curl -fsSL .../install.sh | bash

  # System-wide install
  curl -fsSL .../install.sh | sudo bash -s -- --system

  # Specific version
  curl -fsSL .../install.sh | bash -s -- --version v0.1.5

  # Uninstall
  curl -fsSL .../install.sh | bash -s -- --uninstall
EOF
    exit 0
}

# ============================================================================
# Argument Parsing
# ============================================================================
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="$2"; shift 2;;
        --version=*) VERSION="${1#*=}"; shift;;
        --dest) DEST="$2"; shift 2;;
        --dest=*) DEST="${1#*=}"; shift;;
        --system) SYSTEM=1; DEST="/usr/local/bin"; shift;;
        --verify) VERIFY=1; shift;;
        --checksum) CHECKSUM="$2"; shift 2;;
        --quiet|-q) QUIET=1; shift;;
        --uninstall) UNINSTALL=1; shift;;
        -h|--help) usage;;
        *) shift;;
    esac
done

# Environment variable overrides
[ -n "${BZ_INSTALL_DIR:-}" ] && DEST="$BZ_INSTALL_DIR"

# ============================================================================
# Uninstall
# ============================================================================
do_uninstall() {
    print_banner
    log_step "Uninstalling bz..."

    if [ -f "$DEST/$BINARY_NAME" ]; then
        rm -f "$DEST/$BINARY_NAME"
        log_success "Removed $DEST/$BINARY_NAME"
    else
        log_warn "Binary not found at $DEST/$BINARY_NAME"
    fi

    # Remove PATH modifications from shell rc files
    for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
        if [ -f "$rc" ] && grep -q "# bz installer" "$rc" 2>/dev/null; then
            if [[ "$OSTYPE" == "darwin"* ]]; then
                sed -i '' '/# bz installer/d' "$rc" 2>/dev/null || true
            else
                sed -i '/# bz installer/d' "$rc" 2>/dev/null || true
            fi
            log_step "Cleaned $rc"
        fi
    done

    log_success "bz uninstalled successfully"
    exit 0
}

[ "$UNINSTALL" -eq 1 ] && do_uninstall

# ============================================================================
# Platform Detection
# ============================================================================
detect_platform() {
    local os arch

    case "$(uname -s)" in
        Linux*)  os="linux" ;;
        Darwin*) os="macos" ;;
        MINGW*|MSYS*|CYGWIN*) os="windows" ;;
        *) die "Unsupported OS: $(uname -s)" ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64) arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        *) die "Unsupported architecture: $(uname -m)" ;;
    esac

    echo "${os}-${arch}"
}

# ============================================================================
# Version Resolution
# ============================================================================
resolve_version() {
    if [ -n "$VERSION" ]; then return 0; fi

    log_step "Resolving latest version..."
    local latest_url="https://api.github.com/repos/${OWNER}/${REPO}/releases/latest"
    local tag=""
    local attempts=0

    # Try GitHub API with retries
    while [ $attempts -lt $MAX_RETRIES ] && [ -z "$tag" ]; do
        attempts=$((attempts + 1))

        if command -v curl &>/dev/null; then
            tag=$(curl -fsSL \
                --connect-timeout 10 \
                --max-time 30 \
                -H "Accept: application/vnd.github.v3+json" \
                "$latest_url" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || echo "")
        elif command -v wget &>/dev/null; then
            tag=$(wget -qO- --timeout=30 "$latest_url" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || echo "")
        fi

        [ -z "$tag" ] && [ $attempts -lt $MAX_RETRIES ] && sleep 2
    done

    if [ -n "$tag" ] && [[ "$tag" =~ ^v[0-9] ]]; then
        VERSION="$tag"
        log_success "Latest version: $VERSION"
        return 0
    fi

    # Fallback: try redirect-based resolution
    log_step "Trying redirect-based version resolution..."
    local redirect_url="https://github.com/${OWNER}/${REPO}/releases/latest"
    if command -v curl &>/dev/null; then
        tag=$(curl -fsSL -o /dev/null -w '%{url_effective}' "$redirect_url" 2>/dev/null | sed -E 's|.*/tag/||' || echo "")
    fi

    if [ -n "$tag" ] && [[ "$tag" =~ ^v[0-9] ]] && [[ "$tag" != *"/"* ]]; then
        VERSION="$tag"
        log_success "Latest version (via redirect): $VERSION"
        return 0
    fi

    die "Could not resolve latest version. Try specifying --version vX.Y.Z"
}

# ============================================================================
# Locking (prevent concurrent installs)
# ============================================================================
LOCK_DIR="${LOCK_FILE}.d"
LOCKED=0

acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        LOCKED=1
        echo $$ > "$LOCK_DIR/pid"
        return 0
    fi

    # Check if existing lock is stale
    if [ -f "$LOCK_DIR/pid" ]; then
        local old_pid
        old_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")

        # Check if process is still running
        if [ -n "$old_pid" ] && ! kill -0 "$old_pid" 2>/dev/null; then
            log_warn "Removing stale lock (PID $old_pid not running)"
            rm -rf "$LOCK_DIR"
            if mkdir "$LOCK_DIR" 2>/dev/null; then
                LOCKED=1
                echo $$ > "$LOCK_DIR/pid"
                return 0
            fi
        fi

        # Check lock age (5 minute timeout)
        local lock_age=0
        if [[ "$OSTYPE" == "darwin"* ]]; then
            lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR/pid" 2>/dev/null || echo 0) ))
        else
            lock_age=$(( $(date +%s) - $(stat -c %Y "$LOCK_DIR/pid" 2>/dev/null || echo 0) ))
        fi

        if [ "$lock_age" -gt 300 ]; then
            log_warn "Removing stale lock (age: ${lock_age}s)"
            rm -rf "$LOCK_DIR"
            if mkdir "$LOCK_DIR" 2>/dev/null; then
                LOCKED=1
                echo $$ > "$LOCK_DIR/pid"
                return 0
            fi
        fi
    fi

    if [ "$LOCKED" -eq 0 ]; then
        die "Another installation is running. If incorrect, run: rm -rf $LOCK_DIR"
    fi
}

# ============================================================================
# Cleanup
# ============================================================================
TMP=""
cleanup() {
    [ -n "$TMP" ] && rm -rf "$TMP"
    [ "$LOCKED" -eq 1 ] && rm -rf "$LOCK_DIR"
}
trap cleanup EXIT

# ============================================================================
# Download with retry
# ============================================================================
download_file() {
    local url="$1"
    local dest="$2"
    local attempt=0
    local partial="${dest}.part"

    while [ $attempt -lt $MAX_RETRIES ]; do
        attempt=$((attempt + 1))

        if command -v curl &>/dev/null; then
            local curl_args=(
                -fL
                --connect-timeout 30
                --max-time "$DOWNLOAD_TIMEOUT"
                --retry 2
                -o "$partial"
                "$url"
            )
            if [ "$QUIET" -eq 0 ]; then
                curl_args=(--progress-bar "${curl_args[@]}")
            else
                curl_args=(-sS "${curl_args[@]}")
            fi

            if curl "${curl_args[@]}"; then
                mv -f "$partial" "$dest"
                return 0
            fi
        elif command -v wget &>/dev/null; then
            local wget_args=(
                --timeout="$DOWNLOAD_TIMEOUT"
                -O "$partial"
                "$url"
            )
            if [ "$QUIET" -eq 0 ]; then
                wget_args=(--show-progress "${wget_args[@]}")
            else
                wget_args=(--quiet "${wget_args[@]}")
            fi

            if wget "${wget_args[@]}"; then
                mv -f "$partial" "$dest"
                return 0
            fi
        else
            die "Neither curl nor wget found"
        fi

        [ $attempt -lt $MAX_RETRIES ] && {
            log_warn "Download failed, retrying in 3s..."
            sleep 3
        }
    done

    return 1
}

# ============================================================================
# Atomic binary install
# ============================================================================
install_binary_atomic() {
    local src="$1"
    local dest="$2"
    local tmp_dest="${dest}.tmp.$$"

    install -m 0755 "$src" "$tmp_dest"
    if ! mv -f "$tmp_dest" "$dest"; then
        rm -f "$tmp_dest" 2>/dev/null || true
        die "Failed to move binary into place"
    fi
}

# ============================================================================
# Download release binary
# ============================================================================
download_release() {
    local platform="$1"

    # Binary naming convention: bz-<platform> (e.g., bz-linux-x86_64)
    local binary_name="bz-${platform}"
    if [[ "$platform" == "windows"* ]]; then
        binary_name="${binary_name}.exe"
    fi

    local url="https://github.com/${OWNER}/${REPO}/releases/download/${VERSION}/${binary_name}"
    local checksum_url="${url}.sha256"

    log_step "Downloading ${binary_name}..."
    if ! download_file "$url" "$TMP/$binary_name"; then
        return 1
    fi

    # Download and verify checksum
    local expected=""
    if [ -n "$CHECKSUM" ]; then
        expected="${CHECKSUM%% *}"
    else
        if download_file "$checksum_url" "$TMP/checksum.sha256" 2>/dev/null; then
            expected=$(awk '{print $1}' "$TMP/checksum.sha256")
        fi
    fi

    if [ -n "$expected" ]; then
        log_step "Verifying checksum..."
        local actual
        if command -v sha256sum &>/dev/null; then
            actual=$(sha256sum "$TMP/$binary_name" | awk '{print $1}')
        elif command -v shasum &>/dev/null; then
            actual=$(shasum -a 256 "$TMP/$binary_name" | awk '{print $1}')
        else
            log_warn "No SHA256 tool found, skipping verification"
            actual="$expected"
        fi

        if [ "$expected" != "$actual" ]; then
            log_error "Checksum mismatch!"
            log_error "  Expected: $expected"
            log_error "  Got:      $actual"
            return 1
        fi
        log_success "Checksum verified"
    else
        log_warn "Checksum not available, skipping verification"
    fi

    # Install binary
    chmod +x "$TMP/$binary_name"
    install_binary_atomic "$TMP/$binary_name" "$DEST/$BINARY_NAME"
    log_success "Installed to $DEST/$BINARY_NAME"
    return 0
}

# ============================================================================
# PATH handling
# ============================================================================
maybe_add_path() {
    case ":$PATH:" in
        *:"$DEST":*) return 0;;
        *)
            log_warn "Add $DEST to PATH to use bz"
            log_info "  Run: export PATH=\"$DEST:\$PATH\""
            log_info "  Or add to ~/.bashrc or ~/.zshrc for persistence"
        ;;
    esac
}

# ============================================================================
# Print installation summary
# ============================================================================
print_summary() {
    local installed_version
    installed_version=$("$DEST/$BINARY_NAME" --version 2>/dev/null || echo "unknown")

    echo ""
    log_success "bz installed successfully!"
    echo ""
    echo "  Version:  $installed_version"
    echo "  Location: $DEST/$BINARY_NAME"
    echo ""

    if [[ ":$PATH:" != *":$DEST:"* ]]; then
        echo "  To use bz, restart your shell or run:"
        echo "    export PATH=\"$DEST:\$PATH\""
        echo ""
    fi

    echo "  Quick Start:"
    echo "    bz init            Initialize a workspace"
    echo "    bz create          Create an issue"
    echo "    bz list            List issues"
    echo "    bz ready           Show ready work"
    echo "    bz --help          Full help"
    echo ""
}

# ============================================================================
# Main
# ============================================================================
main() {
    acquire_lock

    print_banner

    TMP=$(mktemp -d)

    local platform
    platform=$(detect_platform)
    log_step "Platform: $platform"
    log_step "Install directory: $DEST"

    mkdir -p "$DEST"

    resolve_version

    if download_release "$platform"; then
        # Success
        :
    else
        die "Binary download failed. Check that a release exists for $platform at version $VERSION"
    fi

    maybe_add_path

    # Verify installation
    if [ "$VERIFY" -eq 1 ]; then
        log_step "Running self-test..."
        "$DEST/$BINARY_NAME" --version || true
        log_success "Self-test complete"
    fi

    print_summary
}

# Run main only when executed directly (not when sourced for tests).
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]] || [[ -z "${BASH_SOURCE[0]:-}" ]]; then
    main "$@"
fi
