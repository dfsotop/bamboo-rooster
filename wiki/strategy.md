# Strategy — How to Build the Rooster

This page lays out the candidate approaches I considered, what each one buys/costs, and the recommended path. The goal is four randomized clock events per workday with a live BambooHR time-off sync, running unattended on my laptop.

---

## What every approach must do

Independent of the chosen runtime, each fired event runs the same checklist:

1. **Calendar gate** — is today Mon–Fri and not a configured public holiday?
2. **Time-off gate (live)** — query BambooHR's time-off API for me + today + status `approved`. Treat **all** time-off types as a skip signal: vacation, personal, sick leave, doctor's appointment, bereavement, parental, jury duty — anything the company has configured. The rooster doesn't try to distinguish "real day off" from "partial absence"; presence of any approved entry covering today is sufficient to bow out. If covered, exit.
3. **Idempotency gate** — read today's existing timesheet entries; if the segment we're about to write is already present, exit.
4. **Random delay** — pick a uniform random offset within the window (e.g. 0–3600 s for a 60-minute window), sleep for it.
5. **Re-check 2 + 3** — PTO could have been entered while we slept. Cheap insurance.
6. **Call BambooHR** — `POST /time_tracking/employees/{id}/clock_in` or `…/clock_out`, attaching geolocation if the company enforces it.
7. **Log** — append a structured line to `~/.bamboo-rooster/log.jsonl` with timestamp, event, outcome, status code.

---

## Candidate Approaches

### A. Local script + `launchd` (recommended)

A small executable (Go or Bash+curl or Node) installed as four `launchd` agents under `~/Library/LaunchAgents/`. Each agent's plist has `StartCalendarInterval` set to the *earliest* time of the window (08:30, 13:30, 14:30, 17:30) and `Weekday 1–5`. The script applies the random offset and the gates above.

**Pros**
- macOS-native, survives reboots, **re-fires when laptop wakes** if the scheduled time was missed (`StartCalendarInterval` semantics, unlike `cron`).
- No third-party runtime cost. No tokens. No network dependency for the scheduler itself.
- Trivially debuggable: `launchctl list | grep bamboo-rooster`, plus the local jsonl log.
- Secrets stay on-device (Keychain or a chmod 600 env file).

**Cons**
- Doesn't run when the laptop is off (vacation, weekend trips, etc.). Acceptable: those days I'm not working anyway.
- `launchd` plist ergonomics are clunky to write by hand (verbose XML).

**Implementation notes**
- One executable, four invocations with a `--phase=morning|lunch-out|lunch-in|evening` flag.
- Holiday list as a YAML/JSON file in `config/`, e.g. Spanish national + my autonomous community pulled once a year.

---

### B. Local script + `cron`

Same script, but scheduled via `crontab -e` with five-field expressions like `30 8 * * 1-5`.

**Pros**
- Familiar, one-line install.

**Cons**
- **No catch-up on wake.** If the Mac is asleep at 08:30, the entry simply never fires. Big problem for me — I lid-close the laptop overnight.
- macOS keeps deprecating cron in favour of launchd; relying on it is fighting the platform.

**Verdict:** rejected. The wake-up gap alone kills it.

---

### C. Run the cloned MCP unattended + Claude

Wire `bamboohr-mcp` into a Claude Code agent that runs on a `/schedule`-style cron, prompted with "clock me in/out, respecting PTO".

**Pros**
- Closes the loop: same MCP I use interactively also drives the automation. Single source of truth.
- Claude can handle the whole "is it a holiday, am I on PTO, did I already clock in" reasoning in one shot.

**Cons**
- Burns model tokens four times every workday for what is fundamentally an `if`-tree.
- Added failure modes: model latency, MCP startup, schedule reliability.
- Non-determinism — for a thing that books HR records I want the logic frozen, not LLM-synthesized each time.
- Harder to reason about idempotency when the actor is a model.

**Verdict:** rejected for the hot path. The MCP stays as the *interactive* surface — "Claude, did I clock in today?" — but doesn't run the automation.

