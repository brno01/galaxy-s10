#!/bin/bash
# Tests for atheron/dev/s10-tela-web and atheron/dev/install-dev.sh (fake adb, websockify, uv, curl, systemctl, id).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
DEV=$HERE/../dev
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home"
export CALLS=$T/calls
fail=0 n=0
ok() { n=$((n + 1)); if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=$((fail + 1)); fi; }

# fake adb: FAKE_STATE (device), FAKE_VNC (1 = droidVNC-NG listening)
cat > "$T/bin/fakeadb" <<'EOF'
#!/bin/sh
echo "adb $*" >> "$CALLS"
case "$1" in
get-state) echo "${FAKE_STATE:-device}"; [ "${FAKE_STATE:-device}" = device ] ;;
shell) [ "${FAKE_VNC:-1}" = 1 ] ;;
*) exit 0 ;;
esac
EOF
# shellcheck disable=SC2016  # literal $CALLS in the fakes
printf '#!/bin/sh\necho "websockify $*" >> "$CALLS"\n' > "$T/bin/websockify"
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "systemctl $*" >> "$CALLS"\n[ "$2" = is-active ] && exit 1\nexit 0\n' > "$T/bin/systemctl"
chmod +x "$T"/bin/*
mkdir -p "$T/novnc"; touch "$T/novnc/vnc.html"
export S10_ADB=$T/bin/fakeadb S10_WEBSOCKIFY=$T/bin/websockify S10_NOVNC_DIR=$T/novnc S10_SYSTEMCTL=$T/bin/systemctl
export S10_VNC_PASSWORD_FILE=$T/pw
TW=$DEV/s10-tela-web

# url: password only in the #fragment, never in the path/query
bash "$TW" url > "$T/out"
ok "url without a password file: no password" "grep -qx 'http://localhost:6080/vnc.html#autoconnect=1&resize=scale&reconnect=1&show_dot=1' '$T/out'"
FAKE_PW=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12)   # random per run: no credential-looking literal in git
printf '%s\n' "$FAKE_PW" > "$T/pw"
bash "$TW" url > "$T/out"
ok "url carries the password in the fragment" "grep -q '^http://localhost:6080/vnc.html#.*&password=$FAKE_PW\$' '$T/out' && ! grep -q '?' '$T/out'"

# run: forward to the phone's VNC, websockify on loopback serving noVNC, forward removed on exit
: > "$CALLS"
bash "$TW" run > "$T/out" 2>&1; rc=$?
ok "run exits when websockify exits" "[ $rc -eq 0 ]"
ok "run forwards 15900 to the phone's 5900" "grep -qx 'adb forward tcp:15900 tcp:5900' '$CALLS'"
ok "run starts websockify on 127.0.0.1:6080 with noVNC" "grep -qx 'websockify --web $T/novnc 127.0.0.1:6080 127.0.0.1:15900' '$CALLS'"
ok "run removes the forward on exit" "grep -qx 'adb forward --remove tcp:15900' '$CALLS'"
ok "forward created before websockify" "[ \$(grep -n 'forward tcp:15900' '$CALLS' | cut -d: -f1) -lt \$(grep -n '^websockify' '$CALLS' | cut -d: -f1) ]"
: > "$CALLS"
FAKE_VNC=0 bash "$TW" run > "$T/out" 2>&1; rc=$?
ok "run: VNC down on the phone -> clear error, no forward" "[ $rc -ne 0 ] && grep -q 'droidVNC-NG' '$T/out' && ! grep -q 'forward tcp' '$CALLS'"
: > "$CALLS"
FAKE_STATE=unauthorized ADB_SERVER_SOCKET=localfilesystem:$T/pw bash "$TW" run > "$T/out" 2>&1; rc=$?
ok "run: phone not ready -> error with the state" "[ $rc -ne 0 ] && grep -q 'unauthorized' '$T/out' && ! grep -q '^websockify' '$CALLS'"
: > "$CALLS"
FAKE_STATE=x ADB_SERVER_SOCKET=localfilesystem:$T/nonexistent.sock bash "$TW" run > "$T/out" 2>&1; rc=$?
ok "run: no access to the adb socket -> explains the group" "[ $rc -ne 0 ] && grep -q 'cerberus-s10' '$T/out'"
: > "$CALLS"
bash "$TW" start > /dev/null 2>&1
ok "start -> systemctl --user start" "grep -qx 'systemctl --user start s10-tela-web.service' '$CALLS'"
bash "$TW" bogus > /dev/null 2>&1; rc=$?
ok "unknown subcommand: usage, exit 2" "[ $rc -eq 2 ]"
ok "unit enters the group with sg" "grep -q '^ExecStart=/usr/bin/sg cerberus-s10 -c \"exec %h/.local/bin/s10-tela-web run\"' '$DEV/s10-tela-web.service'"

# install-dev.sh
mkdir -p "$T/pkg/noVNC-1.7.0"; echo '<html>' > "$T/pkg/noVNC-1.7.0/vnc.html"
tar -czf "$T/novnc.tgz" -C "$T/pkg" noVNC-1.7.0
SUM=$(sha256sum "$T/novnc.tgz" | cut -d' ' -f1)
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "curl $*" >> "$CALLS"\nwhile [ $# -gt 0 ]; do [ "$1" = -o ] && { cp "%s" "$2"; exit 0; }; shift; done\n' "$T/novnc.tgz" > "$T/bin/curl"
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "uv $*" >> "$CALLS"\n[ "$1 $2" = "tool list" ] && [ -n "${HAD_WEBSOCKIFY:-}" ] && echo "websockify v0.12.0"\n[ "$1 $2" = "tool install" ] && { mkdir -p "%s/home/.local/bin"; printf "#!/bin/sh\\n" > "%s/home/.local/bin/websockify"; chmod +x "%s/home/.local/bin/websockify"; }\nexit 0\n' "$T" "$T" "$T" > "$T/bin/uv"
# shellcheck disable=SC2016
printf '#!/bin/sh\nif [ "$1" = -nG ]; then [ -n "${FAKE_MEMBER:-}" ] && echo "dev cerberus-s10" || echo dev; exit 0; fi\nexec /usr/bin/id "$@"\n' > "$T/bin/id"
chmod +x "$T"/bin/*
H=$T/home
inst() { HOME=$H PATH="$T/bin:$PATH" S10_UV=$T/bin/uv S10_CURL=$T/bin/curl S10_NOVNC_SHA256=${SHA:-$SUM} bash "$DEV/install-dev.sh" "$@"; }
: > "$CALLS"
FAKE_MEMBER=1 inst > "$T/out" 2>&1; rc=$?
ok "install exits 0" "[ $rc -eq 0 ]"
ok "install: adb guard, tela-web, env, unit" "cmp -s '$DEV/adb' '$H/.local/bin/adb' && cmp -s '$DEV/s10-tela-web' '$H/.local/bin/s10-tela-web' && cmp -s '$DEV/s10-adb.env.sh' '$H/.config/dev/env.d/s10-adb.sh' && cmp -s '$DEV/s10-tela-web.service' '$H/.config/systemd/user/s10-tela-web.service'"
ok "install: executables 0755" "[ \"\$(stat -c %a '$H/.local/bin/adb')\" = 755 ] && [ \"\$(stat -c %a '$H/.local/bin/s10-tela-web')\" = 755 ]"
ok "install: websockify pinned through uv" "grep -qx 'uv tool install --quiet websockify==0.13.0' '$CALLS'"
ok "install: noVNC extracted with version mark" "[ -f '$H/.local/share/s10-tela-web/novnc/vnc.html' ] && grep -qx 1.7.0 '$H/.local/share/s10-tela-web/novnc/.version'"
ok "install: member -> enable + restart the unit" "grep -qx 'systemctl --user enable s10-tela-web.service' '$CALLS' && grep -qx 'systemctl --user restart s10-tela-web.service' '$CALLS'"
ok "install: password masked in the output" "! grep -q '$FAKE_PW' '$T/out'"
: > "$CALLS"
FAKE_MEMBER=1 inst > "$T/out" 2>&1
ok "install idempotent: noVNC not downloaded again" "[ $? -eq 0 ] && ! grep -q '^curl' '$CALLS'"
rm -rf "$H/.local/share/s10-tela-web"; : > "$CALLS"
SHA=0000 FAKE_MEMBER=1 inst > "$T/out" 2>&1; rc=$?
ok "install: wrong sha256 -> refuses, nothing extracted" "[ $rc -ne 0 ] && grep -q 'sha256' '$T/out' && [ ! -e '$H/.local/share/s10-tela-web/novnc' ]"
: > "$CALLS"
inst > "$T/out" 2>&1; rc=$?
ok "install without the group: enables but does not start, explains" "[ $rc -eq 0 ] && ! grep -q 'restart' '$CALLS' && grep -q 'dev-user' '$T/out'"
inst --check > "$T/out" 2>&1; rc=$?
ok "check reports the missing group" "[ $rc -ne 0 ] && grep -q 'FALTA:  grupo cerberus-s10' '$T/out'"
: > "$CALLS"
inst --undo > "$T/out" 2>&1; rc=$?
ok "undo removes files and the uv tool it installed" "[ $rc -eq 0 ] && [ ! -e '$H/.local/bin/adb' ] && [ ! -e '$H/.config/dev/env.d/s10-adb.sh' ] && [ ! -e '$H/.config/environment.d/s10-adb.conf' ] && [ ! -e '$H/.local/share/s10-tela-web' ] && grep -qx 'uv tool uninstall websockify' '$CALLS'"
# an adb and a websockify the account already had survive install + undo
printf '#!/bin/sh\necho meu adb\n' > "$H/.local/bin/adb"
HAD_WEBSOCKIFY=1 FAKE_MEMBER=1 inst > "$T/out" 2>&1
ok "install keeps a foreign adb as adb.antes-s10" "grep -q 'meu adb' '$H/.local/bin/adb.antes-s10' && cmp -s '$DEV/adb' '$H/.local/bin/adb'"
ok "install writes environment.d for systemd --user" "grep -qx 'ADB_SERVER_SOCKET=localfilesystem:/run/cerberus-s10/adb.sock' '$H/.config/environment.d/s10-adb.conf'"
: > "$CALLS"
inst --undo > "$T/out" 2>&1
ok "undo restores the foreign adb and keeps the preexisting websockify" "grep -q 'meu adb' '$H/.local/bin/adb' && [ ! -e '$H/.local/bin/adb.antes-s10' ] && ! grep -q 'uv tool uninstall' '$CALLS'"
# no systemd --user bus: clear message, exit 1
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "systemctl $*" >> "$CALLS"\nexit 1\n' > "$T/bin/systemctl-nobus"; chmod +x "$T/bin/systemctl-nobus"
S10_SYSTEMCTL=$T/bin/systemctl-nobus FAKE_MEMBER=1 inst > "$T/out" 2>&1; rc=$?
ok "no systemd --user: explains linger, exit 1" "[ $rc -ne 0 ] && grep -q 'enable-linger' '$T/out'"
echo "--- $n checks, $fail failed"
[ "$fail" -eq 0 ]
