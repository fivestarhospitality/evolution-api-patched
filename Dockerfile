FROM evoapicloud/evolution-api:2.4.0-rc2

COPY patch.sh /tmp/patch.sh
RUN sh /tmp/patch.sh && rm -f /tmp/patch.sh
