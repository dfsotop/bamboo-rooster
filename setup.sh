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
# We deliberately avoid Xcode Command Line Tools — the only thing it provides
# us is `git`, and we use a tarball download (curl + tar, both shipped with
# macOS) instead. That saves the user a 1 GB install and a 5-min wait.
deps_missing=()
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

# --- 3. Homebrew (for jq) -------------------------------------------------
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

# --- 4. jq ----------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  say "Installing jq…"
  brew install jq
fi

# --- 5. fetch repo via tarball -------------------------------------------
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

# --- 6. hand off to install.sh -------------------------------------------
say "Running setup wizard"
exec "$INSTALL_DIR/install.sh"
