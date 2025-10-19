#!/usr/bin/env bash
###
# File: run.sh
# Project: steamos_dual_boot_installer_patch
# File Created: Sunday, 19th October 2025 7:30:31 pm
# Author: Josh.5 (jsunnex@gmail.com)
# -----
# Last Modified: Sunday, 19th October 2025 7:30:43 pm
# Modified By: Josh.5 (jsunnex@gmail.com)
###

set -euo pipefail

# Automatically carve out the standard SteamOS partition set after the last
# existing Windows partition, patch the repair script to target those new
# partitions, and kick off the SteamOS system reinstall.

TARGET_DISK=${TARGET_DISK:-/dev/nvme0n1}
TOOLS_DIR=${TOOLS_DIR:-/home/deck/tools}
REPAIR_SCRIPT=${REPAIR_SCRIPT:-${TOOLS_DIR}/repair_device.sh}
PATCHED_SCRIPT=${PATCHED_SCRIPT:-${TOOLS_DIR}/repair_device.safe.sh}

# Sizes can be overridden via environment variables if desired.
ESP_SIZE=${ESP_SIZE:-256M}
EFI_SIZE=${EFI_SIZE:-64M}
ROOT_SIZE=${ROOT_SIZE:-11G}
VAR_SIZE=${VAR_SIZE:-1G}

error() {
    echo "Error: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || error "Command '$1' is required but not found."
}

part_path() {
    local disk=$1
    local part_num=$2
    if [[ $disk =~ [0-9]$ ]]; then
        printf '%sp%s\n' "$disk" "$part_num"
    else
        printf '%s%s\n' "$disk" "$part_num"
    fi
}

confirm() {
    local prompt=$1
    read -r -p "$prompt [y/N]: " reply
    [[ ${reply,,} == y ]]
}

