#!/usr/bin/env bash
###
# File: run.sh
# Project: steamos_dual_boot_installer_patch
# File Created: Sunday, 19th October 2025 7:30:31 pm
# Author: Josh.5 (jsunnex@gmail.com)
# Version: 2.1
# -----
# Last Modified: Sunday, 28th June 2026 11:30:55 am
# Modified By: Josh.5 (jsunnex@gmail.com)
###

set -euo pipefail

# Create the SteamOS partition set inside prepared free space, then perform the
# install directly. This script no longer patches Valve's recovery script at
# runtime; it owns the partitioning and install flow itself.

TARGET_DISK=${TARGET_DISK:-/dev/nvme0n1}
STEAMOS_SILENT=${STEAMOS_SILENT:-0}
STEAMOS_DRY_RUN=${STEAMOS_DRY_RUN:-0}
FREE_REGION_START_MIB=${FREE_REGION_START_MIB:-}
FREE_REGION_END_MIB=${FREE_REGION_END_MIB:-}
FIRST_NEW_PARTITION=${FIRST_NEW_PARTITION:-}

# Sizes can be overridden via environment variables if desired.
ESP_SIZE=${ESP_SIZE:-256M}
EFI_SIZE=${EFI_SIZE:-64M}
ROOT_SIZE=${ROOT_SIZE:-11G}
VAR_SIZE=${VAR_SIZE:-1G}

TYPE_GUID_ESP=C12A7328F81F11D2BA4B00A0C93EC93B
TYPE_GUID_EFI=EBD0A0A2B9E5443387C068B6B72699C7
TYPE_GUID_ROOT=4F68BCE3E8CD4DB196E7FBCAF984B709
TYPE_GUID_VAR=4D21B016B53445C2A9FB5C16E091FD2D
TYPE_GUID_HOME=933AC7E12EB44F13B8440E14E2AEF915

SCRIPT_VERSION=$(sed -n 's/^# Version: //p' "$0" | head -n 1)
SCRIPT_VERSION=${SCRIPT_VERSION:-unknown}

root_fs_frozen=0

error() {
    echo "Error: $*" >&2
    exit 1
}

log() {
    echo "==> $*"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || error "Command '$1' is required but not found."
}

run_sgdisk_checked() {
    local output status

    set +e
    output=$(sgdisk "$@" "$TARGET_DISK" 2>&1)
    status=$?
    set -e

    if ((status != 0)); then
        printf '%s\n' "$output" >&2
        error "sgdisk exited with status $status."
    fi

    if grep -qiE 'could not create partition|unable to set partition|unable to change partition|error encountered' <<<"$output"; then
        printf '%s\n' "$output" >&2
        error "sgdisk reported a partitioning error."
    fi

    printf '%s\n' "$output"
}

cleanup() {
    if [[ ${root_fs_frozen:-0} == 1 ]]; then
        fsfreeze -u / || true
        root_fs_frozen=0
    fi
}

trap cleanup EXIT

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

to_mib() {
    local value=${1^^}
    case "$value" in
    *M)
        printf '%s\n' "${value%M}"
        ;;
    *G)
        printf '%s\n' "$((${value%G} * 1024))"
        ;;
    *)
        error "Unsupported size '$1'. Expected an M or G suffix."
        ;;
    esac
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [--help]

Options:
  -h, --help              Show this help text and exit.
  --dry-run               Print the install plan and exit before partitioning.
  --silent                Run without interactive prompts.
  --target-disk PATH
  --free-start-mib N
  --free-end-mib N
  --first-new-partition N

Environment variables:
  TARGET_DISK         Target disk device (default: /dev/nvme0n1)
  STEAMOS_SILENT      Run without interactive prompts (1/0)
  STEAMOS_DRY_RUN     Print the plan and exit before partitioning (1/0)
  FREE_REGION_START_MIB
  FREE_REGION_END_MIB
  FIRST_NEW_PARTITION
  ESP_SIZE, EFI_SIZE, ROOT_SIZE, VAR_SIZE  Partition sizing overrides
