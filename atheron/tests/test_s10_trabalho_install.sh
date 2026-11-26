#!/bin/bash
# Tests for atheron/user-step-s10-trabalho.sh, s10-trabalho, s10-adb and s10-run (temp root, fake system commands).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
A=$HERE/..
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/root"
export CALLS=$T/calls GROUPS_DB=$T/groups
fail=0 n=0
ok() { n=$((n + 1)); if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=$((fail + 1)); fi; }
# fake getent over a tiny groups file; clubpetro uid 1002, claude 1001
cat > "$T/bin/getent" <<'EOF'
#!/bin/sh
case "$1 $2" in
"passwd clubpetro") echo "clubpetro:x:1002:1003::/home/clubpetro:/bin/bash" ;;
"passwd claude") echo "claude:x:1001:1002::/home/claude:/bin/bash" ;;
"group s10-trabalho") grep '^s10-trabalho:' "$GROUPS_DB" 2>/dev/null || exit 2 ;;
"group cerberus-s10") grep '^cerberus-s10:' "$GROUPS_DB" 2>/dev/null || echo "cerberus-s10:x:977:claude" ;;
*) exit 2 ;;
esac
EOF
# shellcheck disable=SC2016  # literal variables in the fakes
printf '#!/bin/sh\necho "groupadd $*" >> "$CALLS"\necho "s10-trabalho:x:990:" >> "$GROUPS_DB"\n' > "$T/bin/groupadd"
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "usermod $*" >> "$CALLS"\nsed -i "s/^s10-trabalho:x:990:.*/s10-trabalho:x:990:$3/" "$GROUPS_DB"\n' > "$T/bin/usermod"
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "gpasswd $*" >> "$CALLS"\n' > "$T/bin/gpasswd"
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "groupdel $*" >> "$CALLS"\nsed -i "/^s10-trabalho:/d" "$GROUPS_DB"\n' > "$T/bin/groupdel"
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "systemctl $*" >> "$CALLS"\ncase "$1" in is-active) [ -n "${FAKE_ACTIVE:-}" ] ;; is-enabled) exit 1 ;; show) echo "Wed 2026-11-25 10:00:00 -03" ;; esac\n' > "$T/bin/systemctl"
# fake visudo: refuses a file without NOPASSWD (stands for "invalid")
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "visudo $*" >> "$CALLS"\ngrep -q NOPASSWD "$2"\n' > "$T/bin/visudo"
chmod +x "$T"/bin/*
export S10_ALLOW_NONROOT=1 S10_TRABALHO_ROOT=$T/root S10_SKIP_TESTS=1 S10_GETENT=$T/bin/getent S10_GROUPADD=$T/bin/groupadd \
    S10_USERMOD=$T/bin/usermod S10_GPASSWD=$T/bin/gpasswd S10_GROUPDEL=$T/bin/groupdel S10_SYSTEMCTL=$T/bin/systemctl \
    S10_VISUDO=$T/bin/visudo
R=$T/root
inst() { : > "$CALLS"; bash "$A/user-step-s10-trabalho.sh" "$@" > "$T/out" 2>&1; }

inst; rc=$?
ok "install exits 0" "[ $rc -eq 0 ]"
ok "group created, work account added" "grep -qx 'groupadd --system s10-trabalho' '$CALLS' && grep -qx 'usermod -aG s10-trabalho clubpetro' '$CALLS'"
ok "work account NOT added to cerberus-s10" "! grep -q 'cerberus-s10 clubpetro\|-aG cerberus-s10' '$CALLS'"
ok "broker, commands and unit installed" "cmp -s '$A/s10-trabalho-adb' '$R/usr/local/sbin/s10-trabalho-adb' && [ -x '$R/usr/local/bin/s10-adb' ] && [ -x '$R/usr/local/bin/s10-run' ] && [ -x '$R/usr/local/bin/s10-trabalho' ] && cmp -s '$A/s10-trabalho-adb.service' '$R/etc/systemd/system/s10-trabalho-adb.service'"
ok "defaults: numeric uid of the work account; tcpip, VNC and sshd denied" "grep -qx 'S10_TRABALHO_UIDS=1002' '$R/etc/default/s10-trabalho' && grep -qx 'S10_TRABALHO_DENY_TCP=\"5555 5900 8022\"' '$R/etc/default/s10-trabalho'"
ok "sudoers: only restart/stop of the unit, for claude, 0440, validated" "grep -qx 'claude ALL=(root) NOPASSWD: /usr/bin/systemctl restart s10-trabalho-adb.service, /usr/bin/systemctl stop s10-trabalho-adb.service' '$R/etc/sudoers.d/s10-trabalho' && [ \"\$(stat -c %a '$R/etc/sudoers.d/s10-trabalho')\" = 440 ] && grep -q '^visudo -cf' '$CALLS'"
ok "unit is not enabled nor started (window closed)" "! grep -qE 'systemctl (enable|start|restart)' '$CALLS' && grep -qx 'systemctl daemon-reload' '$CALLS'"
# guardian ports come from its config; the owner's package list survives a reinstall
mkdir -p "$R/etc/default"; printf 'S10_VNC_PORT=5901\nS10_SSH_PORT=8222\n' > "$R/etc/default/cerberus-s10"
echo 'S10_TRABALHO_PACOTES="br.com.empresa"' >> "$R/etc/default/s10-trabalho"
inst; rc=$?
ok "deny list follows the guardian's ports" "grep -qx 'S10_TRABALHO_DENY_TCP=\"5555 5901 8222\"' '$R/etc/default/s10-trabalho'"
ok "package list kept across reinstalls" "grep -qx 'S10_TRABALHO_PACOTES=\"br.com.empresa\"' '$R/etc/default/s10-trabalho'"
ok "idempotent: group and membership not redone" "[ $rc -eq 0 ] && ! grep -q groupadd '$CALLS' && ! grep -q usermod '$CALLS'"
S10_WORK_USER=claude inst; rc=$?
ok "work and personal account must differ" "[ $rc -eq 2 ]"
S10_WORK_USER=root inst; rc=$?
ok "root as work account refused" "[ $rc -eq 2 ]"
S10_WORK_USER=ninguem inst; rc=$?
ok "missing work account refused" "[ $rc -eq 2 ] && grep -q 'não existe' '$T/out'"
# an invalid sudoers never goes live
rm -f "$R/etc/sudoers.d/s10-trabalho"
S10_PERSONAL_USER=claude S10_VISUDO=/bin/false inst; rc=$?
ok "sudoers refused by visudo: not installed, exit 1" "[ $rc -ne 0 ] && [ ! -e '$R/etc/sudoers.d/s10-trabalho' ]"
inst
inst --check; rc=$?
ok "check passes after install" "[ $rc -eq 0 ] && grep -q 'clubpetro fora do grupo cerberus-s10' '$T/out' && grep -q 'janela fechada' '$T/out'"
inst --undo; rc=$?
ok "undo removes files, sudoers and the group" "[ $rc -eq 0 ] && [ ! -e '$R/usr/local/sbin/s10-trabalho-adb' ] && [ ! -e '$R/etc/sudoers.d/s10-trabalho' ] && grep -qx 'groupdel s10-trabalho' '$CALLS' && grep -q 'systemctl stop s10-trabalho-adb.service' '$CALLS'"

# s10-trabalho (window control)
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "sudo $*" >> "$CALLS"\nshift; exec "$@"\n' > "$T/bin/sudo"; chmod +x "$T/bin/sudo"
win() { : > "$CALLS"; S10_SUDO=$T/bin/sudo S10_JOURNALCTL=$T/bin/systemctl bash "$A/s10-trabalho" "$@" > "$T/out" 2>&1; }
win liga
ok "liga: sudo -n restart of the unit" "grep -qx 'sudo -n $T/bin/systemctl restart s10-trabalho-adb.service' '$CALLS'"
win desliga
ok "desliga: sudo -n stop" "grep -qx 'sudo -n $T/bin/systemctl stop s10-trabalho-adb.service' '$CALLS'"
FAKE_ACTIVE=1 win status
ok "status open shows since when" "grep -q 'ABERTO desde Wed 2026-11-25' '$T/out'"
win status
ok "status closed" "grep -q 'fechado' '$T/out'"
win log 5
ok "log reads the journal of the unit" "grep -q -- '-u s10-trabalho-adb.service -n 5' '$CALLS'"

# s10-adb / s10-run (work account side)
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "adb $ADB_SERVER_SOCKET port=${ANDROID_ADB_SERVER_PORT:-} $*" >> "$CALLS"\n' > "$T/bin/fakeadb"; chmod +x "$T/bin/fakeadb"
: > "$CALLS"
S10_TRABALHO_SOCKET=$T/nope.sock S10_ADB_BIN=$T/bin/fakeadb sh "$A/s10-adb" devices > "$T/out" 2>&1; rc=$?
ok "s10-adb with the window closed: clear message, exit 69, no adb" "[ $rc -eq 69 ] && grep -q 's10-trabalho liga' '$T/out' && [ ! -s '$CALLS' ]"
python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" "$T/b.sock"
ANDROID_ADB_SERVER_PORT=5038 S10_TRABALHO_SOCKET=$T/b.sock S10_ADB_BIN=$T/bin/fakeadb sh "$A/s10-adb" install app.apk; rc=$?
ok "s10-adb: broker socket, account's own port ignored" "[ $rc -eq 0 ] && grep -qx 'adb localfilesystem:$T/b.sock port= install app.apk' '$CALLS'"
: > "$CALLS"
ANDROID_ADB_SERVER_PORT=5038 S10_TRABALHO_SOCKET=$T/b.sock sh "$A/s10-run" "$T/bin/fakeadb" devices; rc=$?
ok "s10-run runs the command with the broker socket" "[ $rc -eq 0 ] && grep -qx 'adb localfilesystem:$T/b.sock port= devices' '$CALLS'"
sh "$A/s10-run" > /dev/null 2>&1; rc=$?
ok "s10-run without a command: usage" "[ $rc -eq 2 ]"
ok "unit: unix sockets only, no restart, 8 h window, not WantedBy" "grep -qx 'RestrictAddressFamilies=AF_UNIX' '$A/s10-trabalho-adb.service' && grep -qx 'IPAddressDeny=any' '$A/s10-trabalho-adb.service' && grep -qx 'RuntimeMaxSec=8h' '$A/s10-trabalho-adb.service' && grep -qx 'Restart=no' '$A/s10-trabalho-adb.service' && ! grep -q WantedBy '$A/s10-trabalho-adb.service'"
echo "--- $n checks, $fail failed"
[ "$fail" -eq 0 ]
