#!/bin/bash
# Pulumi plugin — expose the pulumi CLI on PATH for every login shell.
#
# pulumi is installed by the standalone tarball at first boot
# (250_pulumi-install.sh) into the persistent ~/.pulumi/bin, not into
# /usr/local/bin, so it is not on the default PATH. Rather than teach every shell
# (bash, zsh, ...) to add ~/.pulumi/bin — which zsh does not pick up from
# /etc/profile.d/* — we bake a symlink into /usr/local/bin, which is already on the
# baseline PATH of every shell and every invocation type (interactive, and
# `ra connect --command=...`).
#
# Only the `pulumi` entry point needs a symlink: pulumi locates its bundled
# language hosts (pulumi-language-*, pulumi-resource-pulumi-*) relative to the
# *resolved* real binary (os.Executable() follows /proc/self/exe), so they are
# found next to the real binary in ~/.pulumi/bin — no need to symlink each one.
#
# Why build time, and why a dangling link is fine: the container root (including
# /usr/local/bin) is ephemeral — reset from the image on every stop/start — while
# ~/.pulumi lives on the persistent /home disk. A symlink created at *runtime*
# would vanish on the next start and the marker-gated installer would not recreate
# it. Baking it into the image means it is present on every boot; it simply points
# at nothing until the first-boot install populates the target, then resolves for
# the workstation's whole life. `-f` keeps this idempotent across rebuilds.
set -euo pipefail

ln -sf /home/user/.pulumi/bin/pulumi /usr/local/bin/pulumi
