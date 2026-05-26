# Implementation Plan — cron + script in Docker

Decision: **`cron` + a single shell script, packaged as a Docker image**. No `launchd`, no Go binary, no Claude/MCP on the hot path. Four crontab lines, one script, four phases. Container runs `crond -f` as PID 1.

Why Docker: the rooster needs to be awake at four specific local-Madrid minutes every workday. A container running on an always-on host (home server, NAS, tiny VPS) sidesteps the laptop-sleep problem that killed plain host-cron in the strategy doc. It also makes the API key + state easy to keep off my dev laptop and version-pinned via image tags.

---

## 1. Repo layout (target)

```
bamboo-rooster/
├── bamboohr-mcp/                 # cloned, unchanged — interactive use only
├── wiki/                         # docs (you are here)
├── bin/
│   ├── rooster                   # the only script. takes one arg: phase
│   └── rooster-status            # prints last 7 days, flags missed phases
├── lib/
│   ├── bamboo.sh                 # curl wrappers: get_whos_out, get_timesheet, clock_in, clock_out
│   ├── gates.sh                  # is_weekday, is_on_time_off, already_clocked
│   ├── auth.sh                   # 401/403 detection, log-rate-limit, recovery marker
│   └── log.sh                    # jsonl logger (the only "notification" surface in v1)
├── config/
│   ├── config.example.env        # template — populated as a .env file the container reads
│   └── windows.conf              # phase → "HH:MM HH:MM" window definitions
├── docker/
│   ├── Dockerfile                # alpine + bash + curl + jq + tzdata + busybox crond
│   ├── crontab                   # the four cron lines, baked into the image
│   └── entrypoint.sh             # validates env, fixes /etc/crontabs, exec crond -f
├── compose.yaml                  # one-service compose file with mounts + env
├── .gitignore                    # ignores secrets, state, logs
└── README.md                     # quickstart pointer to wiki/
```

State + secrets live **outside** the image, in volumes mounted into the container:

```
host: ~/.bamboo-rooster/                 →  container: /var/lib/rooster/
├── secrets/
│   └── api-key                          # the BambooHR API key, single line, chmod 600
├── state.json                           # whos_out cache, last-401 timestamp, employee-id cache
├── log.jsonl                            # append-only, one event per line
└── skip-today                           # touch to bow out for today (auto-cleared at midnight)
```

The script reads `secrets/api-key` from disk on **every invocation** — so rotating the key doesn't need a container restart.

---

## 2. Crontab entries

`docker/crontab` (baked into the image, used by busybox `crond`):

```cron
# bamboo-rooster — randomized BambooHR clock events, Mon–Fri.
# Each line fires at the EARLIEST minute of its window; the script picks a
# random offset within that window's size, then sleeps and acts.
# Times below are LOCAL — the container runs with TZ=Europe/Madrid so
# crond honours wall-clock time across DST transitions automatically.
30 8  * * 1-5 /opt/rooster/bin/rooster morning   >> /var/lib/rooster/cron.err 2>&1
45 12 * * 1-5 /opt/rooster/bin/rooster lunch-out >> /var/lib/rooster/cron.err 2>&1
30 13 * * 1-5 /opt/rooster/bin/rooster lunch-in  >> /var/lib/rooster/cron.err 2>&1
30 17 * * 1-5 /opt/rooster/bin/rooster evening   >> /var/lib/rooster/cron.err 2>&1
```

Per phase the script picks a uniform random offset in `[0, window_size_seconds)`:

| Phase     | Cron fires | Window           | Random offset range |
| --------- | ---------- | ---------------- | ------------------- |
| morning   | 08:30      | 08:30 – 09:30    | 0 – 3600 s          |
| lunch-out | 12:45      | 12:45 – 13:15    | 0 – 1800 s          |
| lunch-in  | 13:30      | 13:30 – 14:00    | 0 – 1800 s          |
| evening   | 17:30      | 17:30 – 18:30    | 0 – 3600 s          |

