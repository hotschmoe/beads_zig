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
#   --easy-mode        Auto-configure PATH in shell rc file
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
EASY_MODE=0
MAX_RETRIES=3
DOWNLOAD_TIMEOUT=120
INSTALLER_VERSION="1.0.0"

# Terminal capability detection
IS_TTY=0
if [ -t 1 ] && [ -t 2 ]; then
    IS_TTY=1
fi

# Colors for output (disabled for non-TTY)
if [ "$IS_TTY" -eq 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
    # Cursor control
    CURSOR_HIDE='\033[?25l'
    CURSOR_SHOW='\033[?25h'
    CURSOR_UP='\033[1A'
    CLEAR_LINE='\033[2K'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    BOLD=''
    DIM=''
    NC=''
    CURSOR_HIDE=''
    CURSOR_SHOW=''
    CURSOR_UP=''
    CLEAR_LINE=''
fi

# Spinner characters (fallback for non-TTY)
SPINNER_CHARS='|/-\'
SPINNER_PID=""

# ============================================================================
# Output functions
# ============================================================================

print_banner() {
    [ "$QUIET" -eq 1 ] && return 0
    echo "" >&2
    echo -e "${BOLD}${BLUE}+--------------------------------------------------+${NC}" >&2
    echo -e "${BOLD}${BLUE}|${NC}  ${BOLD}${GREEN}bz installer${NC}                                    ${BOLD}${BLUE}|${NC}" >&2
    echo -e "${BOLD}${BLUE}|${NC}  ${DIM}Local-first issue tracker (beads_zig)${NC}            ${BOLD}${BLUE}|${NC}" >&2
    echo -e "${BOLD}${BLUE}+--------------------------------------------------+${NC}" >&2
    echo "" >&2
}

log_info() {
    [ "$QUIET" -eq 1 ] && return 0
    echo -e "    ${DIM}$1${NC}" >&2
}

log_warn() {
    echo -e "${YELLOW}[!]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[-]${NC} $1" >&2
}

log_step() {
    [ "$QUIET" -eq 1 ] && return 0
    echo -e "${CYAN}[*]${NC} $1" >&2
}

log_success() {
    [ "$QUIET" -eq 1 ] && return 0
    echo -e "${GREEN}[+]${NC} $1" >&2
}

die() {
    stop_spinner
    log_error "$@"
    exit 1
}

# ============================================================================
# Spinner functions (for TTY environments)
# ============================================================================

start_spinner() {
    local msg="${1:-Working...}"
    [ "$QUIET" -eq 1 ] && return 0
    [ "$IS_TTY" -eq 0 ] && { log_step "$msg"; return 0; }

    # Hide cursor and start spinner in background
    printf '%b' "$CURSOR_HIDE" >&2
    (
        local i=0
        local len=${#SPINNER_CHARS}
        while true; do
            local char="${SPINNER_CHARS:$i:1}"
            printf '\r%b[%s]%b %s' "$CYAN" "$char" "$NC" "$msg" >&2
            i=$(( (i + 1) % len ))
            sleep 0.1
        done
    ) &
    SPINNER_PID=$!
    disown "$SPINNER_PID" 2>/dev/null || true
}

stop_spinner() {
    if [ -n "$SPINNER_PID" ]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
        # Clear spinner line and show cursor
        if [ "$IS_TTY" -eq 1 ]; then
            printf '\r%b%b' "$CLEAR_LINE" "$CURSOR_SHOW" >&2
        fi
    fi
}

spinner_success() {
    local msg="${1:-Done}"
    stop_spinner
    log_success "$msg"
}

spinner_fail() {
    local msg="${1:-Failed}"
    stop_spinner
    log_error "$msg"
}

# ============================================================================
# Progress bar for downloads
# ============================================================================

draw_progress_bar() {
    local current="$1"
    local total="$2"
    local width="${3:-40}"
    local msg="${4:-}"

    [ "$QUIET" -eq 1 ] && return 0
    [ "$IS_TTY" -eq 0 ] && return 0
    [ "$total" -eq 0 ] && return 0

    local percent=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))

    local bar=""
    for ((i=0; i<filled; i++)); do bar+="="; done
    for ((i=0; i<empty; i++)); do bar+=" "; done

    printf '\r    [%s] %3d%% %s' "$bar" "$percent" "$msg" >&2
}

