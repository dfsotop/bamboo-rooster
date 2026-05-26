#!/usr/bin/env bash
# entrypoint.sh — set TZ, validate config, exec the CMD (crond by default).

set -euo pipefail

# Propagate TZ into /etc/localtime so date(1) honours it. Alpine's tzdata
# ships zoneinfo at /usr/share/zoneinfo; missing zone → loud error.
TZ="${TZ:-UTC}"
if [[ -f "/usr/share/zoneinfo/$TZ" ]]; then
  ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
  echo "$TZ" > /etc/timezone
else
  echo "entrypoint: TZ=$TZ has no zoneinfo file under /usr/share/zoneinfo" >&2
  exit 1
fi

# Source ~/.env so the env vars set by config.example.env (BAMBOOHR_SUBDOMAIN,
# cooldowns, DRY_RUN) are also visible to interactive `docker exec` sessions.
# crond invocations don't get this — the rooster script sources $ROOSTER_HOME/.env
# itself for that reason.
if [[ -f "${ROOSTER_HOME:-/var/lib/rooster}/.env" ]]; then
  echo "entrypoint: found ${ROOSTER_HOME}/.env"
fi

# Required runtime config — fail loudly. Otherwise cron fires four times
# a day, every job writes `failed` to log.jsonl, and the user only finds
# out via the missing-timesheet email from HR.
if [[ ! -f "${ROOSTER_HOME:-/var/lib/rooster}/.env" ]]; then
  echo "entrypoint: FATAL ${ROOSTER_HOME}/.env not mounted." >&2
  exit 1
fi
if [[ ! -f "${ROOSTER_HOME:-/var/lib/rooster}/secrets/api-key" ]]; then
  echo "entrypoint: FATAL ${ROOSTER_HOME}/secrets/api-key not mounted." >&2
  exit 1
fi

# Print one banner line to stdout so `docker logs` confirms what's running.
local_now=$(date)
utc_now=$(date -u)
echo "bamboo-rooster up — TZ=$TZ | local=$local_now | utc=$utc_now"

exec "$@"
