#!/bin/bash
#
# Verify that rebuilt Docker images contain binaries with correct architectures
#
# This script checks that:
#   - amd64 images contain x86-64 binaries
#   - arm64 images contain ARM aarch64 binaries
#
# Usage: ./scripts/verify-images.sh [version]
#   version: Optional. Specify "1.22" or "1.23" to verify only that version.
#            If not specified, verifies all versions.
#
# Examples:
#   ./scripts/verify-images.sh        # Verify all images
#   ./scripts/verify-images.sh 1.22   # Verify only 1.22 images
#   ./scripts/verify-images.sh 1.23   # Verify only 1.23 images

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ERRORS=0
CHECKED=0

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_pass() {
    echo -e "  ${GREEN}✓${NC} $1"
}

log_fail() {
    echo -e "  ${RED}✗${NC} $1"
}

# Verify a single binary's architecture from an image
# Args: image_name binary_path expected_arch_pattern arch_description
verify_binary() {
    local image=$1
    local binary_path=$2
    local expected_pattern=$3
    local arch_desc=$4
    local container_name=$5

    CHECKED=$((CHECKED + 1))

    local temp_file="/tmp/verify-binary-$$-$RANDOM"

    if ! docker cp "$container_name:$binary_path" "$temp_file" 2>/dev/null; then
        log_fail "$(basename "$binary_path") - not found at $binary_path"
        ERRORS=$((ERRORS + 1))
        return
    fi

    local file_output
    file_output=$(file "$temp_file")
    rm -f "$temp_file"

    if echo "$file_output" | grep -qE "$expected_pattern"; then
        log_pass "$(basename "$binary_path") ($arch_desc)"
    else
        log_fail "$(basename "$binary_path") - Expected $arch_desc but got: $file_output"
        ERRORS=$((ERRORS + 1))
    fi
}

# Verify all binaries in a server image
verify_server_image() {
    local image=$1
    local expected_pattern=$2
    local arch_desc=$3

    echo ""
    echo "  $image:"

    # Check if image exists
    if ! docker image inspect "$image" >/dev/null 2>&1; then
        log_fail "IMAGE NOT FOUND: $image"
        ERRORS=$((ERRORS + 1))
        return
    fi

    # Create temporary container
    local container_name="verify-$$-$RANDOM"
    if ! docker create --name "$container_name" "$image" >/dev/null 2>&1; then
        log_fail "Failed to create container from $image"
        ERRORS=$((ERRORS + 1))
        return
    fi

    # Server binaries
    local server_binaries=(
        "/usr/local/bin/temporal-server"
        "/usr/local/bin/tctl"
        "/usr/local/bin/tctl-authorization-plugin"
        "/usr/local/bin/temporal"
    )

    for binary in "${server_binaries[@]}"; do
        verify_binary "$image" "$binary" "$expected_pattern" "$arch_desc" "$container_name"
    done

    docker rm "$container_name" >/dev/null 2>&1
}

# Verify all binaries in an admin-tools image
verify_admin_tools_image() {
    local image=$1
    local expected_pattern=$2
    local arch_desc=$3

    echo ""
    echo "  $image:"

    # Check if image exists
    if ! docker image inspect "$image" >/dev/null 2>&1; then
        log_fail "IMAGE NOT FOUND: $image"
        ERRORS=$((ERRORS + 1))
        return
    fi

    # Create temporary container
    local container_name="verify-$$-$RANDOM"
    if ! docker create --name "$container_name" "$image" >/dev/null 2>&1; then
        log_fail "Failed to create container from $image"
        ERRORS=$((ERRORS + 1))
        return
    fi

    # Admin-tools binaries
    local admin_binaries=(
        "/usr/local/bin/tctl"
        "/usr/local/bin/tctl-authorization-plugin"
        "/usr/local/bin/temporal"
        "/usr/local/bin/temporal-cassandra-tool"
        "/usr/local/bin/temporal-sql-tool"
        "/usr/local/bin/tdbg"
    )

    for binary in "${admin_binaries[@]}"; do
        verify_binary "$image" "$binary" "$expected_pattern" "$arch_desc" "$container_name"
    done

    docker rm "$container_name" >/dev/null 2>&1
}

# Verify all images for a specific version
verify_version() {
    local version=$1
    local tag="${version}-rebuild"

    echo ""
    echo -e "${CYAN}=== Verifying version $version ===${NC}"

    # Server images
    echo ""
    echo -e "${YELLOW}Server images:${NC}"
    verify_server_image "temporalio/server:${tag}-amd64" "x86-64|x86_64" "x86-64"
    verify_server_image "temporalio/server:${tag}-arm64" "ARM aarch64|aarch64" "ARM aarch64"

    # Admin-tools images
    echo ""
    echo -e "${YELLOW}Admin-tools images:${NC}"
    verify_admin_tools_image "temporalio/admin-tools:${tag}-amd64" "x86-64|x86_64" "x86-64"
    verify_admin_tools_image "temporalio/admin-tools:${tag}-arm64" "ARM aarch64|aarch64" "ARM aarch64"
}

main() {
    local version_filter="${1:-}"

    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}Verifying rebuilt Docker images${NC}"
    echo -e "${CYAN}========================================${NC}"

    if [[ -n "$version_filter" ]]; then
        case "$version_filter" in
            1.22|1.23)
                verify_version "$version_filter"
                ;;
            *)
                log_error "Unknown version: $version_filter"
                echo "Valid versions: 1.22, 1.23"
                exit 1
                ;;
        esac
    else
        # Verify all versions
        verify_version "1.22"
        verify_version "1.23"
    fi

    echo ""
    echo -e "${CYAN}========================================${NC}"
    if [[ $ERRORS -eq 0 ]]; then
        echo -e "${GREEN}All $CHECKED binaries verified successfully!${NC}"
    else
        echo -e "${RED}Verification failed: $ERRORS/$CHECKED binaries have issues${NC}"
    fi
    echo -e "${CYAN}========================================${NC}"
    echo ""

    exit $ERRORS
}

main "$@"
