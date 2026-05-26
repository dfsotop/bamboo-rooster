# shellcheck shell=bash
# lib/log.sh — single jsonl event logger.
#
# Usage:
#   log_event <event> <phase> [key=value]...
#
# Examples:
#   log_event success morning http_status=200
#   log_event skipped lunch-out reason=time-off-or-holiday
#   log_event auth_failure morning http_status=401
#
# Every line carries both local-Madrid and UTC timestamps. UTC is canonical
# for aggregation; local is for human reading. The UTC stamp lets you compare
# log lines across DST boundaries without ambiguity.

log_event() {
  local event="${1:?event required}"
  local phase="${2:-}"
  shift 2 2>/dev/null || true

  local ts ts_utc
  ts=$(date +%Y-%m-%dT%H:%M:%S%z)
  ts_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Build a base object, then fold each key=value pair into it.
  local jq_args=(
    --arg ts "$ts"
    --arg ts_utc "$ts_utc"
    --arg event "$event"
    --arg phase "$phase"
  )
  local jq_filter='{ts: $ts, ts_utc: $ts_utc, event: $event, phase: $phase}'

  for kv in "$@"; do
    local k="${kv%%=*}"
    local v="${kv#*=}"
    jq_args+=(--arg "$k" "$v")
    jq_filter="${jq_filter} + {\"${k}\": \$${k}}"
  done

  local target="${ROOSTER_LOG_FILE:-/var/lib/rooster/log.jsonl}"
  mkdir -p "$(dirname "$target")"
  jq -nc "${jq_args[@]}" "$jq_filter" >>"$target"

  # --- human-readable summary ---------------------------------------------
  # Same data, one line, terminal-friendly. Errors go to stderr so launchd
  # routes them to launchd.err and `2>/dev/null` silences them when desired.
  local human_ts="${ts:11:8}"   # HH:MM:SS slice of the ISO local stamp
  local glyph
  case "$event" in
    success|auth_recovered)                       glyph="✓" ;;
    failed|auth_failure|api_error|parse_error)    glyph="✗" ;;
    *)                                            glyph="·" ;;
  esac
  local line="${glyph} [${human_ts}] ${phase} ${event}"
  for kv in "$@"; do
    line="${line} ${kv}"
  done
  case "$event" in
    failed|auth_failure|api_error|parse_error) printf '%s\n' "$line" >&2 ;;
    *)                                         printf '%s\n' "$line" ;;
  esac
}