finish_progress_bar() {
    [ "$QUIET" -eq 1 ] && return 0
    [ "$IS_TTY" -eq 0 ] && return 0
    printf '\n' >&2
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
  --easy-mode        Auto-configure PATH in shell rc file
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

  # Auto-configure PATH (recommended for new users)
  curl -fsSL .../install.sh | bash -s -- --easy-mode

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
        --easy-mode) EASY_MODE=1; shift;;
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

    start_spinner "Resolving latest version..."
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
        spinner_success "Latest version: $VERSION"
        return 0
    fi

    # Fallback: try redirect-based resolution
    stop_spinner
    start_spinner "Trying redirect-based resolution..."
    local redirect_url="https://github.com/${OWNER}/${REPO}/releases/latest"
    if command -v curl &>/dev/null; then
        tag=$(curl -fsSL -o /dev/null -w '%{url_effective}' "$redirect_url" 2>/dev/null | sed -E 's|.*/tag/||' || echo "")
    fi

    if [ -n "$tag" ] && [[ "$tag" =~ ^v[0-9] ]] && [[ "$tag" != *"/"* ]]; then
        VERSION="$tag"
        spinner_success "Latest version: $VERSION"
        return 0
    fi

    spinner_fail "Could not resolve version"
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
    # Stop any running spinner and restore cursor
    stop_spinner
    if [ "$IS_TTY" -eq 1 ]; then
        printf '%b' "$CURSOR_SHOW" >&2
    fi
    # Clean up temp files and locks
    [ -n "$TMP" ] && rm -rf "$TMP"
    [ "$LOCKED" -eq 1 ] && rm -rf "$LOCK_DIR"
}
trap cleanup EXIT

