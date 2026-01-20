#!/bin/bash
#
# Rebuild temporalio/server:1.22 Docker images with correct ARM binaries
#
# PROBLEM:
#   The ARM variant of temporalio/server:1.22 was published with x86-64 binaries
#   instead of ARM aarch64 binaries.
#
# ROOT CAUSE:
#   Version 1.22 uses an OLD build system where binaries are compiled inside
#   Docker using multi-stage builds. The Dockerfile has a "temporal-builder"
#   stage that compiles the Go binaries. When building with docker buildx for
#   multiple platforms, the builder stage should compile for the target platform.
#
# SOLUTION:
#   Use docker buildx to build separate images for each platform (amd64, arm64).
#   The buildx builder with QEMU emulation ensures the Go compiler inside the
#   container targets the correct architecture.
#
# METHODOLOGY:
#   1. Checkout the docker-builds commit that corresponds to the 1.22 release
#      (commit e786597 - the most recent update to release/v1.22.x branch)
#   2. Initialize submodules to get the correct temporal server source
#   3. Use docker buildx to build separate images for amd64 and arm64
#   4. The multi-stage Dockerfile compiles binaries inside the container,
#      which ensures correct architecture when using buildx platform targeting
#
# COMMIT SELECTION:
#   The commit e786597 was selected by running:
#     ./scripts/find-version-commit.sh 1.22
#   This finds commits with message "Update temporal submodule for branch release/v1.22.x"
#   The most recent such commit (e786597 from Mar 28, 2024) contains the latest
#   1.22.x release code.
#
# Usage: ./scripts/rebuild-1.22.sh

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# The docker-builds commit for 1.22 release
# Found via: git log --all --oneline --grep="release/v1.22.x" | head -1
COMMIT="e786597"
VERSION="1.22"

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

main() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}Rebuilding server image for $VERSION${NC}"
    echo -e "${CYAN}  Commit: $COMMIT${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""

    cd "$REPO_ROOT"

    # Save current state to restore later
    local original_ref
    original_ref=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || git rev-parse HEAD)
    log_info "Current ref: $original_ref (will restore after build)"

    # Show what we're building from
    echo ""
    echo "Commit details:"
    git log -1 --format="  SHA:     %H%n  Date:    %ad%n  Message: %s" "$COMMIT"
    echo ""

    # Checkout the 1.22 release commit
    log_info "Checking out commit $COMMIT..."
    git checkout "$COMMIT"

    # Initialize submodules to get temporal server source at correct version
    log_info "Initializing submodules..."
    git submodule update --init

    # Show the temporal version we're building
    local temporal_sha
    temporal_sha=$(git submodule status -- temporal | cut -c2-40)
    log_info "Temporal submodule at: $temporal_sha"

    # Get build args for the Dockerfile
    local tctl_sha
    tctl_sha=$(git submodule status -- tctl | cut -c2-40)

    # Ensure buildx builder exists with docker-container driver
    # The docker-container driver is required for cross-platform builds
    # because it runs buildkit in a container with QEMU for emulation
    if ! docker buildx inspect builder-x >/dev/null 2>&1; then
        log_info "Creating buildx builder with docker-container driver..."
        docker buildx create --name builder-x --driver docker-container --use
    fi
    docker buildx use builder-x 2>/dev/null || true

    local image_tag="${VERSION}-rebuild"

    # Build amd64 image
    # The --platform flag tells buildx to build for linux/amd64
    # The multi-stage Dockerfile will compile Go binaries for amd64 inside the container
    log_info "Building amd64 image..."
    docker buildx build . \
        -f server.Dockerfile \
        -t "temporalio/server:${image_tag}-amd64" \
        --platform linux/amd64 \
        --build-arg TEMPORAL_SHA="$temporal_sha" \
        --build-arg TCTL_SHA="$tctl_sha" \
        --load

    # Build arm64 image
    # The --platform flag tells buildx to build for linux/arm64
    # QEMU emulation in the buildx container allows compiling ARM binaries on x86 host
    log_info "Building arm64 image..."
    docker buildx build . \
        -f server.Dockerfile \
        -t "temporalio/server:${image_tag}-arm64" \
        --platform linux/arm64 \
        --build-arg TEMPORAL_SHA="$temporal_sha" \
        --build-arg TCTL_SHA="$tctl_sha" \
        --load

    # Build admin-tools images
    # The admin-tools.Dockerfile for 1.22 uses multi-stage builds similar to server.
    # It has an admin-tools-builder stage that compiles temporal tools, and copies
    # binaries from the server image via "FROM ${SERVER_IMAGE} as server".
    #
    # IMPORTANT: We use regular `docker build` instead of `docker buildx build` here
    # because the buildx docker-container driver runs in an isolated container that
    # cannot access images loaded into the local Docker daemon. The admin-tools
    # Dockerfile needs to copy from the server image we just built, so we need
    # access to local images.
    log_info "Building admin-tools amd64 image..."
    docker build . \
        -f admin-tools.Dockerfile \
        -t "temporalio/admin-tools:${image_tag}-amd64" \
        --platform linux/amd64 \
        --build-arg SERVER_IMAGE="temporalio/server:${image_tag}-amd64"

    log_info "Building admin-tools arm64 image..."
    docker build . \
        -f admin-tools.Dockerfile \
        -t "temporalio/admin-tools:${image_tag}-arm64" \
        --platform linux/arm64 \
        --build-arg SERVER_IMAGE="temporalio/server:${image_tag}-arm64"

    # Restore original branch
    log_info "Restoring original ref: $original_ref"
    git checkout "$original_ref"
    git submodule update --init || true

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Build complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "Images built:"
    echo "  temporalio/server:${image_tag}-amd64"
    echo "  temporalio/server:${image_tag}-arm64"
    echo "  temporalio/admin-tools:${image_tag}-amd64"
    echo "  temporalio/admin-tools:${image_tag}-arm64"
    echo ""
    echo "To verify binary architectures:"
    echo "  ./scripts/verify-images.sh $VERSION"
    echo ""
    echo "To compare rebuilt vs original images:"
    echo "  ./scripts/compare-images.sh $VERSION server"
    echo "  ./scripts/compare-images.sh $VERSION admin-tools"
    echo ""
    echo "To publish to temporaliotest registry:"
    echo "  ./scripts/publish-images.sh $VERSION"
}

main "$@"
