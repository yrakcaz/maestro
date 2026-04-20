#!/usr/bin/env bash
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(cd "$REPO_ROOT/.." && pwd)"

SERIAL_LOG="$BUILD_DIR/maestro_serial.log"
echo "Launching QEMU (VNC on :1 = localhost:5901)"
echo "Kernel log: $SERIAL_LOG"
echo "Login as: root (no password)"
qemu-system-x86_64 \
    -drive file="$BUILD_DIR/qemu_disk",format=raw \
    -cdrom "$BUILD_DIR/maestro.iso" \
    -m 2G \
    -serial file:"$SERIAL_LOG" \
    -vnc :1
