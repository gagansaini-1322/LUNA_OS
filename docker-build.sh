#!/bin/bash
#
# Luna OS Docker build script — v5 (Codespaces rootless-safe, final)
#
# ROOT CAUSE (confirmed):
#   GitHub Codespaces uses overlayfs with noexec all the way down.
#   No bind-mount, named volume, or --tmpfs on a *subdirectory* of a
#   bind-mount escapes this. debootstrap's write-test fails with
#   EPERM at line 1764 regardless of --privileged.
#
# THE ONLY WORKING SOLUTION:
#   Bake the entire project config INTO the Docker image (COPY in the
#   Dockerfile). At runtime, mount a fresh RAM tmpfs at /build (the
#   top-level workdir). Docker's --tmpfs on the container's OWN
#   workdir is always exec+dev+suid — it is a kernel-level tmpfs
#   managed by the Docker daemon, not derived from the host OverlayFS.
#   The image layers (read-only) provide the config; the tmpfs provides
#   the writable exec-enabled workspace. live-build copies config out
#   of the image into the tmpfs at startup.
#
# ISO RETRIEVAL:
#   Since /build is a tmpfs (in-container RAM), the ISO must be copied
#   out before the container exits. We do this with `docker cp`.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="luna-os-builder"
CONTAINER_NAME="luna-os-build-$$"
ISO_NAME="live-image-amd64.hybrid.iso"
LOG_FILE="$PROJECT_ROOT/build.log"
TMPFS_SIZE="10g"   # RAM used during build — needs ~6-8 GB minimum

log() { printf '\033[1;36m[luna-docker]\033[0m %s\n' "$1"; }
err() { printf '\033[1;31m[luna-docker][ERROR]\033[0m %s\n' "$1" >&2; }
die() { err "$1"; exit 1; }

command -v docker >/dev/null 2>&1 || die "Docker is not installed."

# Kill any leftover containers
docker rm -f $(docker ps -aq --filter "name=luna-os-build-") 2>/dev/null || true
rm -f "$PROJECT_ROOT/.build.pid"

# ---------------------------------------------------------------------------
# 1. Build the image — config is COPIED IN, not mounted
# ---------------------------------------------------------------------------
log "Building Docker image (config baked in)..."

TMP_DOCKERFILE="$(mktemp)"
# We build from the PROJECT_ROOT context so COPY can grab config/
cat > "$TMP_DOCKERFILE" <<'DOCKERFILE'
FROM debian:bookworm

# Install live-build toolchain + fakeroot for safety
RUN apt-get update && apt-get install -y --no-install-recommends \
    live-build debootstrap squashfs-tools xorriso bc \
    grub-pc-bin grub-efi-amd64-bin mtools dosfstools \
    ca-certificates rsync curl fakeroot \
    && rm -rf /var/lib/apt/lists/*

# Bake the project config into /src inside the image.
# At runtime we copy /src → /build (the exec-enabled tmpfs).
WORKDIR /src
COPY . .

# Entrypoint copies config to tmpfs workdir then builds
CMD ["bash", "/src/docker-entrypoint.sh"]
DOCKERFILE

docker build -t "$IMAGE_NAME" -f "$TMP_DOCKERFILE" "$PROJECT_ROOT"
rm -f "$TMP_DOCKERFILE"

# ---------------------------------------------------------------------------
# 2. Write the in-container entrypoint (also gets baked into image via COPY)
# ---------------------------------------------------------------------------
cat > "$PROJECT_ROOT/docker-entrypoint.sh" <<'ENTRYPOINT'
#!/bin/bash
set -e

log() { printf '\033[1;36m[luna-build]\033[0m %s\n' "$1"; }

log "Copying config from image layer into exec-enabled /build tmpfs..."
# /build is the tmpfs — empty at start. Copy everything from /src.
rsync -a \
    --exclude='.build' \
    --exclude='binary*' \
    --exclude='chroot' \
    --exclude='*.iso' \
    --exclude='build.log' \
    --exclude='.build.pid' \
    --exclude='docker-entrypoint.sh' \
    /src/ /build/

cd /build

log "Running lb config..."
lb config

log "Running lb build (this will take 30-60 min)..."
lb build

log "Build complete!"
ls -lh /build/*.iso 2>/dev/null || echo "WARNING: no ISO found"
ENTRYPOINT
chmod +x "$PROJECT_ROOT/docker-entrypoint.sh"

# Rebuild the image now that entrypoint exists (COPY . . picks it up)
log "Rebuilding image with entrypoint included..."
TMP_DOCKERFILE="$(mktemp)"
cat > "$TMP_DOCKERFILE" <<'DOCKERFILE'
FROM debian:bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    live-build debootstrap squashfs-tools xorriso bc \
    grub-pc-bin grub-efi-amd64-bin mtools dosfstools \
    ca-certificates rsync curl fakeroot \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .
DOCKERFILE

docker build -t "$IMAGE_NAME" -f "$TMP_DOCKERFILE" "$PROJECT_ROOT"
rm -f "$TMP_DOCKERFILE"

# ---------------------------------------------------------------------------
# 3. Run — /build is a fresh kernel tmpfs, always exec+dev+suid
# ---------------------------------------------------------------------------
log "Starting build in background..."
log "Monitor: tail -f build.log"

nohup docker run \
    --name "$CONTAINER_NAME" \
    --privileged \
    --security-opt seccomp=unconfined \
    --security-opt apparmor=unconfined \
    --cap-add=ALL \
    --tmpfs /build:exec,dev,suid,size="$TMPFS_SIZE" \
    -w /build \
    "$IMAGE_NAME" \
    bash /src/docker-entrypoint.sh \
    > "$LOG_FILE" 2>&1 &

BUILD_PID=$!
echo "$BUILD_PID" > "$PROJECT_ROOT/.build.pid"

log "Build running: PID=$BUILD_PID  container=$CONTAINER_NAME"
log ""
log "When done, copy the ISO out with:"
log "  docker cp $CONTAINER_NAME:/build/$ISO_NAME ./"
log "Or run: ./get-iso.sh"
log ""
log "NOTE: container is NOT --rm so the ISO survives after build exits."

# ---------------------------------------------------------------------------
# 4. get-iso.sh
# ---------------------------------------------------------------------------
cat > "$PROJECT_ROOT/get-iso.sh" <<GETISO
#!/bin/bash
# Copy the built ISO from the stopped/running container to current directory
set -e
CONTAINER="$CONTAINER_NAME"
ISO="$ISO_NAME"

# Find the container (may have exited after build)
if ! docker inspect "\$CONTAINER" &>/dev/null; then
    # Try to find the most recent luna-os-build container
    CONTAINER=\$(docker ps -aq --filter "name=luna-os-build-" | head -1)
    [ -z "\$CONTAINER" ] && { echo "No build container found."; exit 1; }
fi

echo "Copying ISO from container \$CONTAINER..."
docker cp "\$CONTAINER:/build/$ISO" "./$ISO" && echo "Done: ./$ISO" && ls -lh "./$ISO"
GETISO
chmod +x "$PROJECT_ROOT/get-iso.sh"
log "get-iso.sh written."
