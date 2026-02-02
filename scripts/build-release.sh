#!/usr/bin/env bash
#
# Build release binaries for all supported platforms
# Creates binaries with SHA256 checksums for GitHub Releases
#
# Usage:
#   ./scripts/build-release.sh [OPTIONS]
#
# Options:
#   --native-only     Only build for current platform
#   --version X.Y.Z   Override version (default: from build.zig.zon)
#   --dry-run         Show what would be built without building
#   --help            Show this help
#
# Output:
#   ./release/
#     bz-linux-x86_64
#     bz-linux-x86_64.sha256
#     bz-linux-aarch64
#     bz-linux-aarch64.sha256
#     bz-macos-x86_64
#     bz-macos-x86_64.sha256
#     bz-macos-aarch64
#     bz-macos-aarch64.sha256
#     bz-windows-x86_64.exe
#     bz-windows-x86_64.exe.sha256
#
set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
readonly BINARY_NAME="bz"
readonly PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly RELEASE_DIR="${PROJECT_ROOT}/release"

# Zig target triples for cross-compilation
readonly TARGETS=(
    "x86_64-linux"
    "aarch64-linux"
    "x86_64-macos"
    "aarch64-macos"
    "x86_64-windows"
)

# Map Zig target to output name suffix
declare -A TARGET_SUFFIX=(
    ["x86_64-linux"]="linux-x86_64"
    ["aarch64-linux"]="linux-aarch64"
    ["x86_64-macos"]="macos-x86_64"
    ["aarch64-macos"]="macos-aarch64"
    ["x86_64-windows"]="windows-x86_64"
)

# ============================================================================
# Functions
# ============================================================================
log() {
    echo -e "\033[32m->\033[0m $*"
}

warn() {
    echo -e "\033[33m!!\033[0m $*" >&2
}

error() {
    echo -e "\033[31mxx\033[0m $*" >&2
    exit 1
}

get_version() {
    # Extract version from build.zig.zon
    grep '\.version' "${PROJECT_ROOT}/build.zig.zon" | head -1 | sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/'
}

detect_native_target() {
    local os arch

    case "$(uname -s)" in
        Linux*)  os="linux" ;;
        Darwin*) os="macos" ;;
        MINGW*|MSYS*|CYGWIN*) os="windows" ;;
        *) error "Unsupported OS: $(uname -s)" ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64) arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        *) error "Unsupported architecture: $(uname -m)" ;;
    esac

    echo "${arch}-${os}"
}

check_requirements() {
    log "Checking requirements..."

    if ! command -v zig &>/dev/null; then
        error "zig not found. Please install Zig 0.15.2 or later."
    fi

    local zig_version
    zig_version=$(zig version)
    log "Zig version: $zig_version"
}

build_target() {
    local target="$1"
    local version="$2"
    local suffix="${TARGET_SUFFIX[$target]}"
    local output_name="${BINARY_NAME}-${suffix}"

    if [[ "$target" == *"windows"* ]]; then
        output_name="${output_name}.exe"
    fi

    log "Building for $target -> $output_name"

    # Build with Zig cross-compilation
    cd "$PROJECT_ROOT"

    if ! zig build \
        -Doptimize=ReleaseSafe \
        -Dtarget="${target}" \
        2>&1; then
        warn "Failed to build for $target"
        return 1
    fi

    # Find the built binary
    local binary_path="zig-out/bin/${BINARY_NAME}"
    if [[ "$target" == *"windows"* ]]; then
        binary_path="${binary_path}.exe"
    fi

    if [[ ! -f "$binary_path" ]]; then
        warn "Binary not found at $binary_path"
        return 1
    fi

    # Copy to release directory
    cp "$binary_path" "${RELEASE_DIR}/${output_name}"
    chmod +x "${RELEASE_DIR}/${output_name}"

    # Generate checksum
    local checksum_file="${RELEASE_DIR}/${output_name}.sha256"
    if command -v sha256sum &>/dev/null; then
        sha256sum "${RELEASE_DIR}/${output_name}" | awk '{print $1}' > "$checksum_file"
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "${RELEASE_DIR}/${output_name}" | awk '{print $1}' > "$checksum_file"
    else
        warn "No SHA256 tool found, skipping checksum"
    fi

    # Get file size
    local size
    if [[ "$(uname -s)" == "Darwin" ]]; then
        size=$(stat -f %z "${RELEASE_DIR}/${output_name}" 2>/dev/null || echo "unknown")
    else
        size=$(stat -c %s "${RELEASE_DIR}/${output_name}" 2>/dev/null || echo "unknown")
    fi

    # Format size nicely
    if [[ "$size" != "unknown" ]]; then
        if [[ "$size" -gt 1048576 ]]; then
            size="$((size / 1048576))MB"
        elif [[ "$size" -gt 1024 ]]; then
            size="$((size / 1024))KB"
        else
            size="${size}B"
        fi
    fi

    log "  Created: $output_name ($size)"
    return 0
}

