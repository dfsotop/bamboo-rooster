# shellcheck shell=bash
# install/launchd.sh — macOS scheduler. Sourced by install.sh / uninstall.sh.
# Defines install_scheduler and uninstall_scheduler. Reads from the parent:
#   ROOSTER_ROOT, ROOSTER_HOME, morning_start, lunch_out_start,
#   lunch_in_start, evening_start

LAUNCHD_DIR="$HOME/Library/LaunchAgents"
LABEL_PREFIX="com.bamboo-rooster"
UID_NUM=$(id -u)

# Strip leading zeros — plist <integer> doesn't allow them.
_strip_zeros() { echo "$((10#$1))"; }

_write_plist() {
  local phase="$1" hour="$2" minute="$3"
  local label="${LABEL_PREFIX}.${phase}"
  local plist="$LAUNCHD_DIR/${label}.plist"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${ROOSTER_ROOT}/bin/rooster</string>
    <string>${phase}</string>
  </array>
  <key>StartCalendarInterval</key>
  <array>
    <dict><key>Weekday</key><integer>1</integer><key>Hour</key><integer>${hour}</integer><key>Minute</key><integer>${minute}</integer></dict>
    <dict><key>Weekday</key><integer>2</integer><key>Hour</key><integer>${hour}</integer><key>Minute</key><integer>${minute}</integer></dict>
    <dict><key>Weekday</key><integer>3</integer><key>Hour</key><integer>${hour}</integer><key>Minute</key><integer>${minute}</integer></dict>
    <dict><key>Weekday</key><integer>4</integer><key>Hour</key><integer>${hour}</integer><key>Minute</key><integer>${minute}</integer></dict>
    <dict><key>Weekday</key><integer>5</integer><key>Hour</key><integer>${hour}</integer><key>Minute</key><integer>${minute}</integer></dict>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>${LAUNCHD_PATH}</string>
    <key>HOME</key><string>${HOME}</string>
  </dict>
  <key>StandardOutPath</key><string>${ROOSTER_HOME}/launchd.out</string>
  <key>StandardErrorPath</key><string>${ROOSTER_HOME}/launchd.err</string>
  <key>RunAtLoad</key><false/>
  <key>KeepAlive</key><false/>
</dict>
</plist>
EOF
  chmod 644 "$plist"
  if ! plutil -lint "$plist" >/dev/null; then
    echo "  ✗ invalid plist: $plist" >&2
    exit 1
  fi
  echo "  ✓ $plist"
}

install_scheduler() {
  step "writing launchd plists into $LAUNCHD_DIR"
  mkdir -p "$LAUNCHD_DIR"

  # Build PATH for launchd-fired jobs. Order:
  #   1. $ROOSTER_HOME/bin — picks up a jq downloaded by setup.sh (no brew)
  #   2. Homebrew prefix   — if user has brew + a system jq
  #   3. /usr/local/bin /usr/bin /bin /sbin /usr/sbin — standard system paths
  local brew_bin=""
  if command -v brew >/dev/null 2>&1; then
    brew_bin="$(brew --prefix)/bin"
  fi
  LAUNCHD_PATH="${ROOSTER_HOME}/bin:${brew_bin}${brew_bin:+:}/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin"

  _write_plist morning   "$(_strip_zeros "${morning_start%:*}")"    "$(_strip_zeros "${morning_start#*:}")"
  _write_plist lunch-out "$(_strip_zeros "${lunch_out_start%:*}")"  "$(_strip_zeros "${lunch_out_start#*:}")"
  _write_plist lunch-in  "$(_strip_zeros "${lunch_in_start%:*}")"   "$(_strip_zeros "${lunch_in_start#*:}")"
  _write_plist evening   "$(_strip_zeros "${evening_start%:*}")"    "$(_strip_zeros "${evening_start#*:}")"

  step "loading launchd jobs"
  for phase in morning lunch-out lunch-in evening; do
    local label="${LABEL_PREFIX}.${phase}"
    local plist="$LAUNCHD_DIR/${label}.plist"
    launchctl bootout "gui/${UID_NUM}/${label}" 2>/dev/null || true
    launchctl bootstrap "gui/${UID_NUM}" "$plist"
    launchctl enable "gui/${UID_NUM}/${label}" 2>/dev/null || true
    echo "  ✓ loaded ${label}"
  done
}

uninstall_scheduler() {
  for phase in morning lunch-out lunch-in evening; do
    local label="${LABEL_PREFIX}.${phase}"
    local plist="$LAUNCHD_DIR/${label}.plist"
    launchctl bootout "gui/${UID_NUM}/${label}" 2>/dev/null || true
    rm -f "$plist"
    echo "✓ removed ${label}"
  done
}

scheduler_status_lines() {
  launchctl list | awk -v p="$LABEL_PREFIX" '$3 ~ p { printf "  %s\n", $3 }' || true
}

scheduler_useful_commands() {
  cat <<EOF
   launchctl kickstart gui/${UID_NUM}/${LABEL_PREFIX}.morning   # fire morning manually
   launchctl list | grep ${LABEL_PREFIX}                        # show loaded jobs
EOF
}
