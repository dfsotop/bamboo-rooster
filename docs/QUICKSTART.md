# 🐓 bamboo-rooster — quickstart

Five minutes. macOS.

## What this does

Clocks you in and out of BambooHR four times a workday (morning, lunch out, lunch back in, evening) at randomized minutes inside windows you choose. Skips weekends, holidays, and any approved PTO / sick day automatically. Runs in the background — nothing to do once it's set up.

## Requirements

- A Mac (Intel or Apple Silicon)
- A BambooHR account
- Permission to create an API key (most accounts have it — if "API Keys" isn't in your profile dropdown, ask an admin)

---

## 1. Open Terminal

Press **⌘ Space**, type `Terminal`, press Enter.

## 2. Run the bootstrap

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/dfsotop/bamboo-rooster/main/setup.sh)"
```

What it does, in order:

| Step | What happens |
|---|---|
| Xcode Tools | If you don't have `git`, macOS opens a system dialog to install Apple's Command Line Tools (~5 minutes). When it's done, re-run the same command. |
| Homebrew | Installs Homebrew if you don't have it. It'll ask for your Mac password to put files in `/opt/homebrew` or `/usr/local`. |
| jq | A small JSON-parsing tool the script needs. Installs via Homebrew. |
| Download | Copies the bamboo-rooster files to `~/Applications/bamboo-rooster/`. |
| Wizard | The setup wizard starts and asks you questions. |

## 3. Answer the wizard

| Prompt | What to type |
|---|---|
| **BambooHR subdomain** | The prefix in your BambooHR URL. If you log in at `acme.bamboohr.com`, type `acme`. |
| **Employee ID** | Press **Enter** to leave blank — it'll figure it out from your API key. |
| **Timezone** | Press **Enter** to accept the detected default (your Mac's timezone). |
| **DRY_RUN mode** | Press **Enter** (defaults to yes). This is "rehearsal mode" — the rooster will run the schedule but **not actually** clock you in/out. You'll switch this off in a few days once you've verified the schedule looks right. |
| **API key** | See section 4 below. |
| **Time windows** | When to clock in/out. Defaults: 08:30–09:30 morning, 12:45–14:00 lunch, 17:30–18:30 evening. Press **Enter** at each to accept the default, or type your own (`HH:MM`). |

## 4. Get your BambooHR API key

When the wizard reaches the API-key prompt, your browser will pop open at the right BambooHR page. If it doesn't:

1. Open `https://<your-subdomain>.bamboohr.com/settings/api.php` in any browser
2. Click **Add New Key**
3. Name it `bamboo-rooster` (or anything you like)
4. Click **Generate Key**
5. **Copy the long string immediately** (it's only shown once)
6. Switch back to Terminal and paste it (it won't show on screen as you paste — that's normal)
7. Press **Enter**

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
