#!/bin/bash
#build an out-of-tree module for the shim kernel
#usage: tools/build_shim_kmod.sh ksrc module_dir inspect_dir
#ksrc is the chromeos kernel tree at the shim's commit, inspect_dir is the output of inspect_shim_kernel.sh
#the shim has no embedded config, so this uses the chromeos x86_64 config and forces the shim's release string

set -e
ksrc="$(realpath "$1")"
moddir="$(realpath "$2")"
inspect="$(realpath "$3")"
release="$(cut -d' ' -f1 "$inspect/modules.vermagic")"
jobs="$(nproc)"

cd "$ksrc"
if [ ! -f .config ]; then
  if [ -x chromeos/scripts/prepareconfig ]; then
    chromeos/scripts/prepareconfig chromiumos-x86_64
  else
    echo "no chromeos/scripts/prepareconfig, falling back to x86_64_defconfig"
    make x86_64_defconfig
  fi
  #match the shim's vermagic flags, and keep the build light
  vermagic="$(cat "$inspect/modules.vermagic")"
  case "$vermagic" in *modversions*) scripts/config -e MODVERSIONS ;; *) scripts/config -d MODVERSIONS ;; esac
  case "$vermagic" in *preempt*) scripts/config -e PREEMPT ;; esac
  scripts/config -d MODULE_SIG -d DEBUG_INFO -d STACK_VALIDATION -d UNWINDER_ORC -e UNWINDER_FRAME_POINTER
  #these only matter for a full kernel build and break host tools on a modern builder; our module
  #needs none of them and touches no struct whose layout they change, so drop them for the module build
  scripts/config -d SECURITY_SELINUX -d SECURITY_SELINUX_BOOTPARAM -d SECURITY_SELINUX_DEVELOP
  scripts/config -d GCC_PLUGINS -d GCC_PLUGIN_RANDSTRUCT -d GCC_PLUGIN_STRUCTLEAK -d GCC_PLUGIN_LATENT_ENTROPY
  make olddefconfig
fi
make -j"$jobs" modules_prepare

#force the release string the shim kernel reports, vermagic is built from it
echo "$release" > include/config/kernel.release
echo "#define UTS_RELEASE \"$release\"" > include/generated/utsrelease.h

#the shim's symbol crcs, as seen in its own modules, so MODVERSIONS checks pass
if [ -s "$inspect/Module.symvers.shim" ]; then
  awk -F'\t' '{print $1 "\t" $2 "\tvmlinux\tEXPORT_SYMBOL"}' "$inspect/Module.symvers.shim" > Module.symvers
fi

make -j"$jobs" M="$moddir" KBUILD_MODPOST_WARN=1 modules
for ko in "$moddir"/*.ko; do
  echo "built $ko"
  echo "  vermagic: $(modinfo -F vermagic "$ko")"
  echo "  shim:     $(cat "$inspect/modules.vermagic")"
  if [ "$(modinfo -F vermagic "$ko")" = "$(cat "$inspect/modules.vermagic")" ]; then echo "  vermagic matches"; else echo "  VERMAGIC MISMATCH"; fi
done
