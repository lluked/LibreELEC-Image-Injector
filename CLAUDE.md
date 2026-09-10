# LibreELEC boot behavior notes

Findings about how a LibreELEC RPi4 image actually boots, kept because
they explain *why* `scripts/inject-config.sh`,
`scripts/patch-system-scripts.sh`, `scripts/install-injected-config.sh`,
and the diffs under `config/system-patches/` are built the way they are.
Relevant to anything touching those files.

**Maintenance rules for this file:**
- When a finding here turns out to be wrong or incomplete, rewrite it in
  place as current, correct fact — don't narrate the revision ("an
  earlier version claimed X", "correction:", "this was previously
  thought to be Y"). Superseded findings can inform the rewrite, but the
  doc itself should always read as if it were written fresh from today's
  understanding, never as a change-log or edit history.
- When a finding here turns out to be not relevant anymore, remove it.
- Before editing this file, and periodically otherwise, check whether
  its existing content is still relevant against the current state of
  the repo (the actual scripts and diffs, not memory of them) — cross
  reference specific claims (paths, function names, behavior described)
  against what's really there now. Remove or rewrite anything that no
  longer applies; don't leave stale documentation describing mechanisms,
  files, or behavior that have since changed or been removed.
- Also check the comments inside the actual code (the scripts under
  `scripts/`, the patched scripts embedded in the diffs under
  `config/system-patches/`) against both the code they annotate and this
  file — a comment can go stale relative to its own code the same way
  this doc can, and the two should tell a consistent story. If a code
  comment and this file disagree, or a code comment no longer matches
  what the code around it actually does, fix whichever is wrong (or
  both) rather than leaving the mismatch.

## No U-Boot, no initramfs

`kernel.img` on the boot partition is a plain gzip-compressed Linux
`Image` — the RPi firmware (`start.elf`) decompresses and boots it
directly. `cmdline.txt` is the literal kernel command line, no
extlinux/U-Boot layer in between, and there's no separate initramfs file
on the boot partition either. This is why `inject-config.sh` appending
` ssh` straight onto `cmdline.txt` (see the boot-config loop over
`cmdline.txt`/`extlinux.conf`/`extlinux/extlinux.conf`/`syslinux.cfg`)
reliably reaches `/proc/cmdline` on this platform — the other
extlinux/syslinux branches in that loop exist for portability to other
LibreELEC targets, not because RPi4 needs them.

## RTC and journal: no logs survive past the current boot

