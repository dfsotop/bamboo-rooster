# bamboo-rooster — alpine + bash + curl + jq + busybox crond.
# Runs crond -f as PID 1; phases fire as scheduled, the script does the work.

FROM alpine:3.20

# tzdata is required for crond / date / sleep to honour TZ.
# coreutils gives us a GNU `date` (busybox `date -d` is too restrictive for
# arbitrary YYYY-MM-DD inputs and ISO 8601 reformatting).
RUN apk add --no-cache \
      bash \
      coreutils \
      curl \
      jq \
      tzdata

ENV TZ=Europe/Madrid \
    ROOSTER_ROOT=/opt/rooster \
    ROOSTER_HOME=/var/lib/rooster

# Image bundles the script tree under /opt/rooster.
WORKDIR /opt/rooster
COPY bin/   /opt/rooster/bin/
COPY lib/   /opt/rooster/lib/
COPY config/ /opt/rooster/config/
COPY docker/crontab     /etc/crontabs/root
COPY docker/entrypoint.sh /entrypoint.sh

RUN chmod +x /opt/rooster/bin/* /entrypoint.sh \
 && mkdir -p /var/lib/rooster/secrets \
 && chmod 700 /var/lib/rooster /var/lib/rooster/secrets

# Sanity: print the version and exit non-zero if any required binary is missing.
RUN bash -c 'command -v curl && command -v jq && command -v date && command -v crond'

ENTRYPOINT ["/entrypoint.sh"]
CMD ["crond", "-f", "-l", "8"]
