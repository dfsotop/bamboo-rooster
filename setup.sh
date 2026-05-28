#!/usr/bin/env bash
# setup.sh — one-line bootstrap for bamboo-rooster on macOS.
#
# Safe to run via curl | bash:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/dfsotop/bamboo-rooster/main/setup.sh)"
#
# Idempotent — re-running updates an existing install. Steps:
#   1. Verify macOS.
#   2. Install Xcode Command Line Tools if `git` is missing.
#   3. Install Homebrew if missing, then `brew install jq`.
#   4. Clone the repo to ~/Applications/bamboo-rooster (or update if present).
#   5. exec the repo's install.sh to walk through the interactive setup.

set -euo pipefail

TARBALL_URL="https://github.com/dfsotop/bamboo-rooster/archive/refs/heads/main.tar.gz"
INSTALL_DIR="${BAMBOO_ROOSTER_INSTALL_DIR:-$HOME/Applications/bamboo-rooster}"

# Pinned jq binaries with SHA-256 (computed against jqlang/jq 1.7.1
# release artifacts). Bump JQ_VERSION + both sums together when updating.
JQ_VERSION="1.7.1"
JQ_SHA256_arm64="0bbe619e663e0de2c550be2fe0d240d076799d6f8a652b70fa04aea8a8362e8a"
JQ_SHA256_amd64="4155822bbf5ea90f5c79cf254665975eb4274d426d0709770c21774de5407443"

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
say()  { printf '\n\033[1;36m▸\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m⚠\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

bold "🐓 bamboo-rooster · setup"

# --- 1. macOS only --------------------------------------------------------
case "$(uname -s)" in
  Darwin) ;;
  Linux)
    warn "This bootstrap is macOS-only."
    warn "Linux users: download a tarball or 'git clone' the repo, then run ./install.sh"
    exit 1
    ;;
  *) fail "Unsupported OS: $(uname -s)" ;;
esac

# --- 2. existing-config short-circuit -------------------------------------
# If the user already has a working config (BambooHR .env + api-key on
# disk), don't make them re-confirm the disclaimer or re-paste the key.
# Show the current settings and ask one yes/no to proceed with the
# update. Sets BAMBOO_ROOSTER_KEY_CONFIRMED so the disclaimer block below
# is skipped.
EXISTING_HOME="$HOME/.bamboo-rooster"
if [[ -f "$EXISTING_HOME/.env" && -s "$EXISTING_HOME/secrets/api-key" ]]; then
  bold "Found existing bamboo-rooster config at $EXISTING_HOME"

  _envget() { grep -E "^$1=" "$EXISTING_HOME/.env" 2>/dev/null \
    | cut -d= -f2- | tr -d '"' | tr -d "'" | tr -d ' '; }

  cur_subdomain=$(_envget BAMBOOHR_SUBDOMAIN)
  cur_emp=$(_envget BAMBOOHR_EMPLOYEE_ID)
  cur_tz=$(_envget TZ)
  cur_dry=$(_envget DRY_RUN)

  printf '  subdomain     %s\n' "${cur_subdomain:-(not set)}"
  printf '  employee ID   %s\n' "${cur_emp:-(auto-resolved from key)}"
  printf '  timezone      %s\n' "${cur_tz:-(unset)}"
  if [[ "$cur_dry" == "1" ]]; then
    printf '  mode          DRY_RUN — no real clock_in/out\n'
  else
    printf '  mode          LIVE — real clock_in/out\n'
  fi
  printf '  api key file  %s bytes\n' "$(wc -c < "$EXISTING_HOME/secrets/api-key" | tr -d ' ')"
  if [[ -f "$EXISTING_HOME/windows.conf" ]]; then
    echo "  phase windows:"
    grep -E '^[a-z]' "$EXISTING_HOME/windows.conf" \
      | awk '{printf "    %-10s %s – %s\n", $1, $2, $3}'
  fi

  cat <<EOF

This will fetch the latest code and re-run the installer with the above
config — no prompts, just download + regenerate the scheduler units.

To reconfigure something, abort and then:
  rm $EXISTING_HOME/windows.conf      → re-prompt time windows
  rm $EXISTING_HOME/.env              → re-prompt subdomain/TZ/DRY_RUN
  rooster-rotate-key                  → replace the API key
  rm -rf $EXISTING_HOME               → start completely fresh

EOF
  if [[ ! -t 0 ]]; then
    fail "non-interactive shell, can't prompt"
  fi
  read -r -p "Continue with existing config? [Y/n] " answer </dev/tty
  case "${answer:-y}" in
    n|N|no|NO|nope) echo "aborted."; exit 0 ;;
  esac
  export BAMBOO_ROOSTER_KEY_CONFIRMED=1
fi

# --- 3. preflight: disclaimer + API key required (first install only) -----
# Asked BEFORE any system change so we don't install jq or download the
# repo for someone who can't (or won't) use the tool. Skipped when the
# block above already confirmed an existing install.
if [[ -z "${BAMBOO_ROOSTER_KEY_CONFIRMED:-}" ]]; then
cat <<'EOF'

DISCLAIMER
  bamboo-rooster is a helper that schedules clock-in/clock-out actions
  against BambooHR. It is provided AS-IS, without any warranty. YOU
  remain SOLELY RESPONSIBLE for verifying that your timesheet records
  are accurate and complete, and for complying with your company's
  time-tracking policy. The tool can fail silently (network issues,
  API changes, scheduler not firing, etc.) — it does NOT replace your
  own obligation to keep your timesheet correct.

