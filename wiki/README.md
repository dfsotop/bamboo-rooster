# 🐓 Bamboo Rooster — Wiki

A personal automation that clocks me in and out of BambooHR every workday at a randomized minute, so my time-tracking entries are real but don't look mechanically robotic.

This folder is the project root. It contains:

```
bamboo-rooster/
├── bamboohr-mcp/    # upstream MCP clone — the BambooHR API surface for Claude
├── wiki/            # design docs (you are here)
│   ├── README.md    # the need + overview (this file)
│   ├── strategy.md  # candidate approaches, pros/cons, recommendation
│   └── decisions.md # ADR-style decisions as they get locked in
└── (future)         # scheduler, scripts, secrets template, etc.
```

---

## The Need

### Goal

For every working day, fire **four** randomized clock events:

| #   | Action              | Random window (local time)   | Notes                          |
| --- | ------------------- | ---------------------------- | ------------------------------ |
| 1   | Morning clock-in    | **08:30 – 09:30**            | Start of day                   |
| 2   | Lunch clock-out     | **12:45 – 13:15** *(within 12:45–14:00 lunch envelope)* | Pause for lunch    |
| 3   | Lunch clock-in      | **13:30 – 14:00** *(within 12:45–14:00 lunch envelope)* | Resume after lunch |
| 4   | Evening clock-out   | **17:30 – 18:30**            | End of day                     |

Each event picks a uniformly random minute inside its window, independently per day. All four are subject to the same workday and idempotency rules below — if today is a holiday or PTO day, *none* of them fire.

> The two lunch windows live inside a single **12:45–14:00 envelope**, split into a 30-min "out" half and a 30-min "in" half with a 15-min gap between them. That guarantees the break is at least 15 min and at most 75 min, averaging ~45 min. If the split needs to change (tighter break, wider break, no enforced gap), it's a config edit — not a code change.

### Why

- Manual clock-in/out is friction I forget. Forgetting it produces missing-timesheet emails and back-fill work for HR.
- Hardcoding the same time every day looks unnatural and defeats the purpose of clock-tracking.
- A small randomization spread feels human and avoids the "08:30:00 sharp" pattern that stands out in reports.

### Non-goals

- This is **not** a tool to fake hours I haven't worked. It's an automation that closes the visibility gap between *being at work* and *the BambooHR record showing it*. If I'm on PTO, sick, or skipping a day, the automation must respect that.
- Not building a multi-user product. This runs locally for one person (me).

---

## Workday Definition

A "workday" for this automation is:

| Condition                                         | Behavior     |
| ------------------------------------------------- | ------------ |
| Mon–Fri                                           | run          |
| Sat / Sun                                         | skip         |
| Public holiday returned by BambooHR `whos_out`    | skip         |
| **Approved PTO / vacation in BambooHR covering today** | **skip everything** — must be checked live against the API on every run, not just morning |
| **Sick leave logged in BambooHR for today** | **skip everything** — same live check; sick leave is just another time-off type, but it needs to be in the explicit allow-list of types we treat as "skip the rooster" |
| Already clocked in/out for that segment today (idempotency) | skip the redundant call |
| Manual override file present (e.g. `~/.bamboo-rooster/skip-today`) | skip both |

There is no local holiday list — BambooHR's `whos_out` is the single source of truth for both time-off and company holidays. If `whos_out` returns any entry covering today (PTO, sick, doctor, parental, *or* a company-wide holiday), the rooster bows out. Validated as part of the test plan; if `whos_out` turns out not to surface holidays, we add a local JSON fallback at that point.

---

## Constraints & Things to Honour

