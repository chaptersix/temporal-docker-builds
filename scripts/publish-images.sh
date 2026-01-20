#!/bin/bash
#
# Publish rebuilt Docker images to temporaliotest registry
#
# This script pushes the rebuilt multi-arch images to Docker Hub under the
# temporaliotest organization for testing before publishing to the official
# temporalio registry.
#
# Prerequisites:
#   - Docker login to Docker Hub with access to temporaliotest organization
#   - Rebuilt images exist locally (run rebuild-1.22.sh and/or rebuild-1.23.sh first)
#
# Usage: ./scripts/publish-images.sh [-y] <version>
#   -y:       Skip confirmation prompt
#   version:  "1.22" or "1.23"
#
# Examples:
#   ./scripts/publish-images.sh 1.22      # Publish with confirmation
#   ./scripts/publish-images.sh -y 1.23   # Publish without confirmation

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Registry to publish to
REGISTRY="temporaliotest"

# Skip confirmation flag
SKIP_CONFIRM=false

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if local images exist
check_local_images() {
    local version=$1
    local image_tag="${version}-rebuild"
    local missing=0

    log_info "Checking for local images..."

    local images=(
        "temporalio/server:${image_tag}-amd64"
        "temporalio/server:${image_tag}-arm64"
        "temporalio/admin-tools:${image_tag}-amd64"
        "temporalio/admin-tools:${image_tag}-arm64"
    )

    for image in "${images[@]}"; do
        if docker image inspect "$image" >/dev/null 2>&1; then
            echo "  ✓ $image"
        else
            echo -e "  ${RED}✗ $image (not found)${NC}"
            missing=$((missing + 1))
        fi
    done

    if [[ $missing -gt 0 ]]; then
        log_error "Missing $missing local images. Run rebuild-${version}.sh first."
        exit 1
    fi
}

# Push a single image to the registry
push_image() {
    local source_image=$1
    local target_image=$2

    log_info "Tagging $source_image -> $target_image"
    docker tag "$source_image" "$target_image"

    log_info "Pushing $target_image"
    docker push "$target_image"
}

# Create and push multi-arch manifest
create_and_push_manifest() {
    local manifest_tag=$1
    local amd64_image=$2
    local arm64_image=$3

    log_info "Creating manifest: $manifest_tag"

    # Remove existing manifest if present (--amend doesn't always work cleanly)
    docker manifest rm "$manifest_tag" 2>/dev/null || true

    docker manifest create "$manifest_tag" \
        "$amd64_image" \
        "$arm64_image"

    # Annotate with correct architectures
    docker manifest annotate "$manifest_tag" "$amd64_image" --arch amd64 --os linux
    docker manifest annotate "$manifest_tag" "$arm64_image" --arch arm64 --os linux

    log_info "Pushing manifest: $manifest_tag"
    docker manifest push "$manifest_tag"
}

# Confirm before pushing
confirm_push() {
    local version=$1
    local image_tag="${version}-rebuild"

    echo ""
    echo -e "${YELLOW}The following images will be pushed to ${REGISTRY}:${NC}"
    echo ""
    echo "  Server:"
    echo "    ${REGISTRY}/server:${image_tag}-amd64"
    echo "    ${REGISTRY}/server:${image_tag}-arm64"
    echo "    ${REGISTRY}/server:${image_tag} (multi-arch manifest)"
    echo ""
    echo "  Admin-tools:"
    echo "    ${REGISTRY}/admin-tools:${image_tag}-amd64"
    echo "    ${REGISTRY}/admin-tools:${image_tag}-arm64"
    echo "    ${REGISTRY}/admin-tools:${image_tag} (multi-arch manifest)"
    echo ""

    if [[ "$SKIP_CONFIRM" == "true" ]]; then
        log_info "Skipping confirmation (-y flag)"
        return
    fi

    read -p "Do you want to proceed? [y/N] " -n 1 -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Aborted by user."
        exit 0
    fi
}

# Publish images for a version
publish_version() {
    local version=$1
    local image_tag="${version}-rebuild"

    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}Publishing images for version $version${NC}"
    echo -e "${CYAN}  Target registry: $REGISTRY${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""

    # Check local images exist
    check_local_images "$version"

    # Confirm before pushing
    confirm_push "$version"

    echo ""

    # Push server images
    log_info "=== Publishing server images ==="

    push_image "temporalio/server:${image_tag}-amd64" "${REGISTRY}/server:${image_tag}-amd64"
    push_image "temporalio/server:${image_tag}-arm64" "${REGISTRY}/server:${image_tag}-arm64"

    create_and_push_manifest \
        "${REGISTRY}/server:${image_tag}" \
        "${REGISTRY}/server:${image_tag}-amd64" \
        "${REGISTRY}/server:${image_tag}-arm64"

    echo ""

    # Push admin-tools images
    log_info "=== Publishing admin-tools images ==="

    push_image "temporalio/admin-tools:${image_tag}-amd64" "${REGISTRY}/admin-tools:${image_tag}-amd64"
    push_image "temporalio/admin-tools:${image_tag}-arm64" "${REGISTRY}/admin-tools:${image_tag}-arm64"

    create_and_push_manifest \
        "${REGISTRY}/admin-tools:${image_tag}" \
        "${REGISTRY}/admin-tools:${image_tag}-amd64" \
        "${REGISTRY}/admin-tools:${image_tag}-arm64"

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Publish complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "Published images:"
    echo "  ${REGISTRY}/server:${image_tag}"
    echo "    - ${REGISTRY}/server:${image_tag}-amd64"
    echo "    - ${REGISTRY}/server:${image_tag}-arm64"
    echo ""
    echo "  ${REGISTRY}/admin-tools:${image_tag}"
    echo "    - ${REGISTRY}/admin-tools:${image_tag}-amd64"
    echo "    - ${REGISTRY}/admin-tools:${image_tag}-arm64"
    echo ""
    echo "To pull and test:"
    echo "  # Test on AMD64 machine:"
    echo "  docker run --rm ${REGISTRY}/server:${image_tag} file /usr/local/bin/temporal-server"
    echo ""
    echo "  # Test on ARM64 machine:"
    echo "  docker run --rm ${REGISTRY}/server:${image_tag} file /usr/local/bin/temporal-server"
    echo ""
    echo "To verify manifest:"
    echo "  docker manifest inspect ${REGISTRY}/server:${image_tag}"
}

usage() {
    echo "Usage: $0 [-y] <version>"
    echo ""
    echo "Arguments:"
    echo "  -y:       Skip confirmation prompt"
    echo "  version:  1.22 or 1.23"
    echo ""
    echo "Examples:"
    echo "  $0 1.22      # Publish 1.22 images (with confirmation)"
    echo "  $0 -y 1.23   # Publish 1.23 images (skip confirmation)"
    echo ""
    echo "Prerequisites:"
    echo "  - Run rebuild-<version>.sh first to build local images"
    echo "  - Docker login with access to temporaliotest organization"
}

main() {
    # Parse flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y)
                SKIP_CONFIRM=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                break
                ;;
        esac
    done

    if [[ $# -lt 1 ]]; then
        usage
        exit 1
    fi

    local version=$1

    # Validate version
    case "$version" in
        1.22|1.23)
            ;;
        *)
            log_error "Invalid version: $version"
            echo "Valid versions: 1.22, 1.23"
            exit 1
            ;;
    esac

    # Check Docker login
    if ! docker info 2>/dev/null | grep -q "Username"; then
        log_warn "You may not be logged into Docker Hub. Run 'docker login' if push fails."
    fi

    publish_version "$version"
}

main "$@"
