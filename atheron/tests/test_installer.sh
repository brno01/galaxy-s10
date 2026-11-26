#!/bin/bash
# Tests for the --vnc-key and --tunnel-key modes of user-step-s10.sh (non-root, temp dirs, no systemctl).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
INST=$HERE/../user-step-s10.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export S10_ALLOW_NONROOT=1 S10_ETC="$T/etc" S10_TUNNEL_HOME="$T/home"
fail=0 n=0
ok() { n=$((n + 1)); if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=$((fail + 1)); fi; }
KEY=Ab3-xyz_9.key~
printf '%s\n' "$KEY" | bash "$INST" --vnc-key > "$T/out" 2> "$T/err"; rc=$?
ok "vnc-key exits 0" "[ $rc -eq 0 ]"
ok "vnc-key file 0600 with the key" "[ \"\$(stat -c %a '$T/etc/vnc-access-key')\" = 600 ] && [ \"\$(cat '$T/etc/vnc-access-key')\" = '$KEY' ]"
ok "key never printed" "! grep -q -- '$KEY' '$T/out' '$T/err'"
ok "etc dir 0700" "[ \"\$(stat -c %a '$T/etc')\" = 700 ]"
printf 'bad key; reboot\n' | bash "$INST" --vnc-key > "$T/out" 2> "$T/err"; rc=$?
ok "invalid key rejected" "[ $rc -ne 0 ] && grep -q inválida '$T/err'"
ok "invalid key leaves the old one" "[ \"\$(cat '$T/etc/vnc-access-key')\" = '$KEY' ]"
printf '' | bash "$INST" --vnc-key > /dev/null 2>&1; rc=$?
ok "empty key rejected" "[ $rc -ne 0 ]"

