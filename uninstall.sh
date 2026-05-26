#!/usr/bin/env bash
# uninstall.sh — stop the scheduler and remove CLI symlinks.
# Cross-OS: dispatches to install/launchd.sh on macOS or install/systemd.sh
# on Linux. Leaves $HOME/.bamboo-rooster (config, secrets, logs) intact.

set -euo pipefail

ROOSTER_ROOT="$(cd "$(dirname "$0")" && pwd)"
ROOSTER_HOME="${ROOSTER_HOME:-$HOME/.bamboo-rooster}"

OS_KERNEL="$(uname -s)"
case "$OS_KERNEL" in
  Darwin) PLATFORM="launchd" ;;
  Linux)  PLATFORM="systemd" ;;
  *) echo "unsupported OS: $OS_KERNEL" >&2; exit 1 ;;
esac

step() { printf '\n[uninstall] %s\n' "$*"; }

step "removing scheduler ($PLATFORM) units"
# shellcheck disable=SC1090
source "$ROOSTER_ROOT/install/${PLATFORM}.sh"
uninstall_scheduler

step "removing CLI symlinks"
for name in rooster rooster-status rooster-rotate-key; do
  link="$HOME/.local/bin/$name"
  if [[ -L "$link" ]]; then
    rm -f "$link"
    echo "✓ removed $link"
  fi
done

cat <<EOF

scheduler jobs unloaded, CLI symlinks cleared.

host state at $ROOSTER_HOME is intact. To also wipe config + secrets + logs:
  rm -rf "$ROOSTER_HOME"
EOF
