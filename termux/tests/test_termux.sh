#!/bin/bash
# Tests for termux/bootstrap.sh and termux/boot/20-guardian.sh with fake pkg/sshd/pgrep in a temp HOME.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir "$T/bin" "$T/home" "$T/prefix"
export HOME=$T/home PREFIX=$T/prefix LOG_CALLS=$T/calls
# shellcheck disable=SC2016  # fake scripts are generated with literal $LOG_CALLS
for c in pkg pkill sshd termux-wake-lock termux-reload-settings; do
    printf '#!/bin/sh\necho "%s $*" >> "$LOG_CALLS"\nexit 0\n' "$c" > "$T/bin/$c"
done
# pgrep: succeeds only if $T/sshd.up exists
printf '#!/bin/sh\n[ -e "%s/sshd.up" ]\n' "$T" > "$T/bin/pgrep"
chmod +x "$T"/bin/*
export PATH="$T/bin:$PATH"
fail=0 n=0
ok() { n=$((n + 1)); if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=$((fail + 1)); fi; }

printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest nomad\n' > "$T/keys.pub"
sh "$HERE/../bootstrap.sh" "$T/keys.pub" > "$T/out" 2>&1; rc=$?
ok "bootstrap exits 0" "[ $rc -eq 0 ]"
ok "allow-external-apps false" "grep -qx 'allow-external-apps=false' '$HOME/.termux/termux.properties'"
ok "settings reloaded" "grep -q 'termux-reload-settings' '$LOG_CALLS'"
for opt in 'ListenAddress 100.64.0.10' "AllowUsers $(whoami)" 'MaxAuthTries 2' 'LoginGraceTime 15' 'AuthenticationMethods publickey' 'PasswordAuthentication no'; do
    ok "sshd_config: $opt" "grep -qx '$opt' '$PREFIX/etc/ssh/sshd_config'"
done
ok "guardian installed 0700" "[ -x '$HOME/.termux/boot/20-guardian.sh' ]"
ok "10-sshd installed" "[ -x '$HOME/.termux/boot/10-sshd.sh' ]"
ok "bashrc hook v2" "grep -q '# s10-guardian v2' '$HOME/.bashrc'"
ok "hook starts sshd if missing" "grep -qF 'pgrep -x sshd >/dev/null || sshd' '$HOME/.bashrc'"
ok "hook takes wake lock" "grep -qx 'termux-wake-lock' '$HOME/.bashrc'"
ok "hook starts the guardian once" "grep -qF 'pgrep -f 20-guardian.sh >/dev/null ||' '$HOME/.bashrc'"
ok "sshd Port 8022" "grep -qx 'Port 8022' '$PREFIX/etc/ssh/sshd_config'"
ok "key authorized" "grep -q 'AAAAC3NzaC1lZDI1NTE5AAAAItest' '$HOME/.ssh/authorized_keys'"

# idempotent + replaces a commented/false property, appends new key without dup
printf 'allow-external-apps = true\nbell-character=ignore\n' > "$HOME/.termux/termux.properties"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIatheron atheron\n' >> "$T/keys.pub"
sh "$HERE/../bootstrap.sh" "$T/keys.pub" > "$T/out" 2>&1
sh "$HERE/../bootstrap.sh" "$T/keys.pub" > "$T/out" 2>&1
ok "true migrated to false, once" "[ \$(grep -c 'allow-external-apps' '$HOME/.termux/termux.properties') -eq 1 ] && grep -qx 'allow-external-apps=false' '$HOME/.termux/termux.properties'"
S10_TAILNET_IP=100.64.0.20 sh "$HERE/../bootstrap.sh" "$T/keys.pub" > "$T/out" 2>&1
ok "ListenAddress follows S10_TAILNET_IP (no duplicate)" "grep -qx 'ListenAddress 100.64.0.20' '$PREFIX/etc/ssh/sshd_config' && [ \$(grep -c '^ListenAddress' '$PREFIX/etc/ssh/sshd_config') -eq 1 ]"
ok "other properties kept" "grep -qx 'bell-character=ignore' '$HOME/.termux/termux.properties'"
ok "no duplicate keys" "[ \$(wc -l < '$HOME/.ssh/authorized_keys') -eq 2 ]"
ok "bashrc hook once" "[ \$(grep -c '# s10-guardian' '$HOME/.bashrc') -eq 1 ]"
# migration from the old 2-line hook, keeping the user's own lines
# shellcheck disable=SC2016  # literal old hook text
printf 'alias ll="ls -l"\n# s10-guardian\n[ -x "$HOME/.termux/boot/20-guardian.sh" ] && (nohup x &)\nexport FOO=1\n' > "$HOME/.bashrc"
sh "$HERE/../bootstrap.sh" "$T/keys.pub" > "$T/out" 2>&1
ok "old hook migrated" "! grep -q 'nohup x' '$HOME/.bashrc' && grep -q '# s10-guardian v2' '$HOME/.bashrc'"
ok "user lines kept after migration" "grep -qx 'alias ll=\"ls -l\"' '$HOME/.bashrc' && grep -qx 'export FOO=1' '$HOME/.bashrc'"
sh "$HERE/../bootstrap.sh" /nonexistent > "$T/out" 2>&1; rc=$?
ok "missing keys file rejected" "[ $rc -ne 0 ]"

# guardian: sshd down -> restart + log; sshd up -> nothing
: > "$LOG_CALLS"
export GUARDIAN_ONCE=1 GUARDIAN_LOG=$T/g.log GUARDIAN_PID=$T/g.pid
sh "$HERE/../boot/20-guardian.sh"
ok "guardian restarts sshd when down" "grep -q '^sshd' '$LOG_CALLS' && grep -q 'sshd restarted' '$T/g.log'"
ok "guardian holds wake lock" "grep -q 'termux-wake-lock' '$LOG_CALLS'"
touch "$T/sshd.up"; : > "$LOG_CALLS"; rm -f "$T/g.pid"
sh "$HERE/../boot/20-guardian.sh"
ok "guardian leaves a live sshd alone" "! grep -q '^sshd' '$LOG_CALLS'"

# rotation
head -c 400 /dev/zero | tr '\0' x > "$T/g.log"; rm -f "$T/g.pid"
GUARDIAN_MAX_BYTES=100 sh "$HERE/../boot/20-guardian.sh"
ok "log rotated to .1" "[ -f '$T/g.log.1' ] && grep -q 'log rotated' '$T/g.log'"

# single instance
sleep 30 & SP=$!
echo $SP > "$T/g.pid"; : > "$LOG_CALLS"
sh "$HERE/../boot/20-guardian.sh"
ok "single instance: exits when pidfile process alive" "! grep -q wake-lock '$LOG_CALLS'"
kill $SP 2>/dev/null; wait $SP 2>/dev/null

# sshd_config com várias linhas ListenAddress comentadas/duplicadas -> uma só
printf '#ListenAddress 0.0.0.0\n#ListenAddress ::\nListenAddress 10.0.0.1\nListenAddress 10.0.0.2\nPort 22\n' > "$PREFIX/etc/ssh/sshd_config"
sh "$HERE/../bootstrap.sh" "$T/keys.pub" > "$T/out" 2>&1
ok "single ListenAddress after cleaning duplicates" "[ \$(grep -c 'ListenAddress' '$PREFIX/etc/ssh/sshd_config') -eq 1 ]"
ok "sshd_config options appear once" "[ \$(grep -c '^MaxAuthTries' '$PREFIX/etc/ssh/sshd_config') -eq 1 ] && [ \$(grep -c '^Port ' '$PREFIX/etc/ssh/sshd_config') -eq 1 ]"

# --remove-key: tira só a chave com o comentário dado
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIatheronkey atheron-s10\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAInomadkey nomad\n' > "$HOME/.ssh/authorized_keys"
sh "$HERE/../bootstrap.sh" --remove-key atheron-s10 > "$T/out" 2>&1; rc=$?
ok "remove-key exits 0" "[ $rc -eq 0 ] && grep -q '1 chave' '$T/out'"
ok "atheron key removed, nomad kept" "! grep -q atheron-s10 '$HOME/.ssh/authorized_keys' && grep -q ' nomad\$' '$HOME/.ssh/authorized_keys'"
ok "authorized_keys stays 0600" "[ \$(stat -c %a '$HOME/.ssh/authorized_keys') = 600 ]"
sh "$HERE/../bootstrap.sh" --remove-key > /dev/null 2>&1; rc=$?
ok "remove-key without a comment fails" "[ $rc -ne 0 ]"
ok "example has no atheron key" "! grep -v '^#' '$HERE/../authorized_keys.example' | grep -q atheron"

echo "--- $n checks, $fail failed"
[ "$fail" -eq 0 ]
