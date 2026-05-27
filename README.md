# 🐓 bamboo-rooster

Randomized BambooHR clock-in / clock-out, four times a workday. Designed to look human and respect time-off.

For the why and the design rationale, read [`wiki/README.md`](wiki/README.md) and [`wiki/plan.md`](wiki/plan.md). This file is just the quickstart.

> ⚠ **Disclaimer.** bamboo-rooster is a helper tool that schedules clock-in/clock-out actions against BambooHR. It is provided **AS-IS**, without warranty. **You remain solely responsible** for verifying that your timesheet records are accurate and complete, and for complying with your company's time-tracking policy. This tool can fail silently — it does **not** replace your obligation to keep your records correct.

---

## Quickstart

### One-line install (macOS)

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/dfsotop/bamboo-rooster/main/setup.sh)"
```

Downloads the code to `~/Applications/bamboo-rooster/` and runs the wizard. See [`docs/QUICKSTART.md`](docs/QUICKSTART.md) for a step-by-step walkthrough of the prompts.

### From a cloned repo



`./install.sh` detects your OS and dispatches to the right scheduler — **launchd** on macOS, **systemd** user units on Linux. The interactive prompts are identical.

```bash
./install.sh
```

Prerequisites — both macOS and Linux need `jq` and `curl`; the installer suggests the right package-manager incantation for your platform if either is missing.

- **macOS**: `brew install jq curl` (curl usually ships)
- **Debian/Ubuntu**: `sudo apt-get install -y jq curl`
- **Fedora/RHEL**: `sudo dnf install -y jq curl`
- **Arch**: `sudo pacman -S --noconfirm jq curl`
- **Alpine**: `sudo apk add jq curl`

The script will:
1. Prompt for your **BambooHR subdomain** (the prefix in `<x>.bamboohr.com`).
2. Optionally prompt for **employee ID** (blank = auto-resolve at runtime).
3. Detect your **system timezone** and offer it as a prompt default.
4. Ask whether to start in `DRY_RUN=1` mode (default yes — safe first-run behavior).
5. Prompt for your **BambooHR API key** (no echo) and save to `~/.bamboo-rooster/secrets/api-key` (chmod 600).
6. Prompt **once** for your three time-ranges (morning, lunch, evening) and persist them to `~/.bamboo-rooster/windows.conf`. The lunch envelope is auto-split into lunch-out + lunch-in halves with a 15-min gap.
7. Force a live API round-trip to verify the key works.
8. Generate the scheduler units:
   - macOS → four launchd plists under `~/Library/LaunchAgents/com.bamboo-rooster.<phase>.plist`, validated with `plutil -lint`, loaded via `launchctl bootstrap`.
   - Linux → four `.timer` + `.service` pairs under `~/.config/systemd/user/`, enabled via `systemctl --user enable --now`. Includes a `Persistent=true` so missed fires run after wake.
9. Symlink the `rooster`, `rooster-status`, `rooster-rotate-key` commands into `~/.local/bin/` so they're on PATH.

To re-configure the time-ranges later: `rm ~/.bamboo-rooster/windows.conf && ./install.sh`. Other config is kept; you'll only be re-prompted for the windows.

### Linux: keeping it running when you log out

systemd user services normally stop at log-out. For an always-on schedule:

```bash
sudo loginctl enable-linger $USER
```

The installer detects this state and prints a hint if lingering isn't enabled.

### Why not plain cron

Both launchd and systemd re-fire missed jobs on wake (launchd via `StartCalendarInterval`, systemd via `Persistent=true`). `cron` silently drops them.

---

## After install

`install.sh` symlinks the binaries into `~/.local/bin`, so you get three
PATH commands (no need to cd into the repo):

```bash
# tail the structured log
tail -f ~/.bamboo-rooster/log.jsonl

# last 7 days, missed phases flagged
rooster-status

# force a live API key check (bypasses cache, real HTTP round-trip)
rooster --auth-check

# rotate a revoked or regenerated API key (validates before saving)
rooster-rotate-key

# skip every phase for today (auto-cleared tomorrow)
touch ~/.bamboo-rooster/skip-today

# manually fire a phase
#   macOS:
launchctl kickstart "gui/$(id -u)/com.bamboo-rooster.morning"
#   Linux:
systemctl --user start bamboo-rooster-morning.service

# remove the launchd jobs + CLI symlinks (keeps logs/config on disk)
./uninstall.sh
```

If `~/.local/bin` isn't on your PATH, `install.sh` prints the one-liner to
add it to `~/.zshrc`.

---

## Phases (Madrid local time, Mon–Fri)

| Phase     | Cron fires | Random window | Action     |
| --------- | ---------- | ------------- | ---------- |
| morning   | 08:30      | 08:30 – 09:30 | clock in   |
| lunch-out | 12:45      | 12:45 – 13:15 | clock out  |
| lunch-in  | 13:30      | 13:30 – 14:00 | clock in   |
| evening   | 17:30      | 17:30 – 18:30 | clock out  |

Lunch break is guaranteed 15–75 min, averaging ~45 min.

---

## When does it skip?

Every skip is logged with a `reason` field. Skips happen when:

- weekends (Sat/Sun)
- any time-off entry returned by BambooHR `whos_out` for me today — **vacation, sick, doctor, parental, bereavement, jury duty, any approved type**
- company holidays returned by `whos_out`
- the segment is already in today's timesheet (idempotency, including manual entries via the Hours UI)
- `~/.bamboo-rooster/skip-today` exists (mtime today)

The time-off check runs **twice per phase** — once before the random sleep and again after — so sick leave entered mid-day is picked up by the next phase.

---

## When something breaks

- **`auth_failure` in the log** → API key was revoked, regenerated, or otherwise invalidated. Generate a new key in BambooHR and run `./bin/rotate-key`. The next launchd fire picks it up automatically.
- **`api_error` in the log** → transient BambooHR or network issue. The phase skipped to be safe. Usually self-heals on the next phase.
- **`parse_error`** → unexpected response shape. Phase skipped. Worth investigating if it persists.
- **No log line for a workday phase** → the host was down or asleep when launchd should have fired AND no wake fired the catch-up. Run `./bin/rooster-status` to see the gap.

---

## Layout

```
bamboo-rooster/
├── bamboohr-mcp/       # vendored MCP — interactive use only, NOT on the hot path
├── bin/                # rooster, rooster-status, rotate-key
├── lib/                # log.sh, state.sh, auth.sh, bamboo.sh, gates.sh
├── config/             # windows.conf, config.example.env
├── docker/             # Dockerfile, crontab, entrypoint.sh (alternative deploy)
├── wiki/               # design docs
├── compose.yaml        # alternative: Docker deploy
├── install.sh          # the install
└── uninstall.sh        # the uninstall
```

State and secrets live OUTSIDE the repo at `~/.bamboo-rooster/` — never checked in.

---

## Future: Docker deploy

The `docker/` directory + `compose.yaml` are kept as an alternative deployment for when the rooster moves off the laptop (always-on home server, NAS, VPS). Not part of `install.sh` — that's launchd-only on macOS. To use Docker: `docker compose up -d --build` after seeding `~/.bamboo-rooster/.env` and the api-key file manually.
