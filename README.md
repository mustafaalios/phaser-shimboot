# Phaser Shimboot

A fork of [ading2210/shimboot](https://github.com/ading2210/shimboot) specialised for the **Lenovo 100e Chromebook Gen 2 (Phaser, `octopus` board, Celeron N4020)**.

Shimboot patches a Chrome OS RMA shim so it boots a regular Linux distribution. Because this fork targets a single board, the multi-board, ARM, Ubuntu, squashfs and Chrome OS-booting features were removed, and the install is designed around the internal eMMC: the USB drive or SD card is only used to boot, and the system itself lives on the eMMC.

## How it differs from upstream
- Builds for `octopus` only (`sudo ./build_complete.sh`).
- **Install to eMMC** from the bootloader menu (`i`). This erases the eMMC, including Chrome OS, and clones the rootfs from the boot media onto it.
- **Auto-boot**: once installed, the bootloader boots the eMMC system after 3 seconds. Press any key to open the menu instead.
- The root filesystem **grows to fill the disk on first boot** (no manual `expand_rootfs`).
- **Time sync** is enabled out of the box (`systemd-timesyncd` on Debian, `chrony` on Alpine) to avoid the clock getting stuck at an old date.
- Weekly `fstrim`, a capped journal, and tap-to-click on the touchpad.
- The Chrome OS boot options (donor partition, `crossystem` and `mount-encrypted` spoofing) were removed.

## Partition layout of the boot media
1. 1MB dummy stateful partition
2. 32MB Chrome OS kernel (from the shim)
3. 20MB bootloader
4. The rootfs, used as the source for the eMMC install

Rootfs partitions have to be named `shimboot_rootfs:<partname>` for the bootloader to recognise them. The installer sets this label on the eMMC partition automatically.

## Building
You need a Debian-based Linux PC (WSL2 works) with about 20GB free.

```bash
sudo ./build_complete.sh
```

Useful arguments: `distro=alpine`, `release=bookworm`, `distro_kernel=false`, `desktop=lxqt`, `luks=1`, `compress_img=1`. See `./build_complete.sh --help`.

## Booting and installing
1. Flash `data/shimboot_octopus.bin` to a USB drive or SD card.
2. Put the Chromebook in developer mode (see the [sh1mmer website](https://sh1mmer.me) if it is enrolled), plug in the drive and enter recovery mode.
3. In the bootloader menu choose `i`, type `ERASE` to confirm, and wait for the copy to finish.
4. Reboot. Keep the boot media inserted: the firmware still needs it to start the shim, but everything else runs from the eMMC.

Installing erases Chrome OS. The firmware and enrollment status are not touched, and Chrome OS can be restored with a recovery USB.

After installing, you no longer need the large image. Flash `shimboot_octopus_boot.bin` (about 55MB, boot partitions only, no rootfs) to any small USB stick and leave it plugged in. The firmware only starts the shim from external media, but everything else runs from the eMMC, so the stick can be a tiny flush drive.

If the system fails to boot, type `rescue <number>` at the bootloader prompt to get a shell before init starts.

## Newer kernel (kexec)
The shim's kernel is Linux 4.14, and the firmware will only start that one from external media. Builds now also install the distro's own kernel in the rootfs (`distro_kernel=true`, the default on Debian; the default release is `trixie`, which ships Linux 6.12 LTS). When you boot a rootfs, the bootloader loads that kernel with a static `kexec` and jumps into it, so `uname -r` shows the new version. The shim kernel is then only the launcher.

- It falls back to booting on the shim's own kernel if the shim kernel was built without `CONFIG_KEXEC` (check with `ls /sys/kernel/kexec_loaded` in the bootloader shell), if `kexec` fails, if the rootfs is LUKS-encrypted, or in `rescue` mode. Set `USE_KEXEC="no"` in `bootloader/opt/shimboot.conf` to turn it off.
- A rootfs only gets the new kernel if it has `/boot/vmlinuz-*` and `/boot/initrd.img-*`, so an eMMC installed from an older image keeps booting on 4.14 until you install a new image.
- **Untested on hardware.** Please report what `uname -r` shows and what the bootloader prints.

## Experimental: a newer shim kernel from another board
The octopus RMA shim carries Linux 4.14.91 and no kexec, and it is signed, so it can't be changed. The firmware's recovery key is shared across most Chromebooks, so the shim of another board may boot on octopus. `shim_board=<board>` takes the signed launcher kernel (and the matching modules) from that board's shim, while the recovery image, firmware and rootfs still come from octopus.

Kernel versions inside the shims (printed by the `probe-shim-kernels` workflow, `tools/probe_shim_kernels.py`): coral 4.4.96, grunt 4.14.75, octopus 4.14.91, hatch 4.19.84, puff 4.19.131, volteer 5.4.76, zork 5.4.85, dedede 5.4.85, brya 5.10.99, nissa 5.15.74.

```bash
sudo ./build_complete.sh shim_board=nissa     # data/shimboot_octopus_nissa.bin
sudo ./build_complete.sh shim_board=dedede    # data/shimboot_octopus_dedede.bin
```

CI builds `shimboot_octopus_nissa` (5.15) and `shimboot_octopus_dedede` (5.4) next to the normal image. **Untested on hardware.** If the firmware refuses the donor kernel, or the kernel lacks a driver the 100e needs, the screen stays blank or it falls to the recovery screen, and the normal octopus image still works. `uname -r` in the booted system shows which kernel you got.

## Booting without the USB drive
With stock firmware the USB cannot be avoided in recovery mode: the firmware only starts the Google-signed shim kernel from external media. The experimental internal boot (dev-key signed kernel on the eMMC, started with Ctrl+D) needs developer mode to accept it. On at least one enrolled Lenovo 100e Gen 2, Ctrl+D did nothing on either the 'OS verification is OFF' screen or the recovery screen, so the firmware is deciding this and software cannot override it without changing the firmware. Choosing `d` in the bootloader menu prints the firmware settings it can read (`crossystem` values, kexec support, disk layout) and saves them to `shimboot_diag.txt` on the boot drive, which narrows down why. Please attach that file to an issue.

Why it isn't working on an enrolled unit is still unconfirmed. Possible causes are enterprise firmware management parameters (FWMP) blocking dev boot or forcing official-only kernels. That is a guess, not something tested here.

### With write-protect off: UEFI firmware (true auto-boot)
```bash
sudo ./build_uefi.sh data/shimboot_octopus_uefi.bin
```
This builds a normal GPT/GRUB-EFI Debian image with the distro kernel and no shim, for a Chromebook running custom UEFI firmware (for example [MrChromebox](https://docs.mrchromebox.tech/docs/supported-devices.html)). It boots from USB or the internal disk like a PC. From a USB-booted copy, `sudo install_to_internal` copies it to the eMMC. CI builds it as `shimboot_octopus_uefi`.

Hardware steps (Cr50 board, so battery disconnect; SuzyQ/CCD needs dev mode):
1. Check your board on the supported devices page above, which also lists its write-protect method.
2. Fully disable write-protect. All three are needed:
   1. **Hardware**: the GSC/Cr50 write-protect state, by disconnecting the battery with the charger plugged in.
   2. **Software**: write-protect on the flash chip itself.
   3. **Protected range**: clear it, start and end both 0.

   The firmware script normally does 2 and 3. To check by hand, `flashrom -p internal --wp-status`, then `--wp-disable` and `--wp-range 0,0` (flags vary between flashrom versions; older ones take `--wp-range 0 0`). Status should read disabled with start and len both `0x000000` before flashing.
3. Run the firmware utility script and **back up the stock firmware**, then flash the UEFI Full ROM.
4. Power off, unplug the charger, reconnect the battery, and boot the UEFI image from USB.

Chrome OS can't run on UEFI firmware. To go back, flash the stock firmware backup and use a recovery USB. Enrollment is tied to the device, so an enrolled unit normally re-enrolls on its own.

## Known limitations
- The shim's Chrome OS kernel is old, so suspend and swap are disabled by it. Audio support is unverified on this board.
- If GPU acceleration fails, install the `mesa-amber` drivers: `sudo apt install libglx-amber0 libegl-amber0` and set `MESA_LOADER_DRIVER_OVERRIDE=i965` in `/etc/environment`.
- If you cannot connect to some wifi networks, disable PMF: `nmcli connection edit <name>`, `set 802-11-wireless-security.pmf disable`, `save`, `activate`.

## Copyright
Shimboot is licensed under the [GNU GPL v3](https://www.gnu.org/licenses/gpl-3.0.txt). Unless otherwise indicated, the original code was written by [ading2210](https://github.com/ading2210). LUKS2 encryption was contributed by [@a1g0r1thm9](https://github.com/a1g0r1thm9).

```
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
```
