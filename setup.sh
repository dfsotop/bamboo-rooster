#!/usr/bin/env bash
# setup.sh — one-line bootstrap for bamboo-rooster on macOS.
#
# Designed to be safe to run via curl | bash:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/dfsotop/bamboo-rooster/main/setup.sh)"
#
# What it does (idempotent — re-running updates an existing install):
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

# --- 2. Xcode Command Line Tools (provides git) ---------------------------
if ! command -v git >/dev/null 2>&1; then
  say "Installing Xcode Command Line Tools (one-time, takes ~5 minutes)…"
  xcode-select --install 2>/dev/null || true
  cat <<EOF

  A system dialog has popped up. Click "Install" and wait for it to finish.
  When it's done, re-run the same setup command:

    /bin/bash -c "\$(curl -fsSL https://raw.githubusercontent.com/dfsotop/bamboo-rooster/main/setup.sh)"

EOF
  exit 0
fi

# --- 3. Homebrew (for jq) -------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  say "Installing Homebrew (one-time)…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Apple Silicon installs to /opt/homebrew; Intel to /usr/local. Make brew
  # findable in THIS shell so the next step works without re-login.
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
fi

# --- 4. jq ----------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  say "Installing jq…"
  brew install jq
fi

# --- 5. clone or update ---------------------------------------------------
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

# --- 6. hand off to install.sh -------------------------------------------
say "Running setup wizard"
exec "$INSTALL_DIR/install.sh"