# ============================================================================
# Download with retry and progress display
# ============================================================================
download_file() {
    local url="$1"
    local dest="$2"
    local show_progress="${3:-1}"
    local attempt=0
    local partial="${dest}.part"

    while [ $attempt -lt $MAX_RETRIES ]; do
        attempt=$((attempt + 1))

        if command -v curl &>/dev/null; then
            if [ "$QUIET" -eq 1 ] || [ "$IS_TTY" -eq 0 ]; then
                # Silent mode for non-TTY or quiet
                if curl -fsSL \
                    --connect-timeout 30 \
                    --max-time "$DOWNLOAD_TIMEOUT" \
                    --retry 2 \
                    -o "$partial" \
                    "$url" 2>/dev/null; then
                    mv -f "$partial" "$dest"
                    return 0
                fi
            elif [ "$show_progress" -eq 1 ]; then
                # TTY mode with custom progress using write-out
                # First get content length, then download with progress
                local content_length
                content_length=$(curl -sI -L "$url" 2>/dev/null | grep -i 'content-length' | tail -1 | awk '{print $2}' | tr -d '\r' || echo "0")

                if [ -n "$content_length" ] && [ "$content_length" -gt 0 ]; then
                    # Download with progress callback simulation
                    # Use curl's built-in progress bar for simplicity
                    if curl -fL \
                        --connect-timeout 30 \
                        --max-time "$DOWNLOAD_TIMEOUT" \
                        --retry 2 \
                        --progress-bar \
                        -o "$partial" \
                        "$url" 2>&1 | {
                            # Parse curl progress output and draw our own bar
                            while IFS= read -r line; do
                                # curl progress-bar outputs percentage
                                if [[ "$line" =~ ([0-9]+)\.?[0-9]*% ]]; then
                                    local pct="${BASH_REMATCH[1]}"
                                    draw_progress_bar "$pct" 100 40
                                fi
                            done
                        }; then
                        finish_progress_bar
                        mv -f "$partial" "$dest"
                        return 0
                    else
                        finish_progress_bar
                    fi
                else
                    # Unknown size, use spinner
                    if curl -fL \
                        --connect-timeout 30 \
                        --max-time "$DOWNLOAD_TIMEOUT" \
                        --retry 2 \
                        -# \
                        -o "$partial" \
                        "$url" 2>&1; then
                        mv -f "$partial" "$dest"
                        return 0
                    fi
                fi
            else
                # Fallback to curl's built-in progress
                if curl -fL \
                    --connect-timeout 30 \
                    --max-time "$DOWNLOAD_TIMEOUT" \
                    --retry 2 \
                    --progress-bar \
                    -o "$partial" \
                    "$url"; then
                    mv -f "$partial" "$dest"
                    return 0
                fi
            fi
        elif command -v wget &>/dev/null; then
            if [ "$QUIET" -eq 1 ] || [ "$IS_TTY" -eq 0 ]; then
                if wget --quiet \
                    --timeout="$DOWNLOAD_TIMEOUT" \
                    -O "$partial" \
                    "$url" 2>/dev/null; then
                    mv -f "$partial" "$dest"
                    return 0
                fi
            else
                if wget --show-progress \
                    --timeout="$DOWNLOAD_TIMEOUT" \
                    -O "$partial" \
                    "$url"; then
                    mv -f "$partial" "$dest"
                    return 0
                fi
            fi
        else
            die "Neither curl nor wget found"
        fi

        [ $attempt -lt $MAX_RETRIES ] && {
            log_warn "Download failed (attempt $attempt/$MAX_RETRIES), retrying in 3s..."
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

    log_step "Downloading bz ${VERSION}..."
    if [ "$IS_TTY" -eq 1 ] && [ "$QUIET" -eq 0 ]; then
        log_info "Source: github.com/${OWNER}/${REPO}"
    fi

    if ! download_file "$url" "$TMP/$binary_name" 1; then
        return 1
    fi

    # Download and verify checksum
    local expected=""
    if [ -n "$CHECKSUM" ]; then
        expected="${CHECKSUM%% *}"
    else
        start_spinner "Fetching checksum..."
        if download_file "$checksum_url" "$TMP/checksum.sha256" 0 2>/dev/null; then
            expected=$(awk '{print $1}' "$TMP/checksum.sha256")
            spinner_success "Checksum fetched"
        else
            stop_spinner
            log_warn "Checksum not available, skipping verification"
        fi
    fi

    if [ -n "$expected" ]; then
        start_spinner "Verifying checksum..."
        local actual
        if command -v sha256sum &>/dev/null; then
            actual=$(sha256sum "$TMP/$binary_name" | awk '{print $1}')
        elif command -v shasum &>/dev/null; then
            actual=$(shasum -a 256 "$TMP/$binary_name" | awk '{print $1}')
        else
            stop_spinner
            log_warn "No SHA256 tool found, skipping verification"
            actual="$expected"
        fi

        if [ "$expected" != "$actual" ]; then
            spinner_fail "Checksum mismatch!"
            log_error "  Expected: $expected"
            log_error "  Got:      $actual"
            return 1
        fi
        spinner_success "Checksum verified"
    fi

    # Install binary
    start_spinner "Installing binary..."
    chmod +x "$TMP/$binary_name"
    install_binary_atomic "$TMP/$binary_name" "$DEST/$BINARY_NAME"
    spinner_success "Installed to $DEST/$BINARY_NAME"
    return 0
}

# ============================================================================
# PATH handling
# ============================================================================

# Detect the user's shell and corresponding rc file
detect_shell_rc() {
    local shell_name rc_file

    # Check $SHELL first
    shell_name=$(basename "${SHELL:-}")

    case "$shell_name" in
        bash)
            # Prefer .bashrc, fall back to .bash_profile
            if [ -f "$HOME/.bashrc" ]; then
                rc_file="$HOME/.bashrc"
            elif [ -f "$HOME/.bash_profile" ]; then
                rc_file="$HOME/.bash_profile"
            else
                rc_file="$HOME/.bashrc"
            fi
            ;;
        zsh)
            rc_file="$HOME/.zshrc"
            ;;
        fish)
            # Fish uses a different config location
            rc_file="$HOME/.config/fish/config.fish"
            ;;
        *)
            # Fallback: check for common rc files
            if [ -f "$HOME/.bashrc" ]; then
                rc_file="$HOME/.bashrc"
                shell_name="bash"
            elif [ -f "$HOME/.zshrc" ]; then
                rc_file="$HOME/.zshrc"
                shell_name="zsh"
            elif [ -f "$HOME/.config/fish/config.fish" ]; then
                rc_file="$HOME/.config/fish/config.fish"
                shell_name="fish"
            else
                rc_file="$HOME/.profile"
                shell_name="sh"
            fi
            ;;
    esac

    echo "$shell_name:$rc_file"
}

