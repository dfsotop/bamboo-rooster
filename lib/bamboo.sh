# shellcheck shell=bash
# lib/bamboo.sh — high-level BambooHR endpoint wrappers.
# Every call routes through bamboo_request (lib/auth.sh) so 401/403
# detection and auth event logging are centralized.

# Resolve the API-key owner's employee ID. Cached in state.json after the
# first successful call so we don't pay the round-trip every phase.
bamboo_resolve_self_employee_id() {
  if [[ -n "${BAMBOOHR_EMPLOYEE_ID:-}" ]]; then
    echo "$BAMBOOHR_EMPLOYEE_ID"
    return 0
  fi
  local cached
  cached=$(state_get self_employee_id)
  if [[ -n "$cached" ]]; then
    echo "$cached"
    return 0
  fi
  local response id
  response=$(bamboo_request GET "/employees/0/?fields=id") || return 1
  id=$(echo "$response" | jq -r '.id // empty')
  if [[ -z "$id" ]]; then
    return 1
  fi
  state_set self_employee_id "$id"
  echo "$id"
}

# GET /time_off/whos_out for [today, today]. Echoes raw JSON array.
bamboo_get_whos_out_today() {
  local today="$1"
  bamboo_request GET "/time_off/whos_out?start=${today}&end=${today}"
}

# GET /time_tracking/timesheet_entries scoped to today + employee.
# Echoes raw JSON array. NOTE: the BambooHR parameter is `employeeIds`
# (plural, comma-separated). Singular `employeeId` is silently ignored
# and the API tries to return data for the union of all employees the
# token can see — which trips a 403 with a list of forbidden IDs.
bamboo_get_timesheet_today() {
  local employee_id="$1" today="$2"
  bamboo_request GET "/time_tracking/timesheet_entries?employeeIds=${employee_id}&start=${today}&end=${today}"
}

# POST /time_tracking/employees/{id}/clock_in with the supplied timestamp,
# defaulting to "now" in UTC. Pass an explicit clock_time to backdate or
# schedule into the window — BambooHR honours the clockInTime parameter.
bamboo_clock_in() {
  local employee_id="$1"
  local clock_time="${2:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  bamboo_request POST "/time_tracking/employees/${employee_id}/clock_in" \
    "{\"clockInTime\":\"${clock_time}\"}" >/dev/null
}

bamboo_clock_out() {
  local employee_id="$1"
  local clock_time="${2:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  bamboo_request POST "/time_tracking/employees/${employee_id}/clock_out" \
    "{\"clockOutTime\":\"${clock_time}\"}" >/dev/null
}

# Update a CLOSED clock entry. BambooHR requires both start and end as
# local HH:MM strings via /time_tracking/clock_entries/store. Open
# entries can't be updated through this path — the caller must close
# them first (clock_out or rooster lunch-out/evening).
#
# Args: id, employee_id, date (YYYY-MM-DD), start (HH:MM), end (HH:MM)
bamboo_update_clock_entry() {
  local id="$1" employee_id="$2" date="$3" start="$4" end="$5"
  bamboo_request POST "/time_tracking/clock_entries/store" \
    "{\"entries\":[{\"id\":${id},\"employeeId\":${employee_id},\"date\":\"${date}\",\"start\":\"${start}\",\"end\":\"${end}\"}]}" \
    >/dev/null
}
