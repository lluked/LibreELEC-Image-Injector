#!/bin/sh

# Installs whatever inject-config.sh staged on the BOOT partition under
# /flash/.injected-config into its real /storage location. This file is
# copied onto /flash/.injected-config itself by inject-config.sh (not
# baked into the SYSTEM squashfs), and invoked as
# `sh /flash/.injected-config/install-injected-config.sh` by the patched
# usr/lib/libreelec/fs-resize and usr/lib/libreelec/factory-reset (see
# the comment at the top of patch-system-scripts.sh for why /storage is
# never written to directly, and why this lives on /flash permanently
# rather than being backed up/restored around a wipe).

injected_config_dir="/flash/.injected-config"

if [ -d "${injected_config_dir}/connman" ]; then
  mkdir -p /storage/.cache/connman
  cp "${injected_config_dir}/connman/"* /storage/.cache/connman/ 2>/dev/null
fi
if [ -f "${injected_config_dir}/services/sshd.conf" ]; then
  mkdir -p /storage/.cache/services
  cp "${injected_config_dir}/services/sshd.conf" /storage/.cache/services/
fi
if [ -f "${injected_config_dir}/ssh/authorized_keys" ]; then
  mkdir -p /storage/.ssh
  cp "${injected_config_dir}/ssh/authorized_keys" /storage/.ssh/
  chmod 700 /storage/.ssh
  chmod 600 /storage/.ssh/authorized_keys
fi
