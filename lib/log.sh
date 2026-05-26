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
  # Same event as the JSONL line above, rendered as a plain English sentence.
  # Errors go to stderr so launchd splits launchd.out vs launchd.err.
  _emit_human "$event" "$phase" "$ts" "$@"
}

# Look up a key=value pair from a list of args. Echoes the value (or empty).
_kv() {
  local key="$1"; shift
  for kv in "$@"; do
    if [[ "${kv%%=*}" == "$key" ]]; then
      echo "${kv#*=}"
      return 0
    fi
  done
  echo ""
}

# The natural-language verb for a phase.
_phase_action() {
  case "$1" in
    morning|lunch-in)   echo "clock in" ;;
    lunch-out|evening)  echo "clock out" ;;
    *)                  echo "act" ;;
  esac
}

# Format an epoch as HH:MM:SS, portably across GNU and BSD date.
_epoch_hhmmss() {
  local e="$1"
  if date --version >/dev/null 2>&1; then
    date -d "@$e" +%H:%M:%S
  else
    date -r "$e" +%H:%M:%S
  fi
}

# Map opaque skip reasons to short readable strings.
_skip_reason_human() {
  case "$1" in
    manual-override)                  echo "skip-today flag is set" ;;
    weekend)                          echo "it's the weekend" ;;
    time-off-or-holiday)              echo "you're off today (PTO / sick / holiday)" ;;
    time-off-or-holiday-post-sleep)   echo "you went off-duty while we waited" ;;
    already-clocked)                  echo "this segment is already in your timesheet" ;;
    already-clocked-post-sleep)       echo "another source clocked this while we waited" ;;
    *)                                echo "$1" ;;
  esac
}

_emit_human() {
  local event="$1" phase="$2" ts="$3"
  shift 3
  local human_ts="${ts:11:8}"   # HH:MM:SS slice of the ISO local stamp
  local action; action=$(_phase_action "$phase")

  local line=""
  case "$event" in
    planned)
      local offset; offset=$(_kv offset_seconds "$@")
      local fire_at; fire_at=$(_epoch_hhmmss $(( $(date +%s) + offset )))
      local mins=$(( offset / 60 ))
      line=$(printf '· [%s] %s: will %s at %s (in %d min)' \
             "$human_ts" "$phase" "$action" "$fire_at" "$mins")
      ;;
    dry_run)
      local sleep_s; sleep_s=$(_kv would_sleep_seconds "$@")
      local fire_at; fire_at=$(_epoch_hhmmss $(( $(date +%s) + sleep_s )))
      local mins=$(( sleep_s / 60 ))
      line=$(printf '· [%s] %s: DRY RUN — would %s at %s (in %d min), no action taken' \
             "$human_ts" "$phase" "$action" "$fire_at" "$mins")
      ;;
    skipped)
      local r; r=$(_kv reason "$@")
      line=$(printf '· [%s] %s: skipped — %s' \
             "$human_ts" "$phase" "$(_skip_reason_human "$r")")
      ;;
    success)
      local status; status=$(_kv http_status "$@")
      # Past-tense the action: "clock in" → "clocked in".
      local pt; case "$action" in
        "clock in")  pt="clocked in" ;;
        "clock out") pt="clocked out" ;;
        *)           pt="acted" ;;
      esac
      line=$(printf '✓ [%s] %s: %s (HTTP %s)' \
             "$human_ts" "$phase" "$pt" "$status")
      ;;
    failed)
      local status; status=$(_kv http_status "$@")
      line=$(printf '✗ [%s] %s: failed to %s (HTTP %s)' \
             "$human_ts" "$phase" "$action" "$status")
      ;;
    auth_failure)
      local status; status=$(_kv http_status "$@")
      line=$(printf '✗ [%s] %s: API key rejected (HTTP %s). Run rooster-rotate-key.' \
             "$human_ts" "$phase" "$status")
      ;;
    auth_recovered)
      line=$(printf '✓ [%s] %s: API key working again' "$human_ts" "$phase")
      ;;
    api_error)
      local status; status=$(_kv http_status "$@")
      local ep; ep=$(_kv endpoint "$@")
      local reason; reason=$(_kv reason "$@")
      if [[ -n "$reason" ]]; then
        line=$(printf '✗ [%s] %s: API error — %s' "$human_ts" "$phase" "$reason")
      else
        line=$(printf '✗ [%s] %s: API error on %s (HTTP %s)' \
               "$human_ts" "$phase" "${ep:-unknown}" "${status:-000}")
      fi
      ;;
    parse_error)
      local ep; ep=$(_kv endpoint "$@")
      line=$(printf '✗ [%s] %s: unexpected response shape from %s' \
             "$human_ts" "$phase" "${ep:-unknown}")
      ;;
    *)
      # Unknown event type — fall back to the raw form so nothing is hidden.
      line="· [${human_ts}] ${phase} ${event}"
      for kv in "$@"; do line="${line} ${kv}"; done
      ;;
  esac

  case "$event" in
    failed|auth_failure|api_error|parse_error) printf '%s\n' "$line" >&2 ;;
    *)                                         printf '%s\n' "$line" ;;
  esac
}
