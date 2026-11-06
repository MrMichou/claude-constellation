#!/usr/bin/env bash
# Arch Linux installer for the claude-constellation lock screen only: xsecurelock animated with
# the constellation, from any X11 window manager (no AwesomeWM needed). Installs the packages,
# the Claude Code hooks and the `constellation-lock` command.
# Usage: ./install-arch-lock.sh [--no-deps] [--uninstall]   (see ./install-arch.sh --help)
exec "$(dirname "$(readlink -f "$0")")/install-arch.sh" --lock-only "$@"
