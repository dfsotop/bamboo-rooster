#!/usr/bin/env bash
# install.sh — cross-OS setup for bamboo-rooster.
# Dispatches to install/launchd.sh on macOS or install/systemd.sh on Linux.
# Idempotent: re-running re-installs scheduler units without duplicating.
#
# Time-off / sick / holiday handling is built in — lib/gates.sh queries
# BambooHR's /time_off/whos_out before and after the random sleep on every
# phase. Any approved time-off entry (vacation, sick, doctor, parental,
# bereavement, …) or company holiday for today causes the phase to skip.

set -euo pipefail

ROOSTER_ROOT="$(cd "$(dirname "$0")" && pwd)"
ROOSTER_HOME="${ROOSTER_HOME:-$HOME/.bamboo-rooster}"

# --- OS detection --------------------------------------------------------
OS_KERNEL="$(uname -s)"
case "$OS_KERNEL" in
  Darwin) PLATFORM="launchd" ;;
  Linux)  PLATFORM="systemd" ;;
  *)
    echo "unsupported OS: $OS_KERNEL" >&2
    echo "supported: macOS (launchd) and Linux (systemd)." >&2
    echo "Linux users without systemd: see docker/ for a containerized install." >&2
    exit 1
    ;;
esac

step() { printf '\n[install] %s\n' "$*"; }

# Suggest the right package-manager invocation for missing deps.
suggest_install() {
  local pkgs="$*"
  case "$OS_KERNEL" in
    Darwin) echo "brew install $pkgs" ;;
    Linux)
      if   command -v apt-get >/dev/null 2>&1; then echo "sudo apt-get install -y $pkgs"
      elif command -v dnf     >/dev/null 2>&1; then echo "sudo dnf install -y $pkgs"
      elif command -v pacman  >/dev/null 2>&1; then echo "sudo pacman -S --noconfirm $pkgs"
      elif command -v zypper  >/dev/null 2>&1; then echo "sudo zypper install -y $pkgs"
      elif command -v apk     >/dev/null 2>&1; then echo "sudo apk add $pkgs"
      else echo "install $pkgs via your package manager"
      fi
      ;;
    *) echo "install $pkgs via your package manager" ;;
  esac
}

# Best-effort detection of the host timezone — used as the default in the
# interactive prompt below. Works on macOS and most modern Linux distros.
detect_tz() {
  if [[ -L /etc/localtime ]]; then
    readlink /etc/localtime | sed 's|.*/zoneinfo/||'
  elif [[ -f /etc/timezone ]]; then
    tr -d '\n' < /etc/timezone
  else
    echo "UTC"
  fi
}

# --- 0. preflight: API key required --------------------------------------
# When called by setup.sh, BAMBOO_ROOSTER_KEY_CONFIRMED is already set and
# we skip this. When the user runs install.sh directly from a cloned repo,
# we ask the same gate question setup.sh asks.
if [[ -z "${BAMBOO_ROOSTER_KEY_CONFIRMED:-}" ]] \
   && [[ ! -f "$ROOSTER_HOME/secrets/api-key" ]]; then
  cat <<'EOF'

This wizard configures bamboo-rooster. You'll need a BambooHR API key first.

How to get one:
  1. Log in to https://<your-subdomain>.bamboohr.com
  2. Click your profile picture (top right) → "API Keys"
  3. Click "Add New Key", give it a name (e.g. "bamboo-rooster")
  4. Click "Generate Key" — COPY THE STRING NOW (it's only shown once)

If "API Keys" isn't in your profile menu, ask your BambooHR admin to
enable API key generation for your user (it's a 30-second toggle).

EOF
  if [[ ! -t 0 ]]; then
    echo "non-interactive shell, can't prompt. Re-run in a Terminal window." >&2
    exit 1
  fi
  read -r -p "Do you have your API key ready? [y/N] " key_ready </dev/tty
  case "${key_ready:-n}" in
    y|Y|yes|YES) export BAMBOO_ROOSTER_KEY_CONFIRMED=1 ;;
    *)
      echo
      echo "Aborting. Get your API key first, then re-run ./install.sh."
      exit 0
      ;;
  esac
