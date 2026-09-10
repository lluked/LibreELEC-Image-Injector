# LibreELEC boot behavior notes

Findings about how a LibreELEC RPi4 image actually boots, gathered while
debugging why WiFi/SSH-provisioned images weren't auto-expanding storage.
Relevant to anything touching `scripts/patch-system-scripts.sh` or the
diffs under `config/system-patches/`.

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
extlinux/U-Boot layer in between. There's no separate initramfs file on
the boot partition either (checked: no embedded cpio in `kernel.img`).
This is why appending ` ssh` to `cmdline.txt` reliably reaches
`/proc/cmdline`.

## RTC — the clock may start wrong on first boot

There may be no battery-backed RTC. Every boot starts with the system clock
reading a bogus date (observed: `2025-06-26`, roughly this build's
release date) and NTP corrects it partway through that same boot once
network comes up. Confirmed directly: `journalctl --list-boots` on a
42-minute-uptime device showed a *single* boot ID spanning
`2025-06-26T08:44:13` (first entry) to the real current date/time (last
entry) — not two boots, one boot whose clock jumped forward mid-session.
**Any file timestamp from early boot (before NTP syncs) will show this
bogus date.** Don't mistake same-boot pre/post-NTP timestamps for
evidence of separate boots.

## No persistent journal

No persistent journal either (`/var/log/journal` doesn't exist,
`journalctl` config has no `Storage=persistent`) — `journalctl --list-boots`
only ever shows the current boot. There is no way to retrieve logs from
a previous boot after a reboot, including the crucial *true first boot*.

## The `.please_resize_me` / `fs-resize` mechanism

- Storage partition ships with an empty marker file at
  `/storage/.please_resize_me` on a pristine image.
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
  rejects with "already initialised". **This means the marker is
  one-shot: if it's ever evaluated and rejected, that device can never
  auto-resize again without manually recreating the marker
  (`touch /storage/.please_resize_me && reboot`) or reflashing.**
- Always ends with an unconditional `reboot -f`, so a device with the
  marker present will always reboot once extra on first boot regardless
  of outcome.

## `/storage/.cache/systemd-machine-id`

