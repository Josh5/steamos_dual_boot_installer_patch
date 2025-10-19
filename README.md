# SteamOS Dual Boot Installer Patch

Patch the **official SteamOS recovery installer** so you can install SteamOS **into already‑created free space** on your SSD — **without wiping your existing Windows install**.

> ✅ You **must** shrink your Windows C: partition yourself in Windows and leave **Unallocated** space **before** booting the SteamOS recovery image. This script **does not** resize partitions; it only patches the installer to target the free space you prepared.

---

## Supported Devices

- ✅ Tested by me on **ROG Ally X**
- ⚠️ Expected to also work on other **ASUS** and **Lenovo** devices (similar setup, but not tested by myself personally)

---

## Why this exists

Valve’s recovery image assumes it owns the whole disk and wipes everything. Reinstalling Windows afterwards is slow and unnecessary. This project **patches the recovery’s `repair_device.sh`** so it installs SteamOS into your **unallocated free space** instead of erasing the disk.

---

## What the script does (high‑level)

- Detects the highest existing Windows partition number.
- Creates the standard SteamOS partition set **after** your existing partitions:
  - `esp`, `efi-A`, `efi-B`, `rootfs-A`, `rootfs-B`, `var-A`, `var-B`, and `home` (remaining space).
- Formats the new partitions and **patches** the recovery’s `repair_device.sh` to target them.
- Invokes the installer to lay down SteamOS into those partitions.
- **Does not** shrink/resize Windows or touch existing Windows partitions.

> Defaults: `TARGET_DISK=/dev/nvme0n1`, sizes can be overridden via env vars: `ESP_SIZE`, `EFI_SIZE`, `ROOT_SIZE`, `VAR_SIZE`.

---

## Prerequisites (do these in Windows **before** recovery)

1. **Disable BitLocker (C:)**
   - Settings > “Manage BitLocker” > Turn off for C:
   - Wait until decryption is complete, then reboot.
2. **Disable Secure Boot**
   - Reboot into BIOS (pressing **VOL+** during boot).
   - Navigate to **Boot > Secure Boot** and disable it.
   - Save and exit.
3. **Shrink C: to create Unallocated space**

   - Open **Disk Management** (`Win+X > Disk Management` or `diskmgmt.msc`).
   - Right‑click **C:** > **Shrink Volume…** > choose the size to free.
   - Ensure the result shows as **Unallocated** (do **not** format it).

4. **Create SteamOS Recovery USB**
   - Follow Valve’s instructions here:  
     [SteamOS Recovery Instructions](https://help.steampowered.com/en/faqs/view/65B4-2AA3-5F37-4227)
   - Write the recovery image to a USB drive.

---

## Install (from SteamOS Recovery)

1. Boot the device from the **SteamOS recovery USB** (Secure Boot must be **off**).
2. Open a **terminal** (Konsole) from the application menu.
3. Run:

   ```bash
   git clone https://github.com/Josh5/steamos_dual_boot_installer_patch
   cd steamos_dual_boot_installer_patch
   sudo ./run.sh
   ```

4. The script will show the **highest existing partition** and ask for the starting number for new SteamOS partitions (default is correct in most cases). Confirm to proceed.
5. When prompted, it will patch the installer and start the SteamOS install targeting the new partitions.
6. Reboot when done. Use your boot menu/manager to select SteamOS or Windows.

---

## Demonstration Video

I have recorded a quick run through of this script on my ROG Ally X. You can watch it here:

[![Watch the demo](https://img.youtube.com/vi/sVW2MKR5cNk/0.jpg)](https://www.youtube.com/watch?v=sVW2MKR5cNk)


---

## Configuration (optional)

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

---

## Safety notes

- Ensure the free space you created is **truly unallocated** and located **after** the Windows partitions.
- This is **not** an official Valve workflow. Use at your own risk.

---

## Credits

Created by **Josh5** to save everyone from wasting a day reinstalling Windows just to try SteamOS next to it.
