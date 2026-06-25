#!/bin/bash
#
# Luna OS build script
# Builds a bootable ISO via live-build and enforces the <4GB size budget.
#
# Run as: sudo ./build.sh
# Must be run from the LUNA-os project root, on a native ext4/btrfs/xfs
# filesystem (NOT a FUSE-mounted NTFS/exFAT volume — live-build needs to
# exec files inside the chroot during package install).

set -e

ISO_MAX_BYTES=$((4 * 1024 * 1024 * 1024))   # 4 GB hard limit
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISO_NAME="live-image-amd64.hybrid.iso"

log()  { printf '\033[1;36m[luna-build]\033[0m %s\n' "$1"; }
err()  { printf '\033[1;31m[luna-build][ERROR]\033[0m %s\n' "$1" >&2; }
die()  { err "$1"; exit 1; }

# ---------------------------------------------------------------------------
# 0. Must be root
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    die "This script must be run as root (sudo ./build.sh)."
fi

# ---------------------------------------------------------------------------
# 1. Filesystem sanity check — refuse to build on noexec / FUSE NTFS mounts
# ---------------------------------------------------------------------------
log "Checking filesystem of project root: $PROJECT_ROOT"
FS_TYPE=$(df -T "$PROJECT_ROOT" | tail -1 | awk '{print $2}')
MOUNT_OPTS=$(findmnt -no OPTIONS --target "$PROJECT_ROOT" 2>/dev/null || echo "")

case "$FS_TYPE" in
    fuseblk|ntfs|ntfs-3g|exfat)
        die "Project root is on a $FS_TYPE filesystem. live-build cannot exec binaries in a chroot on $FS_TYPE (kernel forces noexec on FUSE mounts). Copy the project to an ext4/btrfs/xfs filesystem and rerun."
        ;;
esac

case "$MOUNT_OPTS" in
    *noexec*)
        die "Project root is mounted with 'noexec' ($MOUNT_OPTS). Remount without noexec or move the project to a native Linux filesystem."
        ;;
esac

# ---------------------------------------------------------------------------
# 2. Dependency check
# ---------------------------------------------------------------------------
REQUIRED_TOOLS="lb debootstrap mksquashfs xorriso bc"
MISSING=""
for tool in $REQUIRED_TOOLS; do
    command -v "$tool" >/dev/null 2>&1 || MISSING="$MISSING $tool"
done

if [ -n "$MISSING" ]; then
    die "Missing required tools:$MISSING
Install with: sudo apt install live-build debootstrap squashfs-tools xorriso bc"
fi

log "All required tools present."

# ---------------------------------------------------------------------------
# 3. Clean previous build artifacts
# ---------------------------------------------------------------------------
cd "$PROJECT_ROOT"
log "Cleaning previous build (lb clean --purge)..."
lb clean --purge

# ---------------------------------------------------------------------------
# 4. Configure
# ---------------------------------------------------------------------------
log "Running auto/config..."
lb config

# ---------------------------------------------------------------------------
# 5. Build
# ---------------------------------------------------------------------------
log "Starting build (lb build) — this will take a while..."
lb build

# ---------------------------------------------------------------------------
# 6. Verify ISO exists
# ---------------------------------------------------------------------------
if [ ! -f "$PROJECT_ROOT/$ISO_NAME" ]; then
    die "Build finished but $ISO_NAME was not found. Check build logs above for the failing stage."
fi

# ---------------------------------------------------------------------------
# 7. Verify ISO size budget
# ---------------------------------------------------------------------------
ISO_BYTES=$(stat -c%s "$PROJECT_ROOT/$ISO_NAME")
ISO_MB=$((ISO_BYTES / 1024 / 1024))
log "ISO size: ${ISO_MB} MB"

if [ "$ISO_BYTES" -gt "$ISO_MAX_BYTES" ]; then
    err "ISO exceeds 4 GB limit! (${ISO_MB} MB)"
    err "Trim package-lists/*.list.chroot or remove unused locales/firmware and rebuild."
    exit 1
fi

log "Build complete: $PROJECT_ROOT/$ISO_NAME (${ISO_MB} MB, within 4 GB budget)"
log "Test it with: ./test-boot.sh   or   qemu-system-x86_64 -m 1G -cdrom $ISO_NAME -boot d"
