#!/usr/bin/env bash
# Compose launcher for the LibreELEC configuration injector.

set -euo pipefail

usage() {
    printf 'Usage: %s [IMAGE]\n' "$(basename "$0")" >&2
    exit 2
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
image_name=''

while [[ $# -gt 0 ]]; do
    case $1 in
        --*)
            usage
            ;;
        *)
            [[ -z "$image_name" ]] || usage
            image_name=$1
            shift
            ;;
    esac
done

run_args=(./scripts/inject-config.sh)
[[ -n "$image_name" ]] && run_args+=(--image "$image_name")

printf '==> Running Compose configuration injector\n'
docker compose \
    --file "$script_dir/compose.yaml" \
    --project-directory "$script_dir" \
    run --rm libreelec-image-injector "${run_args[@]}"
