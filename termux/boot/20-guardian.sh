#!/data/data/com.termux/files/usr/bin/sh
# Termux:Boot: phone-side watchdog, independent of the atheron.
# sshd listens only on the tailnet address (ListenAddress), so right after boot it can fail to bind until tun0 is
# up: the loop below simply keeps retrying every interval.
# Every GUARDIAN_INTERVAL seconds (default 60): keep sshd (port 8022) alive and hold the wake lock.
# Log: ~/guardian.log, rotated at GUARDIAN_MAX_BYTES (default 256 KiB) keeping one old copy (.1).
# Single instance (pidfile). GUARDIAN_ONCE=1 runs one iteration (used by the tests).
# Auto-wake: when the home Wi-Fi comes back (AP up again = power back after an outage, when cerberus-power-guard
# may have powered the atheron off), wake the atheron by Wake-on-LAN until it answers. Off: touch ~/.acordar-atheron.off
HOME_DIR=${HOME:-/data/data/com.termux/files/home}
LOG=${GUARDIAN_LOG:-$HOME_DIR/guardian.log}
PIDF=${GUARDIAN_PID:-$HOME_DIR/.guardian.pid}
INTERVAL=${GUARDIAN_INTERVAL:-60}
MAX=${GUARDIAN_MAX_BYTES:-262144}

SSH_PORT=${GUARDIAN_SSH_PORT:-8022}
# the address sshd listens on (ListenAddress in sshd_config), else the tailnet default
SSH_ADDR=${GUARDIAN_SSH_ADDR:-$(sed -n 's/^ListenAddress[[:space:]]\{1,\}//p' "${PREFIX:-/data/data/com.termux/files/usr}/etc/ssh/sshd_config" 2>/dev/null | head -n 1)}
SSH_ADDR=${SSH_ADDR:-100.64.0.10}

WAKE_SUBNET=${GUARDIAN_WAKE_SUBNET:-192.168.1.}                  # wlan0 IPv4 prefix of the home LAN
ATHERON_IPS=${GUARDIAN_ATHERON_IPS:-192.0.2.10 192.0.2.11}   # cable, Wi-Fi
WAKE_CMD=${GUARDIAN_WAKE_CMD:-acordar-atheron}
WAKE_TRIES=${GUARDIAN_WAKE_TRIES:-10}
WAKE_GAP=${GUARDIAN_WAKE_GAP:-30}
WIFI_STATE=${GUARDIAN_WIFI_STATE:-$HOME_DIR/.guardian-wifi}
WAKE_OFF=${GUARDIAN_WAKE_OFF:-$HOME_DIR/.acordar-atheron.off}
WAKE_PIDF=${GUARDIAN_WAKE_PID:-$HOME_DIR/.auto-wake.pid}

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "$LOG"; }

# home Wi-Fi = wlan0 has an IPv4 in the home LAN (works without root and without the Termux:API app)
home_wifi() {
    if [ -n "${GUARDIAN_WIFI_CHECK:-}" ]; then sh -c "$GUARDIAN_WIFI_CHECK"; return; fi
    /system/bin/ip -4 -o addr show wlan0 2>/dev/null | grep -qF "inet $WAKE_SUBNET"
}

atheron_up() {
    if [ -n "${GUARDIAN_ATHERON_CHECK:-}" ]; then sh -c "$GUARDIAN_ATHERON_CHECK"; return; fi
    for ip in $ATHERON_IPS; do ping -c 1 -W 2 "$ip" > /dev/null 2>&1 && return 0; done
    return 1
}

# a magic packet to a running machine does nothing, so repeating is harmless; stops as soon as the atheron answers
auto_wake() {
    i=1
    while [ "$i" -le "$WAKE_TRIES" ]; do
        if atheron_up; then
            if [ "$i" -eq 1 ]; then log "auto-wake: atheron already up"; else log "auto-wake: atheron answered (round $i)"; fi
            return 0
        fi
        if $WAKE_CMD > /dev/null 2>&1; then log "auto-wake: magic packet sent ($i/$WAKE_TRIES)"; else log "auto-wake: $WAKE_CMD FAILED ($i/$WAKE_TRIES)"; fi
        i=$((i + 1))
        if [ "$i" -le "$WAKE_TRIES" ]; then sleep "$WAKE_GAP"; fi
    done
    if atheron_up; then log "auto-wake: atheron answered"; else log "auto-wake: atheron still down after $WAKE_TRIES rounds"; fi
}

# fires only on the transition down -> up (state kept in a file, so a guardian restart does not fire it)
wake_check() {
    if home_wifi; then now=1; else now=0; fi
    prev=$(cat "$WIFI_STATE" 2> /dev/null) || prev=$now
    echo "$now" > "$WIFI_STATE"
    [ "$prev" = "$now" ] && return 0
    if [ "$now" = 0 ]; then log "home Wi-Fi lost"; return 0; fi
    if [ -e "$WAKE_OFF" ]; then log "home Wi-Fi back; auto-wake disabled ($WAKE_OFF)"; return 0; fi
    if [ -f "$WAKE_PIDF" ] && kill -0 "$(cat "$WAKE_PIDF" 2> /dev/null)" 2> /dev/null; then return 0; fi
    log "home Wi-Fi back (AP up = power back?): auto-wake of the atheron"
    if [ -n "${GUARDIAN_ONCE:-}" ]; then
        auto_wake
    else
        auto_wake &
        echo $! > "$WAKE_PIDF"
    fi
}

# true when something accepts TCP on SSH_ADDR:SSH_PORT (bash /dev/tcp; GUARDIAN_PORT_CHECK overrides for tests)
port_open() {
    if [ -n "${GUARDIAN_PORT_CHECK:-}" ]; then sh -c "$GUARDIAN_PORT_CHECK"; return; fi
    timeout 4 bash -c "</dev/tcp/$SSH_ADDR/$SSH_PORT" 2>/dev/null
}

rotate() {
    [ -f "$LOG" ] || return 0
    size=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    if [ "${size:-0}" -gt "$MAX" ]; then
        mv -f "$LOG" "$LOG.1"
        log "log rotated"
    fi
}

if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; then
    exit 0   # already running (boot script and ~/.bashrc hook may both start us)
fi
echo $$ > "$PIDF"
log "guardian started (pid $$, every ${INTERVAL}s)"

while :; do
    termux-wake-lock 2>/dev/null
    # check the PORT, not just the process: when the VPN restarts (e.g. a tag change) the old sshd keeps
    # running but loses its socket on the tailnet address, so `pgrep sshd` alone says "fine" forever
    if ! pgrep -x sshd > /dev/null 2>&1; then
        log "sshd down: restarting"
        if sshd; then log "sshd restarted"; else log "sshd FAILED to restart"; fi
    elif ! port_open; then
        log "sshd running but :$SSH_PORT not answering on ${SSH_ADDR}: restarting"
        pkill -x sshd 2>/dev/null; sleep 1
        if sshd; then log "sshd restarted"; else log "sshd FAILED to restart"; fi
    fi
    wake_check
    rotate
    [ -n "${GUARDIAN_ONCE:-}" ] && break
    sleep "$INTERVAL"
done
