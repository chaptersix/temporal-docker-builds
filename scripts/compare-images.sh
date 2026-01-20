#!/usr/bin/env bash
#
# Compare rebuilt Docker images to original published images
#
# This script compares the rebuilt images to the original images on Docker Hub,
# showing differences in included binaries and scripts (excluding alpine-provided tools).
#
# Usage: ./scripts/compare-images.sh <version> <image_type> [arch]
#   version:    "1.22" or "1.23"
#   image_type: "server" or "admin-tools"
#   arch:       Optional. "amd64" or "arm64". Defaults to "arm64" (the problematic arch)
#
# Examples:
#   ./scripts/compare-images.sh 1.22 server
#   ./scripts/compare-images.sh 1.23 admin-tools amd64
#   ./scripts/compare-images.sh 1.23 server arm64

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Get file listing with metadata from an image
# Output format: PATH|SIZE
get_file_listing() {
    local image=$1

    docker run --rm --entrypoint="" "$image" sh -c "
        for dir in /usr/local/bin /etc/temporal; do
            if [ -d \"\$dir\" ]; then
                find \"\$dir\" -type f 2>/dev/null | while read -r f; do
                    size=\$(stat -c '%s' \"\$f\" 2>/dev/null || echo 0)
                    echo \"\$f|\$size\"
                done
            fi
        done
    " 2>/dev/null | sort || true
}

# Format bytes to human readable
format_size() {
    local bytes=$1
    if [[ $bytes -ge 1048576 ]]; then
        awk "BEGIN {printf \"%.1fMB\", $bytes/1048576}"
    elif [[ $bytes -ge 1024 ]]; then
        awk "BEGIN {printf \"%.1fKB\", $bytes/1024}"
    else
        echo "${bytes}B"
    fi
}

# Get binary architecture from an image
get_binary_arch() {
    local image=$1
    local binary_path=$2
    local container_name="binarch-$$-$RANDOM"
    local temp_file="/tmp/binarch-$$"

    docker create --name "$container_name" "$image" >/dev/null 2>&1

    local result="NOT FOUND"
    if docker cp "$container_name:$binary_path" "$temp_file" 2>/dev/null; then
        local file_out
        file_out=$(file "$temp_file")
        if echo "$file_out" | grep -q "x86-64\|x86_64"; then
            result="x86-64"
        elif echo "$file_out" | grep -q "ARM aarch64\|aarch64"; then
            result="ARM64"
        else
            result="unknown"
        fi
        rm -f "$temp_file"
    fi

    docker rm "$container_name" >/dev/null 2>&1
    echo "$result"
}

# Show tree diff between two images
show_tree_diff() {
    local original_image=$1
    local rebuilt_image=$2

    echo ""
    echo -e "${YELLOW}=== File Tree Comparison (differences only) ===${NC}"
    echo ""

    log_info "Building file trees..."

    local orig_listing rebuilt_listing
    orig_listing=$(get_file_listing "$original_image")
    rebuilt_listing=$(get_file_listing "$rebuilt_image")

    # Create temp files for comparison
    local orig_file="/tmp/orig_listing_$$"
    local rebuilt_file="/tmp/rebuilt_listing_$$"

    echo "$orig_listing" > "$orig_file"
    echo "$rebuilt_listing" > "$rebuilt_file"

    # Get unique directories
    local all_dirs
    all_dirs=$(cat "$orig_file" "$rebuilt_file" | cut -d'|' -f1 | xargs -I{} dirname {} | sort -u)

    local has_diff=false

    for dir in $all_dirs; do
        local dir_output=""
        local dir_has_diff=false

        # Get files in this directory from both
        local orig_dir_files rebuilt_dir_files
        orig_dir_files=$(grep "^${dir}/[^/]*|" "$orig_file" 2>/dev/null || true)
        rebuilt_dir_files=$(grep "^${dir}/[^/]*|" "$rebuilt_file" 2>/dev/null || true)

        # Get all file names in this directory
        local all_files
        all_files=$(echo -e "${orig_dir_files}\n${rebuilt_dir_files}" | cut -d'|' -f1 | xargs -I{} basename {} 2>/dev/null | sort -u)

        for name in $all_files; do
            [[ -z "$name" ]] && continue
            local path="${dir}/${name}"

            local orig_line rebuilt_line
            orig_line=$(grep "^${path}|" "$orig_file" 2>/dev/null | head -1 || true)
            rebuilt_line=$(grep "^${path}|" "$rebuilt_file" 2>/dev/null | head -1 || true)

            if [[ -n "$orig_line" && -z "$rebuilt_line" ]]; then
                # Only in original
                dir_has_diff=true
                local size=$(echo "$orig_line" | cut -d'|' -f2)
                local size_fmt=$(format_size "$size")
                dir_output+="  ${RED}- ${name}${NC} ${DIM}[${size_fmt}]${NC}\n"
            elif [[ -z "$orig_line" && -n "$rebuilt_line" ]]; then
                # Only in rebuilt
                dir_has_diff=true
                local size=$(echo "$rebuilt_line" | cut -d'|' -f2)
                local size_fmt=$(format_size "$size")
                dir_output+="  ${GREEN}+ ${name}${NC} ${DIM}[${size_fmt}]${NC}\n"
            else
                # In both - check size
                local orig_size=$(echo "$orig_line" | cut -d'|' -f2)
                local rebuilt_size=$(echo "$rebuilt_line" | cut -d'|' -f2)

                if [[ "$orig_size" != "$rebuilt_size" ]]; then
                    dir_has_diff=true
                    local orig_fmt=$(format_size "$orig_size")
                    local rebuilt_fmt=$(format_size "$rebuilt_size")
                    local diff_bytes=$((rebuilt_size - orig_size))
                    local diff_sign="+"
                    [[ $diff_bytes -lt 0 ]] && diff_sign=""
                    dir_output+="  ${YELLOW}~ ${name}${NC} ${DIM}[${orig_fmt} → ${rebuilt_fmt} (${diff_sign}${diff_bytes})]${NC}\n"
                fi
            fi
        done

        if [[ "$dir_has_diff" == "true" ]]; then
            has_diff=true
            echo -e "${CYAN}${dir}/${NC}"
            echo -e "$dir_output"
        fi
    done

    rm -f "$orig_file" "$rebuilt_file"

    if [[ "$has_diff" == "false" ]]; then
        echo -e "${GREEN}No differences in file tree${NC}"
    fi
    echo ""
}

# Compare binary architectures
compare_binary_architectures() {
    local original_image=$1
    local rebuilt_image=$2
    local image_type=$3

    echo -e "${YELLOW}=== Binary Architecture Comparison ===${NC}"
    echo ""

    local binaries
    if [[ "$image_type" == "server" ]]; then
        binaries="temporal-server tctl tctl-authorization-plugin temporal dockerize"
    else
        binaries="tctl tctl-authorization-plugin temporal temporal-cassandra-tool temporal-sql-tool tdbg"
    fi

    printf "  %-30s %12s %12s\n" "Binary" "Original" "Rebuilt"
    printf "  %-30s %12s %12s\n" "------------------------------" "------------" "------------"

    for name in $binaries; do
        local binary="/usr/local/bin/$name"
        local orig_arch=$(get_binary_arch "$original_image" "$binary")
        local rebuilt_arch=$(get_binary_arch "$rebuilt_image" "$binary")

        local color=$NC
        if [[ "$orig_arch" != "$rebuilt_arch" ]]; then
            color=$YELLOW
        fi

        printf "  ${color}%-30s %12s %12s${NC}\n" "$name" "$orig_arch" "$rebuilt_arch"
    done
    echo ""
}

# Compare shell scripts (should be identical)
compare_shell_scripts() {
    local original_image=$1
    local rebuilt_image=$2

    echo -e "${YELLOW}=== Shell Script Comparison ===${NC}"
    echo ""

    # Find all .sh files
    local scripts
    scripts=$(docker run --rm --entrypoint="" "$rebuilt_image" sh -c "
        for dir in /usr/local/bin /etc/temporal; do
            if [ -d \"\$dir\" ]; then
                find \"\$dir\" -name '*.sh' -type f 2>/dev/null
            fi
        done
    " 2>/dev/null || true)

    if [[ -z "$scripts" ]]; then
        echo "  No shell scripts found"
        echo ""
        return 0
    fi

    local errors=0
    local container_orig="scriptorig-$$-$RANDOM"
    local container_rebuilt="scriptrebuilt-$$-$RANDOM"

    docker create --name "$container_orig" "$original_image" >/dev/null 2>&1
    docker create --name "$container_rebuilt" "$rebuilt_image" >/dev/null 2>&1

    echo "$scripts" | while IFS= read -r script; do
        [[ -z "$script" ]] && continue

        local temp_orig="/tmp/script-orig-$$"
        local temp_rebuilt="/tmp/script-rebuilt-$$"

        local orig_exists=false
        local rebuilt_exists=false

        if docker cp "$container_orig:$script" "$temp_orig" 2>/dev/null; then
            orig_exists=true
        fi

        if docker cp "$container_rebuilt:$script" "$temp_rebuilt" 2>/dev/null; then
            rebuilt_exists=true
        fi

        if [[ "$orig_exists" == "true" && "$rebuilt_exists" == "true" ]]; then
            if diff -q "$temp_orig" "$temp_rebuilt" >/dev/null 2>&1; then
                echo -e "  ${GREEN}✓${NC} $script ${DIM}(identical)${NC}"
            else
                echo -e "  ${RED}✗${NC} $script ${RED}(DIFFERENT!)${NC}"
                echo "    Diff:"
                diff "$temp_orig" "$temp_rebuilt" 2>/dev/null | head -10 | sed 's/^/      /'
            fi
        elif [[ "$orig_exists" == "true" ]]; then
            echo -e "  ${RED}✗${NC} $script ${RED}(missing in rebuilt)${NC}"
        elif [[ "$rebuilt_exists" == "true" ]]; then
            echo -e "  ${YELLOW}+${NC} $script ${YELLOW}(only in rebuilt)${NC}"
        fi

        rm -f "$temp_orig" "$temp_rebuilt"
    done

    docker rm "$container_orig" >/dev/null 2>&1
    docker rm "$container_rebuilt" >/dev/null 2>&1

    echo ""
}

# Compare two images
compare_images() {
    local original_image=$1
    local rebuilt_image=$2
    local image_type=$3

    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}Comparing images${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""
    echo "Original: $original_image"
    echo "Rebuilt:  $rebuilt_image"
    echo ""

    # Check if images exist
    log_info "Checking image availability..."

    if ! docker image inspect "$rebuilt_image" >/dev/null 2>&1; then
        log_error "Rebuilt image not found: $rebuilt_image"
        exit 1
    fi

    # Pull original if not present
    if ! docker image inspect "$original_image" >/dev/null 2>&1; then
        log_info "Pulling original image: $original_image"
        if ! docker pull "$original_image" 2>/dev/null; then
            log_error "Failed to pull original image: $original_image"
            exit 1
        fi
    fi

    # Tree comparison
    show_tree_diff "$original_image" "$rebuilt_image"

    # Binary architecture comparison
    compare_binary_architectures "$original_image" "$rebuilt_image" "$image_type"

    # Shell script comparison (should be identical)
    compare_shell_scripts "$original_image" "$rebuilt_image"

    echo -e "${CYAN}========================================${NC}"
    echo -e "${GREEN}Comparison complete${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""
}

usage() {
    echo "Usage: $0 <version> <image_type> [arch]"
    echo ""
    echo "Arguments:"
    echo "  version:    1.22 or 1.23"
    echo "  image_type: server or admin-tools"
    echo "  arch:       amd64 or arm64 (default: arm64)"
    echo ""
    echo "Examples:"
    echo "  $0 1.22 server"
    echo "  $0 1.23 admin-tools amd64"
}

main() {
    if [[ $# -lt 2 ]]; then
        usage
        exit 1
    fi

    local version=$1
    local image_type=$2
    local arch="${3:-arm64}"

    # Validate inputs
    if [[ "$version" != "1.22" && "$version" != "1.23" ]]; then
        log_error "Invalid version: $version (must be 1.22 or 1.23)"
        exit 1
    fi

    if [[ "$image_type" != "server" && "$image_type" != "admin-tools" ]]; then
        log_error "Invalid image type: $image_type (must be server or admin-tools)"
        exit 1
    fi

    if [[ "$arch" != "amd64" && "$arch" != "arm64" ]]; then
        log_error "Invalid arch: $arch (must be amd64 or arm64)"
        exit 1
    fi

    # Construct image names
    local original_image="temporalio/${image_type}:${version}"
    local rebuilt_image="temporalio/${image_type}:${version}-rebuild-${arch}"

    # For pulling the correct arch variant of the original multi-arch image
    export DOCKER_DEFAULT_PLATFORM="linux/${arch}"

    compare_images "$original_image" "$rebuilt_image" "$image_type"
}

main "$@"
