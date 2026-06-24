#!/bin/bash
#
# Luna OS Docker build script
# Builds the ISO inside a throwaway Debian Bookworm container with
# live-build installed. This sidesteps host filesystem issues entirely
# (NTFS/noexec, missing tools, wrong Debian version, etc.) since the
# build happens in a clean container, not on the host filesystem.

set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="luna-os-builder"
CONTAINER_NAME="luna-os-build-$$"
ISO_NAME="live-image-amd64.hybrid.iso"

log()  { printf '\033[1;36m[luna-docker]\033[0m %s\n' "$1"; }
err()  { printf '\033[1;31m[luna-docker][ERROR]\033[0m %s\n' "$1" >&2; }
die()  { err "$1"; exit 1; }

command -v docker >/dev/null 2>&1 || die "Docker is not installed. Install it first: https://docs.docker.com/engine/install/"

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
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
EOF

docker build -t "$IMAGE_NAME" -f "$TMP_DOCKERFILE" .
rm -f "$TMP_DOCKERFILE"

# ---------------------------------------------------------------------------
# 2. Run the build inside a privileged container
#    (live-build needs to mount/chroot, hence --privileged)
# ---------------------------------------------------------------------------
log "Running build inside container ($CONTAINER_NAME)..."

docker run --rm \
    --privileged \
    --name "$CONTAINER_NAME" \
    -v "$PROJECT_ROOT":/build \
    -w /build \
    "$IMAGE_NAME" \
    bash -c "lb clean --purge && lb config && lb build"

# ---------------------------------------------------------------------------
# 3. Verify ISO was produced
# ---------------------------------------------------------------------------
if [ ! -f "$PROJECT_ROOT/$ISO_NAME" ]; then
    die "Build finished but $ISO_NAME was not found in $PROJECT_ROOT. Check container output above."
fi

ISO_MB=$(( $(stat -c%s "$PROJECT_ROOT/$ISO_NAME") / 1024 / 1024 ))
log "Build complete: $PROJECT_ROOT/$ISO_NAME (${ISO_MB} MB)"
log "Test it with: ./test-boot.sh"
