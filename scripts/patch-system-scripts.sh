#!/usr/bin/env bash
# Patch LibreELEC scripts baked into the boot partition's SYSTEM squashfs:
#   - usr/lib/libreelec/factory-reset: preserve WiFi and SSH config across a
#     device reset instead of losing them to the storage wipe.
#   - usr/lib/libreelec/fs-resize: stop the on-device first-boot auto-resize
#     from refusing to run just because /storage/.cache has anything in it
#     (WiFi provisioning, and ConnMan itself the moment it connects, both
#     put real content there before fs-resize ever checks — trying to
#     itemize what's "allowed" there is a losing game, so the check is
#     narrowed to .kodi/.config instead, which are the only unambiguous
#     signs Kodi has actually run). Since fs-resize's actual resize step is
#     a destructive mke2fs reformat, not an in-place grow, this patch also
#     backs up the provisioned WiFi configs and SSH key beforehand and
#     restores them into the freshly-formatted partition afterward — same
#     backup/restore functions as the factory-reset patch below.
#
# Each patch is only applied if the image's copy of that script matches a
# known LibreELEC version exactly (identified by md5), since these are real
# edits to the boot squashfs and shouldn't be applied blind against a script
# they weren't written for. The set of WiFi config files factory-reset backs
# up is read straight off the config/wifi mount at patch time (a sibling of
# patches_dir) and baked into the script, so only what's actually provisioned
# there gets preserved — not ConnMan's whole runtime cache. Never fails the
# caller — any problem is a warning and the affected script is left as-is.

set -euo pipefail
shopt -s nullglob

boot_mount_dir=$1
patches_dir=$2
wifi_config_dir="$(dirname "$patches_dir")/wifi"

system_file="$boot_mount_dir/SYSTEM"

if [[ ! -f "$system_file" ]]; then
    printf 'Warning: no SYSTEM file found on boot partition; skipping system script patches.\n' >&2
    exit 0
fi

work_dir=$(mktemp -d)
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT

if ! unsquashfs -no-xattrs -d "$work_dir/root" "$system_file" >/dev/null 2>&1; then
    printf 'Warning: failed to extract SYSTEM squashfs; skipping system script patches.\n' >&2
    exit 0
fi

patched_anything=0

apply_patch() {
    local rel_path=$1
    local script_path="$work_dir/root/$rel_path"
    local script_name script_hash diff_file

    if [[ ! -f "$script_path" ]]; then
        printf 'Warning: %s not found in SYSTEM; skipping.\n' "$rel_path" >&2
        return
    fi

    script_name=$(basename "$script_path")
    script_hash=$(md5sum "$script_path" | cut -d' ' -f1)
    diff_file="$patches_dir/$script_name.$script_hash.diff"
    if [[ ! -f "$diff_file" ]]; then
        printf 'Warning: no patch available for this %s version (%s); leaving it unpatched.\n' "$script_name" "$script_hash" >&2
        return
    fi

    if ! patch -s "$script_path" < "$diff_file"; then
        printf 'Warning: failed to apply %s; leaving %s unpatched.\n' "$diff_file" "$script_name" >&2
        return
    fi

    printf '==> Patched %s\n' "$script_name"
    patched_anything=1
}

apply_patch usr/lib/libreelec/factory-reset
apply_patch usr/lib/libreelec/fs-resize

if [[ $patched_anything -eq 0 ]]; then
    exit 0
fi

wifi_config_names=""
for wifi_config_file in "$wifi_config_dir"/*.config; do
    wifi_config_names="$wifi_config_names $(basename "$wifi_config_file")"
done
wifi_config_names_escaped=$(printf '%s' "$wifi_config_names" | sed -e 's/[\&|]/\\&/g')

for patched_script in "$work_dir/root/usr/lib/libreelec/factory-reset" "$work_dir/root/usr/lib/libreelec/fs-resize"; do
    if [[ -f "$patched_script" ]] && grep -q '@WIFI_PROVISIONED_FILES@' "$patched_script"; then
        sed -i "s|@WIFI_PROVISIONED_FILES@|$wifi_config_names_escaped|" "$patched_script"
    fi
done

new_system_file="$work_dir/SYSTEM.new"
if ! mksquashfs "$work_dir/root" "$new_system_file" -comp zstd -Xcompression-level 19 -b 1048576 -no-xattrs -noappend >/dev/null 2>&1; then
    printf 'Warning: failed to repack SYSTEM squashfs; leaving SYSTEM unpatched.\n' >&2
    exit 0
fi

cp "$new_system_file" "$system_file"
printf '%s  target/SYSTEM\n' "$(md5sum "$system_file" | cut -d' ' -f1)" > "$boot_mount_dir/SYSTEM.md5"
