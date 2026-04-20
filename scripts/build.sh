#!/usr/bin/env bash
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(cd "$REPO_ROOT/.." && pwd)"

export TARGET=x86_64-unknown-linux-musl
export HOST=x86_64-unknown-linux-musl
export ARCH=x86_64
export JOBS=$(nproc)

# Pin nightly to match the kernel's rust-toolchain.toml
NIGHTLY="nightly-2025-05-10"

SYSROOT="$BUILD_DIR/sysroot"
SOURCES="$BUILD_DIR/sources"

# ── Step 1: Build kernel ──────────────────────────────────────────────
if [ -n "$BUILTIN_MODS" ]; then
    echo "==> Configuring built-in modules: $BUILTIN_MODS"
    TOML_LIST=$(echo "$BUILTIN_MODS" | tr ' ' '\n' | \
        awk 'BEGIN{printf "["} {printf sep"\""$0"\""; sep=","} END{print "]"}')
    cp "$REPO_ROOT/kernel/default.build-config.toml" "$REPO_ROOT/kernel/build-config.toml"
    sed -i "s/builtin = \[\]/builtin = $TOML_LIST/" "$REPO_ROOT/kernel/build-config.toml"
fi

echo "==> Building kernel..."
cd "$REPO_ROOT"
cargo xtask build-kernel --release
KERNEL="$REPO_ROOT/kernel/target/$ARCH/release/maestro"
if [ ! -f "$KERNEL" ]; then
    echo "ERROR: Kernel binary not found at $KERNEL"
    exit 1
fi
echo "    Kernel built: $KERNEL"

# ── Step 2: Prepare sysroot and sources ───────────────────────────────
echo "==> Preparing sysroot..."
rm -rf "$SYSROOT" "$SOURCES"
mkdir -p "$SYSROOT"/{sbin,bin,usr/bin,usr/sbin,lib/modules/maestro-0.1.0/default,etc/solfege/services,dev,proc,tmp,root,var}
mkdir -p "$SOURCES"

# ── Step 3: Build solfege (init) ──────────────────────────────────────
echo "==> Building solfege..."
cd "$SOURCES"
if [ ! -d solfege ]; then
    git clone --depth 1 https://github.com/llenotre/solfege.git
fi
cd solfege
cargo +"$NIGHTLY" build --target "$TARGET" -Zbuild-std=std,panic_abort -Zbuild-std-features=panic_immediate_abort --release
cp "target/$TARGET/release/solfege" "$SYSROOT/sbin/init"
echo "    solfege installed as /sbin/init"

# ── Step 4: Build maestro-utils ───────────────────────────────────────
echo "==> Building maestro-utils..."
cd "$SOURCES"
if [ ! -d maestro-utils ]; then
    git clone https://github.com/llenotre/maestro-utils.git
    cd maestro-utils
    git checkout 577a44b
    cd ..
fi
cd maestro-utils
cargo +"$NIGHTLY" build --target "$TARGET" -Zbuild-std=std,panic_abort -Zbuild-std-features=panic_immediate_abort --release

# maestro-utils uses multicall binaries: mutils (non-suid) and mutils-suid (suid)
UTILS_BIN="target/$TARGET/release"
cp "$UTILS_BIN/mutils" "$SYSROOT/sbin/mutils"
cp "$UTILS_BIN/mutils-suid" "$SYSROOT/sbin/mutils-suid"
chmod u+s "$SYSROOT/sbin/mutils-suid"

# Non-suid symlinks (all -> mutils)
for cmd in dmesg fdisk sfdisk insmod lsmod rmmod mkfs mkfs.ext2 mount umount nologin halt poweroff reboot shutdown suspend ps; do
    ln -sf /sbin/mutils "$SYSROOT/sbin/$cmd"
done

# Suid symlinks (all -> mutils-suid)
for cmd in login su; do
    ln -sf /sbin/mutils-suid "$SYSROOT/sbin/$cmd"
done
echo "    maestro-utils installed"

# ── Step 5: Build bash ────────────────────────────────────────────────
echo "==> Building bash..."
cd "$SOURCES"
BASH_VER="5.1.8"
if [ ! -f "bash-${BASH_VER}.tar.gz" ]; then
    curl -LO "https://ftp.gnu.org/gnu/bash/bash-${BASH_VER}.tar.gz"
fi
if [ ! -d "bash-${BASH_VER}" ]; then
    tar xf "bash-${BASH_VER}.tar.gz"
fi
cd "bash-${BASH_VER}"
make distclean 2>/dev/null || true
CC=x86_64-linux-musl-gcc \
CFLAGS="-Os -Wno-implicit-function-declaration -Wno-int-conversion" \
LDFLAGS="-static" \
./configure --prefix=/ \
    --host=x86_64-linux-musl \
    --build="$(cc -dumpmachine)" \
    --without-bash-malloc
make -j"$JOBS"
make DESTDIR="$SYSROOT" install
ln -sf bash "$SYSROOT/bin/sh"
echo "    bash installed"

# ── Step 6: Build coreutils ──────────────────────────────────────────
echo "==> Building coreutils..."
cd "$SOURCES"
COREUTILS_VER="9.0"
if [ ! -f "coreutils-${COREUTILS_VER}.tar.xz" ]; then
    curl -LO "https://ftp.gnu.org/gnu/coreutils/coreutils-${COREUTILS_VER}.tar.xz"
fi
if [ ! -d "coreutils-${COREUTILS_VER}" ]; then
    tar xf "coreutils-${COREUTILS_VER}.tar.xz"
