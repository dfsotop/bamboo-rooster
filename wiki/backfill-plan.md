# Backfill — design plan (v2: backfill-only scheduler)

A pivot to a **single-fire daily scheduler** that scans backward through today + the past 6 days and creates one clock-in/clock-out entry for each missing workday. No lunch. Replaces the four-phase scheduler (morning / lunch-out / lunch-in / evening) as the **only** automated mode shipped by the installer.

The four-phase code stays in the codebase for manual use (`rooster morning`, etc.) but is no longer scheduled.

---

## Decisions (locked in)

| # | Decision | Value |
|---|---|---|
| 1 | Default mode | **backfill-only** — installer no longer schedules the 4 phases |
| 2 | Default scan fire window | **16:00 – 16:30** (Mon–Fri); scan INCLUDES today |
| 3 | Day cap | `BACKFILL_MAX_DAYS` in `.env`, default **7** |
| 4 | Manual `rooster backfill` | available regardless of scheduling |
| 5 | Time-window source for filled entries | reuse existing `morning` + `evening` windows |

---

## Behavior

Fires once daily, Mon–Fri, at a uniformly-random minute inside the backfill window (default 16:00–16:30).

Iteration order: `[today, yesterday, day-2, …, day-(BACKFILL_MAX_DAYS - 1)]`. For each date:

1. **Weekend filter** — if Saturday/Sunday, skip + continue (no STOP).
2. **Time-off gate** — call `/time_off/whos_out` for that date. If user is on any approved time-off (PTO, sick, doctor, parental, bereavement, or a company holiday entry), skip + continue.
3. **Idempotency gate** — call `/time_tracking/timesheet_entries?employeeIds=me&start=DATE&end=DATE`. If the response has **any** entry (clock or hour, open or closed, manual or scripted), **STOP**.
4. **Fill** — pick random local HH:MM for clock-in inside the `morning` window, random HH:MM for clock-out inside the `evening` window, build a `clock_entries/store` payload with `{employeeId, date, start, end}` (no `id` = create), POST.

Optimization: fetch the whole 7-day `whos_out` once at the top, filter per day in bash. Cuts API cost from `2N` to `N+1`.

