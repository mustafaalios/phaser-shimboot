#!/bin/bash

#build a plain UEFI-bootable disk image with the distro's own kernel
#this is for chromebooks running custom UEFI firmware (e.g. MrChromebox), it does not use a shim at all

. ./common.sh
. ./image_utils.sh

print_help() {
  echo "Usage: ./build_uefi.sh output_path"
  echo "Valid named arguments (specify with 'key=value'):"
  echo "  desktop    - The desktop environment to install. This defaults to 'xfce'."
  echo "  release    - Debian release, defaults to 'trixie' (Linux 6.12 LTS)."
  echo "  hostname   - Hostname for the system. Defaults to 'shimboot-uefi'."
  echo "  rootfs_dir - Reuse a rootfs built with ./build_rootfs.sh ... distro_kernel=true instead of building one."
  echo "  data_dir   - Working directory. Defaults to ./data"
}

assert_root
assert_deps "debootstrap fdisk mkfs.ext4 mkfs.vfat blkid chroot"
assert_args "$1"
parse_args "$@"

base_dir="$(realpath -m "$(dirname "$0")")"
output_path="$(realpath -m "$1")"
desktop="${args['desktop']-xfce}"
release="${args['release']-trixie}"
hostname="${args['hostname']-shimboot-uefi}"
rootfs_dir="${args['rootfs_dir']}"
data_dir="$(realpath -m "${args['data_dir']-$base_dir/data}")"
esp_size=256

mkdir -p "$data_dir"
if [ ! "$rootfs_dir" ]; then
  rootfs_dir="$data_dir/rootfs_uefi"
  rm -rf "$rootfs_dir"
  print_title "building the rootfs"
  ./build_rootfs.sh "$rootfs_dir" "$release" \
    custom_packages="task-$desktop-desktop" \
    hostname="$hostname" username=user user_passwd=user \
    arch=amd64 distro=debian distro_kernel=true
fi
rootfs_dir="$(realpath -m "$rootfs_dir")"

if ! ls "$rootfs_dir"/boot/vmlinuz-* >/dev/null 2>&1; then
  print_error "this rootfs has no kernel in /boot, build it with distro_kernel=true"
  exit 1
fi

print_title "creating the disk image"
rootfs_size="$(du -sm "$rootfs_dir" | cut -f1)"
total_size="$((esp_size + rootfs_size * 13 / 10 + 512))"
rm -f "$output_path"
fallocate -l "${total_size}M" "$output_path"
(
  echo g
  echo n; echo; echo; echo "+${esp_size}M"
  echo t; echo 1                       #efi system
  echo n; echo; echo; echo
  echo x; echo n; echo 2; echo "shimboot_rootfs:uefi"; echo r
  echo w
) | fdisk "$output_path" > /dev/null

image_loop="$(create_loop "$output_path")"
trap 'umount -R /tmp/uefi_mnt 2>/dev/null; losetup -d "$image_loop" 2>/dev/null' EXIT
mkfs.vfat -F32 -n ESP "${image_loop}p1" > /dev/null
mkfs.ext4 -q "${image_loop}p2"

mnt=/tmp/uefi_mnt
safe_mount "${image_loop}p2" "$mnt"
mkdir -p "$mnt/boot/efi"

print_title "copying the rootfs"
copy_progress "$rootfs_dir" "$mnt"
mount "${image_loop}p1" "$mnt/boot/efi"

root_uuid="$(blkid -s UUID -o value "${image_loop}p2")"
esp_uuid="$(blkid -s UUID -o value "${image_loop}p1")"
cat > "$mnt/etc/fstab" << FSTAB
UUID=$root_uuid / ext4 defaults,errors=remount-ro 0 1
UUID=$esp_uuid /boot/efi vfat umask=0077 0 2
FSTAB

#frecon only exists in the chrome os shim
chroot "$mnt" systemctl disable kill-frecon.service 2>/dev/null || true

print_title "installing grub"
for m in proc sys dev run; do mount --make-rslave --rbind "/$m" "$mnt/$m"; done
LC_ALL=C chroot "$mnt" /bin/sh -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y grub-efi-amd64 efibootmgr
  sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"quiet\"/" /etc/default/grub
  #--removable puts grub at EFI/BOOT/BOOTX64.EFI, which the firmware always finds
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --no-nvram
  update-grub
  apt-get clean
'
for m in run dev sys proc; do umount -R -l "$mnt/$m"; done
umount "$mnt/boot/efi" "$mnt"
losetup -d "$image_loop"
trap - EXIT

print_info "done! the UEFI image is at $output_path"
print_info "write it to a usb drive or the internal disk with dd, or use install_to_internal from a running system"
