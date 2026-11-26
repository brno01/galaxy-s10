#!/bin/bash
# Tests for atheron/dev/adb (the guard in front of the real adb for development accounts).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
GUARD=$HERE/../dev/adb
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
# fake real adb: records argv and the server socket it was given
printf '#!/bin/sh\necho "$ADB_SERVER_SOCKET|$*" >> "%s/calls"\n' "$T" > "$T/realadb"
chmod +x "$T/realadb"
export S10_REAL_ADB=$T/realadb
unset ADB_SERVER_SOCKET
fail=0 n=0
ok() { n=$((n + 1)); if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=$((fail + 1)); fi; }
run() { : > "$T/calls"; bash "$GUARD" "$@" > "$T/out" 2>&1; }

for c in "devices" "install app.apk" "-s SER install -r app.apk" "shell getprop ro.product.model" "logcat -d" \
         "forward tcp:5901 tcp:5900" "forward --remove tcp:5901" "reverse tcp:8080 tcp:8080" "reverse --remove-all" "-H 127.0.0.1 -P 5037 devices" \
         "start-server" "-s SER shell echo kill-server"; do
    # shellcheck disable=SC2086  # word splitting is the point: each string is an argv
    run $c; rc=$?
    ok "passes: adb $c" "[ $rc -eq 0 ] && grep -qxF 'localfilesystem:/run/cerberus-s10/adb.sock|$c' '$T/calls'"
done
for c in "kill-server" "-s SER kill-server" "tcpip 5555" "usb" "nodaemon server" "server" "-a devices" "-L tcp:5037 devices" \
         "disconnect" "disconnect 192.0.2.5:5555" "forward --remove-all" "forward --remove tcp:15900" "-s SER forward --remove tcp:27183"; do
    # shellcheck disable=SC2086
    run $c; rc=$?
    ok "refuses: adb $c" "[ $rc -eq 64 ] && [ ! -s '$T/calls' ] && grep -q 'recusado' '$T/out'"
done
: > "$T/calls"; ADB_SERVER_SOCKET=localfilesystem:/tmp/other.sock bash "$GUARD" devices > /dev/null 2>&1
ok "keeps an explicit ADB_SERVER_SOCKET" "grep -qxF 'localfilesystem:/tmp/other.sock|devices' '$T/calls'"
# the env snippet points every client at the guardian's socket and puts ~/.local/bin first
out=$(env -i HOME=/h PATH=/usr/bin sh -c ". '$HERE/../dev/s10-adb.env.sh'; echo \"\$ADB_SERVER_SOCKET|\$PATH\"")
ok "env snippet: socket and ~/.local/bin" "[ '$out' = 'localfilesystem:/run/cerberus-s10/adb.sock|/h/.local/bin:/usr/bin' ]"
echo "--- $n checks, $fail failed"
[ "$fail" -eq 0 ]
