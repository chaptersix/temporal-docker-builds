# Session Context: Rebuild temporalio/server ARM Images

## Goal

Rebuild `temporalio/server` and `temporalio/admin-tools` Docker images for versions 1.22 and 1.23 with correct ARM (aarch64) binaries. The original ARM images were published with x86-64 binaries.

## Repository Location

- Working directory: `/Users/alex.stanfield/repos/wt/reb/docker-builds`
- This is a git worktree on branch `alex/reb`

## Root Cause Analysis

### Version 1.22 (Old Build System)
- Uses multi-stage Docker builds where binaries are compiled INSIDE the container
- The `server.Dockerfile` has a `temporal-builder` stage that compiles Go binaries
- Should work correctly with `docker buildx --platform` targeting
- Commit: `e786597`

### Version 1.23 (New Build System - BUGGY)
- Uses pre-compiled binaries that are copied INTO the Docker image
- The docker-builds `Makefile` has `amd64-bins` and `arm64-bins` targets
- **BUG FOUND**: The temporal submodule's Makefile does NOT pass GOOS/GOARCH to `go build`:
  ```makefile
  # temporal/Makefile - BROKEN
  temporal-server: $(ALL_SRC)
      CGO_ENABLED=$(CGO_ENABLED) go build ... ./cmd/server
      # ^^^ Missing: GOOS=$(GOOS) GOARCH=$(GOARCH)
  ```
- This causes arm64 builds to produce x86-64 binaries
- Commit: `e7a73a0`

## Scripts Created

### 1. `scripts/find-version-commit.sh`
Finds the correct docker-builds commit for a given version by searching git log for submodule updates.

Usage:
```bash
./scripts/find-version-commit.sh 1.22
./scripts/find-version-commit.sh 1.23
```

### 2. `scripts/rebuild-1.22.sh`
Rebuilds 1.22 using the old multi-stage Docker build approach:
- Checks out commit `e786597`
- Uses `docker buildx build --platform linux/amd64` and `--platform linux/arm64`
- The builder stage compiles binaries for the target platform
- Builds both server and admin-tools images

Output images:
- `temporalio/server:1.22-rebuild-amd64`
- `temporalio/server:1.22-rebuild-arm64`
- `temporalio/admin-tools:1.22-rebuild-amd64`
- `temporalio/admin-tools:1.22-rebuild-arm64`

### 3. `scripts/rebuild-1.23.sh`
Rebuilds 1.23 by building binaries directly (bypassing the broken Makefile):
- Checks out commit `e7a73a0`
- Builds temporal binaries directly with explicit `GOOS=linux GOARCH=<arch> go build`
- Other binaries (tctl, cli, dockerize) are built via their Makefiles (which work correctly)
- Verifies all binaries have correct architecture before building Docker image
- Uses `docker buildx build` for each platform
- Builds both server and admin-tools images

Output images:
- `temporalio/server:1.23-rebuild-amd64`
- `temporalio/server:1.23-rebuild-arm64`
- `temporalio/admin-tools:1.23-rebuild-amd64`
- `temporalio/admin-tools:1.23-rebuild-arm64`

### 4. `scripts/verify-images.sh`
Verifies that rebuilt Docker images contain binaries with correct architectures.

Usage:
```bash
./scripts/verify-images.sh        # Verify all images
./scripts/verify-images.sh 1.22   # Verify only 1.22 images
./scripts/verify-images.sh 1.23   # Verify only 1.23 images
```

Checks:
- amd64 images contain x86-64 binaries
- arm64 images contain ARM aarch64 binaries
- Server images: checks `temporal-server`, `tctl`, `tctl-authorization-plugin`, `temporal`
- Admin-tools images: checks `tctl`, `tctl-authorization-plugin`, `temporal`, `temporal-cassandra-tool`, `temporal-sql-tool`, `tdbg`

### 5. `scripts/compare-images.sh`
Compares rebuilt images to the original published images on Docker Hub.

