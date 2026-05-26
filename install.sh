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

# --- 5. configure phase windows ------------------------------------------
# User answers three ranges once; the script splits the lunch envelope into
# the lunch-out and lunch-in sub-windows with a 15-min minimum gap. The
# result is written to ~/.bamboo-rooster/windows.conf and used both by the
# rooster script at runtime and by the launchd plists generated below.

_prompt_hhmm() {
  # $1=prompt text, $2=default. Re-asks until valid HH:MM.
  local prompt="$1" default="$2" answer
  while :; do
    read -r -p "$prompt [$default]: " answer
    answer="${answer:-$default}"
    if [[ "$answer" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
      echo "$answer"; return 0
    fi
    echo "  invalid — expected HH:MM (24h, e.g. 08:30)" >&2
  done
}
_hhmm_to_min() { local h="${1%:*}" m="${1#*:}"; echo $(( 10#$h * 60 + 10#$m )); }
_min_to_hhmm() { printf "%02d:%02d" $(( $1 / 60 )) $(( $1 % 60 )); }

if [[ ! -f "$ROOSTER_HOME/windows.conf" ]]; then
  step "configuring phase windows (one-time setup)"
  echo "Each phase fires at a uniform-random minute inside its range."
  echo
  echo "Morning clock-in window:"
  morning_start=$(_prompt_hhmm "  earliest" "08:30")
  morning_end=$(_prompt_hhmm   "  latest  " "09:30")
  echo
  echo "Lunch break window (clock-out + clock-in fit inside):"
  lunch_start=$(_prompt_hhmm "  earliest start " "12:45")
  lunch_end=$(_prompt_hhmm   "  latest return  " "14:00")
  echo
  echo "Evening clock-out window:"
  evening_start=$(_prompt_hhmm "  earliest" "17:30")
  evening_end=$(_prompt_hhmm   "  latest  " "18:30")

  # Validate ordering and lunch envelope size.
  if (( $(_hhmm_to_min "$morning_end") <= $(_hhmm_to_min "$morning_start") )); then
    echo "morning end must be > start" >&2; exit 1
  fi
  if (( $(_hhmm_to_min "$evening_end") <= $(_hhmm_to_min "$evening_start") )); then
    echo "evening end must be > start" >&2; exit 1
  fi
  lunch_total=$(( $(_hhmm_to_min "$lunch_end") - $(_hhmm_to_min "$lunch_start") ))
  if (( lunch_total < 30 )); then
    echo "lunch envelope must be ≥ 30 min (got $lunch_total)" >&2; exit 1
  fi

  # Split lunch envelope: equal halves either side of a 15-min center gap.
  gap=15
  side=$(( (lunch_total - gap) / 2 ))
  lunch_out_start="$lunch_start"
  lunch_out_end=$(_min_to_hhmm   $(( $(_hhmm_to_min "$lunch_start") + side )))
  lunch_in_start=$(_min_to_hhmm  $(( $(_hhmm_to_min "$lunch_end")   - side )))
  lunch_in_end="$lunch_end"

  umask 077
  cat > "$ROOSTER_HOME/windows.conf" <<EOF
# Generated by install.sh on $(date)
# Edit and re-run install.sh to regenerate the launchd plists.
morning    $morning_start $morning_end
lunch-out  $lunch_out_start $lunch_out_end
lunch-in   $lunch_in_start $lunch_in_end
evening    $evening_start $evening_end
EOF
  echo "  ✓ wrote $ROOSTER_HOME/windows.conf"
fi

# Read final windows back so step 6 (plists) can pick up the times below.
read -r _ morning_start morning_end \
  < <(grep -E '^morning[[:space:]]'    "$ROOSTER_HOME/windows.conf")
read -r _ lunch_out_start lunch_out_end \
  < <(grep -E '^lunch-out[[:space:]]'  "$ROOSTER_HOME/windows.conf")
read -r _ lunch_in_start lunch_in_end \
  < <(grep -E '^lunch-in[[:space:]]'   "$ROOSTER_HOME/windows.conf")
read -r _ evening_start evening_end \
  < <(grep -E '^evening[[:space:]]'    "$ROOSTER_HOME/windows.conf")

# --- 6. verify against live API ------------------------------------------
step "verifying API key against BambooHR"
if ! "$ROOSTER_ROOT/bin/rooster" --auth-check; then
  cat >&2 <<EOF
  ✗ auth check failed.

  fix: regenerate the key in BambooHR and run
       $ROOSTER_ROOT/bin/rotate-key
EOF
  exit 1
fi

# --- 7. generate plists ---------------------------------------------------
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

# Helper: strip leading zeros (plist <integer> doesn't allow them).
_strip_zeros() { echo "$((10#$1))"; }

write_plist morning   "$(_strip_zeros "${morning_start%:*}")"    "$(_strip_zeros "${morning_start#*:}")"
write_plist lunch-out "$(_strip_zeros "${lunch_out_start%:*}")"  "$(_strip_zeros "${lunch_out_start#*:}")"
write_plist lunch-in  "$(_strip_zeros "${lunch_in_start%:*}")"   "$(_strip_zeros "${lunch_in_start#*:}")"
write_plist evening   "$(_strip_zeros "${evening_start%:*}")"    "$(_strip_zeros "${evening_start#*:}")"

# --- 8. (re)load via launchctl -------------------------------------------
step "loading launchd jobs"
for phase in morning lunch-out lunch-in evening; do
  label="${LABEL_PREFIX}.${phase}"
  plist="$LAUNCHD_DIR/${label}.plist"
  launchctl bootout "gui/${UID_NUM}/${label}" 2>/dev/null || true
  launchctl bootstrap "gui/${UID_NUM}" "$plist"
  launchctl enable "gui/${UID_NUM}/${label}" 2>/dev/null || true
  echo "  ✓ loaded ${label}"
done

# --- 9. install CLI shortcuts on PATH -------------------------------------
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

# --- 10. summary ----------------------------------------------------------
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
