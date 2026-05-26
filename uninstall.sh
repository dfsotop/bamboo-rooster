#!/usr/bin/env bash
# uninstall.sh — stop and remove the four launchd jobs.
# Leaves $HOME/.bamboo-rooster (config, secrets, logs) intact so a future
# install picks up where this one left off.

set -euo pipefail

LAUNCHD_DIR="$HOME/Library/LaunchAgents"
LABEL_PREFIX="com.bamboo-rooster"
UID_NUM=$(id -u)
ROOSTER_HOME="${ROOSTER_HOME:-$HOME/.bamboo-rooster}"

for phase in morning lunch-out lunch-in evening; do
  label="${LABEL_PREFIX}.${phase}"
  plist="$LAUNCHD_DIR/${label}.plist"
  launchctl bootout "gui/${UID_NUM}/${label}" 2>/dev/null || true
  rm -f "$plist"
  echo "✓ removed ${label}"
done

# Remove the CLI symlinks installed by install.sh, but only if they really
# are symlinks (defensive — don't clobber an unrelated file by the same name).
for name in rooster rooster-status rooster-rotate-key; do
  link="$HOME/.local/bin/$name"
  if [[ -L "$link" ]]; then
    rm -f "$link"
    echo "✓ removed $link"
  fi
done

cat <<EOF

launchd jobs unloaded, plists removed, CLI symlinks cleared.

host state at $ROOSTER_HOME is intact. To also wipe config + secrets + logs:
  rm -rf "$ROOSTER_HOME"
EOF
