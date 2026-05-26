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

# state_get KEY → echoes the raw value (string or JSON), empty if absent.
state_get() {
  local key="$1"
  [[ -f "$STATE_FILE" ]] || { echo ""; return 0; }
  jq -r --arg k "$key" '.[$k] // empty' "$STATE_FILE"
}

# state_set KEY VALUE — stores VALUE as a JSON string.
state_set() {
  local key="$1" value="$2"
  state_ensure_file
  local tmp; tmp=$(mktemp "${STATE_FILE}.XXXXXX")
  jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$STATE_FILE" >"$tmp"
  mv "$tmp" "$STATE_FILE"
}

# state_set_raw KEY JSON — stores JSON literally (object, number, bool).
state_set_raw() {
  local key="$1" json="$2"
  state_ensure_file
  local tmp; tmp=$(mktemp "${STATE_FILE}.XXXXXX")
  jq --arg k "$key" --argjson v "$json" '.[$k] = $v' "$STATE_FILE" >"$tmp"
  mv "$tmp" "$STATE_FILE"
}

# state_unset KEY
state_unset() {
  local key="$1"
  [[ -f "$STATE_FILE" ]] || return 0
  local tmp; tmp=$(mktemp "${STATE_FILE}.XXXXXX")
  jq --arg k "$key" 'del(.[$k])' "$STATE_FILE" >"$tmp"
  mv "$tmp" "$STATE_FILE"
}
