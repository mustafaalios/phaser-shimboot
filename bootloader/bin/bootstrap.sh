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

#settings, overridable by editing /opt/shimboot.conf on the bootloader partition
USE_KEXEC="auto"       #"auto" kexecs into the rootfs's own kernel when possible, "no" always uses the shim kernel
[ -f /opt/shimboot.conf ] && . /opt/shimboot.conf

#get the whole-disk name (e.g. mmcblk0, sda) from a partition path
part_disk_name() {
  local name="${1#/dev/}"
  case "$name" in
    mmcblk*|nvme*|loop*) echo "$name" | sed 's/p[0-9]\+$//' ;;
    *) echo "$name" | sed 's/[0-9]\+$//' ;;
  esac
}

#get the partition number from a partition path
part_number() {
  echo "$1" | sed 's/.*[^0-9]\([0-9]\+\)$/\1/'
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

#print facts about the firmware and boot setup, and save them to the boot media's stateful partition
#so they can be read on another computer. useful for working out why internal boot is refused
show_diagnostics() {
  local out="/tmp/shimboot_diag.txt"
  {
    echo "== bootloader kernel"
    uname -r
    cat /proc/cmdline
    echo
    echo "== kexec"
    [ -e /sys/kernel/kexec_loaded ] && echo "kernel supports kexec" || echo "kernel has NO kexec support"
    command -v kexec >/dev/null && echo "kexec binary present" || echo "kexec binary missing"
    echo
    echo "== firmware (crossystem)"
    if command -v crossystem >/dev/null 2>&1; then
      for key in hwid fwid ro_fwid mainfw_type mainfw_act wpsw_cur devsw_boot devsw_cur \
          dev_boot_signed_only dev_boot_usb dev_boot_legacy block_devmode recovery_reason \
          recovery_request cros_debug tpm_fwver; do
        echo "$key = $(crossystem $key 2>&1)"
      done
    else
      echo "crossystem is not available in this environment"
    fi
    echo
    echo "== tpm / security chip"
    ls /sys/class/tpm 2>&1
    echo
    echo "== disks"
    for disk in /dev/mmcblk[0-9] /dev/sd[a-z]; do
      [ -b "$disk" ] || continue
      echo "-- $disk"
      cgpt show "$disk" 2>&1
    done
    echo
    echo "== kernel messages"
    dmesg 2>/dev/null | grep -iE 'kexec|lockdown|tpm|secure|verity|cr50|gsc' | tail -n 20
  } > "$out" 2>&1

  clear
  cat "$out"

  #save a copy to the stateful partition of the external boot media
  local saved=""
  for rootfs_partition in $(find_rootfs_partitions); do
    local part_path=$(echo $rootfs_partition | cut -d ":" -f 1)
    local disk="/dev/$(part_disk_name "$part_path")"
    is_emmc_disk "$disk" && continue
    local state="$(get_part_dev "$disk" 1)"
    mkdir -p /tmp/diag_mnt
    if [ -b "$state" ] && mount "$state" /tmp/diag_mnt 2>/dev/null; then
      cp "$out" /tmp/diag_mnt/shimboot_diag.txt 2>/dev/null && saved="$state"
      umount /tmp/diag_mnt
    fi
    break
  done
  echo
  if [ "$saved" ]; then
    echo "saved to shimboot_diag.txt on $saved (the 1MB partition 1 of the boot drive)"
  else
    echo "couldn't save to the boot drive; photograph this screen instead"
  fi
  read -p "press [enter] to return to the bootloader menu"
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
  echo "d) diagnostics"
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
  elif [ "$selection" = "d" ]; then
    show_diagnostics
    return 1
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

#copy a block device to another one with a progress bar
clone_partition() {
  local source="$1"
  local target="$2"
  local bytes=$(($(dev_sectors "$source") * 512))
  dd if="$source" bs=4M 2>/dev/null | pv -s "$bytes" | dd of="$target" bs=4M conv=fsync 2>/dev/null
}

wait_for_partition() {
  local target="$1"
  local tries=0
  while [ ! -b "$target" ] && [ "$tries" -lt 10 ]; do
    mdev -s 2>/dev/null
    sleep 1
    tries=$((tries+1))
  done
  [ -b "$target" ]
}

#wipe the emmc, then recreate the boot media's layout on it so the emmc can boot by itself:
#1 stateful, 2 kernel, 3 bootloader, 4 rootfs
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

  #the other partitions come from the same disk as the rootfs
  local source_disk="$(echo "$source" | sed 's/p\?[0-9]\+$//')"
  local src_state="$(get_part_dev "$source_disk" 1)"
  local src_kernel="$(get_part_dev "$source_disk" 2)"
  local src_boot="$(get_part_dev "$source_disk" 3)"
  for part in "$src_state" "$src_kernel" "$src_boot"; do
    if [ ! -b "$part" ]; then
      echo "unexpected layout on the boot media, $part is missing"
      sleep 3
      return 1
    fi
  done

  #sector layout, 1MiB aligned
  local disk_sectors="$(dev_sectors "$emmc")"
  local state_start=2048
  local state_sectors=2048
  local kernel_start=4096
  local kernel_sectors=65536
  local boot_start=$((kernel_start + kernel_sectors))
  local boot_sectors="$(dev_sectors "$src_boot")"
  local rootfs_start=$((boot_start + boot_sectors))
  local rootfs_sectors="$(dev_sectors "$source")"
  local rootfs_max=$((disk_sectors - rootfs_start - 2048))
  if [ "$rootfs_max" -lt "$rootfs_sectors" ]; then
    echo "the emmc is too small for this image"
    sleep 2
    return 1
  fi

  clear
  echo "This will ERASE EVERYTHING on ${emmc}, including Chrome OS."
  echo "The firmware and enrollment are not touched, and Chrome OS can be restored"
  echo "later with a recovery usb."
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
  local kernel_type="FE3A2A5D-4F32-41A7-B725-ACCC3285A309"
  local rootfs_type="3CB8E202-3B7E-47DD-8A3C-7FF2A13CFCEC"
  local data_type="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
  cgpt create -z "$emmc" || return 1
  cgpt create "$emmc" || return 1
  cgpt add -i 1 -t $data_type -b $state_start -s $state_sectors -l "stateful" "$emmc" || return 1
  cgpt add -i 2 -t $kernel_type -b $kernel_start -s $kernel_sectors -l "kernel" -S 1 -T 5 -P 10 "$emmc" || return 1
  cgpt add -i 3 -t $rootfs_type -b $boot_start -s $boot_sectors -l "bootloader" "$emmc" || return 1
  cgpt add -i 4 -t $data_type -b $rootfs_start -s $((rootfs_max)) -l "shimboot_rootfs:${source_name}" "$emmc" || return 1
  #writing the table with fdisk makes the kernel re-read it
  echo w | fdisk "$emmc" >/dev/null 2>&1

  local emmc_state="$(get_part_dev "$emmc" 1)"
  local emmc_kernel="$(get_part_dev "$emmc" 2)"
  local emmc_boot="$(get_part_dev "$emmc" 3)"
  local emmc_rootfs="$(get_part_dev "$emmc" 4)"
  for part in "$emmc_state" "$emmc_kernel" "$emmc_boot" "$emmc_rootfs"; do
    if ! wait_for_partition "$part"; then
      echo "partition $part did not appear"
      sleep 3
      return 1
    fi
  done

  echo "copying the bootloader"
  clone_partition "$src_state" "$emmc_state"
  clone_partition "$src_boot" "$emmc_boot"

  #the emmc gets a kernel signed for developer mode boots, if the image includes one
  if [ -f /opt/kernel_dev.img ]; then
    echo "writing the internal-boot kernel"
    dd if=/opt/kernel_dev.img of="$emmc_kernel" bs=1M conv=fsync 2>/dev/null
  else
    echo "this image has no internal-boot kernel, copying the boot media kernel instead"
    clone_partition "$src_kernel" "$emmc_kernel"
  fi

  echo "copying $source to $emmc_rootfs"
  clone_partition "$source" "$emmc_rootfs"
  sync

  echo
  echo "install finished. the root filesystem will grow to fill the emmc on the first boot."
  echo
  echo "to boot without the external drive: unplug it, reboot, and at the"
  echo "'OS verification is OFF' screen press Ctrl+D. if the firmware refuses, the"
  echo "external drive and Esc+Refresh+Power still work as before."
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

#load the kernel from the target rootfs and jump into it, this only returns on failure
#the shim kernel is old (4.14 on octopus), so this lets the distro's own newer kernel run instead
try_kexec() {
  local target="$1"
  local mnt="$2"

  [ "$USE_KEXEC" = "no" ] && return 1
  [ "$rescue_mode" = "1" ] && return 1
  [ -x "$(command -v kexec)" ] || return 1
  if [ ! -e /sys/kernel/kexec_loaded ]; then
    echo "kexec: the shim kernel was built without kexec support, using it instead"
    return 1
  fi

  local kernel="$(ls -1 $mnt/boot/vmlinuz-* 2>/dev/null | sort -V | tail -n1)"
  [ "$kernel" ] || return 1
  local version="${kernel##*/vmlinuz-}"
  local initrd="$mnt/boot/initrd.img-$version"
  [ -f "$initrd" ] || return 1

  local disk="/dev/$(part_disk_name "$target")"
  local partuuid="$(cgpt show -i "$(part_number "$target")" -u "$disk" 2>/dev/null)"
  [ "$partuuid" ] || return 1

  echo "kexec: loading kernel $version"
  if ! kexec -l "$kernel" --initrd="$initrd" \
      --command-line="root=PARTUUID=$partuuid rootwait rw quiet"; then
    echo "kexec: failed to load the kernel, falling back"
    return 1
  fi

  echo "kexec: jumping into the new kernel"
  sync
  umount "$mnt" 2>/dev/null
  kexec -e
  echo "kexec: failed to execute the new kernel, falling back"
  kexec -u 2>/dev/null
  mount "$target" "$mnt" #we unmounted it above, the normal boot path still needs it
  return 1
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
    if try_kexec "$target" /newroot; then
      return 0
    fi
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
