#!/data/data/com.termux/files/usr/bin/sh
# Termux:Boot: phone-side watchdog, independent of the atheron.
# sshd listens only on the tailnet address (ListenAddress), so right after boot it can fail to bind until tun0 is
# up: the loop below simply keeps retrying every interval.
# Every GUARDIAN_INTERVAL seconds (default 60): keep sshd (port 8022) alive and hold the wake lock.
# Log: ~/guardian.log, rotated at GUARDIAN_MAX_BYTES (default 256 KiB) keeping one old copy (.1).
# Single instance (pidfile). GUARDIAN_ONCE=1 runs one iteration (used by the tests).
HOME_DIR=${HOME:-/data/data/com.termux/files/home}
LOG=${GUARDIAN_LOG:-$HOME_DIR/guardian.log}
PIDF=${GUARDIAN_PID:-$HOME_DIR/.guardian.pid}
INTERVAL=${GUARDIAN_INTERVAL:-60}
MAX=${GUARDIAN_MAX_BYTES:-262144}

SSH_PORT=${GUARDIAN_SSH_PORT:-8022}
# the address sshd listens on (ListenAddress in sshd_config), else the tailnet default
SSH_ADDR=${GUARDIAN_SSH_ADDR:-$(sed -n 's/^ListenAddress[[:space:]]\{1,\}//p' "${PREFIX:-/data/data/com.termux/files/usr}/etc/ssh/sshd_config" 2>/dev/null | head -n 1)}
SSH_ADDR=${SSH_ADDR:-100.64.0.10}

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "$LOG"; }

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
    rotate
    [ -n "${GUARDIAN_ONCE:-}" ] && break
    sleep "$INTERVAL"
done
