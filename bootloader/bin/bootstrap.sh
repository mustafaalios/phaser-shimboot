#!/bin/busybox sh
# Copyright 2015 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# To bootstrap the factory installer on rootfs. This file must be executed as
# PID=1 (exec).
# Note that this script uses the busybox shell (not bash, not dash).

#original: https://chromium.googlesource.com/chromiumos/platform/initramfs/+/refs/heads/main/factory_shim/bootstrap.sh

#set -x
set +x

rescue_mode=""

invoke_terminal() {
  local tty="$1"
  local title="$2"
  shift
  shift
  # Copied from factory_installer/factory_shim_service.sh.
  echo "${title}" >>${tty}
  setsid sh -c "exec script -afqc '$*' /dev/null <${tty} >>${tty} 2>&1 &"
}

enable_debug_console() {
  local tty="$1"
  echo -e "debug console enabled on ${tty}"
  invoke_terminal "${tty}" "[Bootstrap Debug Console]" "/bin/busybox sh"
}

#get a partition block device from a disk path and a part number
get_part_dev() {
  local disk="$1"
  local partition="$2"

  #disk paths ending with a number will have a "p" before the partition number
  last_char="$(echo -n "$disk" | tail -c 1)"
  if [ "$last_char" -eq "$last_char" ] 2>/dev/null; then
    echo "${disk}p${partition}"
  else
    echo "${disk}${partition}"
  fi
}