fi
cd "coreutils-${COREUTILS_VER}"
make distclean 2>/dev/null || true
CC=x86_64-linux-musl-gcc \
CFLAGS="-Os -Wno-implicit-function-declaration -Wno-int-conversion" \
LDFLAGS="-static" \
./configure --prefix=/usr \
    --host=x86_64-linux-musl \
    --build="$(cc -dumpmachine)" \
    --enable-install-program=hostname
make -j"$JOBS"
make DESTDIR="$SYSROOT" install
# Move chroot to sbin per convention
mkdir -p "$SYSROOT/usr/sbin"
mv "$SYSROOT/usr/bin/chroot" "$SYSROOT/usr/sbin/" 2>/dev/null || true
echo "    coreutils installed"

# ── Step 7: Build PS2 kernel module ──────────────────────────────────
if echo "$BUILTIN_MODS" | grep -qw "ps2"; then
    echo "==> PS2 is built-in — skipping Step 7 (kernel build handles it)"
else
    echo "==> Building PS2 kernel module..."
    cd "$REPO_ROOT/mod/ps2"
    cargo clean
    PROFILE=release "$REPO_ROOT/mod/build"
    cp "target/$ARCH/release/libps2.so" "$SYSROOT/lib/modules/maestro-0.1.0/default/ps2.kmod"
    echo "    PS2 module installed"
fi

# ── Step 8: Build maestro-install ─────────────────────────────────────
echo "==> Building maestro-install..."
cd "$SOURCES"
if [ ! -d maestro-install ]; then
    git clone https://github.com/maestro-os/maestro-install.git
    cd maestro-install
    git checkout 85c994e
    cd ..
    # Add panic = "abort" to release profile for -Zbuild-std compatibility
    if ! grep -q 'panic = "abort"' maestro-install/Cargo.toml; then
        echo 'panic = "abort"' >> maestro-install/Cargo.toml
    fi
    # Pin mutils to last known-good commit (be442de introduced a musl ioctl type mismatch)
    cd maestro-install
    cargo update -p mutils --precise 577a44b874f5451a62cb6edf73b575a8cf82cc0d
    # blimp renamed Disk::size() to get_size(); patch until maestro-install catches up
    sed -i 's/disk\.size()/disk.get_size()/g' src/prompt/term.rs
    cd ..

fi
cd maestro-install
cargo +"$NIGHTLY" build --target "$TARGET" -Zbuild-std=std,panic_abort -Zbuild-std-features=panic_immediate_abort --release
cp "target/$TARGET/release/maestro_install" "$SYSROOT/sbin/install"
# The installer reads lang/ from cwd at runtime; solfege starts it with cwd /
mkdir -p "$SYSROOT/lang"
cp lang/*.json "$SYSROOT/lang/"
echo "    maestro-install installed"

# ── Step 9: Create config files ──────────────────────────────────────
echo "==> Creating config files..."

cat >"$SYSROOT/etc/fstab" <<'EOF'
# <file system> <dir> <type> <options> <dump> <pass>
tmpfs			/tmp	tmpfs	rw		0		0
procfs			/proc	procfs	rw		0		1
EOF

cat >"$SYSROOT/etc/solfege/startup" <<'EOF'
/sbin/install
EOF

ln -sf /proc/self/mounts "$SYSROOT/etc/mtab"

echo "    Config files created"

# ── Step 10: Create qemu_disk (ext2) ─────────────────────────────────
echo "==> Creating qemu_disk..."
dd if=/dev/zero of="$BUILD_DIR/qemu_disk" bs=1M count=1024
/sbin/mkfs.ext2 "$BUILD_DIR/qemu_disk"

DEBUGFS_CMDS=$(mktemp)

generate_debugfs_cmds() {
    local sysroot="$1"
    local cmds="$2"

    find "$sysroot" -mindepth 1 -type d | sort | while read -r dir; do
        local rel="${dir#$sysroot}"
        echo "mkdir $rel" >> "$cmds"
    done

    find "$sysroot" -type f | sort | while read -r file; do
        local rel="${file#$sysroot}"
        echo "write $file $rel" >> "$cmds"
    done

    find "$sysroot" -type l | sort | while read -r link; do
        local rel="${link#$sysroot}"
        local target
        target=$(readlink "$link")
        echo "symlink $rel $target" >> "$cmds"
    done

    echo "sif /sbin/mutils-suid mode 0104755" >> "$cmds"
}

generate_debugfs_cmds "$SYSROOT" "$DEBUGFS_CMDS"

echo "    Populating disk with debugfs ($(wc -l < "$DEBUGFS_CMDS") commands)..."
/sbin/debugfs -wf "$DEBUGFS_CMDS" "$BUILD_DIR/qemu_disk"
rm -f "$DEBUGFS_CMDS"
echo "    qemu_disk created and populated"

# ── Step 11: Build maestro.iso ────────────────────────────────────────
echo "==> Building maestro.iso..."
ISO_DIR=$(mktemp -d)
mkdir -p "$ISO_DIR/boot/grub"
cp "$KERNEL" "$ISO_DIR/boot/maestro"
cp "$REPO_ROOT/kernel/grub.cfg" "$ISO_DIR/boot/grub/grub.cfg"
grub-mkrescue -o "$BUILD_DIR/maestro.iso" "$ISO_DIR"
rm -rf "$ISO_DIR"
echo "    maestro.iso created"

echo "=== BUILD COMPLETE ==="
echo "Run scripts/run.sh to launch QEMU"
