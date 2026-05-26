# shellcheck shell=bash
# install/systemd.sh — Linux scheduler. Sourced by install.sh / uninstall.sh.
# Defines install_scheduler and uninstall_scheduler. Reads from the parent:
#   ROOSTER_ROOT, ROOSTER_HOME, morning_start, lunch_out_start,
#   lunch_in_start, evening_start

SYSTEMD_DIR="$HOME/.config/systemd/user"
UNIT_PREFIX="bamboo-rooster"

_write_units() {
  local phase="$1" hour="$2" minute="$3"
  local service="$SYSTEMD_DIR/${UNIT_PREFIX}-${phase}.service"
  local timer="$SYSTEMD_DIR/${UNIT_PREFIX}-${phase}.timer"

  cat > "$service" <<EOF
[Unit]
Description=bamboo-rooster ${phase} phase

[Service]
Type=oneshot
Environment=ROOSTER_HOME=${ROOSTER_HOME}
Environment=ROOSTER_ROOT=${ROOSTER_ROOT}
Environment=HOME=${HOME}
Environment=PATH=/usr/local/bin:/usr/bin:/bin
ExecStart=${ROOSTER_ROOT}/bin/rooster ${phase}
StandardOutput=append:${ROOSTER_HOME}/systemd.out
StandardError=append:${ROOSTER_HOME}/systemd.err
EOF

  cat > "$timer" <<EOF
[Unit]
Description=bamboo-rooster ${phase} schedule

[Timer]
# Mon–Fri at HH:MM:00 local time. Persistent=true means missed fires
# (machine asleep / off) trigger on the next wake.
OnCalendar=Mon..Fri *-*-* $(printf "%02d:%02d:00" "$hour" "$minute")
Persistent=true

[Install]
WantedBy=timers.target
EOF
  echo "  ✓ ${timer}"
}

install_scheduler() {
  step "writing systemd user units into $SYSTEMD_DIR"
  mkdir -p "$SYSTEMD_DIR"

  _write_units morning   "${morning_start%:*}"    "${morning_start#*:}"
  _write_units lunch-out "${lunch_out_start%:*}"  "${lunch_out_start#*:}"
  _write_units lunch-in  "${lunch_in_start%:*}"   "${lunch_in_start#*:}"
  _write_units evening   "${evening_start%:*}"    "${evening_start#*:}"

  step "loading systemd timers"
  systemctl --user daemon-reload
  for phase in morning lunch-out lunch-in evening; do
    systemctl --user enable --now "${UNIT_PREFIX}-${phase}.timer"
    echo "  ✓ enabled ${UNIT_PREFIX}-${phase}.timer"
  done

  # Without lingering, user timers stop when the user has no active session.
  if ! loginctl show-user "$USER" --property=Linger 2>/dev/null | grep -q "Linger=yes"; then
    cat <<EOF

⚠  systemd user services stop when you log out of all sessions.
   To keep the rooster firing even when you're not logged in:
     sudo loginctl enable-linger $USER
EOF
  fi
}

uninstall_scheduler() {
  for phase in morning lunch-out lunch-in evening; do
    local timer="${UNIT_PREFIX}-${phase}.timer"
    systemctl --user disable --now "$timer" 2>/dev/null || true
    rm -f "$SYSTEMD_DIR/${UNIT_PREFIX}-${phase}.timer"
    rm -f "$SYSTEMD_DIR/${UNIT_PREFIX}-${phase}.service"
    echo "✓ removed ${UNIT_PREFIX}-${phase}"
  done
  systemctl --user daemon-reload 2>/dev/null || true
}

scheduler_status_lines() {
  systemctl --user list-timers --all "${UNIT_PREFIX}-*.timer" --no-legend 2>/dev/null \
    | awk '{ printf "  %s\n", $0 }' \
    || true
}

scheduler_useful_commands() {
  cat <<EOF
   systemctl --user start ${UNIT_PREFIX}-morning.service   # fire morning manually
   systemctl --user list-timers '${UNIT_PREFIX}-*'         # show scheduled timers
   journalctl --user -u ${UNIT_PREFIX}-morning.service     # service logs
EOF
}
