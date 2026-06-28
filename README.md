# SteamOS Dual Boot Installer Patch

Install SteamOS **into already‑created free space** on your SSD — **without wiping your existing Windows install**.

> ✅ You **must** shrink your Windows C: partition yourself in Windows and leave **Unallocated** space **before** booting the SteamOS recovery image. This script **does not** resize partitions; it creates the SteamOS partition set in that prepared free space and performs the install directly.

---

## Supported Devices

- ✅ Tested by me on **ROG Ally X**
- ⚠️ Expected to also work on other **ASUS** and **Lenovo** devices (similar setup, but not tested by myself personally)

---

## Why this exists

Valve’s recovery image assumes it owns the whole disk and wipes everything. Reinstalling Windows afterwards is slow and unnecessary. This project installs SteamOS into your **unallocated free space** instead of erasing the disk.

---

## What the script does

- Detects the highest existing Windows partition number.
- Creates the standard SteamOS partition set **after** your existing partitions:
  - `esp`, `efi-A`, `efi-B`, `rootfs-A`, `rootfs-B`, `var-A`, `var-B`, and `home` (remaining space).
- Formats the new partitions and lays out the SteamOS partition set there.
- Copies the SteamOS recovery rootfs into the new system partitions and finalizes the boot configuration.
- **Does not** shrink/resize Windows or touch existing Windows partitions.

> Defaults: `TARGET_DISK=/dev/nvme0n1`, sizes can be overridden via env vars: `ESP_SIZE`, `EFI_SIZE`, `ROOT_SIZE`, `VAR_SIZE`.

---

## Prerequisites (do these in Windows **before** recovery)

1. **Disable device encryption**
   - Go to **Settings > Privacy & Security > Device Encryption** and turn it **off** (wait for full decryption).
2. **Resize the Windows partition**
   - Open **Disk Management** (`Win+X > Disk Management` or `diskmgmt.msc`).
   - Right‑click the **C:** partition > **Shrink Volume…** and choose how much free space to create (values are entered in MB).
   - Wait for the shrink to finish and confirm the new space shows as **Unallocated** (leave it unformatted).  
     ⚠️ If C: is almost full the shrink can fail—free up space (uninstall games, etc.) before retrying.
3. **Disable Fast Startup in Windows**
   - Go to **Control Panel > Power Options > Choose what the power buttons do**.
   - Click **“Change settings that are currently unavailable”** (if shown) and uncheck **“Turn on fast startup (recommended)”**.
4. **Disable Secure Boot in BIOS**
   - Reboot, enter BIOS (hold your device’s BIOS key, e.g. **VOL+** on Ally/Deck‑like devices), and disable **Secure Boot**.
5. **Disable Fast Boot in BIOS**
   - In the same BIOS session, locate the **Fast Boot** setting and turn it **off**. Save and exit.
6. **Create a SteamOS recovery USB**
   - Follow Valve’s instructions: [SteamOS Recovery Instructions](https://help.steampowered.com/en/faqs/view/65B4-2AA3-5F37-4227) and write the image to a USB drive.
7. **Configure Windows to use UTC for the hardware clock**
   - There is an annoying dual-boot issue where the two OS treat the system real-time clock differently.
   - Linux usually assumes the hardware RTC is stored as **UTC**.
   - Windows usually assumes the hardware RTC is stored as **local time**.
   - When that mismatch leaves Linux with the wrong time after boot, the **SteamOS setup can fail HTTPS/TLS certificate validation** because TLS depends on accurate system time (you can be connected to Wi-Fi just fine, but SteamOS setup may still say there was a problem with the connection because the real failure is TLS, not basic network connectivity).
   - Recommended reference: [Arch Wiki: UTC in Microsoft Windows](https://wiki.archlinux.org/title/System_time?utm_source=chatgpt.com#UTC_in_Microsoft_Windows)
   - The Arch Wiki recommendation is to configure **Windows to use UTC**, rather than configuring Linux to use local time.
   - Open `regedit` and add a `DWORD` named `RealTimeIsUniversal` with hexadecimal value `1` under:
     `HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\TimeZoneInformation`
   - Or run this from an **Administrator Command Prompt**:

   ```bat
   reg add "HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal /d 1 /t REG_DWORD /f
   ```

   - After applying the change, verify the **BIOS/system clock** is correct before starting SteamOS recovery.
   - If the time is still offset, you may need to resync the clocks and time zone after making the change.

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

   or if you want to run it in a single line:

   ```bash
   wget -O /tmp/run.sh https://raw.githubusercontent.com/Josh5/steamos_dual_boot_installer_patch/refs/heads/master/run.sh && sudo bash /tmp/run.sh
   ```

4. The script will show the **highest existing partition** and ask for the starting number for new SteamOS partitions (default is correct in most cases). Confirm to proceed.
5. When prompted, it will start the SteamOS install targeting the new partitions.
6. Reboot when done. Use your boot menu/manager to select SteamOS or Windows.

---

## Demonstration Video

I have recorded a quick run through of this script on my ROG Ally X. You can watch it here:

[![Watch the demo](https://img.youtube.com/vi/sVW2MKR5cNk/0.jpg)](https://www.youtube.com/watch?v=sVW2MKR5cNk)

(https://www.youtube.com/watch?v=sVW2MKR5cNk)

Another creator also made a solid unofficial guide for using this project on the **ROG Ally X**:

[![Watch the an excellent guide](https://img.youtube.com/vi/pd76H_FATT4/0.jpg)](https://www.youtube.com/watch?v=pd76H_FATT4)

(https://www.youtube.com/watch?v=pd76H_FATT4)

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
