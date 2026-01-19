#!/bin/bash
#
# Rebuild temporalio/server:1.23 Docker images with correct ARM binaries
#
# PROBLEM:
#   The ARM variant of temporalio/server:1.23 was published with x86-64 binaries
#   instead of ARM aarch64 binaries.
#
# ROOT CAUSE:
#   Version 1.23 uses a NEW build system where binaries are pre-compiled outside
#   Docker and then copied into the image. The docker-builds Makefile has targets
#   like `amd64-bins` and `arm64-bins` that set GOOS/GOARCH environment variables.
#
#   However, there's a BUG in the temporal submodule's Makefile. The build targets
#   (temporal-server, tdbg, temporal-cassandra-tool, temporal-sql-tool) do NOT
#   pass GOOS/GOARCH to the `go build` command:
#
#     temporal-server: $(ALL_SRC)
#         CGO_ENABLED=$(CGO_ENABLED) go build ... ./cmd/server
#                                    ^^^^^^^^
#                                    Missing GOOS=$(GOOS) GOARCH=$(GOARCH)
#
#   This causes Go to use the native architecture (amd64) even when building
#   for arm64, resulting in x86-64 binaries in the arm64 directory.
#
# SOLUTION:
#   Build the temporal binaries directly using `go build` with explicit
#   GOOS and GOARCH environment variables, bypassing the broken Makefile.
#   Other binaries (tctl, cli, dockerize) are built correctly by their
#   respective Makefiles.
#
# METHODOLOGY:
#   1. Checkout the docker-builds commit for 1.23 release (commit e7a73a0)
#   2. Initialize submodules
#   3. Build non-temporal binaries using make (these work correctly)
#   4. Build temporal binaries directly with explicit GOOS/GOARCH
#   5. Verify all binaries have correct architecture before building image
#   6. Build Docker images using docker buildx bake
#
# COMMIT SELECTION:
#   The commit e7a73a0 was selected by running:
#     ./scripts/find-version-commit.sh 1.23
#   This finds commits with message "Update temporal submodule for branch release/v1.23.x"
#   The most recent such commit (e7a73a0 from Apr 30, 2024) contains the latest
#   1.23.x release code.
#
# Usage: ./scripts/rebuild-1.23.sh

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# The docker-builds commit for 1.23 release
# Found via: git log --all --oneline --grep="release/v1.23.x" | head -1
COMMIT="e7a73a0"
VERSION="1.23"

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Build temporal binaries directly with explicit GOOS/GOARCH
# This bypasses the broken Makefile that doesn't pass arch to go build
build_temporal_binaries() {
    local arch=$1
    local build_dir="$REPO_ROOT/build/$arch"

    log_info "Building temporal binaries for $arch (direct go build)..."

    mkdir -p "$build_dir"
    cd "$REPO_ROOT/temporal"

    # Build temporal-server
    # The Makefile's target doesn't pass GOOS/GOARCH to go build, so we do it directly
    log_info "  Building temporal-server..."
    GOOS=linux GOARCH="$arch" CGO_ENABLED=0 go build -tags protolegacy -o "$build_dir/temporal-server" ./cmd/server

    # Build tdbg (temporal debug tool)
    log_info "  Building tdbg..."
    GOOS=linux GOARCH="$arch" CGO_ENABLED=0 go build -tags protolegacy -o "$build_dir/tdbg" ./cmd/tools/tdbg

    # Build temporal-cassandra-tool
    log_info "  Building temporal-cassandra-tool..."
    GOOS=linux GOARCH="$arch" CGO_ENABLED=0 go build -tags protolegacy -o "$build_dir/temporal-cassandra-tool" ./cmd/tools/cassandra

    # Build temporal-sql-tool
    log_info "  Building temporal-sql-tool..."
    GOOS=linux GOARCH="$arch" CGO_ENABLED=0 go build -tags protolegacy -o "$build_dir/temporal-sql-tool" ./cmd/tools/sql

    cd "$REPO_ROOT"
}

