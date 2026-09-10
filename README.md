# LibreELEC Image Injector

Headlessly provisions a LibreELEC SD card image with SSH access and WiFi
credentials before first boot, so a Raspberry Pi can come up on the network
and be reachable over SSH without ever attaching a keyboard, screen, or
console.

It works by loop-mounting the image's boot and storage partitions in a
privileged Docker container, staging the provisioned config onto the boot
partition, and re-packing the image. (Everything is staged on the boot
partition rather than written to storage directly — see [CLAUDE.md](CLAUDE.md) for why.)

## Requirements

- Docker with Compose v2 (`docker compose`)
- A LibreELEC `.img` or `.img.gz` source image

## Setup

### 1. Add a source image

Drop a LibreELEC image into [images/source/](images/source/) (both `.img` and `.img.gz` are
supported; `.gz` sources are decompressed automatically and the output is
re-compressed back to `.gz`). This directory is gitignored aside from a
placeholder.

### 2. Add your SSH public key

The injector stages [config/authorized_keys](config/authorized_keys) so it
lands at `~/.ssh/authorized_keys` once the device boots. Either:

- Run [`./create-authorized-keys.sh`](create-authorized-keys.sh) `[PRIVATE_KEY]`
  to derive it from a private key (defaults to `~/.ssh/id_rsa`), or
- Copy your own public key contents into
  [config/authorized_keys](config/authorized_keys) by hand (see
  [config/authorized_keys.example](config/authorized_keys.example)).

### 3. Add WiFi profiles (optional)

Drop one `.config` file per network into [config/wifi/](config/wifi/), using ConnMan's
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

Every `.config` file present gets staged onto the image and provisioned once
the device boots — there's no single "active" network to pick. **Each file
needs its own unique `[service_*]` identifier** (e.g. `service_myhome`,
`service_office`); reusing the same identifier across two files makes one
silently clobber the other in ConnMan's internal store.

If you provision multiple networks, ConnMan auto-connects to whichever is
in range, preferring the strongest signal — there's no way to force a fixed
default through the provisioning format itself. See
[config/wifi/wifi.config.example](config/wifi/wifi.config.example) for a template.

If [config/wifi/](config/wifi/) has no `.config` files, WiFi provisioning is skipped
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

The result lands in [images/injected/](images/injected/), named `<original>_injected.img`
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
  injector patches the image's factory-reset script (see
  [Files](#files) below) to reinstall the originally-injected WiFi config,
  SSH key, and `sshd.conf`
  immediately after every reset (hard or soft), so a reset no longer knocks
  WiFi or SSH access out. This always reinstalls the *exact* config that was
  injected into the image, not a backup of whatever was actually live on
  the device — so changing WiFi or SSH credentials means re-injecting and
  reflashing a new image, not reconfiguring the live device and expecting a
  reset to remember it.
- The storage partition auto-expands to fill the SD card on first boot via
  LibreELEC's own `fs-resize`, which refuses to resize (permanently — the
  refusal is one-shot) if `/storage/.kodi`, `/storage/.config`, or
  `/storage/.cache` already exists, on the theory that means the system has
  already been set up. Because that check is a plain existence check, the
  injector never creates any of those paths on the storage partition itself
  — all provisioned config (WiFi config, `sshd.conf`, the SSH key) is
  staged instead on the **boot** partition and only installed onto
  `/storage` by the device itself, after `fs-resize`'s guard has already
  run (or after a factory reset — see above). This also means the resize
  guard is left completely stock/unpatched: a freshly-injected image looks
  identical to an unmodified one as far as the guard is concerned. See
  [CLAUDE.md](CLAUDE.md) for the full mechanism.

## Files

| File | Purpose |
|---|---|
| [create-authorized-keys.sh](create-authorized-keys.sh) | Derives [config/authorized_keys](config/authorized_keys) from an existing SSH private key. |
| [Dockerfile](Dockerfile) | `ubuntu:26.04` plus `squashfs-tools` and `patch`, needed to unpack/repack the boot partition's `SYSTEM` squashfs and apply the system-script patches. |
| [compose.yaml](compose.yaml) | Builds and runs [scripts/inject-config.sh](scripts/inject-config.sh) in a privileged, read-only container (service `libreelec-image-injector`) with the repo bind-mounted. |
| [scripts/inject-config.sh](scripts/inject-config.sh) | Does the actual work: loop-mounts the image, enables `ssh` on the boot partition's kernel command line, and stages the WiFi config, `sshd.conf` (the same file LE Settings' SSH toggle writes, in its key-only/password-disabled state — the boot flag alone wasn't reliably starting `sshd` on real hardware), and the SSH key onto the **boot** partition under `.injected-config/` — never writing to the storage partition on the host side (see [CLAUDE.md](CLAUDE.md) for why). Also stages [install-injected-config.sh](scripts/install-injected-config.sh) itself, then calls [patch-system-scripts.sh](scripts/patch-system-scripts.sh) to patch the on-device scripts that install this staged config. Runs as root inside the container. |
| [scripts/install-injected-config.sh](scripts/install-injected-config.sh) | Staged onto the boot partition by [inject-config.sh](scripts/inject-config.sh), alongside the rest of `.injected-config/`. Invoked **on-device**, by the patched `fs-resize`/`factory-reset` below, to copy the staged WiFi config, `sshd.conf`, and SSH key from `/flash/.injected-config` into their real `/storage/.cache`/`/storage/.ssh` locations. |
| [scripts/patch-system-scripts.sh](scripts/patch-system-scripts.sh) | Unpacks the boot partition's `SYSTEM` squashfs once and, for each of `usr/lib/libreelec/factory-reset` and `usr/lib/libreelec/fs-resize`, hashes the script inside it and applies a diff from [config/system-patches/](config/system-patches/) (`<script-name>.<hash>.diff`) if a patch for that exact version exists — otherwise it warns and leaves that script untouched. Each diff just adds a call to [install-injected-config.sh](scripts/install-injected-config.sh) on every exit path of the target script; `SYSTEM` is only repacked if at least one patch actually applied. Never fails the run. |
| [config/system-patches/](config/system-patches/) | One unified diff per known LibreELEC script version, named `<script-name>.<md5-of-that-version>.diff` (e.g. `factory-reset.<hash>.diff`, `fs-resize.<hash>.diff`). To support a new LibreELEC version, extract the script, hash it, and add a diff named after that script and hash. |
| [run-libreelec-image-injector.sh](run-libreelec-image-injector.sh) | Convenience wrapper around `docker compose run` for local use. |

## License

[GPLv2](LICENSE)
