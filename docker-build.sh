#!/bin/bash
#
# Luna OS Docker build script (Codespaces-compatible version, v2)
#
# Only the inner config/chroot directory needs an exec-enabled tmpfs —
# that's the specific path live-build's debootstrap step complained
# about ("mounted with noexec or nodev"). Everything else (apt's .deb
# cache, the final ISO) stays on the normal host-backed mount, which
# keeps total RAM usage far lower than tmpfs-ing the entire project.
#
# The build also runs detached (nohup + background), writing to
# build.log, so a Codespaces browser disconnect/reload never interrupts
# it. Reattach any time with: tail -f build.log

set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="luna-os-builder"
CONTAINER_NAME="luna-os-build-$$"
ISO_NAME="live-image-amd64.hybrid.iso"
TMPFS_SIZE="8g"   # increase if the build runs out of space inside chroot
LOG_FILE="$PROJECT_ROOT/build.log"

log()  { printf '\033[1;36m[luna-docker]\033[0m %s\n' "$1"; }
err()  { printf '\033[1;31m[luna-docker][ERROR]\033[0m %s\n' "$1" >&2; }
die()  { err "$1"; exit 1; }

command -v docker >/dev/null 2>&1 || die "Docker is not installed. Install it first: https://docs.docker.com/engine/install/"

mkdir -p "$PROJECT_ROOT/chroot"   # must pre-exist so docker can mount tmpfs onto it

# ---------------------------------------------------------------------------
# 1. Build the builder image (Debian Bookworm + live-build toolchain)
# ---------------------------------------------------------------------------
log "Building Docker builder image..."

TMP_DOCKERFILE="$(mktemp)"
cat > "$TMP_DOCKERFILE" <<'EOF'
FROM debian:bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    live-build debootstrap squashfs-tools xorriso bc \
    grub-pc-bin grub-efi-amd64-bin mtools dosfstools \
    ca-certificates rsync \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
EOF

docker build -t "$IMAGE_NAME" -f "$TMP_DOCKERFILE" .
rm -f "$TMP_DOCKERFILE"

# ---------------------------------------------------------------------------
# 2. Run the build detached, in the background, logging to build.log.
#    Only /build/chroot gets the exec-enabled tmpfs; the rest of /build
#    is the normal (disk-backed, cacheable) bind mount.
# ---------------------------------------------------------------------------
log "Starting build in the background (this will take a while)..."
log "Log file: $LOG_FILE"
log "Watch progress with: tail -f build.log"

nohup docker run --rm \
    --privileged \
    --name "$CONTAINER_NAME" \
    -v "$PROJECT_ROOT":/build \
    --tmpfs "/build/chroot:exec,dev,suid,size=$TMPFS_SIZE" \
    -w /build \
    "$IMAGE_NAME" \
    bash -c "lb clean --purge && lb config && lb build" \
    > "$LOG_FILE" 2>&1 &

BUILD_PID=$!
echo "$BUILD_PID" > "$PROJECT_ROOT/.build.pid"
log "Build running in background (PID $BUILD_PID, container $CONTAINER_NAME)."
log "This terminal is now free — you can close it or let it sit."
log "Check on it any time with:  tail -f build.log"
log "Or check if it's still running with:  docker ps --filter name=$CONTAINER_NAME"