---

### D. GitHub Actions cron

Push the script to a private repo and schedule it via `on: schedule: cron`.

**Pros**
- Runs even when laptop is off.
- Free for public/private repos within Actions minutes.

**Cons**
- API key sits in GitHub Secrets — fine but a wider blast radius than my disk.
- Geolocation is wrong (GitHub runners are in US-East). If BambooHR enforces geo, I'd be clocking in from Virginia, which is suspicious and possibly auto-flagged.
- Cron in Actions is UTC-only; DST in Europe/Madrid means I'd have to switch the schedule twice a year or do TZ math in the workflow.
- Latency between scheduled time and runner pickup is 0–15 min, on top of my own random delay — accuracy degrades.

**Verdict:** rejected. The geolocation problem alone is disqualifying if Bamboo enforces it; even if it doesn't, the optics are bad.

---

### E. Always-on small server (Fly.io / Raspberry Pi / home server)

A tiny daemon process running 24/7 that holds the schedule internally.

**Pros**
- No reliance on laptop being awake.
- Runs from a stable, "Spanish" IP if hosted appropriately (home server > Fly).

**Cons**
- New infra to own, monitor, secret-rotate.
- Overkill for one user clocking four events a day.

**Verdict:** rejected as over-engineering. Revisit only if (A) proves unreliable due to laptop-off days.

---

## Recommendation: Approach A (`launchd` + local script)

Concretely:

```
bamboo-rooster/
├── bamboohr-mcp/                   # cloned, unchanged — interactive use only
├── wiki/
├── cmd/rooster/                    # Go binary (matches my stack); or scripts/ for bash
│   └── main.go
├── config/
│   ├── config.example.yaml         # windows, holiday region, geo, log path
│   └── holidays-2026-es.json       # generated yearly
├── launchd/
│   ├── com.bamboo-rooster.morning.plist
│   ├── com.bamboo-rooster.lunch-out.plist
│   ├── com.bamboo-rooster.lunch-in.plist
│   └── com.bamboo-rooster.evening.plist
├── install.sh                      # symlinks plists into ~/Library/LaunchAgents and loads them
└── uninstall.sh
```

### Why Go for the binary

- Matches my day-to-day stack — I'll actually maintain it.
- One static binary, no runtime deps. Perfect for a tiny scheduled job.
- `time.Sleep`, `crypto/rand`, `net/http` with Basic Auth — standard library is enough.

### Phases

| Phase     | `launchd` fires at | Random window | Action       |
| --------- | ------------------ | ------------- | ------------ |
| morning   | 08:30 Mon–Fri      | 0–60 min      | clock_in     |
| lunch-out | 13:30 Mon–Fri      | 0–60 min      | clock_out    |
| lunch-in  | 14:30 Mon–Fri      | 0–60 min      | clock_in     |
| evening   | 17:30 Mon–Fri      | 0–60 min      | clock_out    |

> Note: lunch-out and lunch-in windows touch at 14:30. If we want a guaranteed minimum break length, shift `lunch-in` to start at 14:45 and accept that some days will only have a 15-minute lunch on paper. Decision deferred to `decisions.md`.

### Time-off check (the "sync with Bamboo" requirement)

Covers vacation, sick leave, and any other approved absence. Pseudocode that runs at the top of every phase, *and* again after the random sleep:

```go
today := time.Now().In(madrid).Format("2006-01-02")
out, _ := bamboo.GET("/time_off/whos_out", url.Values{
    "start": {today}, "end": {today},
})
for _, entry := range out {
    if entry.EmployeeId == self.Id {
        // Any time-off type for me today → skip. Don't filter by type;
        // sick leave, vacation, doctor, parental, bereavement all mean "no rooster today".
        log.Info("on approved time-off, skipping", "type", entry.Type, "name", entry.Name)
        return
    }
}
```

