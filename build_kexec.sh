#!/bin/bash

#build a static kexec binary for the bootloader, so that the shim's old kernel
#can hand over to the newer kernel that is installed in the rootfs

. ./common.sh

print_help() {
  echo "Usage: ./build_kexec.sh [output_path]"
  echo "Builds a statically linked kexec and places it at bootloader/bin/kexec by default."
}

assert_deps "gcc make tar wget"
parse_args "$@"

version="2.0.29"
base_dir="$(realpath -m "$(dirname "$0")")"
output_path="$(realpath -m "${1:-$base_dir/bootloader/bin/kexec}")"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

print_info "downloading kexec-tools $version"
wget -q --show-progress "https://mirrors.edge.kernel.org/pub/linux/utils/kernel/kexec/kexec-tools-$version.tar.xz" -O "$work_dir/kexec-tools.tar.xz"
tar -xf "$work_dir/kexec-tools.tar.xz" -C "$work_dir"

print_info "building a static kexec"
cd "$work_dir/kexec-tools-$version"
./configure --without-lzma --without-zlib LDFLAGS="-static" > /dev/null
make -j"$(nproc)" > /dev/null

mkdir -p "$(dirname "$output_path")"
cp build/sbin/kexec "$output_path"
strip "$output_path" || true
chmod +x "$output_path"
if ldd "$output_path" 2>&1 | grep -qv "not a dynamic executable"; then
  print_error "the resulting kexec binary is not static, it will not run in the shim initramfs"
  exit 1
fi
print_info "kexec written to $output_path"
