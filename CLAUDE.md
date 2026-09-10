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
  the start of boot — but that step alone never touches `/storage`:
  with `/storage` not yet mounted at that point, PID1 just keeps the ID
  in a transient in-memory overmount of `/etc/machine-id`.
- *Persisting* it to `/storage/.cache/systemd-machine-id` is a separate
  step, done by the real `machine-id.service` unit
  (`WantedBy=sysinit.target`, no `ConditionPathExists` tying it to
  `.please_resize_me` or resize state — confirmed by reading the unit
  file directly), whose `ExecStart` is
  `/usr/bin/systemd-machine-id-setup` — on this image, not systemd's
  own binary but an 804-byte LibreELEC shell wrapper that
  validates/generates the ID via `dbus-uuidgen`, unmounts that
  transient overmount, and writes the real value to
  `/storage/.cache/systemd-machine-id`.
- That persisting step is an ordinary `sysinit.target`-ordered unit —
  it has no reason to run during `fs-resize.target`'s isolated boot if
  that isolation is actually working as intended (`fs-resize.service`
  has `DefaultDependencies=no` specifically so an isolated resize boot
  pulls in nothing else, `sysinit.target` included).

## Why `/storage/.cache/systemd-machine-id` shows up before `fs-resize` runs

- Debug logging added to this repo's injected images, writing to a
  persistent `/flash/fs-resize.log` (sampled immediately before the
  guard check runs), directly confirmed `machine-id.service` had already
  completed and written the file by that point.
- Why `machine-id.service` runs during a boot that's supposed to
  exclude it remains unexplained; `cache_has_unexpected_content()`
  allowlists it anyway because it isn't evidence of a *user* having
  configured the device, whatever the cause.

## Why `config/system-patches/fs-resize.*.diff` handles `.cache` the way it does

See `cache_has_unexpected_content()` in that diff and the comment above
it for the current, working answer — it allowlists `systemd-machine-id`
and `connman/` (ConnMan's own business) at the top level of `.cache`,
and, inside `services/`, only this tool's own `sshd.conf`, while still
treating anything else there (`avahi.conf`, `samba.conf`, etc.) as real
evidence of prior setup.
