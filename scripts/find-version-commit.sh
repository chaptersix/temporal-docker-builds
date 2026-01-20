#!/bin/bash
# Find the docker-builds commit for a specific Temporal server version
#
# This script searches git history to find commits that updated the temporal
# submodule for a given release branch (e.g., release/v1.22.x).
#
# Usage: ./scripts/find-version-commit.sh <version>
# Example: ./scripts/find-version-commit.sh 1.22

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
    echo "Usage: $0 <version>"
    echo ""
    echo "Arguments:"
    echo "  version    The major.minor version to search for (e.g., 1.22 or 1.23)"
    echo ""
    echo "Examples:"
    echo "  $0 1.22    # Find commits for version 1.22"
    echo "  $0 1.23    # Find commits for version 1.23"
    echo ""
    echo "Output:"
    echo "  Lists all docker-builds commits that updated the temporal submodule"
    echo "  for the specified release branch, with the most recent first."
    exit 1
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

main() {
    if [[ $# -lt 1 ]]; then
        usage
    fi

    local version=$1

    # Validate version format
    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid version format: $version"
        echo "Version must be in format: major.minor (e.g., 1.22)"
        exit 1
    fi

    cd "$REPO_ROOT"

    echo ""
    echo -e "${CYAN}Searching for docker-builds commits for version $version${NC}"
    echo -e "${CYAN}Release branch pattern: release/v${version}.x${NC}"
    echo ""

    # Find all commits that mention this release branch
    local commits
    commits=$(git log --all --oneline --grep="release/v${version}.x" 2>/dev/null || true)

    if [[ -z "$commits" ]]; then
        log_error "No commits found for version $version"
        echo ""
        echo "Try searching manually:"
        echo "  git log --all --oneline | grep -i '${version}'"
        exit 1
    fi

    echo "Found commits (most recent first):"
    echo "=================================="
    echo ""

    # Process each commit to show details
    while IFS= read -r line; do
        local commit_sha
        commit_sha=$(echo "$line" | cut -d' ' -f1)

        echo -e "${GREEN}Commit: $commit_sha${NC}"

        # Get commit date and message
        git log -1 --format="  Date:    %ad%n  Message: %s" "$commit_sha"

        # Get the temporal submodule commit at this point
        local temporal_sha
        temporal_sha=$(git ls-tree "$commit_sha" temporal 2>/dev/null | awk '{print $3}' || echo "unknown")
        echo "  Temporal submodule: $temporal_sha"

        echo ""
    done <<< "$commits"

    # Show the recommended commit (most recent)
    local recommended
    recommended=$(echo "$commits" | head -1 | cut -d' ' -f1)

    echo "=================================="
    echo ""
    echo -e "${YELLOW}Recommended commit (most recent): $recommended${NC}"
    echo ""
    echo "To rebuild with this commit:"
    echo "  ./scripts/rebuild-server-image.sh $recommended $version"
}

main "$@"