fi

# --- 1. host tools --------------------------------------------------------
step "checking host tools (OS=$OS_KERNEL, scheduler=$PLATFORM)"
missing=()
required=(jq curl)
case "$PLATFORM" in
  launchd) required+=(launchctl plutil) ;;
  systemd) required+=(systemctl loginctl) ;;
esac
for bin in "${required[@]}"; do
  command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
done
if (( ${#missing[@]} > 0 )); then
  # Split missing tools into installable (jq, curl) vs system (launchctl, etc.).
  installable=()
  system_missing=()
  for m in "${missing[@]}"; do
    case "$m" in jq|curl) installable+=("$m") ;; *) system_missing+=("$m") ;; esac
  done

  # System binaries can't be installed via package manager — hard fail.
  if (( ${#system_missing[@]} > 0 )); then
    echo "missing system binaries: ${system_missing[*]}" >&2
    for m in "${system_missing[@]}"; do
      case "$m" in
        launchctl|plutil)   echo "  $m is part of macOS — are you sure you're on Darwin?" >&2 ;;
        systemctl|loginctl) echo "  $m is part of systemd — your distro may not use it; consider docker/" >&2 ;;
      esac
    done
    exit 1
  fi

  # Installable deps: show what's needed and offer to run the right command.
  cmd=$(suggest_install "${installable[@]}")
  echo "missing dependencies: ${installable[*]}"
  echo "I can install them by running:"
  echo "    $cmd"
  echo
  if [[ ! -t 0 ]]; then
    echo "non-interactive shell, can't prompt. Run the command above manually, then re-run install.sh." >&2
    exit 1
  fi
  read -r -p "Run it now? [Y/n] " answer </dev/tty
  case "${answer:-y}" in
    n|N|no|NO|nope)
      echo "aborted. Install the dependencies yourself, then re-run install.sh." >&2
      exit 1
      ;;
  esac
  step "installing missing dependencies"
  eval "$cmd"
  # Re-check after install.
  for bin in "${installable[@]}"; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      echo "  ✗ $bin still missing after install — please install it manually" >&2
      exit 1
    fi
  done
  echo "  ✓ ${installable[*]} now available"
fi

# --- 2. host paths --------------------------------------------------------
step "preparing $ROOSTER_HOME"
mkdir -p "$ROOSTER_HOME/secrets"
chmod 700 "$ROOSTER_HOME" "$ROOSTER_HOME/secrets"

# --- 3. config: BambooHR subdomain ----------------------------------------
if [[ ! -f "$ROOSTER_HOME/.env" ]]; then
  step "first-time setup — collecting config"

  subdomain=""
  while [[ -z "$subdomain" ]]; do
    read -r -p "BambooHR subdomain (the prefix in <x>.bamboohr.com): " subdomain
    subdomain="${subdomain// /}"
  done

  read -r -p "BambooHR employee ID [leave blank to auto-resolve]: " employee_id || true
  employee_id="${employee_id// /}"

  detected_tz=$(detect_tz)
  read -r -p "Timezone [$detected_tz]: " tz
  tz="${tz:-$detected_tz}"

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
TZ="${tz}"
ROOSTER_AUTH_FAIL_LOG_COOLDOWN_HOURS="6"
ROOSTER_WHOS_OUT_CACHE_TTL_SECONDS="1800"
DRY_RUN="${dry_run}"
EOF
  chmod 600 "$ROOSTER_HOME/.env"
  echo "  ✓ wrote $ROOSTER_HOME/.env (chmod 600)"
fi

# --- 4. config: BambooHR API key ------------------------------------------
# The upfront preflight gate already confirmed the user has a key, so we
# don't open a browser or print instructions here — straight to the prompt.
if [[ ! -s "$ROOSTER_HOME/secrets/api-key" ]]; then
  step "saving BambooHR API key (paste the key — input is hidden, no echo)"
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
_prompt_hhmm() {
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

  gap=15
  side=$(( (lunch_total - gap) / 2 ))
  lunch_out_start="$lunch_start"
  lunch_out_end=$(_min_to_hhmm   $(( $(_hhmm_to_min "$lunch_start") + side )))
  lunch_in_start=$(_min_to_hhmm  $(( $(_hhmm_to_min "$lunch_end")   - side )))
  lunch_in_end="$lunch_end"

  umask 077
  cat > "$ROOSTER_HOME/windows.conf" <<EOF
# Generated by install.sh on $(date)
# Edit and re-run install.sh to regenerate the scheduler units.
morning    $morning_start $morning_end
lunch-out  $lunch_out_start $lunch_out_end
lunch-in   $lunch_in_start $lunch_in_end
evening    $evening_start $evening_end
EOF
  echo "  ✓ wrote $ROOSTER_HOME/windows.conf"
fi

# Read final windows back so the scheduler installer can pick up the times.
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

# --- 7. install platform-specific scheduler ------------------------------
# shellcheck disable=SC1090
source "$ROOSTER_ROOT/install/${PLATFORM}.sh"
install_scheduler

# --- 8. install CLI shortcuts on PATH -------------------------------------
step "installing CLI shortcuts into ~/.local/bin"
mkdir -p "$HOME/.local/bin"
ln -sf "$ROOSTER_ROOT/bin/rooster"        "$HOME/.local/bin/rooster"
ln -sf "$ROOSTER_ROOT/bin/rooster-status" "$HOME/.local/bin/rooster-status"
ln -sf "$ROOSTER_ROOT/bin/rotate-key"     "$HOME/.local/bin/rooster-rotate-key"
echo "  ✓ rooster, rooster-status, rooster-rotate-key linked"

if ! echo ":$PATH:" | grep -q ":$HOME/.local/bin:"; then
  rc_file="$HOME/.zshrc"
  [[ -f "$HOME/.bashrc" && ! -f "$HOME/.zshrc" ]] && rc_file="$HOME/.bashrc"
  cat <<EOF

⚠  ~/.local/bin is not on your PATH. Add it:
    echo 'export PATH="\$HOME/.local/bin:\$PATH"' >> $rc_file
    source $rc_file
EOF
fi

# --- 9. summary ----------------------------------------------------------
step "active jobs"
scheduler_status_lines

if grep -q '^DRY_RUN="\?1"\?' "$ROOSTER_HOME/.env"; then
  cat <<EOF

⚠  DRY_RUN=1 is still set in $ROOSTER_HOME/.env
   The four jobs are scheduled but will skip the actual clock_in/out HTTP
   call. Watch the log for a few days, then flip DRY_RUN to "0":

     sed -i.bak 's/^DRY_RUN=.*/DRY_RUN="0"/' $ROOSTER_HOME/.env

   No restart needed — the script re-reads .env on every fire.
EOF
fi

cat <<EOF

✓ rooster scheduled (scheduler: $PLATFORM). Phases (Mon–Fri, local TZ):
   morning   ${morning_start} – ${morning_end}     → clock in
   lunch-out ${lunch_out_start} – ${lunch_out_end}   → clock out
   lunch-in  ${lunch_in_start} – ${lunch_in_end}    → clock in
   evening   ${evening_start} – ${evening_end}     → clock out

useful commands:
   tail -f $ROOSTER_HOME/log.jsonl
   rooster-status                          # last 7 days summary
   rooster --auth-check                    # live API key check
   rooster-rotate-key                      # rotate a revoked key
   touch $ROOSTER_HOME/skip-today          # bow out for today
EOF
scheduler_useful_commands
echo "   $ROOSTER_ROOT/uninstall.sh                # remove scheduler + CLI symlinks"