PUB="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItestkey nomad"
printf '# c\n%s\ncommand="evil" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIother x\n\n' "$PUB" > "$T/nomad.pub"
bash "$INST" --tunnel-key "$T/nomad.pub" > "$T/out" 2> "$T/err"; rc=$?
AK=$T/home/.ssh/authorized_keys
ok "tunnel-key exits 0" "[ $rc -eq 0 ]"
ok "authorized_keys 0600, .ssh 0700" "[ \"\$(stat -c %a '$AK')\" = 600 ] && [ \"\$(stat -c %a '$T/home/.ssh')\" = 700 ]"
ok "exactly one key line (option-bearing line refused)" "[ \$(grep -c . '$AK') -eq 1 ] && ! grep -q evil '$AK'"
ok "restrict + port-forwarding" "grep -q '^restrict,port-forwarding,' '$AK'"
ok "remote forwards blocked" "grep -q 'permitlisten=\"127.0.0.1:1\"' '$AK'"
ok "only the video port and the adb socket (bracket form)" "grep -qF 'permitopen=\"127.0.0.1:27183\",permitopen=\"[/run/cerberus-s10/adb.sock]:*\"' '$AK'"
ok "forced command" "grep -q 'command=\"/usr/local/sbin/cerberus-s10-estado\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItestkey nomad\$' '$AK'"
bash "$INST" --tunnel-key "$T/nomad.pub" > /dev/null 2>&1
ok "idempotent" "[ \$(grep -c . '$AK') -eq 1 ]"
bash "$INST" --tunnel-key /nonexistent > /dev/null 2>&1; rc=$?
ok "missing file rejected" "[ $rc -ne 0 ]"
printf 'garbage\n' > "$T/bad.pub"
bash "$INST" --tunnel-key "$T/bad.pub" > /dev/null 2>&1; rc=$?
ok "no valid key rejected" "[ $rc -ne 0 ]"
# migração: linha antiga (inválida) da mesma chave e de outra chave que não está no arquivo passado
OLD='restrict,port-forwarding,permitlisten="127.0.0.1:1",permitopen="127.0.0.1:27183",permitopen="/run/cerberus-s10/adb.sock:*",command="/usr/local/sbin/cerberus-s10-estado"'
printf '%s ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIotherkey outro\n%s %s\n' "$OLD" "$OLD" "$PUB" > "$AK"
bash "$INST" --tunnel-key "$T/nomad.pub" > /dev/null 2>&1
ok "old form never survives" "! grep -qF 'permitopen=\"/run/cerberus-s10/adb.sock:' '$AK'"
ok "other key migrated to the bracket form" "grep -qF '[/run/cerberus-s10/adb.sock]:*\",command=\"/usr/local/sbin/cerberus-s10-estado\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIotherkey outro' '$AK'"
ok "same key not duplicated" "[ \$(grep -c 'AAAAC3NzaC1lZDI1NTE5AAAAItestkey' '$AK') -eq 1 ]"
ok "no permitopen with a bare path anywhere" "! grep -q 'permitopen=\"/' '$AK'"
ok "sshd drop-in: local forwarding only" "grep -q 'Match User s10tunnel' '$HERE/../50-s10tunnel.conf' && grep -q 'AllowStreamLocalForwarding local' '$HERE/../50-s10tunnel.conf' && grep -q 'AllowTcpForwarding local' '$HERE/../50-s10tunnel.conf' && grep -q 'PermitTTY no' '$HERE/../50-s10tunnel.conf' && grep -q 'X11Forwarding no' '$HERE/../50-s10tunnel.conf' && grep -q 'AllowAgentForwarding no' '$HERE/../50-s10tunnel.conf'"
ok "installer validates sshd before reload and sets the shell" "grep -q 'sshd -t' '$HERE/../user-step-s10.sh' && grep -q 'usermod -s \"\$ESTADO_BIN\"' '$HERE/../user-step-s10.sh' && grep -q '\$SHELLS' '$HERE/../user-step-s10.sh'"
ok "unit: UMask=0007" "grep -qx 'UMask=0007' '$HERE/../cerberus-s10.service'"
ok "forced command script only prints the state" "grep -qx 'exec cat /run/cerberus-s10/estado.json' '$HERE/../cerberus-s10-estado'"
ok "udev: only the S10 product, group cerberus-s10" "grep -q 'idProduct}==\"6860\", MODE=\"0660\", GROUP=\"cerberus-s10\"' '$HERE/../51-cerberus-s10.rules' && ! grep -q 'plugdev\$' '$HERE/../51-cerberus-s10.rules'"
for opt in ProtectProc=invisible ProcSubset=pid MemoryDenyWriteExecute=yes SystemCallFilter=@system-service RuntimeDirectoryMode=0750 "Wants=network-online.target" "LoadCredential=vnc-password:"; do
    ok "unit: $opt" "grep -q '$opt' '$HERE/../cerberus-s10.service'"
