# 🐓 bamboo-rooster — quickstart

Five minutes. macOS.

## What this does

Clocks you in and out of BambooHR four times a workday (morning, lunch out, lunch back in, evening) at randomized minutes inside windows you choose. Skips weekends, holidays, and any approved PTO / sick day automatically. Runs in the background — nothing to do once it's set up.

## Requirements

- A Mac (Intel or Apple Silicon)
- A BambooHR account
- Permission to create an API key (most accounts have it — if "API Keys" isn't in your profile dropdown, ask an admin)

---

## 1. Get your BambooHR API key first

The installer refuses to do anything until you confirm you have a key.
Generate one now:

1. Log in at `https://<your-subdomain>.bamboohr.com`
2. Click your profile picture (top right) → **API Keys**
3. Click **Add New Key**, give it a name (e.g. `bamboo-rooster`)
4. Click **Generate Key**
5. **Copy the long string immediately** — it's only displayed once

If "API Keys" isn't in your profile menu, ask your BambooHR admin to enable
API key generation for your user (it's a 30-second toggle on their side).

## 2. Open Terminal

Press **⌘ Space**, type `Terminal`, press Enter.

## 3. Run the bootstrap

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/dfsotop/bamboo-rooster/main/setup.sh)"
```

The installer asks first thing: **"Do you have your API key ready?"** — answer `y`.

What it does, in order:

| Step | What happens |
|---|---|
| API key gate | Confirms you have a BambooHR API key before touching your system. |
| Dependency check | Shows you what's about to be installed (just `jq`, if you don't have it) and asks once before touching anything. |
| jq | A small ~600 KB JSON parser. Downloaded directly from jq's GitHub releases into `~/.bamboo-rooster/bin/jq` — **no Homebrew required**. |
| Download | Fetches the bamboo-rooster files to `~/Applications/bamboo-rooster/` (curl + tar, no git needed). |
| Wizard | The setup wizard starts and asks you questions. |

## 4. Answer the wizard

| Prompt | What to type |
|---|---|
| **BambooHR subdomain** | The prefix in your BambooHR URL. If you log in at `acme.bamboohr.com`, type `acme`. |
| **Employee ID** | Press **Enter** to leave blank — it'll figure it out from your API key. |
| **Timezone** | Press **Enter** to accept the detected default (your Mac's timezone). |
| **DRY_RUN mode** | Press **Enter** (defaults to yes). This is "rehearsal mode" — the rooster will run the schedule but **not actually** clock you in/out. You'll switch this off in a few days once you've verified the schedule looks right. |
| **API key** | Paste the key you copied in step 1 (it won't show on screen — that's normal). Press **Enter**. |
| **Time windows** | When to clock in/out. Defaults: 08:30–09:30 morning, 12:45–14:00 lunch, 17:30–18:30 evening. Press **Enter** at each to accept the default, or type your own (`HH:MM`). |

## 5. Done

You'll see a summary that ends with `✓ rooster scheduled`. That means:

- Four background jobs are now armed
- They'll fire Monday–Friday at the times you chose, each at a uniformly random minute inside the window
- Logs go to `~/.bamboo-rooster/log.jsonl`

---

## Living with it

| What you want | What to type in Terminal |
|---|---|
| See what happened in the last 7 days | `rooster-status` |
| Skip the rooster for today (e.g. you're WFH but already clocked in manually) | `touch ~/.bamboo-rooster/skip-today` |
| Switch from DRY_RUN to live (after a few days of watching) | `sed -i.bak 's/^DRY_RUN=.*/DRY_RUN="0"/' ~/.bamboo-rooster/.env` |
| Get a new API key working (if BambooHR rotated yours) | `rooster-rotate-key` |
| Stop and uninstall everything | `~/Applications/bamboo-rooster/uninstall.sh` |
| Update to the latest version | re-run the one-liner from step 2 |

## What it doesn't do

- ❌ Clock you in when BambooHR shows you on **vacation, sick leave, doctor's appointment, parental leave** — any approved time-off
- ❌ Clock you in on **weekends** or **company holidays**
- ❌ **Clock you in twice** — it checks your timesheet first and skips if there's already an entry

## When something feels off

| What you see | What's happening |
|---|---|
| `auth_failure` in the log | Your BambooHR API key was revoked or rotated. Run `rooster-rotate-key` and paste a fresh one. |
| Nothing happens at the scheduled time | Your laptop was asleep — launchd re-fires on wake. Open the lid and watch the log. |
| A workday entry is missing | The launchd job might have been disabled. Run `launchctl list \| grep bamboo-rooster` to see the four jobs. If they're not there, re-run the setup one-liner. |
| You want to change your time windows | `rm ~/.bamboo-rooster/windows.conf && ~/Applications/bamboo-rooster/install.sh` |

---

## More

- Full README: https://github.com/dfsotop/bamboo-rooster
- Source code: same repo, browse the `bin/`, `lib/`, `install/` folders
- Questions / bug reports: open an issue at https://github.com/dfsotop/bamboo-rooster/issues
