#!/bin/bash
#
# Luna OS QEMU boot test script
# Boots the built ISO in QEMU to sanity-check it before flashing to USB.

set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISO_NAME="live-image-amd64.hybrid.iso"
ISO_PATH="$PROJECT_ROOT/$ISO_NAME"
RAM_MB=1024
PERSIST_IMG="$PROJECT_ROOT/luna-persistence-test.img"
PERSIST_SIZE="2G"
MODE="${1:-bios}"   # bios | uefi | persistence

log()  { printf '\033[1;36m[luna-test-boot]\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31m[luna-test-boot][ERROR]\033[0m %s\n' "$1" >&2; exit 1; }

command -v qemu-system-x86_64 >/dev/null 2>&1 || die "qemu-system-x86_64 not found. Install with: sudo apt install qemu-system-x86"
[ -f "$ISO_PATH" ] || die "$ISO_NAME not found. Run ./build.sh or ./docker-build.sh first."

case "$MODE" in
    bios)
        log "Booting in BIOS mode, ${RAM_MB} MB RAM..."
        qemu-system-x86_64 \
            -m "$RAM_MB" \
            -cdrom "$ISO_PATH" \
            -boot d \
            -vga std \
            -enable-kvm 2>/dev/null || qemu-system-x86_64 -m "$RAM_MB" -cdrom "$ISO_PATH" -boot d -vga std
        ;;

    uefi)
        OVMF_PATH=""
        for p in /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
            [ -f "$p" ] && OVMF_PATH="$p" && break
        done
        [ -n "$OVMF_PATH" ] || die "OVMF UEFI firmware not found. Install with: sudo apt install ovmf"
        log "Booting in UEFI mode (OVMF: $OVMF_PATH), ${RAM_MB} MB RAM..."
        qemu-system-x86_64 \
            -m "$RAM_MB" \
            -bios "$OVMF_PATH" \
            -cdrom "$ISO_PATH" \
            -boot d \
            -vga std \
            -enable-kvm 2>/dev/null || qemu-system-x86_64 -m "$RAM_MB" -bios "$OVMF_PATH" -cdrom "$ISO_PATH" -boot d -vga std
        ;;

    persistence)
        if [ ! -f "$PERSIST_IMG" ]; then
            log "Creating ${PERSIST_SIZE} persistence test disk..."
            qemu-img create -f qcow2 "$PERSIST_IMG" "$PERSIST_SIZE"
        fi
        log "Booting with attached persistence disk..."
        qemu-system-x86_64 \
            -m "$RAM_MB" \
            -cdrom "$ISO_PATH" \
            -drive file="$PERSIST_IMG",format=qcow2,if=virtio \
            -boot d \
            -vga std \
            -enable-kvm 2>/dev/null || qemu-system-x86_64 -m "$RAM_MB" -cdrom "$ISO_PATH" -drive file="$PERSIST_IMG",format=qcow2,if=virtio -boot d -vga std
        ;;

    *)
        die "Usage: ./test-boot.sh [bios|uefi|persistence]"
        ;;
esac

log "QEMU session ended."
log "Inside the VM, check idle RAM with: free -h   (target: under 400 MB used)"
