#!/usr/bin/env bash
# Patch LibreELEC scripts baked into the boot partition's SYSTEM squashfs.
#
# inject-config.sh stages everything it provisions (WiFi config,
# sshd.conf, SSH key, and scripts/install-injected-config.sh itself)
# under /flash/.injected-config, on the BOOT partition — never under
# /storage directly (see inject-config.sh for why: writing straight to
# /storage/.cache used to let PID1's own early machine-id commit land on
# disk during fs-resize's otherwise fully isolated first-boot resize).
# /flash/.injected-config is permanent — nothing ever deletes it — so it
# stays the single source of truth for the life of the device. There is
# no backup/restore of live /storage state anywhere in either patch: a
# reset (or a later manual fs-resize retry) always reinstalls from
# /flash/.injected-config, discarding whatever was actually live on
# /storage. Re-injecting a new image is how WiFi/SSH config changes, not
# reconfiguring the live device and expecting a reset to remember it.
#   - usr/lib/libreelec/fs-resize: patched to call
#     `sh /flash/.injected-config/install-injected-config.sh` — which
#     copies /flash/.injected-config into its real /storage location
#     (/storage/.cache/connman, /storage/.cache/services, /storage/.ssh)
#     — after the resize, after the guard rejects it, or after it aborts
#     for want of a detected partition, whichever the script actually
#     takes. The guard itself
#     (`-d /storage/.kodi -o -d /storage/.config -o -d /storage/.cache`)
#     is left completely stock/unmodified: since nothing is ever written
#     to /storage before this boot, /storage/.cache genuinely doesn't
#     exist at guard-check time on an injected image, same as a clean
#     one, so no allowlisting is needed.
#   - usr/lib/libreelec/factory-reset: patched to make the same call,
#     after the storage wipe (hard reset) or the cache/config/kodi
#     delete (soft reset).
#
# install-injected-config.sh itself isn't touched by this script at all —
# it's staged directly onto /flash by inject-config.sh, like the rest of
# /flash/.injected-config, so it's never tied to any particular
# LibreELEC version the way these two diffs are. Each patch here is only
# applied if the image's copy of that script matches a known LibreELEC
# version exactly (identified by md5), since these are real edits to the
# boot squashfs and shouldn't be applied blind against a script they
# weren't written for. Never fails the caller — any problem is a warning
# and the affected script is left as-is.

set -euo pipefail
shopt -s nullglob

boot_mount_dir=$1
patches_dir=$2

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

new_system_file="$work_dir/SYSTEM.new"
if ! mksquashfs "$work_dir/root" "$new_system_file" -comp zstd -Xcompression-level 19 -b 1048576 -no-xattrs -noappend >/dev/null 2>&1; then
    printf 'Warning: failed to repack SYSTEM squashfs; leaving SYSTEM unpatched.\n' >&2
    exit 0
fi

cp "$new_system_file" "$system_file"
printf '%s  target/SYSTEM\n' "$(md5sum "$system_file" | cut -d' ' -f1)" > "$boot_mount_dir/SYSTEM.md5"