- `/etc/machine-id` is a symlink to `/storage/.cache/systemd-machine-id`.
- PID1 itself unconditionally assigns *some* machine ID at the very
  start of every boot — `journalctl` confirms the line
  `systemd[1]: Initializing machine ID from random generator` right at
  the start of boot. Making that ID show up on disk at
  `/storage/.cache/systemd-machine-id` happens two different ways
  depending on whether `/storage/.cache` already exists:
  - If `/storage/.cache` does **not** exist yet, PID1 has nowhere to
    land its early overmount (it doesn't `mkdir -p` the path itself),
    so it just keeps the ID in memory. Real persistence then waits for
    the proper `machine-id.service` unit (`WantedBy=sysinit.target`,
    `ExecStart=/usr/bin/systemd-machine-id-setup` — on this image not
    systemd's own binary but a LibreELEC shell wrapper that
    `mkdir -p /storage/.cache` before writing). That unit is an
    ordinary `sysinit.target`-ordered job with no `ConditionPathExists`
    tying it to `.please_resize_me` or resize state (confirmed by
    reading the unit file directly).
  - If `/storage/.cache` **already exists** (as a real directory, from
    before this boot), PID1's own early machine-id overmount succeeds
    immediately against that existing path — confirmed by the LibreELEC
    `systemd-machine-id-setup` wrapper itself, which opens with
    `umount /storage/.cache/systemd-machine-id` under the comment "For
    first boot detection systemd may have overmounted the file". This
    happens independent of the unit/target graph entirely — it isn't a
    systemd job that `fs-resize.target`'s isolation could ever exclude.

## Why `/storage/.cache/systemd-machine-id` used to show up before `fs-resize` ran

- Debug logging added to this repo's injected images, writing to a
  persistent `/flash/fs-resize.log` (sampled immediately before the
  guard check runs), directly confirmed the file was already written by
  that point, on every injected image — never on a clean/untouched one
  (confirmed by diffing the extracted `SYSTEM` squashfs of both:
  `machine-id.service`, `libreelec-target-generator`,
  `storage.mount.d/dependencies.conf`, and the `systemd-machine-id-setup`
  wrapper are byte-for-byte identical between clean and injected images,
  so the difference was never in any of that boot machinery).
- The cause was `inject-config.sh` itself: it used to `mkdir -p
  "$mount_dir/.cache/services"` (writing `sshd.conf`) and, when WiFi was
  provisioned, `mkdir -p .cache/connman` too — directly on the STORAGE
  partition, on the host, before the device ever booted. That made
  `/storage/.cache` already exist as a real directory the moment
  `/storage` mounted on first boot, which is exactly the precondition
  above for PID1's early, job-graph-independent machine-id write to land
  on disk — even during `fs-resize.target`'s otherwise fully isolated
  boot.
- Fixed at the source rather than only allowlisted: `inject-config.sh`
  now stages *everything* it provisions — WiFi config, `sshd.conf`,
  `.ssh/authorized_keys`, and `scripts/install-injected-config.sh`
  itself — under `/flash/.injected-config` (see `scripts/inject-config.sh`),
  on the **boot** partition, not `/storage` at all. `/storage/.cache`
  genuinely doesn't exist yet when `/storage` first mounts on an
  injected image, same as a clean one. The patched `fs-resize` script
  calls `sh /flash/.injected-config/install-injected-config.sh`, which
  copies the staged files from `/flash/.injected-config` into their real
  `/storage/.cache`/`/storage/.ssh` locations, after its guard check has
  already run. `install-injected-config.sh` isn't baked into the
  `SYSTEM` squashfs — it's just another file staged on `/flash` by
  `inject-config.sh`, so it's never tied to a particular LibreELEC
  version the way the `fs-resize`/`factory-reset` diffs are. Staging on
  `/flash` rather than `/storage` also means none of this needs backing
  up before `fs-resize`'s `mke2fs` reformat — the boot partition is
  never touched by it, so the old `/run`-tmpfs backup/restore mechanism
  this section used to describe is gone entirely; the call is a single
  plain script invocation, made after the reformat (or in the guard's
  reject path, or the "partition not detected" abort path — whichever
  the script actually takes).
- `/flash/.injected-config` is permanent — neither the `fs-resize` nor
  the `factory-reset` patch ever deletes it. `factory-reset`'s patched
  script makes the same `sh /flash/.injected-config/install-injected-config.sh`
  call after every hard/soft reset too, so a reset always reinstalls the
  *originally injected* WiFi/sshd/SSH config, discarding whatever was
  actually live on the device. There's no backup of live `/storage`
  state anywhere in either patch anymore (that used to be
  `factory-reset`'s whole reason for its own `backup_wifi`/
  `backup_ssh_authorized_keys`/`backup_sshd_conf` — deliberately removed
  now). Changing WiFi/SSH credentials means re-injecting and reflashing
  a new image, not reconfiguring the live device and expecting a reset
  to remember it.

## Why `config/system-patches/fs-resize.*.diff` no longer touches the `.cache` guard at all

Earlier versions of this diff added an allowlist function
(`cache_has_unexpected_content()`) so the guard would tolerate
`systemd-machine-id`/`connman/`/`services/sshd.conf` under `.cache` —
needed back when `inject-config.sh` wrote provisioned config straight
into `/storage/.cache`. Now that provisioning stages entirely through
`/flash/.injected-config` instead (see the section above),
`/storage/.cache` genuinely never exists at guard-check time on a
freshly injected image, so the guard needed nothing special at all. The
current diff leaves the guard completely untouched from stock —
`if [ -d /storage/.kodi -o -d /storage/.config -o -d /storage/.cache ]`
— and only adds the
`sh /flash/.injected-config/install-injected-config.sh` call, made after
the guard has already run (in the resize-success path, the "already
initialised" reject path, and the "partition not detected" abort path
alike).

One consequence of the guard being genuinely stock again: a device
already past its first boot, manually re-pointed at `.please_resize_me`
for a resize retry, with real, live `/storage/.cache` content, is
correctly blocked as "already initialised" rather than resized — same
as it would be on a completely unmodified image (the partition itself
is never reformatted in this path). But `install-injected-config.sh`
is still called in this reject branch too, and `/flash/.injected-config`
is permanent (never deleted — see the section above), so a rejected
retry still overwrites `/storage/.cache/connman`,
`/storage/.cache/services/sshd.conf`, and `/storage/.ssh/authorized_keys`
with the *originally injected* values, even though the resize itself
didn't happen. That's intentional, consistent with
`/flash/.injected-config` being the permanent source of truth for the
whole device lifetime (see above) — not a leftover from when the guard
still needed careful handling around this branch.
