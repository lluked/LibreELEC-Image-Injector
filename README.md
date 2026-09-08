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

## Files

| File | Purpose |
|---|---|
| `create-authorized-keys.sh` | Derives `config/authorized_keys` from an existing SSH private key. |
| `compose.yaml` | Runs `inject-config.sh` in a privileged, read-only `ubuntu:22.04` container (service `libreelec-image-injector`) with the repo bind-mounted. |
| `inject-config.sh` | Does the actual work: loop-mounts the image, enables `ssh` on the boot partition, copies WiFi configs and the SSH key onto the storage partition. Runs as root inside the container. |
| `run-libreelec-image-injector.sh` | Convenience wrapper around `docker compose run` for local use. |

## License

[GPLv2](LICENSE)
