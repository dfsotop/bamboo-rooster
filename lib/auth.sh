# shellcheck shell=bash
# lib/auth.sh — single curl wrapper that handles BambooHR Basic Auth and
# emits auth_failure / auth_recovered events when the API key state flips.
#
# Depends on: log.sh, state.sh. Sets BAMBOO_LAST_STATUS for callers that
# want to inspect the HTTP code (e.g. the bare auth-check helper).

: "${BAMBOOHR_API_BASE:=https://api.bamboohr.com/api/gateway.php}"
: "${ROOSTER_AUTH_FAIL_LOG_COOLDOWN_HOURS:=6}"

# Last HTTP status from bamboo_request. The shell variable works for inline
# callers (auth.sh's own internal handlers); callers that capture stdout via
# `$(bamboo_request …)` lose it to the subshell. For those we ALSO persist
# it to disk and expose `bamboo_last_status` to read it back.
_status_file() {
  printf '%s' "${BAMBOO_STATUS_FILE:-${ROOSTER_HOME:-/tmp}/.last_status}"
}

bamboo_last_status() {
  local f
  f=$(_status_file)
  if [[ -r "$f" ]]; then
    cat "$f"
  else
    echo "000"
  fi
}

# Reads the API key from disk on every call so rotation doesn't need a restart.
# Logs a structured event on failure so missing-key outages are visible in
# log.jsonl (not just on stderr → cron.err).
_read_api_key() {
  if [[ ! -r "$ROOSTER_API_KEY_FILE" ]]; then
    log_event api_error "${PHASE:-unknown}" reason=api-key-unreadable
    echo "rooster: api-key file missing or unreadable at $ROOSTER_API_KEY_FILE" >&2
    return 1
  fi
  tr -d '\n\r' <"$ROOSTER_API_KEY_FILE"
}

# bamboo_request METHOD PATH [JSON_BODY]
#   Echoes the response body to stdout.
#   Sets BAMBOO_LAST_STATUS to the HTTP status code (or "000" on transport error).
#   Returns 0 on 2xx, non-zero otherwise.
#
# On 401/403:
#   - Logs an auth_failure event (rate-limited by ROOSTER_AUTH_FAIL_LOG_COOLDOWN_HOURS).
#   - Records last_auth_failure_log_ts (epoch seconds) in state.json.
#
# On 2xx after a previous auth_failure:
#   - Logs one auth_recovered event and clears last_auth_failure_log_ts.
bamboo_request() {
  local method="$1"; shift
  local path="$1"; shift

  if [[ -z "${BAMBOOHR_SUBDOMAIN:-}" ]]; then
    echo "rooster: BAMBOOHR_SUBDOMAIN not set (check $ROOSTER_HOME/.env)" >&2
    BAMBOO_LAST_STATUS="000"
    return 1
  fi
  if [[ -z "${ROOSTER_API_KEY_FILE:-}" ]]; then
    echo "rooster: ROOSTER_API_KEY_FILE not set" >&2
    BAMBOO_LAST_STATUS="000"
    return 1
  fi

  local key
  key=$(_read_api_key) || {
    BAMBOO_LAST_STATUS="000"
    return 1
  }

  local url="${BAMBOOHR_API_BASE}/${BAMBOOHR_SUBDOMAIN}/v1${path}"

  local body_file http_status
  body_file=$(mktemp)

  if [[ $# -gt 0 ]]; then
    http_status=$(curl -sS -o "$body_file" -w "%{http_code}" \
      --max-time 30 \
      -u "${key}:x" \
      -X "$method" \
      -H "Accept: application/json" \
      -H "Content-Type: application/json" \
      --data-binary "$1" \
      "$url" 2>/dev/null) || http_status="000"
  else
    http_status=$(curl -sS -o "$body_file" -w "%{http_code}" \
      --max-time 30 \
      -u "${key}:x" \
      -X "$method" \
      -H "Accept: application/json" \
      "$url" 2>/dev/null) || http_status="000"
  fi

  BAMBOO_LAST_STATUS="$http_status"
  # Persist to disk so callers using `response=$(bamboo_request …)` can read
  # the status from the parent shell after the subshell exits.
  local status_file
  status_file=$(_status_file)
  mkdir -p "$(dirname "$status_file")" 2>/dev/null || true
  printf '%s' "$http_status" > "$status_file" 2>/dev/null || true

  cat "$body_file"
  rm -f "$body_file"

  case "$http_status" in
    2*)
      _maybe_log_auth_recovered
      return 0
      ;;
    401|403)
      _maybe_log_auth_failure "$http_status"
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

_maybe_log_auth_failure() {
  local status="$1"
  local now last cooldown_secs
  now=$(date +%s)
  last=$(state_get last_auth_failure_log_ts)
  cooldown_secs=$(( ROOSTER_AUTH_FAIL_LOG_COOLDOWN_HOURS * 3600 ))

  if [[ -z "$last" ]] || (( now - last >= cooldown_secs )); then
    log_event auth_failure "${PHASE:-unknown}" http_status="$status"
    state_set_raw last_auth_failure_log_ts "$now"
  fi
}

_maybe_log_auth_recovered() {
  local last
  last=$(state_get last_auth_failure_log_ts)
  if [[ -n "$last" ]]; then
    log_event auth_recovered "${PHASE:-unknown}"
    state_unset last_auth_failure_log_ts
  fi
}
