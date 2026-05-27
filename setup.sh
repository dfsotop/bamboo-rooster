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
    warn "Linux users: download a tarball or 'git clone' the repo, then run ./install.sh"
    exit 1
    ;;
  *) fail "Unsupported OS: $(uname -s)" ;;
esac

# --- 2. preflight: API key required --------------------------------------
# Asked BEFORE any system change so we don't install brew/jq for someone
# who can't actually use the tool. Exports BAMBOO_ROOSTER_KEY_CONFIRMED so
# the install.sh wizard further down doesn't re-prompt for the same thing.
cat <<'EOF'

This installs bamboo-rooster, which clocks you in and out of BambooHR
automatically. You'll need a BambooHR API key first.

How to get one:
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
read -r -p "Do you have your API key ready? [y/N] " key_ready </dev/tty
case "${key_ready:-n}" in
  y|Y|yes|YES)
    export BAMBOO_ROOSTER_KEY_CONFIRMED=1
    ;;
  *)
    cat <<'EOF'

Aborting. Get your API key first, then re-run the same setup command:

  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/dfsotop/bamboo-rooster/main/setup.sh)"

EOF
    exit 0
    ;;
esac

# --- 3. dependency summary + consent --------------------------------------
# No Xcode CLT (we use curl + tar for the repo download). No Homebrew either:
# the only thing it would install for us is jq, and jq publishes single-file
# macOS binaries (~600 KB) we can download directly from its GitHub releases.
JQ_VERSION="1.7.1"
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

# --- 4. jq (direct binary download) --------------------------------------
if (( need_jq )); then
  case "$(uname -m)" in
    arm64)  jq_arch="arm64" ;;
    x86_64) jq_arch="amd64" ;;
    *) fail "unsupported CPU architecture: $(uname -m)" ;;
  esac
  jq_url="https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-macos-${jq_arch}"
  say "Downloading jq ${JQ_VERSION} (macOS ${jq_arch})…"
  mkdir -p "$JQ_INSTALL_DIR"
  chmod 700 "$HOME/.bamboo-rooster"
  if ! curl -fsSL "$jq_url" -o "$JQ_INSTALL_DIR/jq"; then
    fail "could not download jq from $jq_url"
  fi
  chmod +x "$JQ_INSTALL_DIR/jq"
  if ! "$JQ_INSTALL_DIR/jq" --version >/dev/null 2>&1; then
    fail "downloaded jq doesn't run (file may be corrupted or arch wrong)"
  fi
  export PATH="$JQ_INSTALL_DIR:$PATH"
  ok "jq installed at $JQ_INSTALL_DIR/jq"
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
