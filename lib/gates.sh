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
    # so we don't accidentally clock in on a sick day. The phase will skip
    # with reason=time-off-or-holiday.
    log_event api_error "${PHASE:-unknown}" \
      endpoint=whos_out http_status="${BAMBOO_LAST_STATUS:-000}"
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

  local clock_entries
  clock_entries=$(echo "$response" | jq -c \
    'map(select((.type? // "") == "clock"))')

  local now_epoch
  now_epoch=$(date -u +%s)

  # Per-phase decision. When skipping, also echo ONE key=value pair that
  # the caller can hand to log_event so the human line can say *why* (e.g.
  # "already clocked in at 09:15" instead of just "already clocked").
  local should_skip=1   # 1 = proceed (default), 0 = skip
  local skip_kv=""

  case "$phase" in
    morning)
      # Skip iff any entry exists today (clock punch or hour entry).
      if [[ "$(echo "$response" | jq 'length')" -ge 1 ]]; then
        should_skip=0
        local first_start
        first_start=$(echo "$response" | jq -r '.[0].start // empty')
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
      # the last 2h — i.e., we genuinely just clocked out for lunch.
      if ! echo "$clock_entries" | jq -e --argjson now "$now_epoch" '
            length == 1
            and .[0].end != null
            and (
              ($now - (.[0].end | fromdateiso8601? // 0)) > 0
              and ($now - (.[0].end | fromdateiso8601? // 0)) <= 7200
            )
          ' >/dev/null; then
        should_skip=0
        local count open_start last_end
        count=$(echo "$clock_entries" | jq 'length')
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

# Window math is expressed in ABSOLUTE local-today epochs so that the
# target clock time is always inside the configured window — regardless
# of when the script was invoked. cron-fired at 08:30 and `rooster morning`
# manually fired at 10:30 both target the same 08:30–09:30 window;
# manual fires past the window backdate via clockInTime.

# Today's local-midnight as an epoch.
today_midnight_epoch() {
  local today; today=$(date +%F)
  if date --version >/dev/null 2>&1; then
    date -d "${today} 00:00:00" +%s
  else
    date -j -f "%Y-%m-%d %H:%M:%S" "${today} 00:00:00" +%s
  fi
}

# Returns "<start_epoch> <end_epoch>" for the phase's window today.
window_bounds_today() {
  : "${WINDOWS_CONF:?WINDOWS_CONF must be set}"
  local phase="$1"
  local line start end
  line=$(grep -E "^${phase}[[:space:]]" "$WINDOWS_CONF") \
    || { echo "rooster: no window for phase '$phase' in $WINDOWS_CONF" >&2; return 1; }
  read -r _ start end <<<"$line"
  local midnight; midnight=$(today_midnight_epoch)
  echo "$(( midnight + $(_hhmm_to_seconds "$start") )) $(( midnight + $(_hhmm_to_seconds "$end") ))"
}

# Window size in seconds — kept for diagnostics in log lines.
window_size_seconds() {
  local phase="$1"
  local bounds; bounds=$(window_bounds_today "$phase") || return 1
  local s e; read -r s e <<<"$bounds"
  echo $(( e - s ))
}

# Portable epoch → ISO 8601 UTC ("2026-05-26T08:53:14Z").
epoch_to_iso_utc() {
  local e="$1"
  if date --version >/dev/null 2>&1; then
    date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ
  else
    date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ
  fi
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