There's no battery-backed RTC, so every boot starts with the system
clock reading a bogus date and NTP corrects it partway through that same
boot once network comes up — a single boot's `journalctl` output can
span from a bogus early timestamp to the real current date/time, which
looks like two boots but isn't. There's also no persistent journal
(`/var/log/journal` doesn't exist, no `Storage=persistent`), so
`journalctl --list-boots` only ever shows the current boot — there is no
way to retrieve logs from a previous boot after a reboot, including the
device's true first boot. Anything that needs to survive across the
`fs-resize` reboot (or be inspected after the fact) has to write to a
file under `/flash`, not rely on the journal.

## The `.please_resize_me` / `fs-resize` mechanism

- A pristine STORAGE partition ships with an empty marker file at
  `/storage/.please_resize_me`.
- A systemd generator, `libreelec-target-generator`
  (`/usr/lib/systemd/system-generators/`), runs very early and does:
  `[ -f /storage/.please_resize_me ] && TARGET=fs-resize.target`, then
  `ln -sT .../fs-resize.target $EARLY_DIR/default.target` — it
  **replaces `default.target` entirely** for that boot.
- `fs-resize.service` has `DefaultDependencies=no`, so when
  `fs-resize.target` becomes `default.target`, **nothing else starts
  that boot** — no Kodi, no avahi, no samba, no network services. It's
  fully isolated, not a race against anything else.
- `fs-resize.sh` (`/usr/lib/libreelec/fs-resize`) always deletes
  `.please_resize_me` before it finishes, whether it actually resizes or
  rejects with "already initialised". **The marker is one-shot: if it's
  ever evaluated and rejected, that device can never auto-resize again
  without manually recreating the marker
  (`touch /storage/.please_resize_me && reboot`) or reflashing.**
- Its guard is `if [ -d /storage/.kodi -o -d /storage/.config -o -d /storage/.cache ]`
  — a plain directory-existence check, not a content check. If any of
  those three directories exists at all when the guard runs, the resize
  is rejected as "already initialised", permanently (per the one-shot
  point above) until the marker is manually recreated.
- Always ends with an unconditional `reboot -f`, so a device with the
  marker present always reboots once extra on first boot regardless of
  outcome.

## Why provisioned config is staged on `/flash/.injected-config`, never written to `/storage` directly

`inject-config.sh` stages everything it provisions — WiFi config,
`sshd.conf`, `.ssh/authorized_keys`, and
`scripts/install-injected-config.sh` itself — under
`/flash/.injected-config` on the **boot** partition, and never creates
or writes anything under `/storage` on the host side. Two independent
reasons converge on this:

- PID1 unconditionally assigns *some* machine ID for `/etc/machine-id`
  (a symlink to `/storage/.cache/systemd-machine-id`) right at the start
  of every boot, independent of the unit/target graph. If
  `/storage/.cache` already exists as a real directory at that moment,
  PID1's own early overmount writes the ID straight to disk immediately;
  if it doesn't exist yet, PID1 has nowhere to land it and the write
  waits for the ordinary `machine-id.service` job
  (`WantedBy=sysinit.target`) later in the boot. That means a directory
  created under `/storage/.cache` before first boot can cause real
  on-disk writes to happen *before* `fs-resize`'s guard even runs,
  regardless of `fs-resize.target`'s otherwise complete isolation of
  that boot — a pre-existing `/storage/.cache` silently changes
  first-boot behavior even beyond the guard check itself.
- Separately, the `fs-resize` guard above tests `-d /storage/.cache`
  (and `.kodi`, `.config`) for *existence*, not content. If the host
  injector created `/storage/.cache` before the device's first boot —
  even just an empty directory to drop `sshd.conf` into — the very
  first boot's guard check would see it and permanently reject the
  resize, and because the marker is one-shot, the device could never
  auto-expand its storage at all. Never creating anything under
  `/storage/.cache`/`.config`/`.kodi` before first boot keeps the
  guard's view of a freshly-injected image identical to a completely
  clean one.

Staging on `/flash` instead of `/storage` also means the destructive
`mke2fs` reformat that `fs-resize` performs never touches any of it —
there is nothing that needs backing up before the reformat and restoring
after; `install-injected-config.sh` just copies from the permanent
`/flash/.injected-config` into the freshly-formatted partition once,
after the fact.

## How `install-injected-config.sh` gets invoked, and what that implies

`config/system-patches/fs-resize.*.diff` and
`config/system-patches/factory-reset.*.diff` each add a call to
`sh /flash/.injected-config/install-injected-config.sh` (which copies
the staged WiFi config to `/storage/.cache/connman/`, `sshd.conf` to
`/storage/.cache/services/`, and the SSH key to
`/storage/.ssh/authorized_keys`) into every code path that can be
reached, not just the success path:

- In `fs-resize`, it's called in the guard-reject branch ("already
  initialised"), in the normal resize-success branch (mounted directly
  against the freshly-formatted partition, before the final reboot), and
  in the "partition not detected" abort branch. The guard itself is left
  completely unpatched/stock — see the section above for why that's
  sufficient.
- In `factory-reset`, it's called after both the hard-reset path
  (mounted against the reformatted partition) and the soft-reset path
  (`/storage/.cache/`, `/storage/.config/`, `/storage/.kodi/` deleted).

Because `/flash/.injected-config` is never deleted by either patched
script, and every one of these branches reinstalls unconditionally from
it, the practical behavior is: **a factory reset (hard or soft), or a
manually-retried resize that gets guard-rejected, always reinstalls the
originally-injected WiFi/SSH/sshd config, discarding whatever was
actually live on the device** — there is no backup of live `/storage`
state anywhere in this repo. Changing WiFi or SSH credentials on a
device means re-injecting and reflashing a new image, not reconfiguring
the live device and expecting a reset to remember it.
