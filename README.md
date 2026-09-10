# LibreELEC Image Injector

Headlessly provisions a LibreELEC SD card image with SSH access and WiFi
credentials before first boot, so a Raspberry Pi can come up on the network
and be reachable over SSH without ever attaching a keyboard, screen, or
console.

It works by loop-mounting the image's boot and storage partitions in a
privileged Docker container, writing the config in place, and re-packing the
image.

## Requirements

- Docker with Compose v2 (`docker compose`)
- A LibreELEC `.img` or `.img.gz` source image

## Setup

### 1. Add a source image

Drop a LibreELEC image into `images/source/` (both `.img` and `.img.gz` are
supported; `.gz` sources are decompressed automatically and the output is
re-compressed back to `.gz`). This directory is gitignored aside from a
placeholder.

### 2. Add your SSH public key

The injector writes `config/authorized_keys` into the image's
`~/.ssh/authorized_keys`. Either:

- Run `./create-authorized-keys.sh [PRIVATE_KEY]` to derive it from a private
  key (defaults to `~/.ssh/id_rsa`), or
- Copy your own public key contents into `config/authorized_keys` by hand
  (see `config/authorized_keys.example`).

### 3. Add WiFi profiles (optional)

Drop one `.config` file per network into `config/wifi/`, using ConnMan's
[provisioning file format](https://github.com/aldebaran/connman/blob/master/doc/config-format.txt):

```ini
[global]
Name = Wifi
Description = Wifi service config file

[service_myhome]
Type = wifi
Name = MyHomeNetwork
Passphrase = supersecret
```

Every `.config` file present gets copied onto the image's storage partition
and provisioned — there's no single "active" network to pick. **Each file
needs its own unique `[service_*]` identifier** (e.g. `service_myhome`,
`service_office`); reusing the same identifier across two files makes one
silently clobber the other in ConnMan's internal store.

If you provision multiple networks, ConnMan auto-connects to whichever is
in range, preferring the strongest signal — there's no way to force a fixed
default through the provisioning format itself. See
`config/wifi/wifi.config.example` for a template.

If `config/wifi/` has no `.config` files, WiFi provisioning is skipped
entirely and only the SSH key is injected.

### 4. Run the injector

Using the wrapper script:

```sh
./run-libreelec-image-injector.sh                       # process every image in images/source/
./run-libreelec-image-injector.sh some-image.img.gz     # process just this one
```

Or directly with Compose:

```sh
docker compose up
IMAGE=some-image.img.gz docker compose up    # target a specific image
```

The result lands in `images/injected/`, named `<original>_injected.img`
(or `.img.gz` if the source was compressed) — flash that to the SD card.

## After first boot

- The provisioned WiFi networks show up as pre-configured entries in Kodi's
  **LE Settings → Connections** menu, selectable with just the remote (no
  typing required), once each network's been seen over the air at least
  once.
- SSH occasionally isn't reachable until after one reboot on first boot —
  that's LibreELEC's own first-run storage setup, not this tool.
- To change WiFi or SSH settings on a device that's already booted, use
  Kodi's Connections menu or `connmanctl` over SSH — don't hand-edit
  `/storage/.cache/connman/` on a live system, ConnMan manages that itself
  and will likely overwrite manual changes.
- A factory/storage reset from LibreELEC's **LE Settings → System → Reset**
  menu normally wipes `/storage` entirely, taking the provisioned WiFi
  config, the SSH key, and the `sshd.conf` that enables SSH with it. The
  injector patches the image's factory-reset script (see below) to back up
  the exact WiFi `.config` files it provisioned, `~/.ssh/authorized_keys`,
  and `.cache/services/sshd.conf` before a reset and restore them after, so
  a reset no longer knocks WiFi or SSH access out — everything else under
  `/storage` still gets wiped as normal. A **soft** reset only touches
  `.cache/`, `.config/`, `.kodi/` (not `.ssh/`), so only the WiFi config
  and `sshd.conf` need restoring there; a **hard** reset wipes everything,
  so all three get restored. Only the WiFi networks this tool provisioned
  are preserved this way, not whatever ConnMan's runtime state has
  accumulated since boot.
- The storage partition should auto-expand to fill the SD card on first
  boot. LibreELEC's own `fs-resize` skips that expansion if `/storage/.cache`
  has anything in it, on the theory that means Kodi has already run — but in
  practice `.cache` reliably has *something* in it by the time `fs-resize`
  gets a real chance to check: WiFi/SSH provisioning puts files there before
  first boot, ConnMan writes its own `settings`/managed-PSK state within
  seconds of actually connecting, and LibreELEC's own stock services (avahi,
  bluetooth, cron) auto-enable and write their own conf files into
  `.cache/services/` as part of the unattended first-run wizard — which
  only sails through to that step without waiting on user input *because*
  WiFi's already provisioned; without it the wizard would stall on the
  network step waiting for someone to pick a network by remote, and never
  reach them. The injector patches `fs-resize` to only treat `.cache` as
  evidence of a real prior boot if it contains something *other than*
  ConnMan's own `connman/` directory (whatever's inside it is ConnMan's own
  business) or, inside `services/`, anything other than the handful of conf
  files that get written there as stock behaviour regardless of this tool:
  `sshd.conf` (this tool's own) plus `avahi.conf`/`bluez.conf`/`crond.conf`.
  Anything else in `services/` (`samba.conf`, say, from a user actually
  configuring it via the UI) *is* real evidence of prior setup, so only
  those specific files are trusted, not the whole directory. Because
  `fs-resize`'s actual resize step is a destructive `mke2fs` reformat (not
  an in-place grow), the patch also backs up the provisioned WiFi config,
  SSH key, and `sshd.conf` beforehand and restores them into the
  freshly-formatted partition afterward, the same way the factory-reset
  patch does. If you're running an injected image built before this fix,
  the partition stays at its original (small) image size; resize it
  manually over SSH with `parted /dev/sdX resizepart 2 100%` (needs
  `---pretend-input-tty` piped `yes` if `/storage` is mounted) then
  `resize2fs /dev/sdX2`.