The 12:45 and 13:30 cron triggers leave a guaranteed 15-min gap between the latest possible clock-out (13:15) and the earliest possible clock-in (13:30) — the lunch break is always at least 15 min.

**Container-specific gotchas** (handled in `entrypoint.sh`):

- `crond` runs with a minimal `PATH`. The script exports its own `PATH` and uses absolute paths to `curl`, `jq`, `date`.
- The image installs `tzdata` and the entrypoint sets `/etc/localtime` from `$TZ` so `date`, `crond`, and `sleep` all see Europe/Madrid.
- Logs go to a host-mounted volume (not the container layer) so they survive image updates.
- Container restart policy: `unless-stopped` in compose. `crond -f` is PID 1; if it dies, the container exits and Docker restarts it.

---

## 3. Script logic — `bin/rooster <phase>`

Single file, sourcing the helpers in `lib/`. Pseudocode:

```bash
#!/usr/bin/env bash
set -euo pipefail
PHASE="$1"   # morning | lunch-out | lunch-in | evening
source ~/.bamboo-rooster/config.env
source "$ROOT/lib/bamboo.sh"
source "$ROOT/lib/gates.sh"
source "$ROOT/lib/log.sh"

today=$(date +%F)

# --- Gate 1: manual override ----------------------------------------------
if [[ -f ~/.bamboo-rooster/skip-today ]]; then
  log skipped "$PHASE" reason=manual-override; exit 0
fi

# --- Gate 2: weekday ------------------------------------------------------
is_weekday "$today" || { log skipped "$PHASE" reason=weekend; exit 0; }

# --- Gate 3: live BambooHR — holidays + time-off in one call --------------
# whos_out covers PTO, sick leave, doctor, parental, AND company holidays.
# Single source of truth → one API call answers "should I bow out today?".
if is_on_time_off_or_holiday "$today"; then
  log skipped "$PHASE" reason=time-off-or-holiday; exit 0
fi

# --- Gate 4: idempotency (already clocked for this segment?) --------------
if already_clocked "$PHASE" "$today"; then
  log skipped "$PHASE" reason=already-clocked; exit 0
fi

# --- Random delay within the phase window ---------------------------------
window_seconds=$(window_size_for "$PHASE")     # default 3600
offset=$(( RANDOM % window_seconds ))
log planned "$PHASE" offset_seconds="$offset"
sleep "$offset"

# --- Re-check gates 3 + 4 (sick leave may have been entered while sleeping)
if is_on_time_off_or_holiday "$today"; then
  log skipped "$PHASE" reason=time-off-or-holiday-post-sleep; exit 0
fi
if already_clocked "$PHASE" "$today"; then
  log skipped "$PHASE" reason=already-clocked-post-sleep; exit 0
fi

# --- Fire the action ------------------------------------------------------
# auth.sh wraps the call: 401/403 → log auth_failure (rate-limited),
# any other non-2xx → log failed. No external notifier in v1.
case "$PHASE" in
  morning|lunch-in)   bamboo_clock_in  || exit 1 ;;
  lunch-out|evening)  bamboo_clock_out || exit 1 ;;
esac
log success "$PHASE"
```

### `lib/bamboo.sh` — the curl wrappers

Endpoints (all under `https://api.bamboohr.com/api/gateway.php/{subdomain}/v1/`):

