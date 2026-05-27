# shellcheck shell=bash
# lib/state.sh — tiny JSON KV store backed by a single state.json file.
#
# Keys are flat strings. Values are JSON-encoded; callers pass plain strings
# and they're stored as JSON strings. For object values, callers can use
# state_set_raw to inject a literal JSON value.

state_ensure_file() {
  : "${STATE_FILE:?STATE_FILE must be set}"
  if [[ ! -f "$STATE_FILE" ]]; then
    mkdir -p "$(dirname "$STATE_FILE")"
    echo '{}' >"$STATE_FILE"
  fi
}

# Cross-platform advisory lock using mkdir's atomicity. `flock(1)` isn't
# shipped with macOS, so we use the most portable primitive available.
# Returns 0 on lock acquired, 1 on timeout.
_state_acquire_lock() {
  local lock_dir="${STATE_FILE}.lock"
  local timeout_ms=10000   # 10 seconds — phases are short, this is generous
  local elapsed_ms=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    sleep 0.05
    elapsed_ms=$((elapsed_ms + 50))
    if (( elapsed_ms >= timeout_ms )); then
      echo "rooster: state lock timeout after ${timeout_ms}ms (stale $lock_dir?)" >&2
      return 1
    fi
  done
}

_state_release_lock() {
  rmdir "${STATE_FILE}.lock" 2>/dev/null || true
}

# state_get KEY → echoes the raw value (string or JSON), empty if absent.
# Reads are lock-free — the read-modify-write windows are short and `mv`
# is atomic, so any read sees either the pre- or post-update state, never
# a half-written file.
state_get() {
  local key="$1"
  [[ -f "$STATE_FILE" ]] || { echo ""; return 0; }
  jq -r --arg k "$key" '.[$k] // empty' "$STATE_FILE"
}

# state_set KEY VALUE — stores VALUE as a JSON string.
state_set() {
  local key="$1" value="$2"
  state_ensure_file
  _state_acquire_lock || return 1
  local tmp rc=0
  tmp=$(mktemp "${STATE_FILE}.XXXXXX")
  jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$STATE_FILE" >"$tmp" || rc=$?
  if [[ "$rc" == "0" ]]; then mv "$tmp" "$STATE_FILE"; else rm -f "$tmp"; fi
  _state_release_lock
  return $rc
}

# state_set_raw KEY JSON — stores JSON literally (object, number, bool).
state_set_raw() {
  local key="$1" json="$2"
  state_ensure_file
  _state_acquire_lock || return 1
  local tmp rc=0
  tmp=$(mktemp "${STATE_FILE}.XXXXXX")
  jq --arg k "$key" --argjson v "$json" '.[$k] = $v' "$STATE_FILE" >"$tmp" || rc=$?
  if [[ "$rc" == "0" ]]; then mv "$tmp" "$STATE_FILE"; else rm -f "$tmp"; fi
  _state_release_lock
  return $rc
}

# state_unset KEY
state_unset() {
  local key="$1"
  [[ -f "$STATE_FILE" ]] || return 0
  _state_acquire_lock || return 1
  local tmp rc=0
  tmp=$(mktemp "${STATE_FILE}.XXXXXX")
  jq --arg k "$key" 'del(.[$k])' "$STATE_FILE" >"$tmp" || rc=$?
  if [[ "$rc" == "0" ]]; then mv "$tmp" "$STATE_FILE"; else rm -f "$tmp"; fi
  _state_release_lock
  return $rc
}