done
ok "unit: tailscaled ordering" "grep -q '^After=.*network-online.target tailscaled.service' '$HERE/../cerberus-s10.service'"
ok "unit: public dir writable, optional (dash prefix)" "grep -qx 'ReadWritePaths=-/run/cerberus-s10-publico' '$HERE/../cerberus-s10.service' && grep -qx 'ProtectSystem=strict' '$HERE/../cerberus-s10.service' && grep -qx 'UMask=0007' '$HERE/../cerberus-s10.service'"
ok "unit: no Environment for the public path (default in code)" "! grep -q S10_PUBLIC '$HERE/../cerberus-s10.service'"
ok "tmpfiles: public dir 0755 cerberus-s10" "grep -qx 'd /run/cerberus-s10-publico 0755 cerberus-s10 cerberus-s10 -' '$HERE/../cerberus-s10-publico.tmpfiles'"
ok "installer installs and removes the tmpfiles" "grep -q 'tmpfiles.d/cerberus-s10-publico.conf' '$HERE/../user-step-s10.sh' && grep -q 'systemd-tmpfiles --create' '$HERE/../user-step-s10.sh'"
ok "installer --check looks at resumo.json mode" "grep -q 'resumo.json' '$HERE/../user-step-s10.sh'"
# --dev-user / --dev-user-undo: a development account gets the adb socket (group) and the VNC password (0600)
mkdir -p "$T/bin" "$T/devhome"
# fake id/usermod/gpasswd/getent record calls; the "dev" account exists, "ghost" does not
cat > "$T/bin/getent" <<EOF2
#!/bin/sh
[ "\$1 \$2" = "passwd dev" ] && { echo "dev:x:1500:1500::$T/devhome:/bin/bash"; exit 0; }
[ "\$1 \$2" = "passwd root" ] && { echo "root:x:0:0::/root:/bin/bash"; exit 0; }
exit 2
EOF2
# shellcheck disable=SC2016  # literal $LOG_DEV in the fakes
for c in usermod gpasswd; do printf '#!/bin/sh\necho "%s $*" >> "$LOG_DEV"\n' "$c" > "$T/bin/$c"; done
# shellcheck disable=SC2016
printf '#!/bin/sh\nif [ "$1" = -nG ]; then [ -e "$GROUP_MEMBER" ] && echo "dev cerberus-s10" || echo dev; exit 0; fi\nexec /usr/bin/id "$@"\n' > "$T/bin/id"
# fake runuser: records who it runs as, then runs the command (same uid in the tests)
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "runuser $1 $2" >> "$LOG_DEV"\nshift 3\nexec "$@"\n' > "$T/bin/runuser"
chmod +x "$T"/bin/*
export LOG_DEV=$T/devcalls GROUP_MEMBER=$T/member S10_RUNUSER=$T/bin/runuser
FAKE_PW=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12)   # random per run: no credential-looking literal in git
printf '%s\n' "$FAKE_PW" > "$T/etc/vnc-password"; chmod 600 "$T/etc/vnc-password"
: > "$LOG_DEV"
PATH="$T/bin:$PATH" bash "$INST" --dev-user dev > "$T/out" 2>&1; rc=$?
ok "dev-user exits 0" "[ $rc -eq 0 ]"
ok "dev-user adds the account to cerberus-s10" "grep -qx 'usermod -aG cerberus-s10 dev' '$LOG_DEV'"
ok "dev-user copies the VNC password 0600 into the account" "cmp -s '$T/etc/vnc-password' '$T/devhome/.config/s10/vnc-password' && [ \"\$(stat -c %a '$T/devhome/.config/s10/vnc-password')\" = 600 ] && [ \"\$(stat -c %a '$T/devhome/.config/s10')\" = 700 ]"
ok "dev-user says a new login is needed" "grep -q 'login' '$T/out'"
ok "the copy is written AS the account (root never writes in its home)" "grep -qx 'runuser -u dev' '$LOG_DEV' && ! grep -q 'cp \"\$PWFILE\"' '$INST'"
ok "dev-user creates a missing ~/.config as the account" "[ -d '$T/devhome/.config' ]"
: > "$LOG_DEV"; touch "$GROUP_MEMBER"
PATH="$T/bin:$PATH" bash "$INST" --dev-user dev > "$T/out" 2>&1; rc=$?
ok "dev-user idempotent: already a member, no usermod" "[ $rc -eq 0 ] && ! grep -q usermod '$LOG_DEV'"
ok "rerun refreshes the password copy" "cmp -s '$T/etc/vnc-password' '$T/devhome/.config/s10/vnc-password'"
for bad in root cerberus-s10 s10tunnel ghost ''; do
    : > "$LOG_DEV"
    PATH="$T/bin:$PATH" bash "$INST" --dev-user "$bad" > "$T/out" 2>&1; rc=$?
    ok "dev-user refuses '$bad'" "[ $rc -ne 0 ] && [ ! -s '$LOG_DEV' ]"
done
: > "$LOG_DEV"
PATH="$T/bin:$PATH" bash "$INST" --dev-user-undo dev > "$T/out" 2>&1; rc=$?
ok "dev-user-undo removes the group and the password copy (as the account)" "[ $rc -eq 0 ] && grep -qx 'gpasswd -d dev cerberus-s10' '$LOG_DEV' && grep -qx 'runuser -u dev' '$LOG_DEV' && [ ! -e '$T/devhome/.config/s10/vnc-password' ]"
rm -f "$GROUP_MEMBER"; : > "$LOG_DEV"
PATH="$T/bin:$PATH" bash "$INST" --dev-user-undo dev > "$T/out" 2>&1; rc=$?
ok "dev-user-undo idempotent: not a member, no gpasswd" "[ $rc -eq 0 ] && ! grep -q gpasswd '$LOG_DEV'"

echo "--- $n checks, $fail failed"
[ "$fail" -eq 0 ]