| Function          | HTTP                                                                                      |
| ----------------- | ----------------------------------------------------------------------------------------- |
| `whos_out_today`  | `GET /time_off/whos_out?start={today}&end={today}`                                        |
| `time_off_today`  | `GET /time_off/requests?employeeId={me}&start={today}&end={today}&status=approved` (fallback if `whos_out` doesn't include sick leave) |
| `timesheet_today` | `GET /time_tracking/timesheet_entries?employeeId={me}&start={today}&end={today}`          |
| `clock_in`        | `POST /time_tracking/employees/{me}/clock_in`  with optional `latitude`/`longitude`/`note` |
| `clock_out`       | `POST /time_tracking/employees/{me}/clock_out` with optional `latitude`/`longitude`       |

Auth: HTTP Basic Auth, username = API key, password = literal `x` (BambooHR convention). All calls send `Accept: application/json`. `jq` parses responses.

### `lib/gates.sh` — the predicates

- `is_weekday DATE` → exit 0 if Mon–Fri (`date -j -f %F "$1" +%u` returns 1–5).
- `is_on_time_off_or_holiday DATE` → calls `whos_out_today`, parses with `jq`, returns 0 if the response contains either:
  - an entry with `employeeId == self` (PTO, sick leave, doctor, parental — anything in my time-off ledger), or
  - a company-wide holiday entry covering `$1` (typically returned without an `employeeId` or with type `holiday`).

  Caches the negative result for 30 min in `state.json` keyed by date so the four phases don't each hit the API on a normal workday, but the cache expires fast enough to pick up mid-day-entered sick leave.
- `already_clocked PHASE DATE` → calls `timesheet_today`, parses entries by timestamp, applies the per-phase rule:
  - `morning`: any clock-in entry today → already clocked
  - `lunch-out`: a clock-out entry exists *after* the last clock-in → already clocked
  - `lunch-in`: a clock-in entry exists *after* the last clock-out → already clocked
  - `evening`: a clock-out entry exists *after* the last clock-in (any time after 13:30) → already clocked

---

## 4. Config

### `~/.bamboo-rooster/.env` on the host (mounted as `/var/lib/rooster/.env`, chmod 600)

```sh
# --- BambooHR ---
BAMBOOHR_SUBDOMAIN="your-company-subdomain"  # the prefix in <x>.bamboohr.com
BAMBOOHR_EMPLOYEE_ID=""                # leave empty → resolved on first run via /employees/0/?fields=id and cached in state.json

# --- Rooster ---
ROOSTER_TZ="Europe/Madrid"             # ALSO passed to the container as TZ env var
ROOSTER_LOG_FILE="/var/lib/rooster/log.jsonl"
ROOSTER_AUTH_FAIL_LOG_COOLDOWN_HOURS="6"   # rate-limit duplicate auth_failure log lines (not user-facing alerts)
```

No `BAMBOOHR_DEFAULT_LATITUDE/LONGITUDE` — geolocation is intentionally not set. If BambooHR ever starts enforcing it on this account, the calls will start 4xx-ing and we'll add coords then.

No `NOTIFY_*` — v1 is log-only (see §8).

The API key itself lives in a separate file, `~/.bamboo-rooster/secrets/api-key`, NOT in the .env. Rationale: the .env is loaded into the shell environment of every cron run and ends up in `/proc/<pid>/environ`. Keeping the key in a dedicated file that the script `cat`s on demand minimizes that surface.

### `config/windows.conf` (in repo)

```
morning    08:30 09:30
lunch-out  12:45 13:15
lunch-in   13:30 14:00
evening    17:30 18:30
```

Script reads the line for its phase, computes `(end - start)` in seconds, picks `RANDOM % size` as the offset.

### Holidays — single source of truth: `whos_out`

There is **no local holiday JSON file**. Holidays are detected the same way as PTO and sick leave: a `GET /time_off/whos_out?start={today}&end={today}` call. If BambooHR returns a holiday entry covering today (with or without an `employeeId`-attached entry — company-wide holidays sometimes appear as bare entries), the rooster skips.

The verification step in §10 confirms `whos_out` actually returns the user's company-recognised holidays before going live. If it turns out it doesn't, the fallback is to add a local `holidays-<year>-es.json` then — but we don't pay that maintenance cost up-front.

---

## 5. Logging & failure surfacing

`log.jsonl` lines look like:

```json
{"ts":"2026-05-08T08:47:13+02:00","ts_utc":"2026-05-08T06:47:13Z","phase":"morning","event":"planned","offset_seconds":1023}
{"ts":"2026-05-08T09:04:16+02:00","ts_utc":"2026-05-08T07:04:16Z","phase":"morning","event":"success","clock_in_id":"4521-2026-05-08-1"}
{"ts":"2026-05-08T13:38:02+02:00","ts_utc":"2026-05-08T11:38:02Z","phase":"lunch-out","event":"skipped","reason":"time-off"}
{"ts":"2026-05-08T17:42:09+02:00","ts_utc":"2026-05-08T15:42:09Z","phase":"evening","event":"auth_failure","http_status":401}
```

Every line carries **both** local and UTC timestamps. UTC is canonical for any aggregation; local is for human reading.

Failures fire an outbound notification via the configured channel (Slack webhook by default, see §6). `bin/rooster-status` prints the last 7 days from the log and flags missed phases (a workday with no `success` or `skipped` line for `morning`, etc.) — that's our missed-fire detector when the host or container was down.

---

## 6. Time zones — UTC+1 winter / UTC+2 summer, DST handled automatically

Spain switches between **UTC+1 (CET, winter)** and **UTC+2 (CEST, summer)** on the last Sunday of March and October. We handle both by setting `TZ=Europe/Madrid` in the container and pinning `tzdata` in the image — busybox `crond`, `date`, and `sleep` all honour `TZ`, and the kernel switches DST without us writing a line of code.

Equivalently: cron expressions are wall-clock Madrid time; "08:30 Mon–Fri" is 06:30 UTC in summer and 07:30 UTC in winter, automatically.

What "UTC sensitive" means in practice:

1. **Cron schedule is local time** because that's what the windows are expressed in. The kernel handles DST. We do **not** try to maintain two crontab files (winter/summer) — that's where DST bugs live.
2. **Every log line carries a UTC timestamp** alongside the local one (see §5). UTC is the canonical timeline for the jsonl log; aggregations and "did I miss yesterday's morning fire?" queries should always be done in UTC.
3. **State file dates are local** (`today` = "what BambooHR considers today" = Madrid local). BambooHR's clock_in/out endpoints accept ISO-8601 with explicit offset, and we send Madrid-local with `+02:00` / `+01:00` so there's no ambiguity on their side.
4. **Idempotency keys in `state.json` use the local date** (`2026-05-08`), not UTC, so a phase that fires at 23:55 CEST doesn't accidentally compare against the wrong day.
5. **The Dockerfile pins `tzdata`** so the container's view of DST is consistent regardless of host kernel.

Verification check (run after first deploy): `docker exec rooster date` and `docker exec rooster date -u` should differ by exactly 1 h (winter) or 2 h (summer). If they don't, `TZ` isn't propagating.

---

## 7. Authentication & the "API key broke" flow

### What BambooHR uses

Standard BambooHR API endpoints — including the time-tracking ones the MCP and this rooster use — authenticate with **HTTP Basic Auth**:

```
Authorization: Basic base64(<api-key>:x)
```

The username is the API key string, the password is literally the letter `x`. There is no token refresh. Personal API keys **do not auto-expire on a timer**, but they *do* break in three real ways:

1. The user revokes/regenerates the key in BambooHR (deliberate rotation).
2. An admin disables or downgrades the user's account.
3. BambooHR invalidates keys during a security incident.

All three surface identically: the next API call returns **HTTP 401** (or **403** for permission-shaped failures). That's the trigger we hook on.

### Detection

`lib/auth.sh` wraps every `curl` call to BambooHR. If the response status is 401 or 403:

1. Read `state.json` → `last_auth_failure_log_ts`. If unset or older than `ROOSTER_AUTH_FAIL_LOG_COOLDOWN_HOURS` (default 6 h), append a `{"event":"auth_failure","http_status":...}` line to `log.jsonl` and update the timestamp. Within the cooldown, the failure is suppressed from the log to keep it readable — `cron.err` still captures the raw curl exit per phase, so nothing is truly lost.
2. Exit non-zero. The phase aborts.

There is **no external notification channel in v1.** The user discovers the failure by checking `log.jsonl` (or, eventually, via the Android push path — see §8).

### Recovery (the "user logs in manually" path)

There is no OAuth flow for the standard API — "logging in manually" here means **the user generates a new API key in BambooHR's web UI and updates a single file on the host**. Concretely:

1. The user notices an `auth_failure` line in `log.jsonl` (or HR pings them — yes, this is the trade-off).
2. They generate a new key at `https://<subdomain>.bamboohr.com/settings/api.php`.
3. They update the file:
   ```
   echo -n '<new-key>' > ~/.bamboo-rooster/secrets/api-key && chmod 600 ~/.bamboo-rooster/secrets/api-key
   ```
   Or interactively: `docker exec -it rooster rotate-key` (no echo, validates the new key with one read-only call before saving).
4. The script reads the key from disk on every cron invocation, so **no container restart is needed** — the next phase that fires picks up the new key.
5. On the first successful call after an `auth_failure`, `lib/auth.sh` sees `last_auth_failure_log_ts` is set, appends one `{"event":"auth_recovered"}` line to the log, and clears the timestamp.

### `rotate-key` helper (inside the container)

A tiny convenience script for when the user prefers an interactive flow:

```sh
docker exec -it rooster rotate-key
# prompts for the new key on stdin (no echo), writes to /var/lib/rooster/secrets/api-key,
# then runs `bin/rooster --auth-check` which calls /employees/0/?fields=id once;
# prints "✓ key works" or "✗ still 401" without writing a real clock event.
```

### Future path: OAuth2

BambooHR also supports OAuth2 for SSO/integration apps, with refresh tokens and proper expiring access tokens. If we ever swap to that:

- Add `BAMBOOHR_OAUTH_REFRESH_TOKEN` to the secrets file.
- `lib/auth.sh` grows a `refresh_access_token()` that exchanges the refresh token for a new access token before calls when the cached one is within 5 min of expiry.
- 401 detection still triggers the user-facing notification, but only after a refresh attempt also fails (the access-token-expired case becomes invisible to the user; only refresh-token death surfaces).

Out of scope for v1. Listed here so we know where to plug it in later without re-architecting.

---

## 8. Notifications — log-only in v1, push in v2

**v1 has no outbound notification channel.** Every event — success, skip, auth failure, network failure, recovery — appends a structured line to `log.jsonl`. That's it. The user reads the log when they need to.

Trade-off accepted: when the API key dies, the rooster goes silent until the user notices (worst case: HR asks about a missing timesheet). That's fine for now and dramatically simplifies v1 (no Slack webhook to provision, no SMTP creds to manage, no per-channel auth to debug).

**v2 (Android target):** when the rooster runs on Android (Termux + cron, or a native app with WorkManager), the same `auth_failure` / `auth_recovered` events become OS push notifications via `NotificationManager`. The event taxonomy stays identical; only the sink changes. Keeping the log as the canonical event stream means the v1→v2 migration is "tail the log, fire a push for these event types" — no rework of the gating logic.

Event taxonomy (logged today, push-eligible tomorrow):

| Event             | When                                              | v1: log | v2: push |
| ----------------- | ------------------------------------------------- | ------- | -------- |
| `success`         | clock action returned 2xx                          | ✓       |          |
| `skipped`         | gate decided not to act (with `reason`)           | ✓       |          |
| `auth_failure`    | HTTP 401/403 (rate-limited 6 h)                   | ✓       | ✓        |
| `auth_recovered`  | first 2xx after a logged auth_failure             | ✓       | ✓        |
| `network_failure` | other non-2xx after one retry                     | ✓       | ✓        |

---

## 9. Install / uninstall

`install.sh` (run on the Docker host):
1. Verify `docker` and `docker compose` are available.
2. `mkdir -p ~/.bamboo-rooster/secrets && chmod 700 ~/.bamboo-rooster ~/.bamboo-rooster/secrets`.
3. If `~/.bamboo-rooster/.env` doesn't exist, copy `config/config.example.env` there and `chmod 600`. Print "fill in your subdomain, region, and notification channel, then run install.sh again."
4. If `~/.bamboo-rooster/secrets/api-key` doesn't exist, prompt for it (no echo), write it, `chmod 600`. Print where to regenerate it later.
5. `docker compose up -d --build`.
6. Tail `docker compose logs -f` for 5 s, confirm `crond` is running.
7. Run a one-off auth check inside the container: `docker compose exec rooster bin/rooster --auth-check`. If 401, abort with the rotation instructions.

`uninstall.sh`:
1. `docker compose down`.
2. Optionally remove the image (`docker rmi bamboo-rooster`).
3. Leave `~/.bamboo-rooster/` untouched (logs and config are useful even after uninstall).

---

## 10. Test plan

Before turning on real cron entries:

1. **Unit-ish**: invoke `bin/rooster morning` from the terminal with a `DRY_RUN=1` env that short-circuits all `client.post` calls. Confirm gates fire as expected on:
   - a Saturday (skip: weekend)
   - a known holiday from `holidays-2026-es.json` (skip: holiday)
   - a day with a fake `whos_out` API stub returning my employee ID (skip: time-off)
2. **Integration**: real API, `DRY_RUN=0`, run `bin/rooster morning` once at the terminal. Confirm:
   - response 200
   - `bamboohr_get_timesheet_entries` shows the new clock-in
   - re-running the same command gates on `already-clocked`
3. **Sick-leave path**: log a sick-leave entry in BambooHR for today, then run `bin/rooster lunch-out`. Must skip with `reason=time-off`.
4. **Cron wiring**: add a temporary 5th crontab line firing every minute, confirm it runs and logs. Remove it.
5. **Auth-failure path**: temporarily corrupt the API key file, run `bin/rooster morning`, expect 401 → one `auth_failure` line in the log → `state.json` updated. Re-run within the 6 h cooldown → no second `auth_failure` line. Restore key, run again → `success` + `auth_recovered` line, timestamp cleared.
5a. **`whos_out` holiday verification**: pick a known upcoming Spanish holiday (e.g. 2026-12-25). On the day before, manually call `whos_out` for that date and inspect the response. If a holiday entry is returned for me, we're done. If not, add a fallback local JSON before going live — the holiday safety net is non-negotiable.
6. **DST sanity**: spoof the container TZ ahead by 6 months (`docker run -e TZ=...`), confirm `date` and crond show the correct local time.
7. **Soft launch**: deploy the container for one day, manually inspect `log.jsonl` and the BambooHR timesheet at end-of-day. Iterate.
8. **Two-week soak**: declare done when 10 working days have passed with no missed phases and no manual interventions.

---

## 11. Implementation order

1. `lib/bamboo.sh` + manual smoke test against real API (read-only calls only). ← lowest risk, highest learning. Crucial verification: does `whos_out` return company holidays for me?
2. `lib/auth.sh` 401/403 detection wrapper + `lib/log.sh` jsonl writer.
3. `lib/gates.sh` with `whos_out` parsing (PTO + sick + holidays in one pass).
4. `bin/rooster` skeleton with `DRY_RUN=1` always on.
5. `bin/rooster-status` + `rotate-key` helper.
6. `docker/Dockerfile` + `docker/entrypoint.sh` + `compose.yaml`. Verify TZ + crond + DST math.
7. Flip `DRY_RUN=0`, run one phase manually for a real clock event via `docker compose exec`.
8. `install.sh` / `uninstall.sh` + README quickstart.

---

## 12. Out of scope (still)

- launchd, AI agents, MCP-driven automation, GitHub Actions, Slack presence integration, web dashboard. The MCP stays read-only-interactive — Claude uses it when I want to *ask* about my timesheet, not to *write* it.
- OAuth2 against BambooHR. Personal API keys are sufficient for v1; OAuth notes are in §7 for when we need them.
- Multi-user support. The container and the secrets layout assume one person.
- Outbound notifications (Slack/ntfy/email). Log-only in v1 by design; see §8.

---

## 13. Open / deferred

- **Where the container actually runs.** The Docker design is host-agnostic; deferred until after the bash logic is working. Candidates: always-on home machine, NAS, tiny VPS, or eventually an Android device.
- **Android v2.** If the rooster moves to Android (Termux + cron, or a native app with WorkManager), the bash logic ports cleanly — only the scheduler and the notification sink change. The event taxonomy in §8 is designed so log-tail → push-notification is a straight mapping.
