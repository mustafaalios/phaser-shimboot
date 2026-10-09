#!/bin/bash

#patch the target rootfs to add any needed drivers

. ./common.sh
. ./image_utils.sh

print_help() {
  echo "Usage: ./patch_rootfs.sh shim_path reco_path rootfs_dir"
}

assert_root
assert_deps "git gunzip depmod readelf"
assert_args "$3"

copy_modules() {
  local shim_rootfs=$(realpath -m $1)
  local reco_rootfs=$(realpath -m $2)
  local target_rootfs=$(realpath -m $3)

  #keep any modules the rootfs already has (the distro kernel used with kexec), the shim's go alongside
  mkdir -p "${target_rootfs}/lib/modules"
  cp -r "${shim_rootfs}/lib/modules/"* "${target_rootfs}/lib/modules/"

  mkdir -p "${target_rootfs}/lib/firmware"
  cp -r --remove-destination "${shim_rootfs}/lib/firmware/"* "${target_rootfs}/lib/firmware/"
  cp -r --remove-destination "${reco_rootfs}/lib/firmware/"* "${target_rootfs}/lib/firmware/"

  mkdir -p "${target_rootfs}/lib/modprobe.d/"
  mkdir -p "${target_rootfs}/etc/modprobe.d/"
  cp -r "${reco_rootfs}/lib/modprobe.d/"* "${target_rootfs}/lib/modprobe.d/"
  cp -r "${reco_rootfs}/etc/modprobe.d/"* "${target_rootfs}/etc/modprobe.d/"

  #decompress kernel modules if necessary - debian won't recognize these otherwise
  local compressed_files="$(find "${target_rootfs}/lib/modules" -name '*.gz')"
  if [ "$compressed_files" ]; then
    echo "$compressed_files" | xargs gunzip
    for kernel_dir in "$target_rootfs/lib/modules/"*; do
      local version="$(basename "$kernel_dir")"
      depmod -b "$target_rootfs" "$version"
    done
  fi
}

copy_firmware() {
  local firmware_path="/tmp/chromium-firmware"
  local target_rootfs=$(realpath -m $1)

  if [ ! -e "$firmware_path" ]; then
    download_firmware $firmware_path
  fi

  cp -r --remove-destination "${firmware_path}/"* "${target_rootfs}/lib/firmware/"
}

download_firmware() {
  local firmware_url="https://chromium.googlesource.com/chromiumos/third_party/linux-firmware"
  local firmware_path=$(realpath -m $1)

  git clone --branch master --depth=1 "${firmware_url}" $firmware_path
}

#copy ectool and the shared libraries it needs out of the recovery image, so that
#the charging fix can talk to the embedded controller
copy_ectool() {
  local reco_rootfs=$(realpath -m $1)
  local target_rootfs=$(realpath -m $2)
  local ectool_src="${reco_rootfs}/usr/sbin/ectool"
  local lib_dir="${target_rootfs}/usr/local/lib/shimboot-ectool"

  if [ ! -f "$ectool_src" ]; then
    echo "warning: ectool was not found in the recovery image, skipping the charging fix"
    return 0
  fi

  mkdir -p "$lib_dir"
  cp "$ectool_src" "$lib_dir/ectool.real"
  chmod +x "$lib_dir/ectool.real"

  #walk the NEEDED entries, skipping the core libc libraries since the rootfs provides those
  local queue="$ectool_src"
  local seen=""
  while [ "$queue" ]; do
    local current="${queue%% *}"
    if [ "$current" = "$queue" ]; then queue=""; else queue="${queue#* }"; fi
    local needed="$(readelf -d "$current" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')"
    for lib in $needed; do
      case "$lib" in
        libc.so*|libm.so*|libdl.so*|libpthread.so*|librt.so*|ld-linux*|libgcc_s.so*|libstdc++.so*) continue ;;
      esac
      case " $seen " in *" $lib "*) continue ;; esac
      seen="$seen $lib"
      local found="$(find "$reco_rootfs/lib64" "$reco_rootfs/usr/lib64" "$reco_rootfs/lib" "$reco_rootfs/usr/lib" -name "$lib" 2>/dev/null | head -n1)"
      if [ "$found" ]; then
        cp -L "$found" "$lib_dir/$lib"
        queue="$queue $lib_dir/$lib"
      else
        echo "warning: could not find $lib for ectool"
      fi
    done
  done

  #the wrapper makes ectool find the bundled libraries
  cat > "${target_rootfs}/usr/local/bin/ectool" << 'EOF'
#!/bin/sh
export LD_LIBRARY_PATH="/usr/local/lib/shimboot-ectool${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec /usr/local/lib/shimboot-ectool/ectool.real "$@"
EOF
  chmod +x "${target_rootfs}/usr/local/bin/ectool"
}

shim_path=$(realpath -m $1)
reco_path=$(realpath -m $2)
target_rootfs=$(realpath -m $3)
shim_rootfs="/tmp/shim_rootfs"
reco_rootfs="/tmp/reco_rootfs"

echo "mounting shim"
shim_loop=$(create_loop "${shim_path}")
safe_mount "${shim_loop}p3" $shim_rootfs ro

echo "mounting recovery image"
reco_loop=$(create_loop "${reco_path}")
safe_mount "${reco_loop}p3" $reco_rootfs ro

echo "copying modules to rootfs"
copy_modules $shim_rootfs $reco_rootfs $target_rootfs

echo "copying ectool"
copy_ectool $reco_rootfs $target_rootfs

echo "downloading misc firmware"
copy_firmware $target_rootfs

echo "unmounting and cleaning up"
umount $shim_rootfs
umount $reco_rootfs
losetup -d $shim_loop
losetup -d $reco_loop

echo "done"