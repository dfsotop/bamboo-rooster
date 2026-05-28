# Backfill — design plan (v3: additive mode)

A new schedulable mode that scans today + the past 6 days, fills any missing workday with a single clock-in/clock-out (no lunch), stops at the first day that already has an entry. **Strictly additive** — the existing four-phase live tracker stays, no migration is run, and the user explicitly chooses at install time which mode(s) they want.

---

## Decisions (locked in)

| # | Decision | Value |
|---|---|---|
| 1 | New mode positioning | **additive** — installs alongside the live tracker, not in place of it |
| 2 | Default scan fire window | **16:00 – 16:30** (Mon–Fri); scan INCLUDES today |
| 3 | Day cap | `BACKFILL_MAX_DAYS` in `.env`, default **7** |
| 4 | Manual `rooster backfill` | available regardless of scheduling state |
| 5 | Time-window source for filled entries | reuse existing `morning` + `evening` windows |
| 6 | Migration | **none** — user chooses what to enable; existing installs are untouched until the user explicitly toggles via update mode |

---

## Two independent modes

The installer treats each as a separate Y/N choice:

### Mode A — Live tracker (existing)
Schedules four phases through the day: morning clock-in, lunch-out, lunch-in, evening clock-out, each at a uniformly-random minute inside its configured window. Real-time tracking of the workday.

### Mode B — Daily backfill (new)
Schedules one daily sweep at 16:00 + random offset. Iterates `[today, today-1, …, today-(MAX_DAYS-1)]`, skips weekends and time-off days, stops on first existing entry, creates one entry per missing workday using random minutes from the `morning` and `evening` windows. No lunch.

**A user can enable A, B, both, or neither.** Both is harmless: backfill's "stop on existing entry" rule means it always defers to the live tracker on workdays where the user clocked normally; it only fills gaps.

---

## Behavior (mode B)

Fires once daily, Mon–Fri, at a uniformly-random minute inside the backfill window (default 16:00–16:30).

For each date in `[today, …, today-(BACKFILL_MAX_DAYS - 1)]`:

1. **Weekend filter** — Sat/Sun → skip + continue (no STOP).
2. **Time-off gate** — `/time_off/whos_out` for that date covers user (any approved type, including company holidays) → skip + continue.
3. **Idempotency gate** — `/time_tracking/timesheet_entries?employeeIds=me&start=DATE&end=DATE` has any entry → **STOP**.
4. **Fill** — random local HH:MM for clock-in inside `morning` window, random HH:MM for clock-out inside `evening` window; POST `clock_entries/store` with `{employeeId, date, start, end}` and no `id` (= create).

Optimization: fetch the whole 7-day `whos_out` once at the top, filter per day in bash. Reduces API cost from `2N` to `N+1`.

---

## Scheduler outputs

Existing `install/launchd.sh` and `install/systemd.sh` currently install one plist/timer per phase, iterating a hardcoded `morning lunch-out lunch-in evening` list. After this change:

- The list comes from **`windows.conf`** instead. Every non-comment line is a scheduled phase. Adding/removing a line in `windows.conf` directly controls which plists/timers exist.
- The scheduler installer additionally **boots-out + removes** any plist/timer for a phase NOT in the new `windows.conf`, so disabling a phase via update mode actually unloads it.

`windows.conf` shapes per mode:

```
# Mode A enabled:                # Mode B enabled:        # Both:
morning    08:30 09:30           morning    08:30 09:30   morning    08:30 09:30
lunch-out  12:45 13:15           evening    17:30 18:30   lunch-out  12:45 13:15
lunch-in   13:30 14:00           backfill   16:00 16:30   lunch-in   13:30 14:00
evening    17:30 18:30                                    evening    17:30 18:30
                                                          backfill   16:00 16:30
```

Note: when ONLY mode B is enabled, `morning` and `evening` lines are still written because backfill uses them as the random-minute source for the entries it creates. The `lunch-out` / `lunch-in` lines are only written when mode A is enabled. The `backfill` line is only written when mode B is enabled.