Usage:
```bash
./scripts/compare-images.sh 1.22 server arm64      # Compare 1.22 server arm64
./scripts/compare-images.sh 1.23 server arm64      # Compare 1.23 server arm64
./scripts/compare-images.sh 1.22 admin-tools amd64 # Compare 1.22 admin-tools amd64
```

Shows:
- **Tree comparison** (differences only): Files added/removed/changed in size
- **Binary architecture comparison**: Architecture of all Temporal binaries in both images
- **Shell script validation**: Syntax check (`bash -n`) and executable status for all .sh files

## Key Commits

| Version | Commit  | Date       | Temporal Submodule |
|---------|---------|------------|-------------------|
| 1.22    | e786597 | 2024-03-28 | 1c396c1           |
| 1.23    | e7a73a0 | 2024-04-30 | fad6bdc           |

## Binaries That Need Building (1.23)

From temporal submodule (MUST build directly with GOARCH):
- `temporal-server` - `./cmd/server`
- `tdbg` - `./cmd/tools/tdbg`
- `temporal-cassandra-tool` - `./cmd/tools/cassandra`
- `temporal-sql-tool` - `./cmd/tools/sql`

From other submodules (Makefiles work correctly):
- `dockerize` - from dockerize submodule
- `temporal` (CLI) - from cli submodule
- `tctl` - from tctl submodule
- `tctl-authorization-plugin` - from tctl submodule

## Current Status

- [x] Created `find-version-commit.sh`
- [x] Created `rebuild-1.22.sh`
- [x] Created `rebuild-1.23.sh`
- [x] Run `rebuild-1.22.sh` and verify output
- [x] Run `rebuild-1.23.sh` and verify output

## Build Results

| Version | Image | Binary |
|---------|-------|--------|
| 1.22 | `temporalio/server:1.22-rebuild-amd64` | x86-64 ✓ |
| 1.22 | `temporalio/server:1.22-rebuild-arm64` | ARM aarch64 ✓ |
| 1.22 | `temporalio/admin-tools:1.22-rebuild-amd64` | x86-64 ✓ |
| 1.22 | `temporalio/admin-tools:1.22-rebuild-arm64` | ARM aarch64 ✓ |
| 1.23 | `temporalio/server:1.23-rebuild-amd64` | x86-64 ✓ |
| 1.23 | `temporalio/server:1.23-rebuild-arm64` | ARM aarch64 ✓ |
| 1.23 | `temporalio/admin-tools:1.23-rebuild-amd64` | x86-64 ✓ |
| 1.23 | `temporalio/admin-tools:1.23-rebuild-arm64` | ARM aarch64 ✓ |

## Verification Commands

After building, verify binaries in images:
```bash
# Server images - 1.22
docker run --rm temporalio/server:1.22-rebuild-amd64 file /usr/local/bin/temporal-server
# Should show: x86-64

docker run --rm temporalio/server:1.22-rebuild-arm64 file /usr/local/bin/temporal-server
# Should show: ARM aarch64

# Server images - 1.23
docker run --rm temporalio/server:1.23-rebuild-amd64 file /usr/local/bin/temporal-server
# Should show: x86-64

docker run --rm temporalio/server:1.23-rebuild-arm64 file /usr/local/bin/temporal-server
# Should show: ARM aarch64

# Admin-tools images - 1.22
docker run --rm temporalio/admin-tools:1.22-rebuild-amd64 file /usr/local/bin/tctl
# Should show: x86-64

docker run --rm temporalio/admin-tools:1.22-rebuild-arm64 file /usr/local/bin/tctl
# Should show: ARM aarch64

# Admin-tools images - 1.23
docker run --rm temporalio/admin-tools:1.23-rebuild-amd64 file /usr/local/bin/tctl
# Should show: x86-64

docker run --rm temporalio/admin-tools:1.23-rebuild-arm64 file /usr/local/bin/tctl
# Should show: ARM aarch64
```

## User Requirements

1. No publishing in the scripts - images built locally only
2. Build server and admin-tools images (not auto-setup)
3. Separate scripts for 1.22 and 1.23 (different build systems)
4. Include detailed comments explaining methodology
5. Keep the commit-finding script separate from build scripts
