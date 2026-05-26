#!/usr/bin/env bash
# install.sh — single-command setup for bamboo-rooster on macOS.
# Schedules the four phases via launchd (re-fires after laptop wake,
# unlike cron). Idempotent: re-running re-loads jobs without duplicating.
#
# Time-off / sick / holiday handling is built in — lib/gates.sh queries
# BambooHR's /time_off/whos_out before and after the random sleep on every
# phase. Any approved time-off entry (vacation, sick, doctor, parental,
# bereavement, …) or company holiday for today causes the phase to skip.
# Nothing to configure here.

set -euo pipefail

ROOSTER_ROOT="$(cd "$(dirname "$0")" && pwd)"
ROOSTER_HOME="${ROOSTER_HOME:-$HOME/.bamboo-rooster}"
LAUNCHD_DIR="$HOME/Library/LaunchAgents"
LABEL_PREFIX="com.bamboo-rooster"
UID_NUM=$(id -u)

step() { printf '\n[install] %s\n' "$*"; }

# --- 1. host tools --------------------------------------------------------
step "checking host tools"
missing=()
for bin in jq curl launchctl plutil; do
  command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
done
if (( ${#missing[@]} > 0 )); then
  echo "missing: ${missing[*]}" >&2
  echo "install via: brew install ${missing[*]}" >&2
  exit 1
fi

# --- 2. host paths --------------------------------------------------------
step "preparing $ROOSTER_HOME"
mkdir -p "$ROOSTER_HOME/secrets"
chmod 700 "$ROOSTER_HOME" "$ROOSTER_HOME/secrets"

# --- 3. config: BambooHR subdomain ----------------------------------------
# Prompt only for what's missing. Re-runs with config already on disk are
# silent here and jump straight to the auth check.
if [[ ! -f "$ROOSTER_HOME/.env" ]]; then
  step "first-time setup — collecting config"

  # Subdomain. Required. No sensible default.
  subdomain=""
  while [[ -z "$subdomain" ]]; do
    read -r -p "BambooHR subdomain (the prefix in <x>.bamboohr.com): " subdomain
    subdomain="${subdomain// /}"   # strip any pasted whitespace
  done

  # Optional: pin a specific employee ID. Empty means auto-resolve at runtime.
  read -r -p "BambooHR employee ID [leave blank to auto-resolve]: " employee_id || true
  employee_id="${employee_id// /}"

  # DRY_RUN default = 1 (safe). User confirms with [Y/n].
  read -r -p "Start in DRY_RUN mode (gates run, no real clock_in/out)? [Y/n] " dry_run_yn
  case "${dry_run_yn:-y}" in
    n|N|no|NO) dry_run="0" ;;
    *)         dry_run="1" ;;
  esac

  umask 077
  cat > "$ROOSTER_HOME/.env" <<EOF
# Written by install.sh on $(date)
BAMBOOHR_SUBDOMAIN="${subdomain}"
BAMBOOHR_EMPLOYEE_ID="${employee_id}"
TZ="Europe/Madrid"
ROOSTER_AUTH_FAIL_LOG_COOLDOWN_HOURS="6"
ROOSTER_WHOS_OUT_CACHE_TTL_SECONDS="1800"
DRY_RUN="${dry_run}"
EOF
  chmod 600 "$ROOSTER_HOME/.env"
  echo "  ✓ wrote $ROOSTER_HOME/.env (chmod 600)"
fi

# --- 4. config: BambooHR API key ------------------------------------------
if [[ ! -s "$ROOSTER_HOME/secrets/api-key" ]]; then
  step "prompting for BambooHR API key (no echo)"
  read -rs -p "BambooHR API key: " key
  echo
  if [[ -z "$key" ]]; then
    echo "empty key, aborting." >&2
    exit 1
  fi
  umask 077
  printf '%s' "$key" > "$ROOSTER_HOME/secrets/api-key"
  chmod 600 "$ROOSTER_HOME/secrets/api-key"
  unset key
  echo "  ✓ saved $ROOSTER_HOME/secrets/api-key (chmod 600)"
fi

# --- 5. verify against live API ------------------------------------------
step "verifying API key against BambooHR"
if ! "$ROOSTER_ROOT/bin/rooster" --auth-check; then
  cat >&2 <<EOF
  ✗ auth check failed.

  fix: regenerate the key in BambooHR and run
       $ROOSTER_ROOT/bin/rotate-key
EOF
  exit 1
fi

# --- 6. generate plists ---------------------------------------------------
step "writing launchd plists into $LAUNCHD_DIR"
mkdir -p "$LAUNCHD_DIR"

# Detect Homebrew prefix so jq/curl are findable from launchd's minimal PATH.
brew_bin=""
if command -v brew >/dev/null 2>&1; then
  brew_bin="$(brew --prefix)/bin"
fi
launchd_path="${brew_bin}${brew_bin:+:}/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin"

write_plist() {
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
    <key>PATH</key><string>${launchd_path}</string>
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

write_plist morning   8  30
write_plist lunch-out 12 45
write_plist lunch-in  13 30
write_plist evening   17 30

# --- 7. (re)load via launchctl -------------------------------------------
step "loading launchd jobs"
for phase in morning lunch-out lunch-in evening; do
  label="${LABEL_PREFIX}.${phase}"
  plist="$LAUNCHD_DIR/${label}.plist"
  launchctl bootout "gui/${UID_NUM}/${label}" 2>/dev/null || true
  launchctl bootstrap "gui/${UID_NUM}" "$plist"
  launchctl enable "gui/${UID_NUM}/${label}" 2>/dev/null || true
  echo "  ✓ loaded ${label}"
done

# --- 8. install CLI shortcuts on PATH -------------------------------------
# Symlinks into ~/.local/bin so the user can type `rooster`, `rooster-status`,
# `rooster-rotate-key` from anywhere. The source bin/ scripts stay in the repo;
# launchd plists keep using the absolute path, so the symlinks only matter for
# interactive use. `rotate-key` is renamed in the symlink to avoid collisions
# with other tools using the generic name.
step "installing CLI shortcuts into ~/.local/bin"
mkdir -p "$HOME/.local/bin"
ln -sf "$ROOSTER_ROOT/bin/rooster"        "$HOME/.local/bin/rooster"
ln -sf "$ROOSTER_ROOT/bin/rooster-status" "$HOME/.local/bin/rooster-status"
ln -sf "$ROOSTER_ROOT/bin/rotate-key"     "$HOME/.local/bin/rooster-rotate-key"
echo "  ✓ rooster, rooster-status, rooster-rotate-key linked"

if ! echo ":$PATH:" | grep -q ":$HOME/.local/bin:"; then
  cat <<EOF

⚠  ~/.local/bin is not on your PATH. Add it:
    echo 'export PATH="\$HOME/.local/bin:\$PATH"' >> ~/.zshrc
    source ~/.zshrc
EOF
fi

# --- 9. summary -----------------------------------------------------------
step "active jobs"
launchctl list | awk -v p="$LABEL_PREFIX" '$3 ~ p { printf "  %s\n", $3 }' || true

if grep -q '^DRY_RUN="\?1"\?' "$ROOSTER_HOME/.env"; then
  cat <<EOF

⚠  DRY_RUN=1 is still set in $ROOSTER_HOME/.env
   The four jobs are scheduled but will skip the actual clock_in/out HTTP
   call. Watch the log for a few days, then flip DRY_RUN to "0" to go live:
     sed -i.bak 's/^DRY_RUN=.*/DRY_RUN="0"/' $ROOSTER_HOME/.env
EOF
fi

cat <<EOF

✓ rooster scheduled. Phases (local Madrid time, Mon–Fri):
   morning   08:30 + random 0–60 min  → clock in
   lunch-out 12:45 + random 0–30 min  → clock out
   lunch-in  13:30 + random 0–30 min  → clock in
   evening   17:30 + random 0–60 min  → clock out

useful commands:
   tail -f $ROOSTER_HOME/log.jsonl
   rooster-status                             # last 7 days summary
   rooster --auth-check                       # live API key check
   rooster-rotate-key                         # rotate a revoked key
   touch $ROOSTER_HOME/skip-today             # bow out for today
   launchctl kickstart gui/${UID_NUM}/${LABEL_PREFIX}.morning   # fire morning manually
   $ROOSTER_ROOT/uninstall.sh                 # remove launchd jobs + CLI symlinks
EOF