EOF
}

parse_args() {
    local positional=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
        --dry-run)
            STEAMOS_DRY_RUN=1
            shift
            ;;
        --silent)
            STEAMOS_SILENT=1
            shift
            ;;
        --target-disk)
            TARGET_DISK=$2
            shift 2
            ;;
        --free-start-mib)
            FREE_REGION_START_MIB=$2
            shift 2
            ;;
        --free-end-mib)
            FREE_REGION_END_MIB=$2
            shift 2
            ;;
        --first-new-partition)
            FIRST_NEW_PARTITION=$2
            shift 2
            ;;
        --)
            shift
            positional+=("$@")
            break
            ;;
        -*)
            error "Unknown option: $1"
            ;;
        *)
            positional+=("$1")
            shift
            ;;
        esac
    done

    if ((${#positional[@]} > 0)); then
        error "Unexpected positional argument: ${positional[0]}"
    fi
}

wait_for_partition() {
    local path=$1
    local attempt
    for attempt in {1..10}; do
        if [[ -b $path ]]; then
            return 0
        fi
        udevadm settle || true
        sleep 1
    done
    error "Partition device '$path' did not appear."
}

verify_part() {
    local device=$1
    local expected_type=$2
    local expected_partlabel=$3
    local actual_type actual_partlabel

    actual_type=$(blkid -o value -s TYPE "$device" || true)
    actual_partlabel=$(blkid -o value -s PARTLABEL "$device" || true)

    [[ $actual_type == "$expected_type" ]] || error "Device '$device' is type '$actual_type', expected '$expected_type'."
    [[ $actual_partlabel == "$expected_partlabel" ]] || error "Device '$device' has PARTLABEL '$actual_partlabel', expected '$expected_partlabel'."
}

imageroot() {
    local srcroot=$1
    local newroot=$2
    log "Imaging $newroot from $srcroot"
    dd if="$srcroot" of="$newroot" bs=128M status=progress oflag=sync
    btrfstune -f -u "$newroot"
    btrfs check "$newroot"
}

finalize_part() {
    local partset=$1
    log "Finalizing partset $partset"
    steamos-chroot --no-overlay --disk "$TARGET_DISK" --partset "$partset" -- mkdir -p /efi/SteamOS
    steamos-chroot --no-overlay --disk "$TARGET_DISK" --partset "$partset" -- mkdir -p /esp/SteamOS/conf
    steamos-chroot --no-overlay --disk "$TARGET_DISK" --partset "$partset" -- steamos-partsets /efi/SteamOS/partsets
    steamos-chroot --no-overlay --disk "$TARGET_DISK" --partset "$partset" -- steamos-bootconf create --image "$partset" --conf-dir /esp/SteamOS/conf --efi-dir /efi --set title "$partset"
    steamos-chroot --no-overlay --disk "$TARGET_DISK" --partset "$partset" -- grub-mkimage
    steamos-chroot --no-overlay --disk "$TARGET_DISK" --partset "$partset" -- update-grub
}

main() {
    local highest_part number default_start start_part
    local esp_num efi_a_num efi_b_num root_a_num root_b_num var_a_num var_b_num home_num
    local esp_mib efi_mib root_mib var_mib fixed_total_mib free_region_size_mib current_start home_mib
    local rootdevice

    parse_args "$@"

    cat <<EOF
SteamOS Installer Backend
Version ${SCRIPT_VERSION}
EOF
    sleep 3

    [[ $EUID -eq 0 ]] || error "Please run as root."

    require_cmd lsblk
    require_cmd sgdisk
    require_cmd parted
    require_cmd sed
    require_cmd mkfs.vfat
    require_cmd mkfs.ext4
    require_cmd tune2fs
    require_cmd udevadm
    require_cmd partprobe
    require_cmd blkid
    require_cmd dd
    require_cmd btrfstune
    require_cmd btrfs
    require_cmd fsfreeze
    require_cmd findmnt
    require_cmd steamos-chroot
    require_cmd steamcl-install

    [[ -b $TARGET_DISK ]] || error "Target disk '$TARGET_DISK' not found."

    if [[ $STEAMOS_SILENT == 1 ]]; then
        [[ -n $FREE_REGION_START_MIB ]] || error "FREE_REGION_START_MIB is required in silent mode."
        [[ -n $FREE_REGION_END_MIB ]] || error "FREE_REGION_END_MIB is required in silent mode."
        [[ -n $FIRST_NEW_PARTITION ]] || error "FIRST_NEW_PARTITION is required in silent mode."
        [[ $FREE_REGION_START_MIB =~ ^[0-9]+$ ]] || error "FREE_REGION_START_MIB must be an integer."
        [[ $FREE_REGION_END_MIB =~ ^[0-9]+$ ]] || error "FREE_REGION_END_MIB must be an integer."
        [[ $FIRST_NEW_PARTITION =~ ^[0-9]+$ ]] || error "FIRST_NEW_PARTITION must be an integer."
        ((FREE_REGION_END_MIB > FREE_REGION_START_MIB)) || error "FREE_REGION_END_MIB must be greater than FREE_REGION_START_MIB."
    fi

    echo "Detected disk: $TARGET_DISK"
    echo
    echo "Existing partitions:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTLABEL "$TARGET_DISK"
    echo
    echo "Free space overview:"
    parted -s "$TARGET_DISK" unit MiB print free
    echo

    highest_part=0
    while IFS= read -r dev; do
        number=$(sed -n 's/.*[^0-9]\([0-9]\+\)$/\1/p' <<<"$dev")
        [[ -n $number ]] || continue
        ((number > highest_part)) && highest_part=$number
    done < <(lsblk -nrpo NAME "$TARGET_DISK" | tail -n +2)

    if ((highest_part == 0)); then
        echo "No existing partitions detected on $TARGET_DISK."
    else
        echo "Highest existing partition detected: $(part_path "$TARGET_DISK" "$highest_part")"
    fi

    if [[ $STEAMOS_SILENT == 1 ]]; then
        start_part=$FIRST_NEW_PARTITION
    else
        if ((highest_part == 0)); then
            default_start=1
        else
            default_start=$((highest_part + 1))
        fi
        read -r -p "First SteamOS partition number [default ${default_start}]: " start_part
        start_part=${start_part:-$default_start}
    fi

    [[ $start_part =~ ^[0-9]+$ ]] || error "Partition number must be an integer."
    ((start_part > highest_part)) || error "First SteamOS partition number must be greater than the highest existing partition."

    esp_num=$start_part
    efi_a_num=$((start_part + 1))
    efi_b_num=$((start_part + 2))
    root_a_num=$((start_part + 3))
    root_b_num=$((start_part + 4))
    var_a_num=$((start_part + 5))
    var_b_num=$((start_part + 6))
    home_num=$((start_part + 7))

    esp_mib=$(to_mib "$ESP_SIZE")
    efi_mib=$(to_mib "$EFI_SIZE")
    root_mib=$(to_mib "$ROOT_SIZE")
    var_mib=$(to_mib "$VAR_SIZE")
    fixed_total_mib=$((esp_mib + efi_mib + efi_mib + root_mib + root_mib + var_mib + var_mib))

    if [[ $STEAMOS_SILENT == 1 ]]; then
        free_region_size_mib=$((FREE_REGION_END_MIB - FREE_REGION_START_MIB))
        ((free_region_size_mib > fixed_total_mib)) || error "Selected free-space region is too small for the SteamOS partition layout."
    fi

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
    if [[ $STEAMOS_SILENT == 1 ]]; then
        printf '  Selected free region: %s MiB -> %s MiB (%s MiB total)\n' "$FREE_REGION_START_MIB" "$FREE_REGION_END_MIB" "$free_region_size_mib"
    fi
    if [[ $STEAMOS_DRY_RUN == 1 ]]; then
        echo "  Mode: DRY RUN"
    fi
    echo

    if [[ $STEAMOS_SILENT != 1 ]]; then
        confirm "Does this look correct?" || error "User aborted before partitioning."
    fi

    if [[ $STEAMOS_DRY_RUN == 1 ]]; then
        echo "Dry-run mode: exiting before partitioning or formatting."
        exit 0
    fi

    log "Creating SteamOS partitions"
    for num in "$esp_num" "$efi_a_num" "$efi_b_num" "$root_a_num" "$root_b_num" "$var_a_num" "$var_b_num" "$home_num"; do
        sgdisk --delete="$num" "$TARGET_DISK" >/dev/null 2>&1 || true
    done

    if [[ $STEAMOS_SILENT == 1 ]]; then
        current_start=$FREE_REGION_START_MIB
        run_sgdisk_checked "-n${esp_num}:${current_start}MiB:+${ESP_SIZE}" "-c${esp_num}:esp" "-t${esp_num}:${TYPE_GUID_ESP}"
        current_start=$((current_start + esp_mib))
        run_sgdisk_checked "-n${efi_a_num}:${current_start}MiB:+${EFI_SIZE}" "-c${efi_a_num}:efi-A" "-t${efi_a_num}:${TYPE_GUID_EFI}"
        current_start=$((current_start + efi_mib))
        run_sgdisk_checked "-n${efi_b_num}:${current_start}MiB:+${EFI_SIZE}" "-c${efi_b_num}:efi-B" "-t${efi_b_num}:${TYPE_GUID_EFI}"
        current_start=$((current_start + efi_mib))
        run_sgdisk_checked "-n${root_a_num}:${current_start}MiB:+${ROOT_SIZE}" "-c${root_a_num}:rootfs-A" "-t${root_a_num}:${TYPE_GUID_ROOT}"
        current_start=$((current_start + root_mib))
        run_sgdisk_checked "-n${root_b_num}:${current_start}MiB:+${ROOT_SIZE}" "-c${root_b_num}:rootfs-B" "-t${root_b_num}:${TYPE_GUID_ROOT}"
        current_start=$((current_start + root_mib))
        run_sgdisk_checked "-n${var_a_num}:${current_start}MiB:+${VAR_SIZE}" "-c${var_a_num}:var-A" "-t${var_a_num}:${TYPE_GUID_VAR}"
        current_start=$((current_start + var_mib))
        run_sgdisk_checked "-n${var_b_num}:${current_start}MiB:+${VAR_SIZE}" "-c${var_b_num}:var-B" "-t${var_b_num}:${TYPE_GUID_VAR}"
        current_start=$((current_start + var_mib))
        home_mib=$((FREE_REGION_END_MIB - current_start - 1))
        ((home_mib > 0)) || error "Selected free-space region leaves no room for the final home partition after alignment. Choose a larger region."
        run_sgdisk_checked "-n${home_num}:${current_start}MiB:+${home_mib}M" "-c${home_num}:home" "-t${home_num}:${TYPE_GUID_HOME}"
    else
        run_sgdisk_checked "-n${esp_num}:0:+${ESP_SIZE}" "-c${esp_num}:esp" "-t${esp_num}:${TYPE_GUID_ESP}"
        run_sgdisk_checked "-n${efi_a_num}:0:+${EFI_SIZE}" "-c${efi_a_num}:efi-A" "-t${efi_a_num}:${TYPE_GUID_EFI}"
        run_sgdisk_checked "-n${efi_b_num}:0:+${EFI_SIZE}" "-c${efi_b_num}:efi-B" "-t${efi_b_num}:${TYPE_GUID_EFI}"
        run_sgdisk_checked "-n${root_a_num}:0:+${ROOT_SIZE}" "-c${root_a_num}:rootfs-A" "-t${root_a_num}:${TYPE_GUID_ROOT}"
        run_sgdisk_checked "-n${root_b_num}:0:+${ROOT_SIZE}" "-c${root_b_num}:rootfs-B" "-t${root_b_num}:${TYPE_GUID_ROOT}"
        run_sgdisk_checked "-n${var_a_num}:0:+${VAR_SIZE}" "-c${var_a_num}:var-A" "-t${var_a_num}:${TYPE_GUID_VAR}"
        run_sgdisk_checked "-n${var_b_num}:0:+${VAR_SIZE}" "-c${var_b_num}:var-B" "-t${var_b_num}:${TYPE_GUID_VAR}"
        run_sgdisk_checked "-n${home_num}:0:0" "-c${home_num}:home" "-t${home_num}:${TYPE_GUID_HOME}"
    fi

    partprobe "$TARGET_DISK"
    udevadm settle

    wait_for_partition "$(part_path "$TARGET_DISK" "$esp_num")"
    wait_for_partition "$(part_path "$TARGET_DISK" "$efi_a_num")"
    wait_for_partition "$(part_path "$TARGET_DISK" "$efi_b_num")"
    wait_for_partition "$(part_path "$TARGET_DISK" "$root_a_num")"
    wait_for_partition "$(part_path "$TARGET_DISK" "$root_b_num")"
    wait_for_partition "$(part_path "$TARGET_DISK" "$var_a_num")"
    wait_for_partition "$(part_path "$TARGET_DISK" "$var_b_num")"
    wait_for_partition "$(part_path "$TARGET_DISK" "$home_num")"

    log "Formatting boot and data partitions"
    mkfs.vfat -F 32 -n esp "$(part_path "$TARGET_DISK" "$esp_num")"
    mkfs.vfat -n efi "$(part_path "$TARGET_DISK" "$efi_a_num")"
    mkfs.vfat -n efi "$(part_path "$TARGET_DISK" "$efi_b_num")"
    mkfs.ext4 -F -L var "$(part_path "$TARGET_DISK" "$var_a_num")"
    mkfs.ext4 -F -L var "$(part_path "$TARGET_DISK" "$var_b_num")"
    mkfs.ext4 -F -O casefold -T huge -L home "$(part_path "$TARGET_DISK" "$home_num")"
    tune2fs -m 0 "$(part_path "$TARGET_DISK" "$home_num")"

    log "Verifying partition metadata"
    verify_part "$(part_path "$TARGET_DISK" "$esp_num")" vfat esp
    verify_part "$(part_path "$TARGET_DISK" "$efi_a_num")" vfat efi-A
    verify_part "$(part_path "$TARGET_DISK" "$efi_b_num")" vfat efi-B
    verify_part "$(part_path "$TARGET_DISK" "$var_a_num")" ext4 var-A
    verify_part "$(part_path "$TARGET_DISK" "$var_b_num")" ext4 var-B
    verify_part "$(part_path "$TARGET_DISK" "$home_num")" ext4 home

    rootdevice=$(findmnt -n -o source /)
    [[ -n $rootdevice && -e $rootdevice ]] || error "Could not find the recovery environment root device."

    log "Freezing the recovery rootfs before imaging"
    fsfreeze -f /
    root_fs_frozen=1

    imageroot "$rootdevice" "$(part_path "$TARGET_DISK" "$root_a_num")"
    imageroot "$rootdevice" "$(part_path "$TARGET_DISK" "$root_b_num")"

    cleanup

    finalize_part A
    finalize_part B

    log "Finalizing EFI configuration"
    steamos-chroot --no-overlay --disk "$TARGET_DISK" --partset A -- steamcl-install --flags restricted --force-extra-removable

    echo
    echo "Partition layout after changes:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTLABEL "$TARGET_DISK"
    echo
    echo "SteamOS install complete. Reboot manually when ready."
}

main "$@"
