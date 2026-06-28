# SteamOS Dual Boot Installer

Install SteamOS into already-created unallocated space on your SSD without wiping your existing Windows install.

Latest GUI build:

- [Download the latest release](https://github.com/Josh5/steamos_dual_boot_installer_patch/releases/latest)

Download this binary from the latest release page:

- `steamos-installer-wizard-<version>-linux-x86_64`

> [!IMPORTANT]
> You must shrink your Windows partition yourself in Windows before booting the SteamOS recovery image. This tool does not resize partitions. It creates the SteamOS partition set inside prepared unallocated space and performs the install there.

## Supported Devices

- Tested on ROG Ally X
- Tested on a DIY Steam Machine:
  - AMD 5800X
  - AMD RX 9060 XT
  - 16 GB RAM
  - 1 NVMe SSD shared by Windows, Bazzite, and SteamOS
  - 2 additional SSDs for game storage
- Expected to also work on similar ASUS and Lenovo handhelds, but not personally tested on all of them

## Why this exists

Valve’s recovery image assumes it owns the whole disk. That is fine for a clean install, but wasteful if Windows is already set up and you only want to install SteamOS into free space you prepared ahead of time.

This project provides two ways to do that:

- A GUI wizard that helps you pick the correct disk and unallocated region from inside SteamOS recovery
- A direct `run.sh` backend flow if you want to execute the installer manually

## What the tool does

- Detects existing disks, partitions, and unallocated regions
- Creates the standard SteamOS partition layout after your existing partitions:
  - `esp`, `efi-A`, `efi-B`, `rootfs-A`, `rootfs-B`, `var-A`, `var-B`, and `home`
- Formats the new partitions
- Copies the SteamOS recovery root filesystem into the new SteamOS partitions
- Finalizes the SteamOS boot configuration
- Does not shrink Windows or resize existing partitions for you

Default backend values:

- `TARGET_DISK=/dev/nvme0n1`
- `ESP_SIZE=256M`
- `EFI_SIZE=64M`
- `ROOT_SIZE=11G`
- `VAR_SIZE=1G`

## Prerequisites

Do these in Windows before booting SteamOS recovery:

1. Disable device encryption.
   Go to `Settings > Privacy & Security > Device Encryption` and turn it off. Wait for decryption to fully finish.
2. Shrink the Windows partition.
   Open `Disk Management`, shrink `C:`, and leave the new space as unallocated. Do not create a filesystem there.
3. Disable Fast Startup in Windows.
   Go to `Control Panel > Power Options > Choose what the power buttons do`, unlock the protected settings, and uncheck `Turn on fast startup`.
4. Disable Secure Boot in BIOS.
5. Disable Fast Boot in BIOS.
6. Create a SteamOS recovery USB.
   Use Valve’s instructions: [SteamOS Recovery Instructions](https://help.steampowered.com/en/faqs/view/65B4-2AA3-5F37-4227)
7. Configure Windows to use UTC for the hardware clock.
   Windows and Linux treat the RTC differently by default. If the clock is wrong after booting Linux, SteamOS recovery can fail HTTPS/TLS validation and report a connection problem even though Wi-Fi itself is working.

   Reference:
   - [Arch Wiki: UTC in Microsoft Windows](https://wiki.archlinux.org/title/System_time?utm_source=chatgpt.com#UTC_in_Microsoft_Windows)

   Administrator Command Prompt command:

   ```bat
   reg add "HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal /d 1 /t REG_DWORD /f
   ```

   > [!IMPORTANT]
   > After applying the Windows UTC change, make sure the actual system time is correct before starting recovery. It is worth forcing Windows to resync the clock before rebooting. Change the time manually, then set it back correctly, or otherwise trigger a time resync, and verify the BIOS/system clock is correct before booting SteamOS recovery.

## GUI Install Flow

This is the recommended way to use the project.

1. Boot from the SteamOS recovery USB.
2. Download the latest `steamos-installer-wizard` build from the repository releases page.
3. In the file manager, right-click the downloaded file, open `Properties`, go to `Permissions` tab, and allow it to be executed as a program.
4. Double click the `steamos-installer-wizard` file to run the wizard.
5. Let the wizard guide you through selecting the target disk and unallocated region, reviewing the install plan, and launching the installer.
6. Reboot when finished and select SteamOS or Windows from your boot menu.

Alternately, if you prefer using a terminal, you can also download and run the current latest GUI build with:

```bash
url="$(curl -fsSL https://api.github.com/repos/Josh5/steamos_dual_boot_installer_patch/releases/latest | grep -o 'https://[^"]*steamos-installer-wizard-[^"]*-linux-x86_64' | head -n 1)" && curl -fsSL "$url" -o /tmp/steamos-installer-wizard && chmod +x /tmp/steamos-installer-wizard && /tmp/steamos-installer-wizard
```

## Script Install Flow

Use this if you do not want to use the GUI, or if you want to simply run the installer script on its own (not really recomended tho).

1. Boot the device from the **SteamOS recovery USB** (Secure Boot must be **off**).
2. Open a **terminal** (Konsole) from the application menu.
3. Clone the repo and run the backend:

   ```bash
   git clone https://github.com/Josh5/steamos_dual_boot_installer_patch
   cd steamos_dual_boot_installer_patch
   sudo ./run.sh
   ```

   or if you want to run it in a single line:

   ```bash
   wget -O /tmp/run.sh https://raw.githubusercontent.com/Josh5/steamos_dual_boot_installer_patch/refs/heads/master/run.sh && sudo bash /tmp/run.sh
   ```

The script flow assumes you already know which disk and free-space region you want to use. It also will assume you are targeting the first disk.

## Videos

### DIY Steam Machine Dual Boot

[![DIY Steam Machine Dual Boot video](https://img.youtube.com/vi/8_6u0za39JA/0.jpg)](https://youtu.be/8_6u0za39JA)

https://youtu.be/8_6u0za39JA

### Dual Boot Ally X

[![Dual Boot Ally X](https://img.youtube.com/vi/sVW2MKR5cNk/0.jpg)](https://www.youtube.com/watch?v=sVW2MKR5cNk)

https://www.youtube.com/watch?v=sVW2MKR5cNk

### Unofficial Guides

[![ROG Ally X guide](https://img.youtube.com/vi/pd76H_FATT4/0.jpg)](https://www.youtube.com/watch?v=pd76H_FATT4)

https://www.youtube.com/watch?v=pd76H_FATT4

## Script Configuration

Environment variables you can pass to `run.sh`:

- `TARGET_DISK` (default `/dev/nvme0n1`)
- `ESP_SIZE` (default `256M`)
- `EFI_SIZE` (default `64M`)
- `ROOT_SIZE` (default `11G`)
- `VAR_SIZE` (default `1G`)

Example:

```bash
sudo TARGET_DISK=/dev/nvme1n1 ROOT_SIZE=15G ./run.sh
```

## Safety Notes

- Double-check that the space you prepared is truly unallocated before running the installer.
- Double-check that you selected the correct physical disk.
- Double-check the first new partition number shown in the review step or backend output.

> [!WARNING]
> This is not an official Valve workflow. Use it at your own risk.

## High-Level Partition Layout

This installer creates the standard SteamOS partition set inside the unallocated space you prepared. It does not replace your existing Windows partitions. It appends a new SteamOS layout after the partitions you already have on the selected disk.

The installer creates 8 new partitions:

- `esp`
- `efi-A`
- `efi-B`
- `rootfs-A`
- `rootfs-B`
- `var-A`
- `var-B`
- `home`

This means you will see:

- 1 `esp` partition
- 2 `efi` partitions: `efi-A` and `efi-B`
- 2 root filesystem partitions: `rootfs-A` and `rootfs-B`
- 2 `var` partitions: `var-A` and `var-B`
- 1 `home` partition that uses the remaining selected space

The two `efi` partitions and the two `rootfs` partitions are part of SteamOS's A/B system layout. That is expected and matches the official SteamOS recovery scripts.

## Credits

Created by **Josh5** to save everyone from wasting a day reinstalling Windows just to try SteamOS next to it.