- **Do not double-clock.** If an entry already exists for today, the script must no-op. BambooHR will accept duplicate clock-ins and produce a mess.
- **Live BambooHR sync for time-off — vacation *and* sick leave.** Before *every* clock event (not just the morning one), call `GET /time_off/whos_out` (or `GET /time_off/requests` filtered to me + today + status `approved`) and skip if today is covered by **any** time-off type the user owns: vacation, personal, sick, doctor, bereavement, parental, etc. The mid-day check matters most for sick leave: if I wake up fine, the rooster clocks me in at 09:00, then I go home sick at 11:30 and HR enters sick leave for today, the lunch and evening events must notice the new entry and *not* clock me in/out for the rest of the day. Cache the result per-phase in `~/.bamboo-rooster/state.json` (TTL ≤ 30 min) so we don't hammer the API on normal workdays but always re-fetch close to firing time.
- **Geolocation.** BambooHR may enforce a location when clocking in. If so, set `BAMBOOHR_DEFAULT_LATITUDE` / `BAMBOOHR_DEFAULT_LONGITUDE` in the scheduler env. (To be confirmed by trying once and seeing if the API rejects without coords.)
- **Daylight Saving.** Schedule must run on **local wall-clock time** (Europe/Madrid). `launchd` and `cron` both honour the system TZ — fine on macOS as long as `TZ` isn't overridden in the job env.
- **Laptop sleep.** If the Mac is asleep at 08:30, `cron` silently misses the window. `launchd` with `StartCalendarInterval` re-fires on wake — preferred for that reason.
- **Secrets.** API key never goes into the repo. Either `~/.bamboo-rooster/.env` (chmod 600) or macOS Keychain. Decision pending in `decisions.md`.
- **Observability.** Each run should append to a local log file with timestamp, action, response status, and chosen random offset. If a run fails, I want to be able to see it — not silently miss days.

---

## High-Level Architecture (Sketch)

```
  Docker container (TZ=Europe/Madrid, crond -f as PID 1)
                ┌──────────────────────────────────┐
   crond     ──▶│  bin/rooster <phase>             │
   (08:30,      │   - is weekday + not a holiday?  │
    12:45,      │   - live BambooHR sync: any      │
    13:30,      │     approved time-off for me     │
    17:30)      │     today? (vacation, sick,      │
                │     doctor, parental…)           │
                │   - already clocked for this     │
                │     segment today?               │
                │   - sleep random offset          │
                │   - re-check time-off & state    │
                │   - call clock-in / -out         │
                │   - on 401/403: append            │
                │     auth_failure to log.jsonl     │
                │     (rate-limited 6 h)            │
                └──────────┬───────────────────────┘
                           │  HTTPS Basic Auth (api-key:x)
                           ▼
                  api.bamboohr.com

mounts: ~/.bamboo-rooster/{secrets/api-key, .env, state.json, log.jsonl}
```

The MCP (cloned in `bamboohr-mcp/`) is **not on this hot path** — it's the human-facing interface. Claude uses it when I want to ask "did I clock in today?" or "what's my timesheet for last week?". The unattended scheduler talks to BambooHR directly because it's simpler, has no Node/Claude runtime cost, and is easier to debug.

See [strategy.md](strategy.md) for the candidate approaches considered (launchd vs. cron vs. GitHub Actions vs. running the MCP unattended) and the recommended path.

---

## Status

- [x] MCP cloned, time-tracking tools located
- [x] Need + constraints written down
- [x] Strategy chosen — **`cron` + bash script in a Docker container**, TZ=Europe/Madrid (no agents, no MCP on the hot path). See [plan.md](plan.md).
- [x] Auth model chosen — BambooHR Basic Auth with personal API key. 401/403 → log + pause until user rotates the key file. OAuth2 deferred.
- [x] Holiday source chosen — `whos_out` only, no local JSON. Verification step in test plan §10.
- [x] No outbound notification channel in v1 — log-only. Android push is the v2 sink.
- [x] No geolocation. If BambooHR starts requiring it, we add coords then.
- [x] Lunch split locked — 12:45–13:15 / 13:30–14:00 (15-min minimum gap).
- [ ] Deployment target picked (deferred — laptop, home server, VPS, Android future).
- [ ] `lib/bamboo.sh` curl wrappers + smoke test against real API
- [ ] `whos_out` holiday return verified on a known Spanish holiday
- [ ] `lib/auth.sh` 401/403 detection + log-rate-limit
- [ ] `lib/gates.sh` whos_out parsing
- [ ] `bin/rooster` skeleton with `DRY_RUN=1`
- [ ] Dockerfile + compose.yaml, verify TZ + DST propagation
- [ ] First successful auto clock-in / clock-out
- [ ] Auth-failure path tested (one log line per cooldown, recovery line on first 2xx)
- [ ] Two weeks of stable runs before declaring done