# Check if PATH entry already exists in rc file
path_already_configured() {
    local rc_file="$1"
    local shell_name="$2"

    [ ! -f "$rc_file" ] && return 1

    if [ "$shell_name" = "fish" ]; then
        grep -q "fish_add_path.*$DEST" "$rc_file" 2>/dev/null && return 0
        grep -q "set.*PATH.*$DEST" "$rc_file" 2>/dev/null && return 0
    else
        grep -q "PATH.*$DEST" "$rc_file" 2>/dev/null && return 0
    fi

    return 1
}

# Backup rc file before modification
backup_rc_file() {
    local rc_file="$1"
    local backup="${rc_file}.bz-backup.$(date +%Y%m%d%H%M%S)"

    if [ -f "$rc_file" ]; then
        cp "$rc_file" "$backup"
        log_info "Backed up $rc_file to $backup"
        echo "$backup"
    else
        echo ""
    fi
}

# Configure PATH in the appropriate rc file
configure_path_easy_mode() {
    local shell_info rc_file shell_name backup_file path_line

    # Check if already in PATH
    case ":$PATH:" in
        *:"$DEST":*)
            log_success "PATH already includes $DEST"
            return 0
            ;;
    esac

    shell_info=$(detect_shell_rc)
    shell_name="${shell_info%%:*}"
    rc_file="${shell_info#*:}"

    log_step "Detected shell: ${BOLD}$shell_name${NC}"
    log_step "Config file: ${BOLD}$rc_file${NC}"

    # Check if already configured in rc file
    if path_already_configured "$rc_file" "$shell_name"; then
        log_success "PATH already configured in $rc_file"
        log_info "Restart your shell or run: source $rc_file"
        return 0
    fi

    # Ensure parent directory exists (for fish)
    local rc_dir
    rc_dir=$(dirname "$rc_file")
    if [ ! -d "$rc_dir" ]; then
        mkdir -p "$rc_dir"
    fi

    # Backup existing rc file
    start_spinner "Backing up $rc_file..."
    backup_file=$(backup_rc_file "$rc_file")
    if [ -n "$backup_file" ]; then
        spinner_success "Created backup: $(basename "$backup_file")"
    else
        stop_spinner
        log_info "No existing $rc_file to backup"
    fi

    # Add PATH configuration
    start_spinner "Configuring PATH..."

    if [ "$shell_name" = "fish" ]; then
        # Fish uses a different syntax
        path_line="fish_add_path $DEST  # bz installer"
    else
        # Bash, zsh, sh compatible
        path_line="export PATH=\"$DEST:\$PATH\"  # bz installer"
    fi

    # Append to rc file with newlines for safety
    {
        echo ""
        echo "# Added by bz installer ($(date +%Y-%m-%d))"
        echo "$path_line"
    } >> "$rc_file"

    spinner_success "Added PATH to $rc_file"

    # Show what was added
    echo "" >&2
    echo -e "    ${DIM}Added to $rc_file:${NC}" >&2
    echo -e "    ${CYAN}$path_line${NC}" >&2
    echo "" >&2

    # Try to source the rc file or instruct user
    if [ "$shell_name" = "fish" ]; then
        log_info "Run: source $rc_file"
        log_info "Or restart your terminal"
    elif [ -n "${BASH_VERSION:-}" ] || [ -n "${ZSH_VERSION:-}" ]; then
        # We're running in bash or zsh, can source directly
        log_step "To use bz now, run:"
        echo -e "    ${CYAN}source $rc_file${NC}" >&2
        echo "" >&2
    else
        log_info "Restart your terminal or run: source $rc_file"
    fi

    return 0
}