---

## UX — install prompts

### First-time install

After the existing subdomain / employee-id / TZ / DRY_RUN / API-key prompts:

```
The rooster has two scheduling modes — pick either, both, or neither.

(1) Live tracker: clocks in/out 4 times a day (morning, lunch break,
    evening) at randomized minutes inside the windows you configure.
    Real-time tracking.

    Enable live tracker? [Y/n] _

(2) Daily backfill: a single 16:00 sweep that scans the last 7 days,
    finds any workday with no entry, and adds one clock-in/clock-out
    (random morning/evening times, no lunch). Stops on the first
    already-filled day. Catch-up safety net.

    Enable daily backfill? [y/N] _
```

Defaults: live tracker **Y** (preserves the current fresh-install behavior), backfill **N**.

If both are N: warn the user (`⚠ No phases scheduled. Manual 'rooster <phase>' and 'rooster backfill' still work.`), proceed without installing any plist.

Then per-mode follow-up prompts only appear if that mode is enabled:
- Live tracker → existing morning/lunch/evening window prompts
- Backfill → `BACKFILL_MAX_DAYS` (default 7) + backfill window prompt (default 16:00 16:30)

### Update mode

When user picks "edit" in `setup.sh`'s existing-config menu:

```
Current scheduling: live tracker ENABLED, backfill DISABLED

Keep live tracker enabled? [Y/n] _
Enable daily backfill? [y/N] _
```

Defaults reflect the current state. Yes/no on each toggles independently. The wizard then walks through the relevant window prompts for any mode that's newly enabled or that the user chose to re-tune.

### No migration prompt

Existing four-phase users running the new `install.sh` see no special warning. If they pick "keep" in the update menu, nothing changes — their 4 plists stay, no backfill. If they pick "edit", they see the same toggles as above with the current state pre-selected; they can opt into backfill if they want.

---

## Configuration files

### `~/.bamboo-rooster/.env`

Add one optional field (only written when backfill is enabled):
```
BACKFILL_MAX_DAYS="7"
```

Unset → default to 7 at runtime. Existing `.env` files without this field keep working.

Other fields unchanged.

### `~/.bamboo-rooster/windows.conf`

Becomes the source of truth for which phases are scheduled. Lines vary by mode (see "Scheduler outputs" above).

### `config/config.example.env` and `config/windows.conf`

Updated to mention the new `BACKFILL_MAX_DAYS` field and the optional `backfill` window line.

---

## Manual invocation

```bash
rooster backfill [--max-days N] [--dry-run-only]
```

Always available, even when backfill isn't scheduled. Useful for "I forgot to clock yesterday, fix it now" one-shots. `--max-days N` overrides the env default (1–30 allowed). `--dry-run-only` forces dry-run regardless of `.env`.

---

## Implementation map

### New code

**`lib/bamboo.sh`** — create variant:
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

**`lib/gates.sh`** — date / window helpers:
```bash
bamboo_get_whos_out_range()      # date range version of current helper
date_is_weekend()                # Mon..Fri test
date_off_in_whos_out()           # lookup against cached range
date_has_timesheet_entry()       # idempotency check per date
random_hhmm_in_window()          # picks "HH:MM" string in window
iterate_dates_from_today()       # echo today, today-1, …, today-(N-1)
```

**`bin/rooster backfill`** — new subcommand:
- argv: `--max-days N`, `--dry-run-only`, `--help`
- if scheduled (no args + windows.conf has a `backfill` line): pick random sleep offset, sleep
- pre-fetch whos_out for the date range (one call)
- iterate dates, apply gates, fill or stop
- log events + final `backfill_complete` summary

**`install/launchd.sh` + `install/systemd.sh`** — generalize:
- read phases from `windows.conf` instead of hardcoding 4 names
- install a plist/timer per non-comment line
- compute set of "previously known" phases (morning, lunch-out, lunch-in, evening, backfill) and `bootout + rm` any that aren't in the current `windows.conf`
- this is the **only** mechanism that ever removes plists — no migration code path