main() {
    [[ $EUID -eq 0 ]] || error "Please run as root."

    require_cmd lsblk
    require_cmd sgdisk
    require_cmd parted
    require_cmd sed
    require_cmd mkfs.vfat
    require_cmd mkfs.ext4
    require_cmd tune2fs
    require_cmd udevadm

    [[ -b $TARGET_DISK ]] || error "Target disk '$TARGET_DISK' not found."
    [[ -f $REPAIR_SCRIPT ]] || error "Expected repair script at '$REPAIR_SCRIPT' but it was not found."

    echo "Detected disk: $TARGET_DISK"
    echo
    echo "Existing partitions:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTLABEL "$TARGET_DISK"
    echo
    echo "Free space overview:"
    parted -s "$TARGET_DISK" unit MiB print free
    echo

    highest_part=0
    mapfile -t partitions < <(lsblk -nrpo NAME "$TARGET_DISK" | tail -n +2)
    if ((${#partitions[@]} == 0)); then
        error "No partitions detected on $TARGET_DISK. Aborting."
    fi

    for dev in "${partitions[@]}"; do
        number=$(sed -n 's/.*[^0-9]\([0-9]\+\)$/\1/p' <<<"$dev")
        [[ -n $number ]] || continue
        ((number > highest_part)) && highest_part=$number
    done

    if ((highest_part == 0)); then
        error "Could not determine the highest existing partition number."
    fi

    suffix=$([[ $TARGET_DISK =~ [0-9]$ ]] && printf 'p')
    echo "Highest existing partition detected: ${TARGET_DISK}${suffix}${highest_part}"
    default_start=$((highest_part + 1))
    read -r -p "First SteamOS partition number [default ${default_start}]: " start_part
    start_part=${start_part:-$default_start}
    [[ $start_part =~ ^[0-9]+$ ]] || error "Partition number must be an integer."

    esp_num=$start_part
    efi_a_num=$((start_part + 1))
    efi_b_num=$((start_part + 2))
    root_a_num=$((start_part + 3))
    root_b_num=$((start_part + 4))
    var_a_num=$((start_part + 5))
    var_b_num=$((start_part + 6))
    home_num=$((start_part + 7))

    echo
    echo "Planned SteamOS partition mapping on $TARGET_DISK:"
    printf '  %s -> esp (%s)\n' "$(part_path "$TARGET_DISK" "$esp_num")" "$ESP_SIZE"
    printf '  %s -> efi-A (%s)\n' "$(part_path "$TARGET_DISK" "$efi_a_num")" "$EFI_SIZE"
    printf '  %s -> efi-B (%s)\n' "$(part_path "$TARGET_DISK" "$efi_b_num")" "$EFI_SIZE"
    printf '  %s -> rootfs-A (%s)\n' "$(part_path "$TARGET_DISK" "$root_a_num")" "$ROOT_SIZE"
    printf '  %s -> rootfs-B (%s)\n' "$(part_path "$TARGET_DISK" "$root_b_num")" "$ROOT_SIZE"
    printf '  %s -> var-A (%s)\n' "$(part_path "$TARGET_DISK" "$var_a_num")" "$VAR_SIZE"
    printf '  %s -> var-B (%s)\n' "$(part_path "$TARGET_DISK" "$var_b_num")" "$VAR_SIZE"
    printf '  %s -> home (remaining space)\n' "$(part_path "$TARGET_DISK" "$home_num")"
    echo

    confirm "Does this look correct?" || error "User aborted before partitioning."

    echo "Creating SteamOS partitions..."
    for num in "$esp_num" "$efi_a_num" "$efi_b_num" "$root_a_num" "$root_b_num" "$var_a_num" "$var_b_num" "$home_num"; do
        sgdisk --delete="$num" "$TARGET_DISK" >/dev/null 2>&1 || true
    done

    sgdisk -n${esp_num}:0:+${ESP_SIZE} -c${esp_num}:"esp" -t${esp_num}:C12A7328F81F11D2BA4B00A0C93EC93B "$TARGET_DISK"
    sgdisk -n${efi_a_num}:0:+${EFI_SIZE} -c${efi_a_num}:"efi-A" -t${efi_a_num}:EBD0A0A2B9E5443387C068B6B72699C7 "$TARGET_DISK"
    sgdisk -n${efi_b_num}:0:+${EFI_SIZE} -c${efi_b_num}:"efi-B" -t${efi_b_num}:EBD0A0A2B9E5443387C068B6B72699C7 "$TARGET_DISK"
    sgdisk -n${root_a_num}:0:+${ROOT_SIZE} -c${root_a_num}:"rootfs-A" -t${root_a_num}:4F68BCE3E8CD4DB196E7FBCAF984B709 "$TARGET_DISK"
    sgdisk -n${root_b_num}:0:+${ROOT_SIZE} -c${root_b_num}:"rootfs-B" -t${root_b_num}:4F68BCE3E8CD4DB196E7FBCAF984B709 "$TARGET_DISK"
    sgdisk -n${var_a_num}:0:+${VAR_SIZE} -c${var_a_num}:"var-A" -t${var_a_num}:4D21B016B53445C2A9FB5C16E091FD2D "$TARGET_DISK"
    sgdisk -n${var_b_num}:0:+${VAR_SIZE} -c${var_b_num}:"var-B" -t${var_b_num}:4D21B016B53445C2A9FB5C16E091FD2D "$TARGET_DISK"
    sgdisk -n${home_num}:0:0 -c${home_num}:"home" -t${home_num}:933AC7E12EB44F13B8440E14E2AEF915 "$TARGET_DISK"

    partprobe "$TARGET_DISK"
    udevadm settle

    echo "Formatting partitions for installer verification..."
    mkfs.vfat -F 32 -n esp "$(part_path "$TARGET_DISK" "$esp_num")"
    mkfs.vfat -F 32 -n efi-A "$(part_path "$TARGET_DISK" "$efi_a_num")"
    mkfs.vfat -F 32 -n efi-B "$(part_path "$TARGET_DISK" "$efi_b_num")"

    mkfs.ext4 -F -L var-A "$(part_path "$TARGET_DISK" "$var_a_num")"
    mkfs.ext4 -F -L var-B "$(part_path "$TARGET_DISK" "$var_b_num")"

    mkfs.ext4 -F -O casefold -T huge -L home "$(part_path "$TARGET_DISK" "$home_num")"
    tune2fs -m 0 "$(part_path "$TARGET_DISK" "$home_num")"

    echo
    echo "Partition layout after changes:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTLABEL "$TARGET_DISK"
    echo

    echo "Patching $REPAIR_SCRIPT -> $PATCHED_SCRIPT"
    sed \
        -e "s#^DISK=.*#DISK=$TARGET_DISK#" \
        -e "s/^FS_ESP=.*/FS_ESP=$esp_num/" \
        -e "s/^FS_EFI_A=.*/FS_EFI_A=$efi_a_num/" \
        -e "s/^FS_EFI_B=.*/FS_EFI_B=$efi_b_num/" \
        -e "s/^FS_ROOT_A=.*/FS_ROOT_A=$root_a_num/" \
        -e "s/^FS_ROOT_B=.*/FS_ROOT_B=$root_b_num/" \
        -e "s/^FS_VAR_A=.*/FS_VAR_A=$var_a_num/" \
        -e "s/^FS_VAR_B=.*/FS_VAR_B=$var_b_num/" \
        -e "s/^FS_HOME=.*/FS_HOME=$home_num/" \
        -e '/^all)$/,/^  ;;$/d' \
        "$REPAIR_SCRIPT" >"$PATCHED_SCRIPT"

    chmod +x "$PATCHED_SCRIPT"

    echo "Patched installer saved to $PATCHED_SCRIPT"
    echo
    if ! confirm "About to launch the SteamOS repair (system target). Continue?"; then
        echo "SteamOS install skipped at user request."
        exit 0
    fi

    echo "Running SteamOS installer..."
    (
        cd "$TOOLS_DIR"
        NOPROMPT=1 "$PATCHED_SCRIPT" system
    )
}

main "$@"
