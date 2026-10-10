# A kexec module for the octopus shim kernel

The octopus RMA shim runs **Linux 4.14.91**, built **without `CONFIG_KEXEC_CORE`**. The
firmware only boots that Google-signed kernel from external media, so it can't be rebuilt or
replaced, and the shimboot kexec path (`bootloader/bin/bootstrap.sh`) normally falls back to
running everything on 4.14. That kernel is too old for some things people actually want on the
100e (for example Vulkan on the Gemini Lake iGPU).

This directory builds a **loadable kernel module that adds kexec back at runtime**, so the
bootloader can `kexec` into the distro's own kernel (Debian trixie ships 6.12 LTS) even though
the shim kernel shipped without it.

> **Status: builds and loads, but the kexec *jump* is unverified on real hardware.** Treat this
> as experimental. If it doesn't work the normal octopus image is unaffected — with no module
> present, the bootloader behaves exactly as before.

## Why this can work on a locked-down shim kernel

The `probe-shim-kernels` and `kexec-module` CI workflows read these facts straight out of the
octopus shim (see `tools/inspect_shim_kernel.sh`):

| Fact | Value on the octopus shim | Why it matters |
|------|---------------------------|----------------|
| Module signature enforcement | **off** (293 stock modules, all unsigned) | a module we build loads without a Google key |
| `MODVERSIONS` | **off** | only the vermagic *string* must match, no per-symbol CRCs |
| `kallsyms_lookup_name` | **exported** | the module can reach unexported internals |
| `CONFIG_KEXEC_CORE` | **off** | confirms we must ship kexec ourselves |
| vermagic | `4.14.91-18023-g2ab161c540baf SMP preempt mod_unload` | the module is built to match this exactly |

## How the module works

* It carries a **trimmed copy of the 4.14 kexec core** (`kernel/kexec_core.c` + `kernel/kexec.c`),
  the **x86_64 relocate code** (`arch/x86/kernel/machine_kexec_64.c`), and the **relocate
  trampoline** (`relocate_kernel_64.S`, verbatim). Crash/kdump, file-based load and kexec-jump are
  all removed — only a plain default `kexec_load` is kept.
* Unexported symbols it needs (`machine_shutdown`, `migrate_to_reboot_cpu`,
  `kernel_restart_prepare`, `max_pfn`, …) are resolved through `kallsyms_lookup_name`. Only
  non-static globals are looked up, so it does **not** depend on `CONFIG_KALLSYMS_ALL`.
* It **hooks the `kexec_load` and `reboot` entries in `sys_call_table`** (4.14 x86_64 still uses the
  classic syscall calling convention, and there is no CR0 write-protect pinning yet). That means the
  **stock `kexec-tools` binary already in the bootloader works unchanged**: `kexec -l` lands in our
  `kexec_load`, and `kexec -e` → `reboot(LINUX_REBOOT_CMD_KEXEC)` lands in our reboot hook.
* It maps all of low RAM (`0 .. max_pfn`) plus the loaded segments identity-mapped for the brief
  trampoline, instead of walking the kernel's static `pfn_mapped[]`.

## Building it

You can't build it in the normal image build, because it needs the matching ChromiumOS kernel
source. CI does the whole thing: the **`kexec-module` workflow** downloads the octopus shim, pulls
the chromeos-4.14 source at the shim's exact commit, builds `shimboot_kexec.ko` in an era-matched
toolchain (gcc-8), checks the vermagic matches, and uploads the `.ko` as an artifact (and attaches
it to draft releases on tags).

To reproduce the steps by hand on a Linux box with network access to googlesource:

```bash
tools/fetch_shim.sh octopus shim.bin                 # download the RMA shim
sudo tools/inspect_shim_kernel.sh shim.bin inspect    # read vermagic + the go/no-go flags
# fetch the chromeos-4.14 source at the commit printed in inspect/vmlinux, into ./ksrc, then:
tools/build_shim_kmod.sh ksrc kexec_mod/src inspect   # -> kexec_mod/src/shimboot_kexec.ko
```

## Installing and testing it (on the 100e)

1. **Pre-flight the symbols first** with the smoke module, which never reboots anything:
   ```bash
   insmod shimboot_kexec_smoke.ko
   dmesg | tail -n 20        # every "required" symbol must say "resolved"
   rmmod shimboot_kexec_smoke
   ```
   If any *required* symbol is missing, stop — the kexec module can't work as-is on your kernel and
   needs a tweak, rather than risking a bad jump.

2. **Ship the module** so the bootloader loads it automatically. Put `shimboot_kexec.ko` at
   **`bootloader/opt/shimboot_kexec.ko`** before building an image (the whole `bootloader/` tree is
   copied onto the bootloader partition), or drop it into `/opt/` on the boot media after flashing.
   The bootloader also checks `/opt/shimboot_kexec.ko` on the rootfs as a fallback.

3. **Boot.** `bootstrap.sh` `insmod`s the module and, if it loaded, runs the normal kexec path into
   the distro kernel. Then in the booted system:
   ```bash
   uname -r        # should show the distro kernel (e.g. 6.12.x), not 4.14.91
   ```

To force the old behavior, set `USE_KEXEC="no"` in `/opt/shimboot.conf` on the bootloader
partition, or just remove the `.ko`.

## Known risks (all need the actual device to settle)

* **Struct layout.** The shim kernel doesn't embed its `.config`, so the module is built with the
  chromeos-4.14 `chromiumos-x86_64` config at the shim's commit. If the real build used a config that
  shifts the layout of a kernel-owned struct the module touches (`struct page`, the page tables),
  `MODVERSIONS` being off means nothing catches it at load time — it would just misbehave. The smoke
  module is the first line of defence; a clean `kexec -l` that then hangs on `-e` is the symptom to
  watch for.
* **The jump itself.** `machine_kexec` tears down the GDT/IDT and jumps through the trampoline. This
  is the part that can only be proven by trying it. If it fails you get a hang or a reboot, and the
  normal octopus image still works.
* **Syscall-table hooking** assumes no CR0.WP pinning (true on 4.14) and the classic x86_64 syscall
  ABI (confirmed: 4.14 has no pt_regs syscall stubs).

Please report what the smoke module prints and what `uname -r` shows after a boot attempt.