## Files

| File | Purpose |
|---|---|
| `create-authorized-keys.sh` | Derives `config/authorized_keys` from an existing SSH private key. |
| `Dockerfile` | `ubuntu:26.04` plus `squashfs-tools` and `patch`, needed to unpack/repack the boot partition's `SYSTEM` squashfs and apply the system-script patches. |
| `compose.yaml` | Builds and runs `scripts/inject-config.sh` in a privileged, read-only container (service `libreelec-image-injector`) with the repo bind-mounted. |
| `scripts/inject-config.sh` | Does the actual work: loop-mounts the image, enables `ssh` on the boot partition's kernel command line *and* writes `/storage/.cache/services/sshd.conf` (the same file LE Settings' SSH toggle writes, in its key-only/password-disabled state — the boot flag alone wasn't reliably starting `sshd` on real hardware), copies WiFi configs and the SSH key onto the storage partition, and calls `patch-system-scripts.sh` to preserve WiFi/SSH across a reset and fix first-boot auto-resize. Runs as root inside the container. |
| `scripts/patch-system-scripts.sh` | Unpacks the boot partition's `SYSTEM` squashfs once and, for each of `usr/lib/libreelec/factory-reset` and `usr/lib/libreelec/fs-resize`, hashes the script inside it and applies `config/system-patches/<script-name>.<hash>.diff` if a patch for that exact version exists — otherwise it warns and leaves that script untouched. Each diff is static (structural); for factory-reset, this script then also reads `config/wifi/*.config` directly and bakes that filename list into the patched script (replacing a `@WIFI_PROVISIONED_FILES@` placeholder), so it only ever restores what's actually provisioned there — no separate manifest file. `SYSTEM` is only repacked if at least one patch actually applied. Never fails the run. |
| `config/system-patches/` | One unified diff per known LibreELEC script version, named `<script-name>.<md5-of-that-version>.diff` (e.g. `factory-reset.<hash>.diff`, `fs-resize.<hash>.diff`). To support a new LibreELEC version, extract the script, hash it, and add a diff named after that script and hash. |
| `run-libreelec-image-injector.sh` | Convenience wrapper around `docker compose run` for local use. |

## License

[GPLv2](LICENSE)
