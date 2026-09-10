#!/usr/bin/env bash
# Inject LibreELEC network and SSH configuration into images.

set -euo pipefail
shopt -s nullglob

usage() {
    printf 'Usage: %s [--image IMAGE_NAME]\n' "$(basename "$0")" >&2
    printf '       (or IMAGE=IMAGE_NAME %s with no flag)\n' "$(basename "$0")" >&2
    printf '       every *.config file in config/wifi is provisioned automatically\n' >&2
    exit 2
}

image_name=${IMAGE:-}
while [[ $# -gt 0 ]]; do
    case $1 in
        --image)
            [[ $# -ge 2 ]] || usage
            image_name=$2
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
workspace_dir=$(cd "$script_dir/.." && pwd -P)

source_dir="$workspace_dir/images/source"
injected_dir="$workspace_dir/images/injected"
config_dir_source="$workspace_dir/config/wifi"
ssh_key_source="$workspace_dir/config/authorized_keys"
wifi_enabled=0

if [[ -d "$config_dir_source" ]]; then
    available_configs=("$config_dir_source"/*.config)
    [[ ${#available_configs[@]} -gt 0 ]] && wifi_enabled=1
fi

if [[ ${EUID} -ne 0 ]]; then
    printf 'Error: run this script with sudo (it must run as root).\n' >&2
    exit 1
fi

if [[ ! -f "$ssh_key_source" ]]; then
    printf 'Error: SSH public key file not found: %s\n' "$ssh_key_source" >&2
    exit 1
fi

for command_name in losetup mount umount mkdir mktemp cp chmod grep sed basename gunzip gzip mknod unsquashfs mksquashfs patch md5sum; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'Error: required command not found: %s\n' "$command_name" >&2
        exit 1
    }
done

mkdir -p "$injected_dir"
if [[ -n "$image_name" ]]; then
    if [[ -f "$image_name" ]]; then
        source_images=("$image_name")
    else
        source_images=("$source_dir/$image_name")
    fi
else
    source_images=("$source_dir"/*.img "$source_dir"/*.img.gz)
fi
[[ ${#source_images[@]} -gt 0 ]] || {
    printf 'Error: no .img or .img.gz files found in %s\n' "$source_dir" >&2
    exit 1
}

mount_dir=''
boot_mount_dir=''
loop_device=''

cleanup_mounts() {
    set +e
    [[ -n "$mount_dir" ]] && mountpoint -q "$mount_dir" 2>/dev/null && umount "$mount_dir"
    [[ -n "$boot_mount_dir" ]] && mountpoint -q "$boot_mount_dir" 2>/dev/null && umount "$boot_mount_dir"
    [[ -n "$loop_device" ]] && losetup -d "$loop_device"
    [[ -n "$mount_dir" && -d "$mount_dir" ]] && rmdir "$mount_dir"
    [[ -n "$boot_mount_dir" && -d "$boot_mount_dir" ]] && rmdir "$boot_mount_dir"
    mount_dir=''
    boot_mount_dir=''
    loop_device=''
}

cleanup() {
    local exit_code=$?
    cleanup_mounts
    exit "$exit_code"
}
trap cleanup EXIT

ensure_partition_node() {
    local dev_path=$1
    local loop_name partition_name sys_dev_file major minor attempt
    [[ -b "$dev_path" ]] && return 0

    loop_name=$(basename "$loop_device")
    partition_name=$(basename "$dev_path")
    sys_dev_file="/sys/block/${loop_name}/${partition_name}/dev"

    for attempt in 1 2 3 4 5; do
        [[ -b "$dev_path" ]] && return 0
        if [[ -f "$sys_dev_file" ]]; then
            IFS=: read -r major minor < "$sys_dev_file"
            mknod "$dev_path" b "$major" "$minor" 2>/dev/null || true
        fi
        [[ -b "$dev_path" ]] && return 0
        sleep 0.2
    done

    [[ -b "$dev_path" ]]
}

for source_image in "${source_images[@]}"; do
    image_name=$(basename "$source_image")
    is_gz=0
    if [[ "$image_name" == *.gz ]]; then
        is_gz=1
        image_stem=${image_name%.img.gz}
    else
        image_stem=${image_name%.img}
    fi
    image_path="$injected_dir/${image_stem}_injected.img"
    if [[ $is_gz -eq 1 ]]; then
        printf '==> Decompressing %s to %s\n' "$source_image" "$image_path"
        gunzip -c "$source_image" > "$image_path"
    else
        printf '==> Copying %s to %s\n' "$source_image" "$image_path"
        cp -p "$source_image" "$image_path"
    fi

    mount_dir=$(mktemp -d)
    boot_mount_dir=$(mktemp -d)
    loop_device=''

    printf '==> Attaching image partitions\n'
    loop_device=$(losetup -fP --show "$image_path")
    printf '==> Using loop device %s\n' "$loop_device"
    boot_partition="${loop_device}p1"
    storage_partition="${loop_device}p2"
    ensure_partition_node "$boot_partition"
    ensure_partition_node "$storage_partition"
    if [[ ! -b "$boot_partition" || ! -b "$storage_partition" ]]; then
        printf 'Error: expected LIBREELEC p1 and STORAGE p2 partitions were not found.\n' >&2
        exit 1
    fi

    printf '==> Mounting LIBREELEC partition\n'
    mount "$boot_partition" "$boot_mount_dir"
    printf '==> Mounting STORAGE partition\n'
    mount "$storage_partition" "$mount_dir"

    boot_config_found=0
    for boot_config in "$boot_mount_dir/cmdline.txt" "$boot_mount_dir/extlinux.conf" "$boot_mount_dir/extlinux/extlinux.conf" "$boot_mount_dir/syslinux.cfg"; do
        if [[ -f "$boot_config" ]]; then
            boot_config_found=1
            if ! grep -Eq '(^|[[:space:]])ssh([[:space:]]|$)' "$boot_config"; then
                if [[ $(basename "$boot_config") == cmdline.txt ]]; then
                    sed -i -E 's/[[:space:]]*$/ ssh/' "$boot_config"
                else
                    sed -i -E '/^[[:space:]]*APPEND[[:space:]]/ s/[[:space:]]*$/ ssh/' "$boot_config"
                fi
            fi
        fi
    done
    [[ $boot_config_found -eq 1 ]] || {
        printf 'Error: no supported boot configuration was found to enable SSH.\n' >&2
        exit 1
    }

    # All provisioned config (WiFi, sshd, SSH key) is staged on the BOOT
    # partition under .injected-config, not written to the STORAGE
    # partition at all. Two reasons: (1) STORAGE's /storage/.cache existing
    # at all before first boot is what lets PID1's own early machine-id
    # commit land on disk during fs-resize's otherwise fully isolated boot
    # (see scripts/patch-system-scripts.sh and the fs-resize diff for the
    # full story); (2) the boot partition is never touched by fs-resize's
    # destructive mke2fs reformat, so staging here means install-injected-config.sh
    # (staged below) can install everything into its real location with a
    # single plain copy, no backup-before-wipe/restore-after-wipe dance
    # needed at all.
    config_dir="$boot_mount_dir/.injected-config/connman"
    if [[ $wifi_enabled -eq 1 ]]; then
        printf '==> Staging WiFi configuration\n'
        mkdir -p "$config_dir"
        config_files=("$config_dir_source"/*.config)
        for config_file in "${config_files[@]}"; do
            [[ -f "$config_file" ]] && cp "$config_file" "$config_dir/"
        done
        chmod 600 "$config_dir"/*
    else
        printf '==> Skipping WiFi configuration\n'
    fi

    printf '==> Staging SSH public key\n'
    mkdir -p "$boot_mount_dir/.injected-config/ssh"
    cp "$ssh_key_source" "$boot_mount_dir/.injected-config/ssh/authorized_keys"
    chmod 600 "$boot_mount_dir/.injected-config/ssh/authorized_keys"

    # Same file LE Settings' SSH toggle writes in "secure"/key-only mode
    # (SSHD_DISABLE_PW_AUTH + SSH_ARGS). Staged under .injected-config, not
    # .cache/services, for the same reason as the WiFi config above.
    printf '==> Staging sshd config (key-only)\n'
    mkdir -p "$boot_mount_dir/.injected-config/services"
    printf "SSHD_DISABLE_PW_AUTH=true\nSSH_ARGS=-o 'PasswordAuthentication no'\n" > "$boot_mount_dir/.injected-config/services/sshd.conf"

    # Installer for everything staged above, run on-device by the patched
    # fs-resize/factory-reset (see scripts/patch-system-scripts.sh). Staged
    # here rather than baked into the SYSTEM squashfs so it isn't tied to
    # any particular LibreELEC version.
    printf '==> Staging install-injected-config.sh\n'
    cp "$script_dir/install-injected-config.sh" "$boot_mount_dir/.injected-config/install-injected-config.sh"
    chmod 755 "$boot_mount_dir/.injected-config/install-injected-config.sh"

    printf '==> Checking LibreELEC system scripts for available patches\n'
    "$script_dir/patch-system-scripts.sh" "$boot_mount_dir" "$workspace_dir/config/system-patches" || true

    cleanup_mounts

    if [[ $is_gz -eq 1 ]]; then
        printf '==> Compressing injected image to %s.gz\n' "$image_path"
        gzip -f "$image_path"
        injected_image="${image_path}.gz"
    else
        injected_image="$image_path"
    fi
    printf '==> Configuration injected into %s\n' "$injected_image"
done

trap - EXIT
printf '==> Processed %s image(s)\n' "${#source_images[@]}"
