#!/bin/sh
# shellcheck shell=dash
#
# Railway entrypoint: Tor egress for the engines, then the upstream entrypoint.
#
# 1. Start the bundled Tor client (container/torrc) and wait for 100% bootstrap.
# 2. Bootstrapped  -> settings from railway-tor.settings.yml (engines via Tor).
#    Not in time    -> settings from the plain template (the pre-Tor behaviour),
#                      so a Tor outage degrades the instance instead of killing it.
#    SEARXNG_TOR=0  -> skip Tor entirely (kill switch).
# 3. exec the upstream entrypoint. We write settings.yml ourselves on EVERY boot;
#    the upstream script only creates it when missing, so it leaves ours alone.
set -u

CONF_DIR="${__SEARXNG_CONFIG_PATH:-/etc/searxng}"
TARGET="$CONF_DIR/settings.yml"
TEMPLATE_TOR=/usr/local/searxng/railway-tor.settings.yml
TEMPLATE_PLAIN=/usr/local/searxng/settings.template.yml
TOR_TIMEOUT="${SEARXNG_TOR_BOOTSTRAP_TIMEOUT:-90}"

mode=plain
if [ "${SEARXNG_TOR:-1}" != "0" ]; then
    rm -rf /tmp/tor-data /tmp/tor.log
    mkdir -p /tmp/tor-data
    chmod 700 /tmp/tor-data
    LD_LIBRARY_PATH=/opt/tor/lib /opt/tor/bin/tor -f /opt/tor/torrc &
    tor_pid=$!
    waited=0
    while [ "$waited" -lt "$TOR_TIMEOUT" ]; do
        if grep -q "Bootstrapped 100%" /tmp/tor.log 2>/dev/null; then
            mode=tor
            break
        fi
        if ! kill -0 "$tor_pid" 2>/dev/null; then
            echo "[railway] tor exited during bootstrap"
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done
    if [ "$mode" = tor ]; then
        echo "[railway] tor bootstrapped in ${waited}s - engines egress via Tor"
        # Onion engines: the first rendezvous takes ~40 s, longer than the
        # engine timeout. Warm them before SearXNG serves, then keep them warm.
        /usr/local/searxng/.venv/bin/python /opt/tor/tor-keepalive.py --warm
        /usr/local/searxng/.venv/bin/python /opt/tor/tor-keepalive.py &
    else
        echo "[railway] tor NOT bootstrapped within ${TOR_TIMEOUT}s - starting with PLAIN egress"
        tail -n 5 /tmp/tor.log 2>/dev/null
        kill "$tor_pid" 2>/dev/null
    fi
else
    echo "[railway] SEARXNG_TOR=0 - Tor disabled, plain egress"
fi

mkdir -p "$CONF_DIR"
if [ "$mode" = tor ]; then
    cp -f "$TEMPLATE_TOR" "$TARGET"
else
    cp -f "$TEMPLATE_PLAIN" "$TARGET"
fi
sed -i "s/ultrasecretkey/$(head -c 24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9')/g" "$TARGET"

if [ "$mode" != tor ]; then
    exec /usr/local/searxng/entrypoint.sh
fi

# Tor mode: stay PID 1 as a tiny supervisor.
#  - TERM/INT (a normal redeploy) is forwarded to SearXNG: graceful, exit 0.
#  - If Tor dies, stop SearXNG and exit NON-ZERO. Measured: a graceful stop
#    exits 0, and Railway's default on-failure policy would then leave the
#    service DOWN; exit 1 gets it restarted.
#  - A dead child stays a ZOMBIE until reaped, so `kill -0` proves nothing;
#    the state letter in /proc/<pid>/stat does.
dead() {
    st=$(sed -n 's/^[^)]*) \([A-Z]\).*/\1/p' "/proc/$1/stat" 2>/dev/null)
    [ -z "$st" ] || [ "$st" = Z ] || [ "$st" = X ]
}

/usr/local/searxng/entrypoint.sh &
app_pid=$!
trap 'kill -TERM "$app_pid" 2>/dev/null; wait "$app_pid"; exit 0' TERM INT
while :; do
    sleep 10 &
    wait $!
    if dead "$app_pid"; then
        wait "$app_pid"
        rc=$?
        echo "[railway] SearXNG exited (rc=$rc)"
        exit "$rc"
    fi
    if dead "$tor_pid"; then
        echo "[railway] tor is gone - stopping SearXNG, exit 1 for a restart"
        kill -TERM "$app_pid" 2>/dev/null
        wait "$app_pid"
        exit 1
    fi
done
