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

REPO_URL="https://github.com/dfsotop/bamboo-rooster.git"
INSTALL_DIR="${BAMBOO_ROOSTER_INSTALL_DIR:-$HOME/Applications/bamboo-rooster}"

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
    warn "Linux users:  git clone $REPO_URL && cd bamboo-rooster && ./install.sh"
    exit 1
    ;;
  *) fail "Unsupported OS: $(uname -s)" ;;
esac

# --- 2. dependency summary + consent --------------------------------------
# Inspect every dependency BEFORE installing anything. Show one combined
# summary, ask the user once, then proceed. This avoids the surprise of
# an install kicking off before the user knows what's coming.
deps_missing=()
command -v git  >/dev/null 2>&1 || deps_missing+=("Xcode Command Line Tools — provides git/curl (~5 min, pops a system dialog)")
command -v brew >/dev/null 2>&1 || deps_missing+=("Homebrew — the macOS package manager (run by its official installer)")
command -v jq   >/dev/null 2>&1 || deps_missing+=("jq — small JSON parser the rooster uses (via Homebrew)")

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

# --- 3. Xcode Command Line Tools (provides git) ---------------------------
if ! command -v git >/dev/null 2>&1; then
  say "Installing Xcode Command Line Tools…"
  xcode-select --install 2>/dev/null || true
  cat <<EOF

  A system dialog has popped up. Click "Install" and wait for it to finish.
  When it's done, re-run the same setup command:

    /bin/bash -c "\$(curl -fsSL https://raw.githubusercontent.com/dfsotop/bamboo-rooster/main/setup.sh)"

EOF
  exit 0
fi

# --- 4. Homebrew (for jq) -------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  say "Installing Homebrew…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Apple Silicon installs to /opt/homebrew; Intel to /usr/local. Make brew
  # findable in THIS shell so the next step works without re-login.
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
fi

# --- 5. jq ----------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  say "Installing jq…"
  brew install jq
fi

# --- 6. clone or update ---------------------------------------------------
if [[ -d "$INSTALL_DIR/.git" ]]; then
  say "Updating existing install at $INSTALL_DIR"
  cd "$INSTALL_DIR"
  git fetch --quiet origin
  git reset --quiet --hard origin/main
else
  say "Downloading bamboo-rooster to $INSTALL_DIR"
  mkdir -p "$(dirname "$INSTALL_DIR")"
  git clone --quiet "$REPO_URL" "$INSTALL_DIR"
fi
ok "code ready at $INSTALL_DIR"

# --- 7. hand off to install.sh -------------------------------------------
say "Running setup wizard"
exec "$INSTALL_DIR/install.sh"
