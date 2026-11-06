#!/usr/bin/env bash
# Arch Linux installer for claude-constellation: the system packages, then install.js.
#
# Usage: ./install-arch.sh [--lock-only] [--no-deps] [--no-rc] [--restart] [--uninstall]
#   (default)     everything: AwesomeWM wallpaper layer, commands, hooks and the lock screen
#   --lock-only   only the animated lock screen (xsecurelock), for any X11 window manager
#                 (same as ./install-arch-lock.sh)
#   --no-deps     don't run pacman
#   --no-rc       don't add the module to ~/.config/awesome/rc.lua
#   --restart     restart the running AwesomeWM at the end
#   --uninstall   remove the hooks, links, commands and the rc.lua line (packages stay)
set -euo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
RC="${XDG_CONFIG_HOME:-$HOME/.config}/awesome/rc.lua"
MARK="-- added by claude-constellation install-arch.sh"
RC_LINE="pcall(require, \"ui.desktop.claude_constellation\") $MARK"

# Lock screen: hooks (node), xsecurelock, and a Lua with lgi + GTK 3 for saver.lua.
PKGS_LOCK=(nodejs xsecurelock gtk3 cairo gdk-pixbuf2 lua54 lua54-lgi)
# Everything: Awesome (brings lua53 + lua53-lgi), curl for Promview/Grafana, secret-tool.
PKGS_FULL=(nodejs xsecurelock gtk3 cairo gdk-pixbuf2 awesome curl libsecret)

lock_only=0 deps=1 rc=1 restart=0 uninstall=0
for a in "$@"; do
  case "$a" in
    --lock-only) lock_only=1 ;;
    --no-deps) deps=0 ;;
    --no-rc) rc=0 ;;
    --restart) restart=1 ;;
    --uninstall) uninstall=1 ;;
    -h|--help) sed -n '2,11s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "install-arch.sh: unknown option '$a'" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1;34m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m::\033[0m %s\n' "$*" >&2; }

if [ "$(id -u)" -eq 0 ]; then
  echo "install-arch.sh: run it as your user, not root (it installs into your \$HOME; pacman goes through sudo)" >&2
  exit 1
fi

# Remove the line this script added to rc.lua (and nothing else).
rc_remove() {
  [ -f "$RC" ] && grep -qF -- "$MARK" "$RC" || return 0
  cp "$RC" "$RC.bak-constellation"
  grep -vF -- "$MARK" "$RC.bak-constellation" > "$RC"
  say "Removed the module line from $RC (backup: $RC.bak-constellation)"
}

if [ "$uninstall" -eq 1 ]; then
  node "$ROOT/install.js" --uninstall
  rc_remove
  say "Uninstalled. Packages were left in place; restart Awesome (if you use it) to drop the layer."
  exit 0
fi

if ! command -v pacman >/dev/null 2>&1; then
  echo "install-arch.sh: pacman not found; on another distro, install the packages yourself and run: node install.js" >&2
  exit 1
fi

if [ "$deps" -eq 1 ]; then
  if [ "$lock_only" -eq 1 ]; then pkgs=("${PKGS_LOCK[@]}"); else pkgs=("${PKGS_FULL[@]}"); fi
  say "Installing packages: ${pkgs[*]}"
  sudo pacman -S --needed --noconfirm "${pkgs[@]}"
fi

command -v node >/dev/null 2>&1 || { echo "install-arch.sh: node is missing (pacman -S nodejs)" >&2; exit 1; }
command -v claude >/dev/null 2>&1 || warn "Claude Code (claude) is not on PATH: sessions show up once it runs with the hooks."

if [ "$lock_only" -eq 1 ]; then
  node "$ROOT/install.js" --lock-only
else
  node "$ROOT/install.js"
fi

# The saver re-executes itself under the first Lua that can load lgi: check there is one.
probe=$(env -u XSCREENSAVER_WINDOW sh "$ROOT/awesome/claude_constellation/saver.lua" 2>&1 || true)
if [[ "$probe" != *XSCREENSAVER_WINDOW* ]]; then
  warn "No Lua with lgi found for the lock screen (pacman -S lua54 lua54-lgi)."
fi

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) warn "$HOME/.local/bin is not on your PATH: add it to use the constellation-* commands." ;;
esac

if [ "$lock_only" -eq 1 ]; then
  say "Lock screen installed. Lock with:  constellation-lock"
  cat <<'EOF'
   Bind it to a key in your window manager, e.g. in i3:
     bindsym $mod+l exec --no-startup-id constellation-lock
   To also lock on idle and before suspend, run at session start (pacman -S xss-lock):
     xss-lock -l -- constellation-lock
   Restart your open Claude Code sessions so they pick up the hooks.
EOF
  exit 0
fi

# Add the module to rc.lua: before require("ui") when there is one (otherwise the desktop layer
# covers the bar), else right after beautiful.init(...).
if [ "$rc" -eq 1 ]; then
  if [ ! -f "$RC" ]; then
    warn "No $RC: copy /etc/xdg/awesome/rc.lua there, then add after beautiful.init(...):"
    warn "  pcall(require, \"ui.desktop.claude_constellation\")"
  elif grep -q 'ui\.desktop\.claude_constellation' "$RC"; then
    say "$RC already loads the module"
  else
    cp "$RC" "$RC.bak-constellation"
    if awk -v line="$RC_LINE" '
        !done && /^[[:space:]]*require[[:space:]]*\(?[[:space:]]*["\x27]ui["\x27]/ { print line; done = 1 }
        { print }
        END { exit done ? 0 : 1 }' "$RC.bak-constellation" > "$RC.tmp"; then
      mv "$RC.tmp" "$RC"
    elif awk -v line="$RC_LINE" '
        { print }
        !done && /beautiful\.init[[:space:]]*\(/ { print line; done = 1 }
        END { exit done ? 0 : 1 }' "$RC.bak-constellation" > "$RC.tmp"; then
      mv "$RC.tmp" "$RC"
    else
      rm -f "$RC.tmp"
      warn "Found neither require(\"ui\") nor beautiful.init(...) in $RC; add by hand, after beautiful.init:"
      warn "  pcall(require, \"ui.desktop.claude_constellation\")"
    fi
    grep -qF -- "$MARK" "$RC" && say "Added the module to $RC (backup: $RC.bak-constellation)"
  fi
fi

if [ "$restart" -eq 1 ] && pgrep -x awesome >/dev/null 2>&1; then
  say "Restarting AwesomeWM"
  echo 'awesome.restart()' | awesome-client >/dev/null 2>&1 || warn "awesome-client failed: restart Awesome yourself"
else
  say "Done. Restart Awesome to load it:  echo 'awesome.restart()' | awesome-client"
fi
cat <<'EOF'
   Lock screen: constellation-lock (or cc.lock() from a key binding, see the README).
   Settings: constellation-menu. Restart your open Claude Code sessions so they pick up the hooks.
EOF
