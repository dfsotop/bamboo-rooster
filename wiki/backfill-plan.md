# Backfill — design plan

A new phase that fills in **past missing workdays** with a single clock-in / clock-out pair (no lunch). Runs once per day in the late afternoon, scans backward, stops at the first day that already has any timesheet entry, hard caps at 7 days. **Backwards compatible**: the existing 4 phases (morning, lunch-out, lunch-in, evening) keep working unchanged; backfill is a 5th phase added alongside.

---

## Goal

If a user forgot to clock-in/out yesterday (or for the last few days), have the rooster catch up automatically in the evening so HR's monthly export doesn't show holes. Without forging history if the user was actually off (PTO / sick / holiday).

---

## Behavior

Once per day, at a randomized minute inside a configured window (default **19:00 – 19:30** local). For each day in `[yesterday, yesterday-6]`:

1. **Date check** — skip Sat/Sun.
2. **Time-off gate** — call BambooHR `/time_off/whos_out` for the date. If the user is on PTO / sick / doctor / parental / company holiday for that day → **skip (continue to previous day)**.
3. **Idempotency gate** — call `/time_tracking/timesheet_entries?employeeIds=me&start=DATE&end=DATE`. If the response has **any** entry (clock or hour, by us or manual) → **STOP** the scan. We've caught up.
4. **Fill** — pick a random clock-in minute inside the configured morning window, a random clock-out minute inside the evening window, build one `clock_entries/store` payload with `{date, start (HH:MM), end (HH:MM), employeeId}` (no `id` field → create), POST.

Iteration order: yesterday → 2 days ago → … → 7 days ago. Stop on first idempotency hit or after 7 iterations. Total HTTP cost on a normal workday with yesterday already filled: 2 requests (whos_out + timesheet_entries for yesterday, hit, stop).

**No lunch break.** Each created day is a single clock entry from morning random minute to evening random minute. If the company's BambooHR config auto-deducts unpaid breaks, that handling is BambooHR-side; we just record start+end.

---

## Time selection — reuse the existing windows

The 4-phase rooster already has user-configured morning and evening windows in `~/.bamboo-rooster/windows.conf`. Backfill reuses them:

| Field | Source |
|---|---|
| backfilled clock-in time | random local minute in `morning` window (e.g. 08:45 from 08:45–09:30) |
| backfilled clock-out time | random local minute in `evening` window (e.g. 17:42 from 17:30–18:30) |
| **scan fire window** | new line in `windows.conf` → `backfill 19:00 19:30` |

A `backfill` window line is added during update / first-install when the feature is enabled. Existing installs without that line default to `19:00 – 19:30` if backfill is later enabled.

---

## Schedule

| Existing phases | Fire (Mon–Fri) |
|---|---|
| morning   | 08:30 + rnd |
| lunch-out | 12:45 + rnd |
| lunch-in  | 13:30 + rnd |
| evening   | 17:30 + rnd |
| **backfill (new)** | **19:00 + rnd**, Mon–Fri |

Fires AFTER the evening phase's latest possible clock-out (18:30), so today's entry is closed before the scan starts. (Scan ignores today anyway — yesterday is the most recent date inspected — but firing later is conceptually cleaner.)

---

## Gates — what backfill respects