#a disk is the internal emmc if the mmc subsystem reports it as type MMC (sd cards report SD)
is_emmc_disk() {
  local name="$(basename "$1")"
  case "$name" in
    mmcblk[0-9]|mmcblk[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  [ "$(cat "/sys/block/$name/device/type" 2>/dev/null)" = "MMC" ]
}

find_emmc_disk() {
  for sys_disk in /sys/block/mmcblk*; do
    local disk="/dev/$(basename "$sys_disk")"
    if is_emmc_disk "$disk"; then
      echo "$disk"
      return 0
    fi
  done
  return 1
}

#prints one "device:name" line per shimboot rootfs, with ":internal" appended if it lives on the emmc
find_rootfs_partitions() {
  local disks=$(fdisk -l | sed -n "s/Disk \(\/dev\/.*\):.*/\1/p")
  if [ ! "${disks}" ]; then
    return 1
  fi

  for disk in $disks; do
    local partitions=$(fdisk -l $disk | sed -n "s/^[ ]\+\([0-9]\+\).*shimboot_rootfs:\(.*\)$/\1:\2/p")
    if [ ! "${partitions}" ]; then
      continue
    fi
    local flag=""
    if is_emmc_disk "$disk"; then
      flag=":internal"
    fi
    for partition in $partitions; do
      echo "$(get_part_dev "$disk" "$partition")${flag}"
    done
  done
}

#from original bootstrap.sh
move_mounts() {
  local base_mounts="/sys /proc /dev"
  local newroot_mnt="$1"
  for mnt in $base_mounts; do
    # $mnt is a full path (leading '/'), so no '/' joiner
    mkdir -p "$newroot_mnt$mnt"
    mount -n -o move "$mnt" "$newroot_mnt$mnt"
  done
}

print_license() {
  local shimboot_version="$(cat /opt/.shimboot_version)"
  if [ -f "/opt/.shimboot_version_dev" ]; then
    local git_hash="$(cat /opt/.shimboot_version_dev)"
    local suffix="-dev-$git_hash"
  fi
  cat << EOF 
Shimboot ${shimboot_version}${suffix}

ading2210/shimboot: Boot desktop Linux from a Chrome OS RMA shim.
Copyright (C) 2025 ading2210

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
EOF
}

print_selector() {
  local rootfs_partitions="$1"
  local i=1

  echo "┌──────────────────────┐"
  echo "│ Shimboot OS Selector │"
  echo "└──────────────────────┘"

  if [ "${rootfs_partitions}" ]; then
    for rootfs_partition in $rootfs_partitions; do
      #i don't know of a better way to split a string in the busybox shell
      local part_path=$(echo $rootfs_partition | cut -d ":" -f 1)
      local part_name=$(echo $rootfs_partition | cut -d ":" -f 2)
      echo "${i}) ${part_name} on ${part_path}"
      i=$((i+1))
    done
  else
    echo "no bootable partitions found. please see the shimboot documentation to mark a partition as bootable."
  fi

  if [ "$(find_emmc_disk)" ]; then
    echo "i) install to internal storage (erases the emmc)"
  fi
  echo "q) reboot"
  echo "s) enter a shell"
  echo "l) view license"
}

get_selection() {
  local rootfs_partitions="$1"
  local i=1

  read -p "Your selection: " selection
  if [ "$selection" = "q" ]; then
    echo "rebooting now."
    reboot -f
  elif [ "$selection" = "s" ]; then
    reset
    enable_debug_console "$TTY1"
    return 0
  elif [ "$selection" = "i" ]; then
    install_to_emmc "$rootfs_partitions"
    return 1
  elif [ "$selection" = "l" ]; then
    clear
    print_license
    echo
    read -p "press [enter] to return to the bootloader menu"
    return 1
  fi

  local selection_cmd="$(echo "$selection" | cut -d' ' -f1)"
  if [ "$selection_cmd" = "rescue" ]; then
    selection="$(echo "$selection" | cut -d' ' -f2-)"
    rescue_mode="1"
  else
    rescue_mode=""
  fi

  for rootfs_partition in $rootfs_partitions; do
    local part_path=$(echo $rootfs_partition | cut -d ":" -f 1)
    local part_name=$(echo $rootfs_partition | cut -d ":" -f 2)

    if [ "$selection" = "$i" ]; then
      echo "selected $part_path"
      boot_target "$part_path"
      return 1
    fi

    i=$((i+1))
  done
  
  echo "invalid selection"
  sleep 1
  return 1
}

#size of a block device in 512 byte sectors
dev_sectors() {
  cat "/sys/class/block/$(basename "$1")/size"
}

#wipe the emmc, then clone the first external shimboot rootfs onto it
install_to_emmc() {
  local rootfs_partitions="$1"
  local emmc="$(find_emmc_disk)"
  if [ ! "$emmc" ]; then
    echo "no internal emmc found"
    sleep 2
    return 1
  fi

  #the source is the first rootfs that is not already on the emmc
  local source="" source_name=""
  for rootfs_partition in $rootfs_partitions; do
    if [ "$(echo $rootfs_partition | cut -d ":" -f 3)" != "internal" ]; then
      source="$(echo $rootfs_partition | cut -d ":" -f 1)"
      source_name="$(echo $rootfs_partition | cut -d ":" -f 2)"
      break
    fi
  done
  if [ ! "$source" ]; then
    echo "no rootfs on the boot media to install from"
    sleep 2
    return 1
  fi

  local disk_sectors="$(dev_sectors "$emmc")"
  local source_sectors="$(dev_sectors "$source")"
  #leave 1MiB at the start and room for the backup gpt at the end
  local part_start=2048
  local part_sectors=$((disk_sectors - part_start - 2048))
  if [ "$part_sectors" -lt "$source_sectors" ]; then
    echo "the emmc is too small for this image"
    sleep 2
    return 1
  fi

  clear
  echo "This will ERASE EVERYTHING on ${emmc}, including Chrome OS."
  echo "The firmware and enrollment are not touched, and Chrome OS can be restored"
  echo "later with a recovery usb. After installing, the boot media must stay"
  echo "inserted to start the system."
  echo
  fdisk -l "$emmc" 2>/dev/null | head -n 4
  echo
  read -p "Type ERASE to continue, anything else cancels: " confirm
  if [ "$confirm" != "ERASE" ]; then
    echo "cancelled"
    sleep 1
    return 1
  fi

  echo "creating partition table"
  cgpt create -z "$emmc" || return 1
  cgpt create "$emmc" || return 1
  cgpt add -i 1 -t 0FC63DAF-8483-4772-8E79-3D69D8477DE4 \
    -b $part_start -s $part_sectors \
    -l "shimboot_rootfs:${source_name}" "$emmc" || return 1
  #writing the table with fdisk makes the kernel re-read it
  echo w | fdisk "$emmc" >/dev/null 2>&1

  local target="$(get_part_dev "$emmc" 1)"
  local tries=0
  while [ ! -b "$target" ] && [ "$tries" -lt 10 ]; do
    mdev -s 2>/dev/null
    sleep 1
    tries=$((tries+1))
  done
  if [ ! -b "$target" ]; then
    echo "partition $target did not appear"
    sleep 3
    return 1
  fi

  echo "copying $source to $target"
  dd if="$source" bs=4M 2>/dev/null | pv -s $((source_sectors * 512)) | dd of="$target" bs=4M conv=fsync 2>/dev/null
  sync

  echo
  echo "install finished. keep the boot media inserted; the system now boots from the emmc."
  echo "the root filesystem will grow to fill the emmc on the first boot."
  read -p "press [enter] to continue "
  return 0
}

#give the user a moment to interrupt before booting the installed system
autoboot_wait() {
  local seconds=3
  echo "booting from internal storage in ${seconds}s. press any key for the menu."
  if read -t $seconds -n 1 key; then
    return 1
  fi
  return 0
}

exec_init() {
  if [ "$rescue_mode" = "1" ]; then
    echo "entering a rescue shell instead of starting init"
    echo "once you are done fixing whatever is broken, run 'exec /sbin/init' to continue booting the system normally"
    
    if [ -f "/bin/bash" ]; then
      exec /bin/bash < "$TTY1" >> "$TTY1" 2>&1
    else
      exec /bin/sh < "$TTY1" >> "$TTY1" 2>&1
    fi
  else
    exec /sbin/init < "$TTY1" >> "$TTY1" 2>&1
  fi
}

boot_target() {
  local target="$1"

  echo "moving mounts to newroot"
  mkdir /newroot
  #use cryptsetup to check if the rootfs is encrypted
  if [ -x "$(command -v cryptsetup)" ] && cryptsetup luksDump "$target" >/dev/null 2>&1; then
    cryptsetup open $target rootfs
    mount /dev/mapper/rootfs /newroot
  else
    mount $target /newroot
  fi
  #bind mount /dev/console to show systemd boot msgs
  if [ -f "/bin/frecon-lite" ]; then 
    rm -f /dev/console
    touch /dev/console #this has to be a regular file otherwise the system crashes afterwards
    mount -o bind "$TTY1" /dev/console
  fi
  move_mounts /newroot

  echo "switching root"
  mkdir -p /newroot/bootloader
  pivot_root /newroot /newroot/bootloader
  exec_init
}

main() {
  echo "starting the shimboot bootloader"

  enable_debug_console "$TTY2"

  local autoboot_tried=""

  while true; do
    #rescan every pass so a fresh emmc install shows up in the menu
    local valid_partitions="$(find_rootfs_partitions)"

    if [ ! "$autoboot_tried" ]; then
      autoboot_tried=1
      local internal="$(echo "$valid_partitions" | grep ":internal$" | head -n1)"
      if [ "$internal" ] && autoboot_wait; then
        boot_target "$(echo "$internal" | cut -d ":" -f 1)"
      fi
    fi

    clear
    print_selector "${valid_partitions}"

    if get_selection "${valid_partitions}"; then
      break
    fi
  done
}

trap - EXIT
main "$@"
sleep 1d
