#!/bin/sh
set -e

# System packages
sudo apt-get update -y
sudo apt-get install -y \
    git curl make gcc \
    qemu-system-x86 \
    grub-pc-bin grub-common xorriso \
    mtools \
    e2fsprogs \
    libisoburn-dev \
    binutils-x86-64-linux-gnu \
    binutils-i686-linux-gnu

# Cross-linker aliases expected by the kernel build
sudo ln -sf /usr/bin/x86_64-linux-gnu-ld /usr/local/bin/x86_64-elf-ld
sudo ln -sf /usr/bin/i686-linux-gnu-ld   /usr/local/bin/i686-elf-ld

# musl cross-compiler — x86_64-linux-musl-gcc is not in apt
curl -fsSL https://musl.cc/x86_64-linux-musl-cross.tgz | \
    sudo tar -xz -C /usr/local/
sudo mv /usr/local/x86_64-linux-musl-cross /usr/local/musl-cross

