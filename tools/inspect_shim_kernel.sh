#!/bin/bash
#report what decides whether a self-built kernel module (the kexec module) can load on a shim's kernel
#usage: sudo tools/inspect_shim_kernel.sh shim.bin out_dir
#leaves out_dir/vmlinux, out_dir/modules.vermagic and out_dir/Module.symvers.shim (crcs seen in the shim's modules)

set -e
shim_bin="$(realpath "$1")"
out="$(realpath -m "$2")"
here="$(dirname "$(realpath "$0")")"
mkdir -p "$out"

loop="$(losetup -P --show -f -r "$shim_bin")"
mnt="$(mktemp -d)"
cleanup() { umount "$mnt" 2>/dev/null || true; losetup -d "$loop" 2>/dev/null || true; }
trap cleanup EXIT

echo "== kernel"
dd if="${loop}p2" of="$out/kern.bin" bs=1M status=none
python3 -I "$here/probe_shim_kernels.py" --vmlinux "$out/kern.bin" "$out/vmlinux"
echo "  signed cmdline: $(grep -aoE "[ -~]*cros_[ -~]*" "$out/kern.bin" | head -n1)"

#strings that only exist when the feature is built in
check() {
  if grep -aqF -- "$2" "$out/vmlinux"; then echo "  yes  $1"; else echo "  no   $1"; fi
}
check "module signing (MODULE_SIG)"                    "module.sig_enforce"
check "unsigned modules rejected message"              "Loading of unsigned module is rejected"
check "unsigned modules allowed, taint message"        "module verification failed: signature and/or required key missing"
check "LoadPin LSM"                                    "loadpin"
check "kallsyms_lookup_name in the symbol table"       "kallsyms_lookup_name"
check "kexec built in"                                 "kexec_load"
check "chromiumos LSM"                                 "Chromium OS LSM"
echo "  cmdline defaults containing loadpin/module:"
grep -aoE "(loadpin|module)\.[a-z_]+=[a-z0-9]+" "$out/vmlinux" | sort -u | sed 's/^/    /' || true

echo "== shim rootfs modules"
mount -o ro "${loop}p3" "$mnt"
kdir="$(ls -d "$mnt"/lib/modules/*/ | head -n1)"
echo "  module dir: $kdir"
kos="$(find "$kdir" -name '*.ko' -o -name '*.ko.gz' | head -n 400)"
echo "  modules found: $(echo "$kos" | grep -c . || true)"

tmpko="$(mktemp -d)"
signed=0; unsigned=0; versioned=0
for ko in $kos; do
  f="$tmpko/m.ko"
  case "$ko" in *.gz) zcat "$ko" > "$f" ;; *) cp "$ko" "$f" ;; esac
  if tail -c 28 "$f" | grep -qF "~Module signature appended~"; then signed=$((signed+1)); else unsigned=$((unsigned+1)); fi
  if readelf -S "$f" 2>/dev/null | grep -q "__versions"; then
    versioned=$((versioned+1))
    #collect crc/symbol pairs: each __versions entry is 8 bytes crc (64bit) + 56 bytes name
    objcopy -O binary --only-section=__versions "$f" "$tmpko/v.bin" 2>/dev/null && python3 -I -c '
import struct, sys
d = open(sys.argv[1], "rb").read()
for i in range(0, len(d) - 63, 64):
    crc = struct.unpack_from("<Q", d, i)[0]
    name = d[i + 8:i + 64].split(b"\0")[0].decode()
    print("0x%08x\t%s" % (crc & 0xffffffff, name))
' "$tmpko/v.bin" >> "$out/symvers.raw"
  fi
  [ -s "$out/modules.vermagic" ] || modinfo -F vermagic "$f" > "$out/modules.vermagic" 2>/dev/null || true
done
echo "  signed: $signed  unsigned: $unsigned  with __versions (MODVERSIONS): $versioned"
echo "  vermagic: $(cat "$out/modules.vermagic" 2>/dev/null)"
if [ -s "$out/symvers.raw" ]; then
  sort -u -k2,2 "$out/symvers.raw" > "$out/Module.symvers.shim"
  echo "  distinct crcs collected: $(wc -l < "$out/Module.symvers.shim")"
  for s in kallsyms_lookup_name module_layout __register_chrdev misc_register; do
    grep -P "\t$s\$" "$out/Module.symvers.shim" | sed 's/^/    /' || echo "    (no crc seen for $s)"
  done
fi
echo "== graphics: is the shim's i915 a module, and does it have what Mesa needs"
modname() { basename "$1" | sed -E 's/\.ko(\.gz)?$//'; }
unpack() { case "$1" in *.gz) zcat "$1" > "$2" ;; *) cp "$1" "$2" ;; esac; }
echo "  drm / i915 / intel / video modules shipped:"
find "$kdir" \( -name '*.ko' -o -name '*.ko.gz' \) | grep -E '/gpu/|/video/|/char/agp/|drm|i915|intel_gtt' | sed "s|$kdir||; s|^|    |" | sort
echo "  built into the kernel (modules.builtin) matching drm/i915/agp/fb:"
grep -E 'drm|i915|agp|fb_|video' "$kdir/modules.builtin" 2>/dev/null | sed 's/^/    /' | head -n 30 || true
i915ko="$(find "$kdir" \( -name 'i915.ko' -o -name 'i915.ko.gz' \) | head -n1)"
if [ "$i915ko" ]; then
  unpack "$i915ko" "$out/i915.ko"
  echo "  i915.ko: $(ls -l "$out/i915.ko" | awk '{print $5}') bytes"
  echo "  i915 depends on modules: $(modinfo -F depends "$out/i915.ko")"
  echo "  i915 retpoline/vermagic: $(modinfo -F vermagic "$out/i915.ko")"
  echo "  i915 parameters: $(modinfo -F parm "$out/i915.ko" | cut -d: -f1 | tr '\n' ' ')"
  echo "  context-isolation / golden-state symbols in the shim's i915.ko:"
  (nm "$out/i915.ko" 2>/dev/null || true) | grep -iE 'context_isolation|default_state|intel_engines_has' | sed 's/^/    /'
  strings -a "$out/i915.ko" | grep -iE 'context_isolation|default_state|golden' | sort -u | head -n 10 | sed 's/^/    string: /'
else
  echo "  NO i915 module found, so it is built into the kernel image"
fi
echo "  drm symbols i915 imports that are exported by the kernel (count): $(nm -u "$out/i915.ko" 2>/dev/null | grep -c ' U drm_' || true)"
echo "  loadpin / module settings in the shim's kernel cmdline config:"
grep -rhoE "(loadpin|module)\.[a-z_]+=[a-z0-9]+" "$mnt/etc" 2>/dev/null | sort -u | sed 's/^/    /' || true
rm -rf "$tmpko"
