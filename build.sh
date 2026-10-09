#!/bin/bash

#build the bootloader image

. ./common.sh
. ./image_utils.sh
. ./shim_utils.sh

print_help() {
  echo "Usage: ./build.sh output_path shim_path rootfs_dir"
  echo "Valid named arguments (specify with 'key=value'):"
  echo "  quiet - Don't use progress indicators which may clog up log files."
  echo "  name  - The name for the shimboot rootfs partition."
  echo "  bootonly - Build a small image with only the boot partitions and no rootfs. Used after installing to the internal eMMC."
  echo "  luks  - Set this argument to encrypt the rootfs partition."
}

assert_root
assert_deps "cpio binwalk pcregrep realpath cgpt mkfs.ext4 mkfs.ext2 fdisk"
assert_args "$3"
parse_args "$@"

output_path="$(realpath -m "${1}")"
shim_path="$(realpath -m "${2}")"
rootfs_dir="$(realpath -m "${3}")"

quiet="${args['quiet']}"
bootloader_part_name="${args['name']}"
luks_enabled="${args['luks']}"
bootonly="${args['bootonly']}"

if [ "$luks_enabled" ]; then
  if [ ! "$bootonly" ]; then
    while true; do
      read -p "Enter the LUKS2 password for the image: " crypt_password
      read -p "Retype the password: " crypt_password_confirm
      if [ "$crypt_password" = "$crypt_password_confirm" ]; then
        break
      else
        echo "Passwords do not match. Please try again."
      fi
    done
  fi
  print_info "downloading shimboot-binaries"
  temp_shimboot_binaries="/tmp/shimboot-binaries.tar.gz"
  #download the tar into /tmp before extracting cryptsetup
  wget -q --show-progress "https://github.com/ading2210/shimboot-binaries/releases/latest/download/shimboot_binaries_amd64.tar.gz" -O "$temp_shimboot_binaries"
  #extract cryptsetup and delete the archive
  tar -xf "$temp_shimboot_binaries" -C $(realpath -m "bootloader/bin/") "cryptsetup"
  rm "$temp_shimboot_binaries"
  chmod +x "$(realpath -m "bootloader/bin/")/cryptsetup"
fi

print_info "reading the shim image"
initramfs_dir=/tmp/shim_initramfs
kernel_img=/tmp/kernel.img
rm -rf "$initramfs_dir" "$kernel_img"
extract_initramfs_full "$shim_path" "$initramfs_dir" "$kernel_img"

print_info "patching initramfs"
patch_initramfs "$initramfs_dir"

#an extra kernel signed for developer mode lets the emmc boot without the external drive
print_info "signing the internal-boot kernel"
bootloader_size=20
kernel_dev_img=/tmp/kernel_dev.img
rm -f "$kernel_dev_img"
if sign_dev_kernel "$kernel_img" "$kernel_dev_img"; then
  mkdir -p "$initramfs_dir/opt"
  cp "$kernel_dev_img" "$initramfs_dir/opt/kernel_dev.img"
  kernel_dev_mb="$(( ($(stat -c %s "$kernel_dev_img") + 1048575) / 1048576 ))"
  #the bootloader partition has to hold the kernel as well
  bootloader_size="$((20 + kernel_dev_mb + 5))"
else
  print_error "could not sign the internal-boot kernel, the image will only boot from external media"
fi

print_info "creating disk image"
rootfs_size="$(du -sm $rootfs_dir | cut -f 1)"
rootfs_part_size="$(($rootfs_size * 12 / 10 + 5))"
if [ "$bootonly" ]; then
  #no rootfs partition, just 1mb of room for the backup gpt
  rootfs_part_size=1
  bootloader_part_name=""
fi
#create a 20mb bootloader partition
#rootfs partition is 20% larger than its contents
create_image "$output_path" "$bootloader_size" "$rootfs_part_size" "$bootloader_part_name"

print_info "creating loop device for the image"
image_loop="$(create_loop ${output_path})"

print_info "creating partitions on the disk image"
create_partitions "$image_loop" "$kernel_img" "$luks_enabled" "$crypt_password" "$bootonly"

print_info "copying data into the image"
populate_partitions "$image_loop" "$initramfs_dir" "$rootfs_dir" "$quiet" "$luks_enabled" "$bootonly"
rm -rf "$initramfs_dir" "$kernel_img"

print_info "cleaning up loop devices"
losetup -d "$image_loop"
print_info "done"