# Build other binaries using their Makefiles (these work correctly)
build_other_binaries() {
    local arch=$1
    local build_dir="$REPO_ROOT/build/$arch"

    mkdir -p "$build_dir"

    # Build dockerize - its Makefile correctly uses GOARCH
    log_info "Building dockerize for $arch..."
    cd "$REPO_ROOT/dockerize"
    GOOS=linux GOARCH="$arch" CGO_ENABLED=0 go build -o "$build_dir/dockerize" .

    # Build temporal CLI - its Makefile correctly uses GOARCH
    log_info "Building temporal CLI for $arch..."
    cd "$REPO_ROOT/cli"
    GOOS=linux GOARCH="$arch" CGO_ENABLED=0 make build
    cp temporal "$build_dir/"

    # Build tctl - its Makefile correctly uses GOARCH
    log_info "Building tctl for $arch..."
    cd "$REPO_ROOT/tctl"
    GOOS=linux GOARCH="$arch" CGO_ENABLED=0 make build
    cp tctl "$build_dir/"
    cp tctl-authorization-plugin "$build_dir/"

    cd "$REPO_ROOT"
}

# Verify all binaries have the correct architecture
verify_binaries() {
    log_info "Verifying binary architectures..."

    local errors=0

    echo ""
    echo "Checking amd64 binaries:"
    for bin in "$REPO_ROOT/build/amd64/"*; do
        if [[ -f "$bin" ]]; then
            local arch_info
            arch_info=$(file "$bin")
            if echo "$arch_info" | grep -q "x86-64"; then
                echo -e "  ${GREEN}✓${NC} $(basename "$bin")"
            else
                echo -e "  ${RED}✗${NC} $(basename "$bin") - NOT x86-64!"
                errors=$((errors + 1))
            fi
        fi
    done

    echo ""
    echo "Checking arm64 binaries:"
    for bin in "$REPO_ROOT/build/arm64/"*; do
        if [[ -f "$bin" ]]; then
            local arch_info
            arch_info=$(file "$bin")
            if echo "$arch_info" | grep -q "ARM aarch64\|aarch64"; then
                echo -e "  ${GREEN}✓${NC} $(basename "$bin")"
            else
                echo -e "  ${RED}✗${NC} $(basename "$bin") - NOT ARM aarch64!"
                echo "      Got: $arch_info"
                errors=$((errors + 1))
            fi
        fi
    done

    echo ""

    if [[ $errors -gt 0 ]]; then
        log_error "Binary verification failed with $errors errors"
        exit 1
    fi

    log_info "All binaries verified successfully"
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

    # Checkout the 1.23 release commit
    log_info "Checking out commit $COMMIT..."
    git checkout "$COMMIT"

    # Initialize submodules to get source at correct versions
    log_info "Initializing submodules..."
    git submodule update --init

    # Show the temporal version we're building
    local temporal_sha
    temporal_sha=$(git submodule status -- temporal | cut -c2-41)
    log_info "Temporal submodule at: $temporal_sha"

    # Clean previous builds
    log_info "Cleaning previous builds..."
    rm -rf "$REPO_ROOT/build"

    # Build binaries for amd64
    log_info "=== Building amd64 binaries ==="
    build_temporal_binaries "amd64"
    build_other_binaries "amd64"

    # Build binaries for arm64
    log_info "=== Building arm64 binaries ==="
    build_temporal_binaries "arm64"
    build_other_binaries "arm64"

    # Verify all binaries before building Docker image
    verify_binaries

    # Get build args
    local tctl_sha
    tctl_sha=$(git submodule status -- tctl | cut -c2-41)

    local image_tag="${VERSION}-rebuild"

    # Ensure buildx builder exists
    if ! docker buildx inspect builder-x >/dev/null 2>&1; then
        log_info "Creating buildx builder..."
        docker buildx create --name builder-x --driver docker-container --use
    fi
    docker buildx use builder-x 2>/dev/null || true

    # Build Docker images
    # Note: docker buildx bake --load doesn't support multi-arch manifest lists
    # So we build each platform separately using docker buildx build
    # The server.Dockerfile uses TARGETARCH to select the correct binary directory

    log_info "Building amd64 Docker image..."
    docker buildx build . \
        -f server.Dockerfile \
        --target server \
        -t "temporalio/server:${image_tag}-amd64" \
        --platform linux/amd64 \
        --build-arg TEMPORAL_SHA="$temporal_sha" \
        --build-arg TCTL_SHA="$tctl_sha" \
        --load

    log_info "Building arm64 Docker image..."
    docker buildx build . \
        -f server.Dockerfile \
        --target server \
        -t "temporalio/server:${image_tag}-arm64" \
        --platform linux/arm64 \
        --build-arg TEMPORAL_SHA="$temporal_sha" \
        --build-arg TCTL_SHA="$tctl_sha" \
        --load

    # Build admin-tools images
    # The 1.23 admin-tools.Dockerfile uses pre-compiled binaries from build/${TARGETARCH}/
    # just like the server. These binaries were already built above (tctl, temporal CLI,
    # temporal-cassandra-tool, temporal-sql-tool, tdbg).
    log_info "Building admin-tools amd64 Docker image..."
    docker buildx build . \
        -f admin-tools.Dockerfile \
        -t "temporalio/admin-tools:${image_tag}-amd64" \
        --platform linux/amd64 \
        --load

    log_info "Building admin-tools arm64 Docker image..."
    docker buildx build . \
        -f admin-tools.Dockerfile \
        -t "temporalio/admin-tools:${image_tag}-arm64" \
        --platform linux/arm64 \
        --load

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
    echo "To verify the server images have correct binaries:"
    echo "  # Extract and check amd64 binary:"
    echo "  docker create --name temp temporalio/server:${image_tag}-amd64 && \\"
    echo "    docker cp temp:/usr/local/bin/temporal-server /tmp/ts && \\"
    echo "    docker rm temp && file /tmp/ts"
    echo "  # Should show: x86-64"
    echo ""
    echo "  # Extract and check arm64 binary:"
    echo "  docker create --name temp temporalio/server:${image_tag}-arm64 && \\"
    echo "    docker cp temp:/usr/local/bin/temporal-server /tmp/ts && \\"
    echo "    docker rm temp && file /tmp/ts"
    echo "  # Should show: ARM aarch64"
    echo ""
    echo "To verify the admin-tools images have correct binaries:"
    echo "  # Extract and check amd64 binary:"
    echo "  docker create --name temp temporalio/admin-tools:${image_tag}-amd64 && \\"
    echo "    docker cp temp:/usr/local/bin/tctl /tmp/tctl && \\"
    echo "    docker rm temp && file /tmp/tctl"
    echo "  # Should show: x86-64"
    echo ""
    echo "  # Extract and check arm64 binary:"
    echo "  docker create --name temp temporalio/admin-tools:${image_tag}-arm64 && \\"
    echo "    docker cp temp:/usr/local/bin/tctl /tmp/tctl && \\"
    echo "    docker rm temp && file /tmp/tctl"
    echo "  # Should show: ARM aarch64"
    echo ""
    echo "To create multi-arch manifests and push:"
    echo "  # Server"
    echo "  docker manifest create temporalio/server:$VERSION \\"
    echo "    temporalio/server:${image_tag}-amd64 \\"
    echo "    temporalio/server:${image_tag}-arm64"
    echo "  docker manifest push temporalio/server:$VERSION"
    echo ""
    echo "  # Admin-tools"
    echo "  docker manifest create temporalio/admin-tools:$VERSION \\"
    echo "    temporalio/admin-tools:${image_tag}-amd64 \\"
    echo "    temporalio/admin-tools:${image_tag}-arm64"
    echo "  docker manifest push temporalio/admin-tools:$VERSION"
}

main "$@"
