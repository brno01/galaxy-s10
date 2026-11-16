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
echo "--- $n checks, $fail failed"
[ "$fail" -eq 0 ]
