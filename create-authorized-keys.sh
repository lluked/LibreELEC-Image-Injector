#!/usr/bin/env bash
# Derive the SSH public key from a private key for LibreELEC injection.

set -euo pipefail

usage() {
    printf 'Usage: %s [PRIVATE_KEY]\n' "$(basename "$0")" >&2
    exit 2
}

[[ $# -le 1 ]] || usage

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
private_key=${1:-$HOME/.ssh/id_rsa}
authorized_keys="$script_dir/config/authorized_keys"

if ! command -v ssh-keygen >/dev/null 2>&1; then
    printf 'Error: ssh-keygen is required but was not found.\n' >&2
    exit 1
fi

if [[ ! -f "$private_key" ]]; then
    printf 'Error: private key not found: %s\n' "$private_key" >&2
    exit 1
fi

mkdir -p "$(dirname "$authorized_keys")"
printf '==> Deriving public key from %s\n' "$private_key"
ssh-keygen -y -f "$private_key" > "$authorized_keys"
chmod 600 "$authorized_keys"
printf '==> Wrote %s\n' "$authorized_keys"