You'll need a BambooHR API key. How to get one:
  1. Log in to https://<your-subdomain>.bamboohr.com
  2. Click your profile picture (top right) → "API Keys"
  3. Click "Add New Key", give it a name (e.g. "bamboo-rooster")
  4. Click "Generate Key" — COPY THE STRING NOW (it's only shown once)

If "API Keys" isn't in your profile menu, ask your BambooHR admin to
enable API key generation for your user (it's a 30-second toggle).

EOF
if [[ ! -t 0 ]]; then
  fail "non-interactive shell, can't prompt. Re-run in a Terminal window."
fi
read -r -p "I accept the disclaimer and have my API key ready. [y/N] " accept </dev/tty
case "${accept:-n}" in
  y|Y|yes|YES)
    export BAMBOO_ROOSTER_KEY_CONFIRMED=1
    ;;
  *)
    cat <<'EOF'

Aborting. When you're ready, re-run the same setup command:

  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/dfsotop/bamboo-rooster/main/setup.sh)"

EOF
    exit 0
    ;;
esac
fi  # end first-install disclaimer/gate

# --- 4. dependency summary + consent --------------------------------------
# No Xcode CLT (we use curl + tar for the repo download). No Homebrew either:
# the only thing it would install for us is jq, and jq publishes single-file
# macOS binaries (~600 KB) we can download directly from its GitHub releases.
JQ_INSTALL_DIR="$HOME/.bamboo-rooster/bin"

deps_missing=()
need_jq=0
if ! command -v jq >/dev/null 2>&1; then
  deps_missing+=("jq ${JQ_VERSION} — small JSON parser, ~600 KB, downloaded directly from github.com/jqlang/jq (no Homebrew required)")
  need_jq=1
fi

if (( ${#deps_missing[@]} == 0 )); then
  ok "all dependencies present"
else
  bold "The following will be installed:"
  for d in "${deps_missing[@]}"; do
    echo "  • $d"
  done
  echo
  if [[ ! -t 0 ]]; then
    fail "non-interactive shell, can't prompt. Re-run in a Terminal window."
  fi
  read -r -p "Continue? [Y/n] " answer </dev/tty
  case "${answer:-y}" in
    n|N|no|NO|nope) fail "aborted by user" ;;
  esac
fi

# --- 5. jq (direct binary download with SHA-256 verification) ------------
if (( need_jq )); then
  case "$(uname -m)" in
    arm64)  jq_arch="arm64"; jq_sha="$JQ_SHA256_arm64" ;;
    x86_64) jq_arch="amd64"; jq_sha="$JQ_SHA256_amd64" ;;
    *) fail "unsupported CPU architecture: $(uname -m)" ;;
  esac
  jq_url="https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-macos-${jq_arch}"
  say "Downloading jq ${JQ_VERSION} (macOS ${jq_arch})…"
  mkdir -p "$JQ_INSTALL_DIR"
  chmod 700 "$HOME/.bamboo-rooster"
  if ! curl -fsSL "$jq_url" -o "$JQ_INSTALL_DIR/jq"; then
    fail "could not download jq from $jq_url"
  fi
  # Pinned SHA-256 check — refuses to install anything other than the
  # exact bytes we expect. Protects against a future supply-chain swap.
  actual_sha=$(shasum -a 256 "$JQ_INSTALL_DIR/jq" | awk '{print $1}')
  if [[ "$actual_sha" != "$jq_sha" ]]; then
    rm -f "$JQ_INSTALL_DIR/jq"
    fail "jq SHA-256 mismatch — expected $jq_sha, got $actual_sha. Aborting."
  fi
  chmod +x "$JQ_INSTALL_DIR/jq"
  if ! "$JQ_INSTALL_DIR/jq" --version >/dev/null 2>&1; then
    fail "downloaded jq doesn't run (file may be corrupted or arch wrong)"
  fi
  export PATH="$JQ_INSTALL_DIR:$PATH"
  ok "jq installed at $JQ_INSTALL_DIR/jq (sha256 verified)"
fi

# --- 6. fetch repo via tarball -------------------------------------------
# Guard against env-poisoned BAMBOO_ROOSTER_INSTALL_DIR being set to
# something we'd `rm -rf` later — like $HOME or /. Refuse without prejudice.
case "$INSTALL_DIR" in
  ""|"/"|"$HOME"|"$HOME/") fail "refusing to install at '$INSTALL_DIR' (too broad)" ;;
esac
case "$INSTALL_DIR" in
  /tmp|/var|/etc|/usr|/bin|/sbin) fail "refusing to install at system path '$INSTALL_DIR'" ;;
esac

# If the user has cloned the repo manually (so .git is present), respect
# that and let them update via git themselves. Otherwise atomically replace
# the install with the latest main branch tarball.
if [[ -d "$INSTALL_DIR/.git" ]]; then
  say "Existing git checkout at $INSTALL_DIR — not touching (update via 'git pull' if you want to)"
else
  say "Downloading bamboo-rooster to $INSTALL_DIR"
  mkdir -p "$(dirname "$INSTALL_DIR")"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "$TARBALL_URL" | tar -xz -C "$tmp"
  # GitHub tarballs extract to <repo>-<branch>/, e.g. bamboo-rooster-main
  extracted="$tmp"/bamboo-rooster-main
  if [[ ! -d "$extracted" ]]; then
    fail "tarball didn't contain the expected directory"
  fi
  rm -rf "$INSTALL_DIR"
  mv "$extracted" "$INSTALL_DIR"
fi
ok "code ready at $INSTALL_DIR"

# --- 7. hand off to install.sh -------------------------------------------
say "Running setup wizard"
exec "$INSTALL_DIR/install.sh"
