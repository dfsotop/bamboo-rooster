# shellcheck shell=bash
# lib/gates.sh — predicates the rooster runs before clocking in/out.
#
# All gates return 0 when the gate's condition is TRUE (i.e. "yes, you should
# act on this"), non-zero when FALSE. So `is_weekday` returns 0 on Mon–Fri,
# `is_on_time_off_or_holiday` returns 0 when there IS a time-off entry today.

: "${ROOSTER_WHOS_OUT_CACHE_TTL_SECONDS:=1800}"

# --- Weekday --------------------------------------------------------------

is_weekday() {
  local date="$1"
  local dow
  # ISO day-of-week: 1=Mon … 7=Sun. Both GNU and busybox date understand
  # YYYY-MM-DD inputs; the format below works on Alpine and macOS dev too.
  if date --version >/dev/null 2>&1; then
    dow=$(date -d "$date" +%u)
  else
    dow=$(date -j -f "%Y-%m-%d" "$date" +%u)
  fi
  [[ "$dow" -le 5 ]]
}

# --- BambooHR time-off + holidays in one call ----------------------------
#
# Calls /time_off/whos_out and returns 0 if either:
#   - an entry has employeeId == self (PTO, sick, doctor, parental — anything),
#     or
#   - a company-wide holiday entry covers today (type "holiday").
#
# Cache: positive AND negative results are cached in state.json with a TTL,
# scoped by date. Pass --force-refresh to bypass the cache (used after the
# pre-action sleep so mid-day-entered sick leave is picked up).