| Gate | Behavior |
|---|---|
| `skip-today` flag (`~/.bamboo-rooster/skip-today`) | skip the entire scan today |
| Weekend (firing on Sat/Sun) | not scheduled — `1-5` weekday filter |
| `DRY_RUN=1` in `.env` | log what would be created, don't POST |
| For each candidate day — weekend | skip + continue |
| For each candidate day — `whos_out` covers it | skip + continue (don't forge a PTO day) |
| For each candidate day — already filled | **stop** (we've caught up) |

The "for each day" gates **never** cause the scan to stop early on PTO / holidays — only on actual existing timesheet entries. PTO days are skipped past, scanning continues backward.

---

## Configuration & UX

### First-time install

Add a step in `install.sh` first-time setup (after windows prompts):

```
Enable daily backfill? Fills missed workdays in the past 7 days,
  fires once daily after the evening phase. [y/N] _
```

Default **N** — opt-in keeps the existing behavior unchanged for users who don't ask. Choosing yes:
- Appends `backfill 19:00 19:30` to `windows.conf`
- Writes a 5th plist / timer for the `backfill` phase

### Update mode (`setup.sh` → edit, or `rooster update` after `BAMBOO_ROOSTER_UPDATE_MODE=1`)

If backfill isn't enabled yet → ask "Enable daily backfill? [y/N]".
If backfill IS enabled → ask "Disable daily backfill? [y/N]" + a "Change backfill fire window? [y/N]".

### Manual trigger

`rooster backfill` — runs the scan immediately, regardless of schedule. Useful for testing. Honours `DRY_RUN`. Output via the existing log_event pipeline plus terminal lines.

### Backfill subcommand `--help`

```
Usage: rooster backfill [--max-days N] [--dry-run-only]

Scan backwards from yesterday, fill any missing workday with a single
clock-in/clock-out at randomized minutes inside the morning and evening
windows. Stops on the first day that already has any timesheet entry,
or after --max-days (default 7).

--max-days N      Override the 7-day cap (1–30).
--dry-run-only    Force DRY_RUN behavior for this invocation regardless
                  of the .env setting.
```

---

## Backwards compatibility

| | |
|---|---|
| Existing 4 phases | unchanged in code, behavior, scheduling |
| Existing `windows.conf` (no backfill line) | still works; backfill is disabled if no `backfill` line AND no `bamboo-rooster.backfill` plist/timer is loaded |
| Existing `.env` | unchanged; no new required fields |
| `rooster --auth-check`, `rooster edit`, `rooster status`, `rooster config`, `rooster update` | unchanged |
| `uninstall.sh` | extends to also remove the backfill plist/timer if present (idempotent loop, just adds "backfill" to the list) |
| Re-running `setup.sh` on an existing install without enabling backfill | no behavior change |

In other words: if a user installs today and never explicitly enables backfill, their tool keeps behaving exactly like it does now.

---

## Implementation map

### New code

**`lib/bamboo.sh`**:
```bash
# Create a CLOSED clock entry (no `id` → create instead of update).
bamboo_create_clock_entry() {
  local employee_id="$1" date="$2" start="$3" end="$4"
  jq -nc \
    --argjson eid "$employee_id" \
    --arg date "$date" \
    --arg start "$start" \
    --arg end "$end" \
    '{entries:[{employeeId:$eid, date:$date, start:$start, end:$end}]}' \
  | bamboo_request_with_body POST "/time_tracking/clock_entries/store"
}
```

**`lib/gates.sh`** — helpers for the date loop:
```bash
# Range-aware version of the current `bamboo_get_whos_out_today`:
bamboo_get_whos_out_range() { bamboo_request GET "/time_off/whos_out?start=$1&end=$2"; }

# Returns 0 if employee X has any whos_out entry covering date D.
date_is_off() { local employee_id="$1" date="$2" cached_response="$3"; ... }

# Returns 0 if the timesheet has any entry on that date.
date_already_filled() { local employee_id="$1" date="$2"; ... }
```

**`bin/rooster`** — new subcommand `backfill`:
- argv parser for `--max-days`, `--dry-run-only`, `--help`
- random offset within `backfill` window from `windows.conf`
- iterate `iso_dates_back N` (helper), apply gates, fill or stop
- single jsonl summary event at the end: `backfill_complete days_filled=N days_scanned=M`

**`install/launchd.sh`**:
- `_write_plist backfill HH MM` for the 5th plist if `windows.conf` has a `backfill` line
- skip-otherwise

**`install/systemd.sh`**:
- `_write_units backfill HH MM` analogously

**`install.sh`**:
- first-time setup: add the "Enable backfill?" prompt + append line to `windows.conf` if yes
- update mode: add enable/disable + change-fire-window prompts
- after the existing windows write: check if `backfill` line exists; pass that to the scheduler installer to decide whether to write a 5th plist

**`uninstall.sh`** / `install/{launchd,systemd}.sh`:
- add `backfill` to the loop of unit names removed

### Modified

`config/windows.conf` (example, not user state):
```
# Optional 5th line — backfill scan fire window. Add by re-running
# install.sh and answering yes to the "Enable backfill?" prompt.
# backfill 19:00 19:30
```

(Comment-only by default; activated when enabled.)

`lib/log.sh::_emit_human` — add cases for new event types:
- `backfill_started` — `· [HH:MM:SS] backfill: scanning last N days`
- `backfill_filled` — `✓ [HH:MM:SS] backfill: filled YYYY-MM-DD (HH:MM – HH:MM)`
- `backfill_skipped` — `· [HH:MM:SS] backfill: YYYY-MM-DD off (PTO/holiday)`
- `backfill_stopped` — `· [HH:MM:SS] backfill: stopped at YYYY-MM-DD (already filled)`
- `backfill_complete` — `✓ [HH:MM:SS] backfill: 2 days filled, 5 days scanned`

### Things that DON'T change

- `lib/auth.sh`, `lib/state.sh`, `lib/log.sh` core, `bin/rotate-key`, `bin/rooster-status` (it will pick up the new event types automatically since it just tails the log).
- The four existing phases' code in `bin/rooster`. Their gates are unrelated to backfill.

---

## Test plan

Wave 1 — pure-logic, no network:
- iterate `iso_dates_back 7` produces `[yesterday, day-2, …, day-7]`
- weekend filter excludes Sat/Sun even on a Mon scan

Wave 2 — live API, `DRY_RUN=1`:
- yesterday has an entry → log `backfill_stopped`, exit
- yesterday empty, day-2 empty, day-3 has entry → log 2× `backfill_would_fill` (dry-run name), then `backfill_stopped`
- yesterday on approved PTO → log `backfill_skipped`, continue to day-2
- last 7 days entirely empty + no PTO → log `backfill_complete days_filled=5` (5 weekdays in a 7-day calendar window)

Wave 3 — live API, `DRY_RUN=0`, controlled date range (set up by clearing a known-empty day on a test BambooHR account if available; otherwise eyeball with a real day after deliberately not clocking):
- Real entry creation lands at the right minute, employee, no `id`
- HTTP 201 expected
- Verify entry shape via `rooster-status`

Wave 4 — install/uninstall idempotency:
- Fresh install + "no" to backfill prompt → only 4 plists, no `backfill.plist`
- Fresh install + "yes" → 5 plists
- Update mode toggle on / off → plist appears / disappears
- `uninstall.sh` removes all 5 (or however many are present)

---

## Open decisions — please pick

1. **Default for the "Enable backfill?" prompt** — `[y/N]` (opt-in, safer) or `[Y/n]` (opt-out, more useful by default)? I lean **opt-in**.
2. **Backfill scan fire window default** — `19:00 – 19:30`? Or earlier (closer to evening at 17:30–18:30)? `19:00` gives a safe ~30 min buffer after evening's latest fire.
3. **Cap** — 7 days, or expose `--max-days` AND make the default configurable in `.env` (e.g. `BACKFILL_MAX_DAYS=7`)?
4. **Manual `rooster backfill` should also be available without backfill being scheduled?** I'd say yes — handy for "I forgot to clock yesterday, fix it now" usage even if the user doesn't want the daily auto-scan.
5. **Time-window source for the created entries** — reuse `morning` + `evening` windows (proposed), or define separate `backfill-clock-in` / `backfill-clock-out` windows for users who want past days to look slightly different from today's randomized times?

---

## What I'd implement first

If you green-light the plan, sequence:

1. `lib/bamboo.sh::bamboo_create_clock_entry` + manual `curl` probe to confirm BambooHR accepts a no-`id` POST as a create. (5 min, low risk.)
2. `bin/rooster backfill --dry-run-only` against your account. Verify the date iteration + gates work. (~30 min.)
3. `install.sh` + platform installers add the optional 5th plist/timer with the "enable backfill?" prompt. (~45 min.)
4. End-to-end with `DRY_RUN=0` on a real missed day (manually skip a day on your timesheet to test). (~15 min.)
5. Document in QUICKSTART + README.

Total realistic effort: a focused half-day.
