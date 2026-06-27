#!/usr/bin/env bash
###
# File: run.sh
# Project: steamos_dual_boot_installer_patch
# File Created: Sunday, 19th October 2025 7:30:31 pm
# Author: Josh.5 (jsunnex@gmail.com)
# -----
# Last Modified: Saturday, 27th June 2026 12:32:45 pm
# Modified By: Josh.5 (jsunnex@gmail.com)
###

set -euo pipefail

# Automatically carve out the standard SteamOS partition set after the last
# existing Windows partition, patch the repair script to target those new
# partitions, and kick off the SteamOS system reinstall.

TARGET_DISK=${TARGET_DISK:-/dev/nvme0n1}
TOOLS_DIR=${TOOLS_DIR:-/home/deck/tools}
REPAIR_SCRIPT=${REPAIR_SCRIPT:-${TOOLS_DIR}/repair_device.sh}
PATCHED_SCRIPT=${PATCHED_SCRIPT:-${TOOLS_DIR}/repair_device.patched.sh}
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
  TOOLS_DIR           Directory containing repair_device.sh (default: /home/deck/tools)
  REPAIR_SCRIPT       Path to the original repair script
  PATCHED_SCRIPT      Path to write the patched repair script
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

main() {
    parse_args "$@"

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
    if [[ $STEAMOS_DRY_RUN != 1 ]]; then
        [[ -f $REPAIR_SCRIPT ]] || error "Expected repair script at '$REPAIR_SCRIPT' but it was not found."
    fi

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
    mapfile -t partitions < <(lsblk -nrpo NAME "$TARGET_DISK" | tail -n +2)
    for dev in "${partitions[@]}"; do
        number=$(sed -n 's/.*[^0-9]\([0-9]\+\)$/\1/p' <<<"$dev")
        [[ -n $number ]] || continue
        ((number > highest_part)) && highest_part=$number
    done

    suffix=$([[ $TARGET_DISK =~ [0-9]$ ]] && printf 'p')
    if ((highest_part == 0)); then
        echo "No existing partitions detected on $TARGET_DISK."
    else
        echo "Highest existing partition detected: ${TARGET_DISK}${suffix}${highest_part}"
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

    echo "Creating SteamOS partitions..."
    for num in "$esp_num" "$efi_a_num" "$efi_b_num" "$root_a_num" "$root_b_num" "$var_a_num" "$var_b_num" "$home_num"; do
        sgdisk --delete="$num" "$TARGET_DISK" >/dev/null 2>&1 || true
    done

    if [[ $STEAMOS_SILENT == 1 ]]; then
        current_start=$FREE_REGION_START_MIB
        sgdisk "-n${esp_num}:${current_start}MiB:+${ESP_SIZE}" "-c${esp_num}:esp" "-t${esp_num}:C12A7328F81F11D2BA4B00A0C93EC93B" "$TARGET_DISK"
        current_start=$((current_start + esp_mib))
        sgdisk "-n${efi_a_num}:${current_start}MiB:+${EFI_SIZE}" "-c${efi_a_num}:efi-A" "-t${efi_a_num}:EBD0A0A2B9E5443387C068B6B72699C7" "$TARGET_DISK"
        current_start=$((current_start + efi_mib))
        sgdisk "-n${efi_b_num}:${current_start}MiB:+${EFI_SIZE}" "-c${efi_b_num}:efi-B" "-t${efi_b_num}:EBD0A0A2B9E5443387C068B6B72699C7" "$TARGET_DISK"
        current_start=$((current_start + efi_mib))
        sgdisk "-n${root_a_num}:${current_start}MiB:+${ROOT_SIZE}" "-c${root_a_num}:rootfs-A" "-t${root_a_num}:4F68BCE3E8CD4DB196E7FBCAF984B709" "$TARGET_DISK"
        current_start=$((current_start + root_mib))
        sgdisk "-n${root_b_num}:${current_start}MiB:+${ROOT_SIZE}" "-c${root_b_num}:rootfs-B" "-t${root_b_num}:4F68BCE3E8CD4DB196E7FBCAF984B709" "$TARGET_DISK"
        current_start=$((current_start + root_mib))
        sgdisk "-n${var_a_num}:${current_start}MiB:+${VAR_SIZE}" "-c${var_a_num}:var-A" "-t${var_a_num}:4D21B016B53445C2A9FB5C16E091FD2D" "$TARGET_DISK"
        current_start=$((current_start + var_mib))
        sgdisk "-n${var_b_num}:${current_start}MiB:+${VAR_SIZE}" "-c${var_b_num}:var-B" "-t${var_b_num}:4D21B016B53445C2A9FB5C16E091FD2D" "$TARGET_DISK"
        current_start=$((current_start + var_mib))
        sgdisk "-n${home_num}:${current_start}MiB:${FREE_REGION_END_MIB}MiB" "-c${home_num}:home" "-t${home_num}:933AC7E12EB44F13B8440E14E2AEF915" "$TARGET_DISK"
    else
        sgdisk -n${esp_num}:0:+${ESP_SIZE} -c${esp_num}:"esp" -t${esp_num}:C12A7328F81F11D2BA4B00A0C93EC93B "$TARGET_DISK"
        sgdisk -n${efi_a_num}:0:+${EFI_SIZE} -c${efi_a_num}:"efi-A" -t${efi_a_num}:EBD0A0A2B9E5443387C068B6B72699C7 "$TARGET_DISK"
        sgdisk -n${efi_b_num}:0:+${EFI_SIZE} -c${efi_b_num}:"efi-B" -t${efi_b_num}:EBD0A0A2B9E5443387C068B6B72699C7 "$TARGET_DISK"
        sgdisk -n${root_a_num}:0:+${ROOT_SIZE} -c${root_a_num}:"rootfs-A" -t${root_a_num}:4F68BCE3E8CD4DB196E7FBCAF984B709 "$TARGET_DISK"
        sgdisk -n${root_b_num}:0:+${ROOT_SIZE} -c${root_b_num}:"rootfs-B" -t${root_b_num}:4F68BCE3E8CD4DB196E7FBCAF984B709 "$TARGET_DISK"
        sgdisk -n${var_a_num}:0:+${VAR_SIZE} -c${var_a_num}:"var-A" -t${var_a_num}:4D21B016B53445C2A9FB5C16E091FD2D "$TARGET_DISK"
        sgdisk -n${var_b_num}:0:+${VAR_SIZE} -c${var_b_num}:"var-B" -t${var_b_num}:4D21B016B53445C2A9FB5C16E091FD2D "$TARGET_DISK"
        sgdisk -n${home_num}:0:0 -c${home_num}:"home" -t${home_num}:933AC7E12EB44F13B8440E14E2AEF915 "$TARGET_DISK"
    fi

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
    tmp_patch=$(mktemp)
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
        -e 's/^  estat "Finalizing install part $1"$/  sleep 5\n  estat "Finalizing install part $1"/' \
        -e 's/^  writeHome=1$/  writeHome=1\n  writeOS=1/' \
        -e 's/^  prompt_reboot "SteamOS reinstall complete."$/  estat "SteamOS reinstall complete. Reboot manually when ready."/' \
        -e 's/^  prompt_reboot "User partitions have been reformatted."$/  estat "User partitions have been reformatted. Reboot manually when ready."/' \
        -e '/^all)$/,/^  ;;$/d' \
        "$REPAIR_SCRIPT" >"$tmp_patch"

    required_assignments=(
        "DISK=$TARGET_DISK"
        "FS_ESP=$esp_num"
        "FS_EFI_A=$efi_a_num"
        "FS_EFI_B=$efi_b_num"
        "FS_ROOT_A=$root_a_num"
        "FS_ROOT_B=$root_b_num"
        "FS_VAR_A=$var_a_num"
        "FS_VAR_B=$var_b_num"
        "FS_HOME=$home_num"
    )

    for assignment in "${required_assignments[@]}"; do
        if ! grep -q "^${assignment}\$" "$tmp_patch"; then
            rm -f "$tmp_patch"
            error "Failed to patch repair script; expected '$assignment'."
        fi
    done

    if grep -q '^all)$' "$tmp_patch"; then
        rm -f "$tmp_patch"
        error "Failed to strip destructive 'all' target from repair script."
    fi

    mv "$tmp_patch" "$PATCHED_SCRIPT"
    chmod 777 "$PATCHED_SCRIPT"

    echo "Patched installer saved to $PATCHED_SCRIPT"
    echo

    local target_mode=home
    if [[ $STEAMOS_SILENT != 1 ]]; then
        local confirm_message="About to launch the SteamOS install. Continue?"
        if ! confirm "$confirm_message"; then
            echo "SteamOS install skipped at user request."
            exit 0
        fi
    fi

    echo "Running SteamOS installer..."
    (
        cd "$TOOLS_DIR"
        NOPROMPT=1 "$PATCHED_SCRIPT" "$target_mode"
    )
}

main "$@"
