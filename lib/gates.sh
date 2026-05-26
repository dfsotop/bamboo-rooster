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

  # Each phase has a tight "proceed" condition; skip is "anything else".
  # The function returns 0 when we should SKIP, 1 when we should proceed.
  case "$phase" in
    morning)
      # Proceed iff there are zero entries of ANY kind today. Manual "hour"
      # entries (entered via BambooHR's daily-hours UI rather than clock
      # punches) have type != "clock" but still mean "user already logged
      # time today" — skipping is correct.
      [[ "$(echo "$response" | jq 'length')" -ge 1 ]]
      ;;
    lunch-out)
      # Proceed iff there's exactly one open entry to close.
      ! echo "$clock_entries" | jq -e \
        'length == 1 and .[0].end == null' >/dev/null
      ;;
    lunch-in)
      # Proceed iff there's exactly one closed entry whose end was within
      # the last 2 hours — i.e., we genuinely just clocked out for lunch.
      # Excludes: 0 entries (no morning), >=2 entries (lunch-in already
      # happened), open entry (still on morning clock), closed entry that
      # ended too long ago (manual full-day entry, sick-day morning, etc.).
      ! echo "$clock_entries" | jq -e --argjson now "$now_epoch" '
        length == 1
        and .[0].end != null
        and (
          ($now - (.[0].end | fromdateiso8601? // 0)) > 0
          and ($now - (.[0].end | fromdateiso8601? // 0)) <= 7200
        )
      ' >/dev/null
      ;;
    evening)
      # Proceed iff at least one open entry exists to close.
      ! echo "$clock_entries" | jq -e \
        'map(select(.end == null)) | length > 0' >/dev/null
      ;;
    *)
      return 1
      ;;
  esac
}

# --- Window helpers -------------------------------------------------------

# Returns the window size in seconds for the given phase.
window_size_seconds() {
  : "${WINDOWS_CONF:?WINDOWS_CONF must be set}"
  local phase="$1"
  local line start end
  line=$(grep -E "^${phase}[[:space:]]" "$WINDOWS_CONF") \
    || { echo "rooster: no window for phase '$phase' in $WINDOWS_CONF" >&2; return 1; }
  read -r _ start end <<<"$line"
  echo $(( $(_hhmm_to_seconds "$end") - $(_hhmm_to_seconds "$start") ))
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