is_on_time_off_or_holiday() {
  local employee_id="$1" today="$2"
  local force_refresh="${3:-}"

  local cache decision cache_date cache_fetched_at now ttl
  now=$(date +%s)
  ttl="$ROOSTER_WHOS_OUT_CACHE_TTL_SECONDS"

  if [[ "$force_refresh" != "--force-refresh" ]]; then
    cache=$(state_get whos_out_cache)
    if [[ -n "$cache" ]]; then
      cache_date=$(echo "$cache" | jq -r '.date // empty')
      cache_fetched_at=$(echo "$cache" | jq -r '.fetched_at // 0')
      decision=$(echo "$cache" | jq -r '.is_on // empty')
      if [[ "$cache_date" == "$today" ]] \
         && [[ -n "$decision" ]] \
         && (( now - cache_fetched_at < ttl )); then
        [[ "$decision" == "true" ]]
        return $?
      fi
    fi
  fi

  local response
  if ! response=$(bamboo_get_whos_out_today "$today"); then
    # Conservative: if we can't reach the API, treat it as "on time off"
    # so we don't accidentally clock in on a sick day. Emit a DISTINCT
    # detail string so the caller can log the real reason (api error)
    # rather than misleading "time-off-or-holiday".
    log_event api_error "${PHASE:-unknown}" \
      endpoint=whos_out http_status="$(bamboo_last_status)"
    echo "whos-out-api-error"
    return 0
  fi

  local hit
  hit=$(echo "$response" | jq -r --arg id "$employee_id" '
    map(select(
         (.employeeId? // "" | tostring) == $id
      or ((.type? // "") | ascii_downcase) == "holiday"
    )) | length
  ')

  local is_on=false
  if [[ "${hit:-0}" -gt 0 ]]; then
    is_on=true
  fi

  state_set_raw whos_out_cache \
    "{\"date\":\"$today\",\"is_on\":$is_on,\"fetched_at\":$now}"

  [[ "$is_on" == "true" ]]
}

# --- Idempotency: is this segment already in today's timesheet? -----------
#
# Each clock entry has a `start` (ISO 8601, always set) and `end` (ISO 8601
# or null while the entry is "open"). The rules below treat the timesheet
# as state, not as a count, so they work for both the rooster's own 2-entry
# day AND a manually-entered single 8-hour entry.
#
#   clock-in phases (morning, lunch-in):
#     skip if any entry covers "now" — either an open entry that started
#     before now, or a closed entry whose [start, end] range encloses now.
#     Either way, clocking in again would corrupt the timesheet.
#
#   clock-out phases (lunch-out, evening):
#     skip if no entry is "open" — there's nothing to close. Closing a
#     non-open entry isn't possible at the API level; the gate makes it
#     explicit in the log.

already_clocked_for_phase() {
  local employee_id="$1" phase="$2" today="$3"
  local response
  if ! response=$(bamboo_get_timesheet_today "$employee_id" "$today"); then
    log_event api_error "${PHASE:-unknown}" \
      endpoint=timesheet_entries http_status="$(bamboo_last_status)"
    # Conservative: if we can't tell, assume already clocked → skip.
    return 0
  fi

  # Refuse to interpret anything other than a JSON array. An object body
  # (error envelope that somehow slipped past the 2xx check, a future API
  # shape change, etc.) is an unknown-state signal — skip conservatively
  # rather than coerce to [] and risk clocking in over real entries.
  if ! echo "$response" | jq -e 'type == "array"' >/dev/null 2>&1; then
    log_event parse_error "${PHASE:-unknown}" endpoint=timesheet_entries
    return 0
  fi

  # Filter to entries we understand. Surface unknown types (a hypothetical
  # future BambooHR addition) via parse_error so we don't silently broaden
  # or narrow the gate's behaviour without anyone noticing.
  local known_count unknown_count
  known_count=$(echo "$response" | jq \
    'map(select((.type? // "") == "clock" or (.type? // "") == "hour")) | length')
  unknown_count=$(echo "$response" | jq \
    'map(select((.type? // "") != "clock" and (.type? // "") != "hour")) | length')
  if (( unknown_count > 0 )); then
    log_event parse_error "${PHASE:-unknown}" \
      endpoint=timesheet_entries reason=unknown-entry-types \
      unknown_count="$unknown_count"
  fi

  # Sort clock entries chronologically by start, so .[0] is genuinely the
  # first and .[-1] is the last (BambooHR's response order isn't contractual).
  local clock_entries
  clock_entries=$(echo "$response" | jq -c \
    'map(select((.type? // "") == "clock")) | sort_by(.start // "")')

  local now_epoch
  now_epoch=$(date -u +%s)

  # Per-phase decision. When skipping, also echo ONE key=value pair that
  # the caller can hand to log_event so the human line can say *why* (e.g.
  # "already clocked in at 09:15" instead of just "already clocked").
  local should_skip=1   # 1 = proceed (default), 0 = skip
  local skip_kv=""

  case "$phase" in
    morning)
      # Skip iff any entry of a known type (clock or hour) exists today.
      if [[ "$known_count" -ge 1 ]]; then
        should_skip=0
        # Pick the chronologically-earliest entry for the display message.
        local first_start
        first_start=$(echo "$response" | jq -r \
          'map(select((.type? // "") == "clock" or (.type? // "") == "hour"))
           | sort_by(.start // "") | .[0].start // empty')
        if [[ -n "$first_start" ]]; then
          skip_kv="clocked_in_at=$(iso_to_local_hhmm "$first_start")"
        fi
      fi
      ;;
    lunch-out)
      # Skip unless there's exactly one open entry to close.
      if ! echo "$clock_entries" | jq -e \
            'length == 1 and .[0].end == null' >/dev/null; then
        should_skip=0
        local last_end count
        last_end=$(echo "$clock_entries" | jq -r \
          '[.[] | select(.end != null)] | last.end // empty')
        count=$(echo "$clock_entries" | jq 'length')
        if [[ -n "$last_end" ]]; then
          skip_kv="last_clocked_out_at=$(iso_to_local_hhmm "$last_end")"
        elif [[ "$count" == "0" ]]; then
          skip_kv="no_clock_in_yet=today"
        fi
      fi
      ;;
    lunch-in)
      # Skip unless there's exactly one closed entry whose end was within
      # the last 2h. The end-epoch is precomputed in BASH because jq's
      # `fromdateiso8601` only parses "…Z" form; BambooHR returns "+00:00"
      # — the old jq-only path silently treated the parse failure as
      # "ended at epoch 0", which would let lunch-in proceed and double-clock.
      local count last_end_iso last_end_epoch
      count=$(echo "$clock_entries" | jq 'length')
      last_end_iso=$(echo "$clock_entries" | jq -r '.[0].end // empty')
      last_end_epoch=0
      [[ -n "$last_end_iso" ]] && last_end_epoch=$(iso_to_epoch "$last_end_iso")

      local can_proceed=0
      if (( count == 1 )) && [[ -n "$last_end_iso" ]]; then
        local delta=$(( now_epoch - last_end_epoch ))
        if (( delta > 0 )) && (( delta <= 7200 )); then
          can_proceed=1
        fi
      fi

      if (( can_proceed == 0 )); then
        should_skip=0
        local open_start last_end
        open_start=$(echo "$clock_entries" | jq -r \
          '[.[] | select(.end == null)] | first.start // empty')
        last_end=$(echo "$clock_entries" | jq -r \
          '[.[] | select(.end != null)] | last.end // empty')
        if [[ -n "$open_start" ]]; then
          skip_kv="still_clocked_in_since=$(iso_to_local_hhmm "$open_start")"
        elif [[ "$count" -ge 2 ]]; then
          local latest_start
          latest_start=$(echo "$clock_entries" | jq -r '.[-1].start // empty')
          skip_kv="latest_session_started_at=$(iso_to_local_hhmm "$latest_start")"
        elif [[ -n "$last_end" ]]; then
          skip_kv="last_session_ended_at=$(iso_to_local_hhmm "$last_end")"
        elif [[ "$count" == "0" ]]; then
          skip_kv="no_clock_in_yet=today"
        fi
      fi
      ;;
    evening)
      # Skip unless at least one open entry exists to close.
      if ! echo "$clock_entries" | jq -e \
            'map(select(.end == null)) | length > 0' >/dev/null; then
        should_skip=0
        local last_end count
        last_end=$(echo "$clock_entries" | jq -r \
          '[.[] | select(.end != null)] | last.end // empty')
        count=$(echo "$clock_entries" | jq 'length')
        if [[ -n "$last_end" ]]; then
          skip_kv="last_clocked_out_at=$(iso_to_local_hhmm "$last_end")"
        elif [[ "$count" == "0" ]]; then
          skip_kv="no_clock_in_yet=today"
        fi
      fi
      ;;
    *)
      return 1
      ;;
  esac

  if (( should_skip == 0 )); then
    [[ -n "$skip_kv" ]] && echo "$skip_kv"
    return 0
  fi
  return 1
}

# --- Window helpers -------------------------------------------------------

# window_size_seconds — random sleep spread (window's end minus start) per
# phase. The script does NOT enforce that the clock event lands inside the
# absolute window; the launchd plist controls when this is invoked, and
# manual invocations are allowed at any time.
window_size_seconds() {
  : "${WINDOWS_CONF:?WINDOWS_CONF must be set}"
  local phase="$1"
  local line start end
  line=$(grep -E "^${phase}[[:space:]]" "$WINDOWS_CONF") \
    || { echo "rooster: no window for phase '$phase' in $WINDOWS_CONF" >&2; return 1; }
  read -r _ start end <<<"$line"
  echo $(( $(_hhmm_to_seconds "$end") - $(_hhmm_to_seconds "$start") ))
}

# BambooHR ISO 8601 timestamp → epoch (seconds). Handles both "…Z" and
# "+HH:MM" offsets, portably across GNU/BSD date. Returns "0" on parse
# failure — caller should treat 0 as "unknown / can't reason about time".
# jq's `fromdateiso8601` ONLY parses Z form, so we precompute in bash.
iso_to_epoch() {
  local iso="$1" e
  if date --version >/dev/null 2>&1; then
    e=$(date -d "$iso" +%s 2>/dev/null) || { echo "0"; return; }
  else
    local cleaned
    cleaned=$(echo "$iso" | sed -E 's/([+-][0-9]{2}):([0-9]{2})$/\1\2/' | sed 's/Z$/+0000/')
    e=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$cleaned" +%s 2>/dev/null) || { echo "0"; return; }
  fi
  echo "$e"
}

# BambooHR timestamps ("2026-05-22T07:15:00+00:00") → local "HH:MM".
# Returns the raw string on parse failure so the human log still says
# *something* informative.
iso_to_local_hhmm() {
  local iso="$1" e
  if date --version >/dev/null 2>&1; then
    e=$(date -d "$iso" +%s 2>/dev/null) || { echo "$iso"; return; }
    date -d "@$e" +%H:%M
  else
    # BSD date: strip the colon from ±HH:MM and rewrite Z → +0000.
    local cleaned
    cleaned=$(echo "$iso" | sed -E 's/([+-])([0-9]{2}):([0-9]{2})$/\1\2\3/' | sed 's/Z$/+0000/')
    e=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$cleaned" +%s 2>/dev/null) || { echo "$iso"; return; }
    date -r "$e" +%H:%M
  fi
}

_hhmm_to_seconds() {
  local hhmm="$1"
  local h="${hhmm%:*}"
  local m="${hhmm#*:}"
  echo $(( 10#$h * 3600 + 10#$m * 60 ))
}

# --- Skip-today file helpers ---------------------------------------------
#
# Returns 0 if SKIP_TODAY_FILE exists AND its mtime is today (local). When
# the file is left over from a previous day, the caller cleans it up.
skip_today_active() {
  [[ -f "$SKIP_TODAY_FILE" ]] || return 1
  local mtime_date today
  if date --version >/dev/null 2>&1; then
    mtime_date=$(date -r "$(stat -c %Y "$SKIP_TODAY_FILE")" +%F 2>/dev/null \
      || stat -c %y "$SKIP_TODAY_FILE" | cut -c1-10)
  else
    mtime_date=$(stat -f %Sm -t %Y-%m-%d "$SKIP_TODAY_FILE")
  fi
  today=$(date +%F)
  [[ "$mtime_date" == "$today" ]]
}

# --- Action-for-phase helper (used by DRY_RUN logging) -------------------
action_for_phase() {
  case "$1" in
    morning|lunch-in)  echo clock_in ;;
    lunch-out|evening) echo clock_out ;;
    *)                 echo unknown ;;
  esac
}
