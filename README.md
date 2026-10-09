Phaser specific fork of Shimboot, this is specifically made to make QoL far better on my specific device, the Lenovo 100e Gen 2 (81MA), however it should work on other Phaser (Octopus) boards too.


## What this fork changes

Stock shimboot boots the Chrome OS RMA shim's kernel, which on Octopus boards is **Linux 4.14**. This fork adds two boot tracks, depending on whether you've disabled hardware write-protect (WP).

### Track A: write-protect ON (stock firmware, stays enrolled)

```
sudo ./build_complete.sh octopus          # distro_kernel=true is the default on amd64
```

- The image still has to be booted from external media with **Esc + Refresh + Power** (recovery mode). The firmware only accepts the shim's Google-signed kernel in recovery mode and only from removable media. Dev mode is blocked on an enrolled device, so software can't change this.
- The shim's 4.14 kernel is used only to start. The bootloader then `kexec`s into the distro's own kernel from the rootfs (Debian 12 ships 6.1 and Debian 13 ships 6.12).
  - It falls back to the old shim-kernel boot if the shim kernel has no `CONFIG_KEXEC`, if `kexec` fails, or if the rootfs is LUKS-encrypted.
  - Check kexec support on the device with `ls /sys/kernel/kexec_loaded` from the bootloader shell (`s` in the menu).
- The bootloader boots by itself after a countdown (default 5s, press any key for the menu) and prefers the internal eMMC over USB/SD. Edit `bootloader/opt/shimboot.conf` to change `AUTOBOOT_TIMEOUT`, `AUTOBOOT_PREFER` and `USE_KEXEC`.
- `install_to_internal` (in the rootfs, `/usr/local/bin`) copies the running system to the eMMC. **This erases Chrome OS.**
- After the install, a bootable USB or SD card is still needed to start the shim kernel. It can be a tiny drive that stays plugged in. The rootfs lives on the eMMC, and the drive only has to hold the kernel and bootloader.

### Track B: write-protect OFF + custom UEFI firmware (true auto-boot)

```
sudo ./build_uefi.sh data/uefi.bin
```

- This builds a normal GPT/GRUB-EFI Debian image with the distro kernel and no shim, then boots it from USB or the internal disk like any PC.
- Hardware steps:
  1. Find your board name on the recovery screen (bottom of the screen, first part of the HWID) and check it on the [MrChromebox supported devices list](https://docs.mrchromebox.tech/docs/supported-devices.html). That page also lists your device's write-protect method (battery disconnect, a jumper, or a screw), and the [write-protect guide](https://docs.mrchromebox.tech/docs/firmware/wp/disabling.html) covers the procedure.
  2. Disable write-protect.
  3. Run the firmware utility script and **back up the stock firmware** when it offers to. Keep that backup somewhere safe.
  4. Flash the UEFI Full ROM.
  5. Write `uefi.bin` to a USB drive, boot it, then run `install_to_internal` to copy it to the eMMC.
- Chrome OS can't run on UEFI firmware. To go back, flash the stock firmware backup and use a recovery USB. Enrollment is tied to the device, not the firmware, so an enrolled device normally re-enrolls on its own.

## Status: untested on hardware

This fork was written without access to a Phaser/Octopus device or to the shim download. These pieces were only syntax-checked, or tested with mocks, and have never been run end to end:
- `kexec` handoff
- `build_kexec.sh`
- `build_uefi.sh`
- `install_to_internal`

Expect to debug on first use, and please report what breaks. The autoboot picker and countdown logic were tested with mocks.