clean_release_dir() {
    log "Preparing release directory..."
    if [[ -d "$RELEASE_DIR" ]]; then
        # Move existing to backup instead of deleting (per CLAUDE.md policy)
        local ts
        ts="$(date +%Y%m%d_%H%M%S)"
        local backup="${RELEASE_DIR}.${ts}"
        log "  Moving existing release/ to ${backup}"
        mv "$RELEASE_DIR" "$backup"
    fi
    mkdir -p "$RELEASE_DIR"
}

list_artifacts() {
    echo ""
    log "Release artifacts in ${RELEASE_DIR}:"
    echo ""

    local count=0
    for file in "${RELEASE_DIR}"/${BINARY_NAME}-*; do
        if [[ -f "$file" && ! "$file" == *.sha256 ]]; then
            local size
            if [[ "$(uname -s)" == "Darwin" ]]; then
                size=$(du -h "$file" | cut -f1)
            else
                size=$(du -h "$file" | cut -f1)
            fi

            local checksum="none"
            if [[ -f "${file}.sha256" ]]; then
                checksum=$(cat "${file}.sha256")
            fi

            echo "  $(basename "$file") ($size)"
            echo "    SHA256: $checksum"
            count=$((count + 1))
        fi
    done

    if [[ $count -eq 0 ]]; then
        warn "No artifacts built"
    else
        echo ""
        log "Built $count binaries"
        echo ""
        log "Next steps:"
        echo "  1. Test binaries locally"
        echo "  2. Create git tag: git tag -a v\$VERSION -m 'Release v\$VERSION'"
        echo "  3. Push tag: git push origin v\$VERSION"
        echo "  4. CI will create GitHub release with these binaries"
    fi
}

build_native_only() {
    local version="$1"
    local native_target
    native_target=$(detect_native_target)

    log "Building native target only: $native_target"
    build_target "$native_target" "$version"
}

show_dry_run() {
    local version="$1"
    local targets_to_build=("${@:2}")

    echo ""
    log "Dry run - would build the following:"
    echo ""
    echo "  Version: v${version}"
    echo "  Output:  ${RELEASE_DIR}/"
    echo ""
    echo "  Targets:"
    for target in "${targets_to_build[@]}"; do
        local suffix="${TARGET_SUFFIX[$target]}"
        local output_name="${BINARY_NAME}-${suffix}"
        if [[ "$target" == *"windows"* ]]; then
            output_name="${output_name}.exe"
        fi
        echo "    $target -> $output_name"
    done
    echo ""
}

usage() {
    cat <<'EOF'
Build release binaries for beads_zig

Usage:
  ./scripts/build-release.sh [OPTIONS]

Options:
  --native-only     Only build for current platform
  --version X.Y.Z   Override version (default: from build.zig.zon)
  --dry-run         Show what would be built without building
  --help            Show this help

Output:
  Creates binaries in ./release/ directory:
    bz-linux-x86_64        Linux AMD64
    bz-linux-aarch64       Linux ARM64
    bz-macos-x86_64        macOS Intel
    bz-macos-aarch64       macOS Apple Silicon
    bz-windows-x86_64.exe  Windows AMD64

Examples:
  # Build all platforms
  ./scripts/build-release.sh

  # Build only for current platform
  ./scripts/build-release.sh --native-only

  # See what would be built
  ./scripts/build-release.sh --dry-run
EOF
    exit 0
}

# ============================================================================
# Main
# ============================================================================
main() {
    local version=""
    local native_only=false
    local dry_run=false

    # Parse args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --native-only)
                native_only=true
                shift
                ;;
            --version)
                version="$2"
                shift 2
                ;;
            --version=*)
                version="${1#*=}"
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --help|-h)
                usage
                ;;
            *)
                shift
                ;;
        esac
    done

    # Get version if not provided
    if [[ -z "$version" ]]; then
        version="$(get_version)"
    fi

    log "Building release v${version}"

    # Determine targets
    local targets_to_build=()
    if [[ "$native_only" == "true" ]]; then
        targets_to_build=("$(detect_native_target)")
    else
        targets_to_build=("${TARGETS[@]}")
    fi

    # Handle dry run
    if [[ "$dry_run" == "true" ]]; then
        show_dry_run "$version" "${targets_to_build[@]}"
        exit 0
    fi

    check_requirements
    clean_release_dir

    local success_count=0
    local fail_count=0

    for target in "${targets_to_build[@]}"; do
        if build_target "$target" "$version"; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    done

    list_artifacts

    if [[ $fail_count -gt 0 ]]; then
        warn "$fail_count targets failed to build"
        exit 1
    fi
}

main "$@"