The `/whos_out` endpoint returns approved time-off and holidays the employee owns; it's the lowest-cardinality call. If `/whos_out` doesn't include sick leave for the requesting user (some BambooHR configs hide medical absence types from the directory view), fall back to `GET /time_off/requests?employeeId={me}&start={today}&end={today}&status=approved` — that endpoint sees everything, including categories that don't surface in the public "who's out" feed. **Verify which one returns sick leave for me before trusting the simpler call.**

Cache the result per-phase in `~/.bamboo-rooster/state.json` with a short TTL (≤ 30 min) so the four phases don't each pay a fresh API round-trip on normal workdays, but the cache expires fast enough that mid-day-entered sick leave is picked up by the next phase.

### Idempotency

Before each clock action, call `GET /time_tracking/timesheet_entries?employeeId={me}&start=today&end=today` and inspect the entries. Only proceed if the segment we're about to add isn't already there:

- morning: skip if any clock-in entry exists today
- lunch-out: skip if there's a clock-out timestamp after the morning clock-in
- lunch-in: skip if there's a clock-in entry after the lunch clock-out
- evening: skip if there's a clock-out entry after the lunch clock-in

This handles two failure cases cleanly:
- I clocked in manually from my phone → automation backs off.
- A previous run partially succeeded → next phase still runs correctly.

### Holiday list

Spanish national holidays + Madrid (or whichever region applies). Not derivable from BambooHR alone — *company* holidays might show in `whos_out`, but personal regional holidays might not. Pull from a public ICS feed yearly and bake into `config/holidays-<year>-es.json`. Refresh in December.

> **Open question:** does `bamboohr_get_whos_out` return the requesting employee's company-recognised holidays? If yes, we may be able to drop the local holiday list entirely. To verify in dev mode against a single test day.

### Logging & failure surfacing

- `~/.bamboo-rooster/log.jsonl` — append-only, one line per run (planned + actual outcome).
- On API error: write to log and post a macOS notification (`osascript -e 'display notification ...'`). I want to *know* the rooster missed.
- Weekly: a tiny `rooster status` command that summarizes the last 7 days from the log.

---

## Risks & Mitigations

| Risk                                         | Mitigation                                                        |
| -------------------------------------------- | ----------------------------------------------------------------- |
| Laptop closed at 08:30                       | `launchd` re-fires on wake; if window passed entirely, log + notify, manual catch-up |
| BambooHR enforces geolocation                | Set `BAMBOOHR_DEFAULT_LATITUDE/LONGITUDE` (office or home coords) |
| API key leaked via repo                      | Keychain or `~/.bamboo-rooster/.env` chmod 600; `.gitignore` everything sensitive |
| Holiday list goes stale                      | December reminder to regenerate; `rooster status` warns if config year ≠ current year |
| Network down at firing time                  | One in-process retry with backoff; on final failure log + notify, never silent |
| I wake up sick                               | Log sick leave in BambooHR (web/app) — every subsequent rooster phase reads the live time-off state and self-skips. As a belt-and-braces fallback when I can't reach Bamboo, `touch ~/.bamboo-rooster/skip-today` before the next phase fires; phases self-skip and the file is cleared at midnight. |
| BambooHR API silently changes shape          | Minimal parsing — only fields we need; integration smoke test once a week |

---

## Out-of-Scope (for v1)

- Auto-detecting "I'm working from home today vs office" and adjusting geo accordingly.
- Slack presence integration ("don't clock me in if I'm clearly still asleep at 09:25").
- Smart variance — making each day's offset depend on the previous day's so the sequence looks more "natural" than uniform random. Plain uniform is good enough.
- A web dashboard. The jsonl log + a status subcommand is enough for one user.

---

## Next Decision Points

Tracked in [decisions.md](decisions.md):

1. **Language**: Go (recommended) vs Bash+curl vs Node.
2. **Secrets storage**: macOS Keychain (`security` CLI) vs `.env` file.
3. **Lunch break minimum length**: touching windows (0+) vs enforced 15-min gap vs enforced 30-min gap.
4. **Holiday source**: local JSON vs trusting BambooHR's `whos_out` exclusively.
5. **Notifications**: macOS notification on every run, only on failure, or never (log only).
