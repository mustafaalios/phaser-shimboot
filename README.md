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

Useful arguments: `distro=alpine`, `release=trixie`, `desktop=lxqt`, `luks=1`, `compress_img=1`. See `./build_complete.sh --help`.

## Booting and installing
1. Flash `data/shimboot_octopus.bin` to a USB drive or SD card.
2. Put the Chromebook in developer mode (see the [sh1mmer website](https://sh1mmer.me) if it is enrolled), plug in the drive and enter recovery mode.
3. In the bootloader menu choose `i`, type `ERASE` to confirm, and wait for the copy to finish.
4. Reboot. Keep the boot media inserted: the firmware still needs it to start the shim, but everything else runs from the eMMC.

Installing erases Chrome OS. The firmware and enrollment status are not touched, and Chrome OS can be restored with a recovery USB.

If the system fails to boot, type `rescue <number>` at the bootloader prompt to get a shell before init starts.

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
