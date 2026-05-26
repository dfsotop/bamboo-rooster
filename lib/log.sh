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

# Format an epoch as HH:MM:SS in local time, portably across GNU and BSD.
_epoch_hhmmss() {
  local e="$1"
  if date --version >/dev/null 2>&1; then
    date -d "@$e" +%H:%M:%S
  else
    date -r "$e" +%H:%M:%S
  fi
}

# ISO 8601 UTC string → local HH:MM:SS, portably.
_iso_utc_to_local_hhmmss() {
  local iso="$1" e
  if date --version >/dev/null 2>&1; then
    e=$(date -d "$iso" +%s)
  else
    e=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null) || echo "$iso"
  fi
  _epoch_hhmmss "$e"
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
      local target_iso sleep_s fire_at mins
      target_iso=$(_kv target_iso "$@")
      sleep_s=$(_kv sleep_seconds "$@")
      fire_at=$(_iso_utc_to_local_hhmmss "$target_iso")
      mins=$(( sleep_s / 60 ))
      if (( sleep_s > 0 )); then
        line=$(printf '· [%s] %s: will %s at %s (in %d min)' \
               "$human_ts" "$phase" "$action" "$fire_at" "$mins")
      else
        line=$(printf '· [%s] %s: will %s now, backdated to %s (window has passed)' \
               "$human_ts" "$phase" "$action" "$fire_at")
      fi
      ;;
    dry_run)
      local target_iso sleep_s fire_at mins
      target_iso=$(_kv target_iso "$@")
      sleep_s=$(_kv sleep_seconds "$@")
      fire_at=$(_iso_utc_to_local_hhmmss "$target_iso")
      mins=$(( sleep_s / 60 ))
      if (( sleep_s > 0 )); then
        line=$(printf '· [%s] %s: DRY RUN — would %s at %s (in %d min), no action taken' \
               "$human_ts" "$phase" "$action" "$fire_at" "$mins")
      else
        line=$(printf '· [%s] %s: DRY RUN — would %s now, backdated to %s, no action taken' \
               "$human_ts" "$phase" "$action" "$fire_at")
      fi
      ;;
    skipped)
      local r; r=$(_kv reason "$@")
      case "$r" in
        already-clocked|already-clocked-post-sleep)
          # Detailed messages when gates.sh supplied a timestamp kv.
          local in_at out_at still_in last_session latest_started no_in
          in_at=$(_kv clocked_in_at "$@")
          out_at=$(_kv last_clocked_out_at "$@")
          still_in=$(_kv still_clocked_in_since "$@")
          last_session=$(_kv last_session_ended_at "$@")
          latest_started=$(_kv latest_session_started_at "$@")
          no_in=$(_kv no_clock_in_yet "$@")
          local suffix=""
          [[ "$r" == "already-clocked-post-sleep" ]] && suffix=" (changed during sleep)"
          if   [[ -n "$in_at" ]];          then line="· [${human_ts}] ${phase}: skipped — already clocked in at ${in_at}${suffix}"
          elif [[ -n "$still_in" ]];       then line="· [${human_ts}] ${phase}: skipped — still clocked in since ${still_in} (no lunch break yet)${suffix}"
          elif [[ -n "$latest_started" ]]; then line="· [${human_ts}] ${phase}: skipped — already had 2 sessions today (latest started ${latest_started})${suffix}"
          elif [[ -n "$last_session" ]];   then line="· [${human_ts}] ${phase}: skipped — last session ended at ${last_session}, too long ago for a resume${suffix}"
          elif [[ -n "$out_at" ]];         then line="· [${human_ts}] ${phase}: skipped — no open entry to close (last clocked out at ${out_at})${suffix}"
          elif [[ -n "$no_in" ]];          then line="· [${human_ts}] ${phase}: skipped — no clock-in yet today${suffix}"
          else                                  line="· [${human_ts}] ${phase}: skipped — $(_skip_reason_human "$r")"
          fi
          ;;
        *)
          line=$(printf '· [%s] %s: skipped — %s' \
                 "$human_ts" "$phase" "$(_skip_reason_human "$r")")
          ;;
      esac
      ;;
    success)
      local status target_iso target_at
      status=$(_kv http_status "$@")
      target_iso=$(_kv target_iso "$@")
      target_at=""
      [[ -n "$target_iso" ]] && target_at=$(_iso_utc_to_local_hhmmss "$target_iso")
      # Past-tense the action: "clock in" → "clocked in".
      local pt; case "$action" in
        "clock in")  pt="clocked in" ;;
        "clock out") pt="clocked out" ;;
        *)           pt="acted" ;;
      esac
      if [[ -n "$target_at" ]]; then
        line=$(printf '✓ [%s] %s: %s at %s (HTTP %s)' \
               "$human_ts" "$phase" "$pt" "$target_at" "$status")
      else
        line=$(printf '✓ [%s] %s: %s (HTTP %s)' \
               "$human_ts" "$phase" "$pt" "$status")
      fi
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