**`install.sh`**:
- two new prompts in first-time setup: enable live tracker? enable backfill?
- conditionally write `lunch-out` / `lunch-in` lines (only if live tracker on)
- conditionally write `backfill` line (only if backfill on)
- conditionally prompt `BACKFILL_MAX_DAYS` (only if backfill on)
- update mode: two new toggles, defaults = current state, walk through window prompts only for modes being enabled

### Modified

- `bin/rooster --help` lists `backfill`
- `bin/rooster config` shows backfill window + MAX_DAYS if enabled
- `lib/log.sh::_emit_human` — new event verbs for `backfill_*`
- `README.md` / `docs/QUICKSTART.md` describe both modes side by side

### Unchanged

- `lib/auth.sh`, `lib/state.sh`, `lib/log.sh` core
- `bin/rotate-key`, `bin/rooster-status`, `bin/rooster --auth-check`, `rooster edit`, `rooster config`, `rooster update`
- All four phase code paths (`bin/rooster morning` etc.) — they keep working both as scheduled jobs (when mode A is on) and as manual one-shots (always).
- License, disclaimer, dependency gate, secret handling
- Existing 4-phase users who don't opt into anything see zero behavioral change

---

## Test plan

Wave 1 — pure logic:
- date iteration produces the right list for various MAX_DAYS values
- random HH:MM falls inside [start, end]
- `windows.conf`-driven plist install + boot-out: add/remove a line, see plist appear/disappear

Wave 2 — live API, `DRY_RUN=1`:
- today empty, yesterday empty, day-2 filled → 2 fills (today + yesterday), STOP
- today on PTO → skip; yesterday already filled → STOP
- entire 7-day window empty + no PTO → 5 weekday fills

Wave 3 — live API, `DRY_RUN=0`:
- Delete a known-empty past day in BambooHR's UI; trigger `rooster backfill`; verify single entry with realistic times

Wave 4 — install / mode toggles:
- Fresh install, both Y → 5 plists/timers
- Fresh install, only live tracker → 4 plists/timers
- Fresh install, only backfill → 1 plist/timer
- Fresh install, neither → 0 plists/timers + warning
- Existing 4-phase install, run update mode, toggle backfill ON → 5 plists/timers; OFF → back to 4
- Existing 4-phase install, run update mode, toggle live tracker OFF + backfill ON → 1 plist (backfill); the 4 old plists are gone

Wave 5 — manual override:
- `rooster backfill` works when only live tracker is scheduled (not auto-fired, but manually invocable)
- `rooster morning` still works when only backfill is scheduled

---

## Open question — last sanity check

When today simultaneously has an existing entry AND `whos_out` says the user is off (e.g. a half-day after sick leave), which gate wins?

- **Time-off first (proposed)**: skip + continue. Backfill stays out of contested days entirely; the next-day's scan will look further back.
- **Idempotency first**: STOP because an entry exists; backfill stops the scan even on a PTO day.

I lean **time-off first** — safer, doesn't second-guess HR. **OK to ship with that ordering?**

---

## Implementation order

If you green-light, ~3 focused hours:

1. **Probe `clock_entries/store` create** (no `id`). Confirm HTTP 201 + correct stored shape. (~5 min)
2. **`lib/bamboo.sh::bamboo_create_clock_entry`** + helpers in `lib/gates.sh`. (~30 min)
3. **`bin/rooster backfill`** subcommand, DRY_RUN end-to-end. (~45 min)
4. **`install/launchd.sh` + `install/systemd.sh`** — `windows.conf`-driven plist generation, boot-out for removed lines. (~30 min)
5. **`install.sh`** — two mode-toggle prompts in first-time + update modes, conditional window prompts, `BACKFILL_MAX_DAYS` handling. (~45 min)
6. **End-to-end live test** with `DRY_RUN=0` on a real missed day. (~15 min)
7. **README + QUICKSTART rewrite**: describe both modes, defaults, toggling. (~15 min)