**Real-world flow:**
- Normal day: user already clocked in (morning) and out (evening). At 16:00 backfill fires, sees today's open entry, STOPS. Cost: 1 API call.
- Today is fresh / forgot: backfill fires, today empty → fills with random 08:45–17:42 etc. Goes to yesterday → already filled → STOP. Cost: 3 calls (whos_out, today's timesheet, today's create, then yesterday's timesheet which hits, stop).
- Came back from vacation: today empty, yesterday on PTO (skip), 2 days ago on PTO, …, day-7 hits 7-day cap. Nothing illegitimate is filled — only honest empty workdays.

---

## Schedule

One launchd plist / systemd timer:

```
backfill   Mon–Fri at 16:00 + random 0-30 min
```

Replaces the four existing plists (`morning`, `lunch-out`, `lunch-in`, `evening`). The migration step in `install.sh` unloads any existing four-phase plists during the update.

---

## Configuration

### `~/.bamboo-rooster/.env`

New required field:
```
BACKFILL_MAX_DAYS="7"
```

(Existing fields — `BAMBOOHR_SUBDOMAIN`, `BAMBOOHR_EMPLOYEE_ID`, `TZ`, `DRY_RUN`, cooldowns — all kept unchanged.)

### `~/.bamboo-rooster/windows.conf`

```
morning    08:30 09:30
evening    17:30 18:30
backfill   16:00 16:30
```

The `lunch-out` and `lunch-in` lines are no longer written by the installer for new installs. **Existing installs upgrading**: the lines are left alone (no destructive edit) so manual `rooster lunch-out` still works for users who used to invoke them; only the launchd plists are removed.

### Manual invocation

```bash
rooster backfill [--max-days N] [--dry-run-only]
```

Same gate logic as scheduled, runs immediately. `--max-days N` overrides the env-var default (1–30 allowed). `--dry-run-only` forces dry-run for the invocation regardless of `.env`.

---

## Migration for existing users

When an existing 4-phase install runs the new `install.sh`:

1. **Detect** existing plists at `~/Library/LaunchAgents/com.bamboo-rooster.{morning,lunch-out,lunch-in,evening}.plist`.
2. Print a one-time migration notice:
   ```
   ⚠ Migrating from 4-phase scheduler to backfill-only mode.
     The morning / lunch-out / lunch-in / evening launchd jobs will be
     removed and replaced with a single daily backfill job.
     
     Your config and API key are preserved. The phase commands
     (rooster morning, etc.) remain available for manual use.
   ```
3. Ask explicit confirmation: `Proceed? [y/N]` — opt-in to the migration. Existing users get one chance to bail if they prefer the old behavior.
4. On yes: `launchctl bootout` + `rm` each of the four old plists, then install the new `bamboo-rooster.backfill` plist.
5. Append `BACKFILL_MAX_DAYS=7` to `.env` if not present.
6. Append `backfill 16:00 16:30` to `windows.conf` if not present.

Brand-new installs see no migration prompt — they just install the backfill scheduler from the start.

---

## What the four-phase code becomes

| | Before | After |
|---|---|---|
| `bin/rooster morning` (and lunch-out, lunch-in, evening) | scheduled + invokable | **invokable only** — kept for manual override / testing |
| `lib/gates.sh::already_clocked_for_phase` | used by phases | unchanged; phases that call it still work manually |
| `lib/log.sh::_emit_human` phase rendering | full | unchanged |
| Launchd / systemd plists for the 4 phases | shipped | **not shipped**; migration removes any existing ones |
| `install/launchd.sh` / `install/systemd.sh` | install 4 plists | install 1 plist (`backfill`) |

The four-phase code becomes "advanced manual mode" — useful if a user wants to test or run an individual phase by hand. Documented as such in the README.

---

## Implementation map

### New code

**`lib/bamboo.sh`** — add a create variant (no `id`):
```bash
bamboo_create_clock_entry() {
  local employee_id="$1" date="$2" start="$3" end="$4"
  local body
  body=$(jq -nc \
    --argjson eid "$employee_id" \
    --arg date "$date" \
    --arg start "$start" \
    --arg end "$end" \
    '{entries:[{employeeId:$eid, date:$date, start:$start, end:$end}]}')
  bamboo_request POST "/time_tracking/clock_entries/store" "$body" >/dev/null
}
```

**`lib/gates.sh`** — helpers for backfill:
```bash
bamboo_get_whos_out_range()    # date range
date_is_weekend()              # Mon..Fri test
date_off_in_whos_out()         # cached lookup
date_has_timesheet_entry()     # idempotency check
random_hhmm_in_window()        # picks "HH:MM" string in window
```

**`bin/rooster backfill`** — new subcommand:
- argv: `--max-days N` (1–30), `--dry-run-only`, `--help`
- read `BACKFILL_MAX_DAYS`, `morning`, `evening`, `backfill` windows
- when scheduled (no args): pick random offset in backfill window, sleep
- pre-fetch whos_out for the date range (one call)
- iterate dates today-back, apply gates, fill or stop, log per event
- final `backfill_complete` event with `days_filled` / `days_scanned` / `stopped_at`

**`install/launchd.sh`** — replace four `_write_plist` calls with one (`backfill`); add migration cleanup (`launchctl bootout` the four old labels if loaded).

**`install/systemd.sh`** — same for systemd: one unit + migration cleanup.

**`install.sh`**:
- migration detection + confirmation prompt
- prompt for `BACKFILL_MAX_DAYS` (default 7) in first-time + update modes
- prompt for `backfill` window (default `16:00 16:30`) in first-time + update modes
- write `BACKFILL_MAX_DAYS` to `.env`
- write `backfill` line to `windows.conf`
- drop the `lunch-out` / `lunch-in` lines from new installs' `windows.conf` writes

**`lib/log.sh::_emit_human`** — new event verbs:
- `backfill_started`: `· [HH:MM:SS] backfill: scanning 7 days back`
- `backfill_filled`: `✓ [HH:MM:SS] backfill: filled 2026-05-25 (08:47 – 17:53)`
- `backfill_skipped_offday`: `· [HH:MM:SS] backfill: 2026-05-22 off (PTO / sick / holiday)`
- `backfill_skipped_weekend`: `· [HH:MM:SS] backfill: 2026-05-23 weekend`
- `backfill_stopped`: `· [HH:MM:SS] backfill: stopped at 2026-05-24 (already filled)`
- `backfill_complete`: `✓ [HH:MM:SS] backfill: 2 days filled, 5 scanned, stopped at 2026-05-24`

### Modified

- `bin/rooster --help` lists `backfill`
- `config/config.example.env` adds `BACKFILL_MAX_DAYS="7"`
- `config/windows.conf` adds `backfill 16:00 16:30`, drops `lunch-out` / `lunch-in` from defaults
- README + QUICKSTART rewritten to describe the single-fire model
- `uninstall.sh` (via scheduler installers) tries to remove BOTH the new backfill unit AND the four legacy units, ignoring "not loaded" errors

### Unchanged

- `lib/auth.sh`, `lib/state.sh` core
- `bin/rotate-key`, `bin/rooster-status`, `bin/rooster --auth-check`, `rooster edit`, `rooster config`, `rooster update`
- The MIT license, disclaimer, API-key gate, dependency consent prompt
- The pre-install dependency check (jq still required)

---

## Test plan

Wave 1 — pure logic, no network:
- date iteration produces `[today, today-1, …, today-6]` for `MAX_DAYS=7`
- weekend filter excludes Sat/Sun in the middle of the range
- random HH:MM falls inside the [start, end] window

Wave 2 — live API, `DRY_RUN=1`:
- All 7 days empty + no PTO → would-fill 5 weekdays, 2 weekends skipped, no STOP
- Today already has an entry → STOP immediately, 0 filled
- Today empty, yesterday on PTO, day-2 already filled → 1 fill (today), 1 skip (PTO), STOP at day-2

Wave 3 — live API, `DRY_RUN=0`:
- Delete a known-empty past day in BambooHR's UI; verify backfill creates one entry with realistic random times
- Verify via `rooster-status` and BambooHR UI

Wave 4 — migration:
- On an install with 4 plists loaded, run new `install.sh`
- Answer "no" → migration aborts, 4 plists stay
- Answer "yes" → 4 plists unloaded + removed, 1 backfill plist loaded
- Re-run install.sh → no migration prompt (4 plists already gone), idempotent

Wave 5 — manual override:
- `rooster morning` (or lunch-out/lunch-in/evening) still works as one-shot command
- `rooster backfill` works without backfill being scheduled
- `rooster backfill --max-days 14 --dry-run-only` accepts the override

---

## Implementation order

If you green-light, sequence (focused half-day):

1. **Probe `clock_entries/store` create** — POST without `id`, confirm it returns `201` and stores a new entry on a known past day. (~5 min, may need to delete the entry afterward.)
2. **`lib/bamboo.sh::bamboo_create_clock_entry`** + helpers in `lib/gates.sh` for date iteration / windowed random / whos_out range. (~30 min.)
3. **`bin/rooster backfill`** subcommand end-to-end with `DRY_RUN=1`. Log events, terminal output. (~45 min.)
4. **`install/launchd.sh` + `install/systemd.sh`** — single plist generator, migration cleanup. (~30 min.)
5. **`install.sh`** — migration prompt, `BACKFILL_MAX_DAYS` + `backfill` window prompts, drop lunch-out/in from new windows.conf writes. (~30 min.)
6. **End-to-end live test** with `DRY_RUN=0` on a real missed day. (~15 min.)
7. **README + QUICKSTART rewrite**. (~15 min.)

Total: ~3 hours of focused work.

---

## Open question — one last sanity check

When today's `whos_out` says you're on PTO/sick and you ALSO have an existing entry already (e.g. you decided to come in for a half-day on a sick day): which gate wins?

Per the algorithm above: idempotency runs AFTER the time-off gate, so we'd SKIP for time-off and never see the existing entry. That feels right — backfill stays out of contested days entirely.

But if you want "any existing entry stops the scan, even on PTO days" (so that backfill doesn't silently keep going past a day where you ALSO have a real entry), the order can be swapped.

My read: time-off-first is safer (don't fabricate, don't second-guess HR), idempotency-second is fine for the rest. **OK to ship with time-off-first?**