maybe_add_path() {
    # If easy-mode is enabled, configure PATH automatically
    if [ "$EASY_MODE" -eq 1 ]; then
        configure_path_easy_mode
        return $?
    fi

    # Otherwise just warn if not in PATH
    case ":$PATH:" in
        *:"$DEST":*) return 0;;
        *)
            # Don't warn here, let print_summary handle it
            :
        ;;
    esac
}

# ============================================================================
# Print installation summary
# ============================================================================
print_summary() {
    [ "$QUIET" -eq 1 ] && return 0

    local installed_version
    installed_version=$("$DEST/$BINARY_NAME" --version 2>/dev/null || echo "unknown")

    echo "" >&2
    echo -e "${GREEN}[+]${NC} ${BOLD}Installation complete!${NC}" >&2
    echo "" >&2
    echo -e "    ${DIM}Version:${NC}  $installed_version" >&2
    echo -e "    ${DIM}Location:${NC} $DEST/$BINARY_NAME" >&2
    echo "" >&2

    # Only show PATH warning if easy-mode wasn't used
    if [ "$EASY_MODE" -eq 0 ] && [[ ":$PATH:" != *":$DEST:"* ]]; then
        echo -e "${YELLOW}[!]${NC} $DEST is not in your PATH" >&2
        echo "" >&2
        echo "    To use bz, restart your shell or run:" >&2
        echo -e "    ${CYAN}export PATH=\"$DEST:\$PATH\"${NC}" >&2
        echo "" >&2
        echo "    Or re-run with --easy-mode to configure automatically:" >&2
        echo -e "    ${CYAN}curl -fsSL .../install.sh | bash -s -- --easy-mode${NC}" >&2
        echo "" >&2
    fi

    log_success "Run 'bz --help' to get started"
    echo "" >&2
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

    # Format platform for display
    local display_os display_arch
    case "$platform" in
        linux-x86_64)  display_os="Linux"; display_arch="x86_64" ;;
        linux-aarch64) display_os="Linux"; display_arch="ARM64" ;;
        macos-x86_64)  display_os="macOS"; display_arch="Intel" ;;
        macos-aarch64) display_os="macOS"; display_arch="Apple Silicon" ;;
        windows-x86_64) display_os="Windows"; display_arch="x86_64" ;;
        *) display_os="$platform"; display_arch="" ;;
    esac

    log_step "Detecting platform... ${BOLD}${display_os} ${display_arch}${NC}"

    start_spinner "Creating install directory..."
    mkdir -p "$DEST"
    spinner_success "Install directory: $DEST"

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
        start_spinner "Running self-test..."
        if "$DEST/$BINARY_NAME" --version >/dev/null 2>&1; then
            spinner_success "Self-test passed"
        else
            spinner_fail "Self-test failed (binary may still work)"
        fi
    fi

    print_summary
}

# Run main only when executed directly (not when sourced for tests).
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]] || [[ -z "${BASH_SOURCE[0]:-}" ]]; then
    main "$@"
fi
