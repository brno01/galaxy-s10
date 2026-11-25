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
# without any site value the bootstrap refuses (no real default exists), before touching sshd_config
sh "$HERE/../bootstrap.sh" "$T/keys.pub" > "$T/out" 2>&1; rc=$?
ok "bootstrap without tailnet IP fails clearly" "[ $rc -ne 0 ] && grep -q 'S10_TAILNET_IP' '$T/out' && [ ! -e '$HOME/.s10.conf' ]"
printf 'S10_TAILNET_IP=100.64.0.10\nGUARDIAN_WAKE_SUBNET=192.0.2.\nGUARDIAN_ATHERON_IPS=192.0.2.10 192.0.2.11\nATHERON_MAC=02:00:00:00:00:aa\nATHERON_BCAST=192.0.2.255\n' > "$T/site.conf"
S10_CONF_SRC="$T/site.conf" sh "$HERE/../bootstrap.sh" "$T/keys.pub" > "$T/out" 2>&1; rc=$?
ok "config written to ~/.s10.conf, 0600" "cmp -s '$T/site.conf' '$HOME/.s10.conf' && [ \"\$(stat -c %a '$HOME/.s10.conf')\" = 600 ]"
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
ok "socat installed (Wake-on-LAN)" "grep -q '^pkg install .*socat' '$LOG_CALLS'"
ok "acordar-atheron installed 0700" "[ -x '$PREFIX/bin/acordar-atheron' ] && [ \"\$(stat -c %a '$PREFIX/bin/acordar-atheron')\" = 700 ]"

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

# site values: read from ~/.s10.conf (data, not executed); GUARDIAN_* env wins; nothing real by default
ok "acordar-atheron: MAC and broadcast from ~/.s10.conf" "[ \"\$(sh '$HERE/../acordar-atheron' --dump | od -An -tx1 | tr -d ' \n' | tail -c 12)\" = 0200000000aa ]"
ok "acordar-atheron: argument wins over the file" "[ \"\$(sh '$HERE/../acordar-atheron' --dump 02:00:00:00:00:bb | od -An -tx1 | tr -d ' \n' | tail -c 12)\" = 0200000000bb ]"
ok "acordar-atheron: no MAC configured is an error" "S10_CONF='$T/none' sh '$HERE/../acordar-atheron' --dump > '$T/o' 2>&1; [ \$? -eq 2 ] && grep -q 'não configurado' '$T/o'"
ok "acordar-atheron: no broadcast configured is an error" "printf 'ATHERON_MAC=02:00:00:00:00:aa\n' > '$T/mac.conf'; S10_CONF='$T/mac.conf' sh '$HERE/../acordar-atheron' > '$T/o' 2>&1; [ \$? -eq 2 ] && grep -q 'broadcast' '$T/o'"
# guardian: tailnet address falls back to ~/.s10.conf when sshd_config has no ListenAddress
touch "$T/sshd.up"; rm -f "$T/g.pid"; : > "$T/g.log"
PREFIX="$T/nopfx" GUARDIAN_ONCE=1 GUARDIAN_LOG="$T/g.log" GUARDIAN_PID="$T/g.pid" GUARDIAN_PORT_CHECK=false sh "$HERE/../boot/20-guardian.sh"
ok "guardian takes the tailnet address from the config file" "grep -q 'not answering on 100.64.0.10' '$T/g.log'"
rm -f "$T/sshd.up" "$T/g.pid"
# guardian: sshd down -> restart + log; sshd up -> nothing
: > "$LOG_CALLS"
export GUARDIAN_ONCE=1 GUARDIAN_LOG=$T/g.log GUARDIAN_PID=$T/g.pid
sh "$HERE/../boot/20-guardian.sh"
ok "guardian restarts sshd when down" "grep -q '^sshd' '$LOG_CALLS' && grep -q 'sshd restarted' '$T/g.log'"
ok "guardian holds wake lock" "grep -q 'termux-wake-lock' '$LOG_CALLS'"
# From here on sshd counts as up. Answer the port check locally: without this the guardian probes the
# real phone on the tailnet, so the test only passed on a machine that could reach it.
export GUARDIAN_PORT_CHECK=true
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

# auto-wake: só na transição Wi-Fi caído -> de volta, e só se o atheron não responde
# shellcheck disable=SC2016  # literal $LOG_CALLS in the fake script
printf '#!/bin/sh\necho "wake" >> "$LOG_CALLS"\ntouch "%s/woke"\nexit 0\n' "$T" > "$T/bin/fake-wake"; chmod +x "$T/bin/fake-wake"
gw() { # gw <wifi true|false> <atheron true|false>: one guardian iteration, sshd fine
    : > "$LOG_CALLS"; : > "$T/g.log"; rm -f "$T/g.pid" "$T/woke"
    GUARDIAN_PORT_CHECK=true GUARDIAN_WIFI_CHECK=$1 GUARDIAN_ATHERON_CHECK=$2 sh "$HERE/../boot/20-guardian.sh"
}
export GUARDIAN_WIFI_STATE=$T/wifi GUARDIAN_WAKE_OFF=$T/wake.off GUARDIAN_WAKE_PID=$T/wake.pid
export GUARDIAN_WAKE_CMD=fake-wake GUARDIAN_WAKE_TRIES=3 GUARDIAN_WAKE_GAP=0
rm -f "$T/wifi"
gw true false
ok "auto-wake: guardian start with Wi-Fi up does not fire" "! grep -q '^wake' '$LOG_CALLS' && [ \"\$(cat '$T/wifi')\" = 1 ]"
gw false false
ok "auto-wake: Wi-Fi loss logged, no wake" "grep -q 'home Wi-Fi lost' '$T/g.log' && ! grep -q '^wake' '$LOG_CALLS'"
gw true false
ok "auto-wake: Wi-Fi back + atheron down -> wakes every round" "[ \$(grep -c '^wake' '$LOG_CALLS') -eq 3 ] && grep -q 'magic packet sent (3/3)' '$T/g.log'"
ok "auto-wake: gives up with a log line" "grep -q 'still down after 3 rounds' '$T/g.log'"
gw true false
ok "auto-wake: Wi-Fi still up -> nothing" "! grep -q '^wake' '$LOG_CALLS'"
gw false false; gw true true
ok "auto-wake: atheron already up -> no packet" "! grep -q '^wake' '$LOG_CALLS' && grep -q 'already up' '$T/g.log'"
printf '0\n' > "$T/wifi"
GUARDIAN_PORT_CHECK=true GUARDIAN_WIFI_CHECK=true GUARDIAN_ATHERON_CHECK="[ -e '$T/woke' ]" sh -c ': > "$LOG_CALLS"; : > "$0/g.log"; rm -f "$0/g.pid" "$0/woke"; sh "$1"' "$T" "$HERE/../boot/20-guardian.sh"
ok "auto-wake: stops as soon as the atheron answers" "[ \$(grep -c '^wake' '$LOG_CALLS') -eq 1 ] && grep -q 'answered (round 2)' '$T/g.log'"
touch "$T/wake.off"; gw false false; gw true false
ok "auto-wake: disabled by ~/.acordar-atheron.off" "! grep -q '^wake' '$LOG_CALLS' && grep -q 'auto-wake disabled' '$T/g.log'"
rm -f "$T/wake.off"
unset GUARDIAN_WIFI_STATE GUARDIAN_WAKE_OFF GUARDIAN_WAKE_PID GUARDIAN_WAKE_CMD GUARDIAN_WAKE_TRIES GUARDIAN_WAKE_GAP

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

# dev-setup.sh: proot Debian + chave s10-dev com comando forçado
# shellcheck disable=SC2016  # fake proot-distro is generated with literal $LOG_CALLS/$PREFIX
# installed = "$T/distro-<name>" exists; login fails before install (like proot-distro 5.x)
printf '#!/bin/sh\necho "proot-distro $*" >> "$LOG_CALLS"\ncase "$1" in\nreset) echo "Error: container $2 has no OCI manifest."; exit 1 ;;\nremove) rm -f "%s/distro-$2.broken" "%s/distro-$2" ;;\ninstall) [ "$2" = "${FAKE_PD_FAIL_IMAGE:-}" ] && { echo "Unauthorized"; exit 1; }; [ -e "%s/distro-$4" ] && { echo "Error: container already exists"; exit 1; }; touch "%s/distro-$4" ;;\nlogin) [ -e "%s/distro-$2.broken" ] && { echo "Error: lock held"; exit 1; }; [ -e "%s/distro-$2" ] || { echo "Error: container $2 is not installed."; exit 1; } ;;\nesac\nexit 0\n' "$T" "$T" "$T" "$T" "$T" "$T" > "$T/bin/proot-distro"
chmod +x "$T/bin/proot-distro"
DEVKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIdevkey nomad-s10-dev'
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAInomadkey nomad\n' > "$HOME/.ssh/authorized_keys"
: > "$LOG_CALLS"
sh "$HERE/../dev-setup.sh" > "$T/out" 2>&1; rc=$?
ok "dev-setup without a key fails" "[ $rc -ne 0 ] && ! grep -q proot-distro '$LOG_CALLS'"
sh "$HERE/../dev-setup.sh" 'command="sh" ssh-ed25519 AAAA' > "$T/out" 2>&1; rc=$?
ok "dev-setup refuses options in the key" "[ $rc -ne 0 ] && ! grep -q 'command=\"sh\"' '$HOME/.ssh/authorized_keys'"
sh "$HERE/../dev-setup.sh" "$DEVKEY" > "$T/out" 2>&1; rc=$?
ok "dev-setup exits 0" "[ $rc -eq 0 ]"
ok "dev-setup installs proot-distro and debian (AWS mirror, named debian)" "grep -q '^pkg install -y proot-distro' '$LOG_CALLS' && grep -qx 'proot-distro install public.ecr.aws/docker/library/debian:trixie --name debian' '$LOG_CALLS'"
ok "dev-setup installs guest packages" "grep -q '^proot-distro login debian -- /bin/sh -c .*apt-get install -y --no-install-recommends .*git' '$LOG_CALLS'"
ok "s10-dev-shell installed 0700" "[ \"\$(stat -c %a '$PREFIX/bin/s10-dev-shell')\" = 700 ] && cmp -s '$HERE/../s10-dev-shell' '$PREFIX/bin/s10-dev-shell'"
ok "dev key restricted with forced command" "grep -qxF 'restrict,port-forwarding,pty,command=\"$PREFIX/bin/s10-dev-shell\" $DEVKEY' '$HOME/.ssh/authorized_keys'"
ok "plain nomad key untouched" "grep -qx 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAInomadkey nomad' '$HOME/.ssh/authorized_keys'"
: > "$LOG_CALLS"
sh "$HERE/../dev-setup.sh" "$DEVKEY" > "$T/out" 2>&1
ok "dev-setup idempotent: no reinstall, one key line" "! grep -q 'proot-distro install' '$LOG_CALLS' && [ \$(grep -c 'AAAAIdevkey' '$HOME/.ssh/authorized_keys') -eq 1 ] && [ \$(wc -l < '$HOME/.ssh/authorized_keys') -eq 2 ]"
printf '%s\n' "$DEVKEY" >> "$HOME/.ssh/authorized_keys"   # an unrestricted copy of the dev key gets replaced
sh "$HERE/../dev-setup.sh" "$DEVKEY" > "$T/out" 2>&1
ok "unrestricted copy of the dev key replaced" "! grep -qx '$DEVKEY' '$HOME/.ssh/authorized_keys' && [ \$(grep -c 'AAAAIdevkey' '$HOME/.ssh/authorized_keys') -eq 1 ]"
# Debian installed by an earlier run / another proot-distro layout: no install attempt (it would fail "already exists")
rm -f "$PREFIX/bin/s10-dev-shell"; : > "$LOG_CALLS"
sh "$HERE/../dev-setup.sh" "$DEVKEY" > "$T/out" 2>&1; rc=$?
ok "existing Debian detected by login, not by path" "[ $rc -eq 0 ] && ! grep -q 'proot-distro install' '$LOG_CALLS' && grep -q 'login debian -- /bin/true' '$LOG_CALLS'"
# first image refused (Docker Hub "Unauthorized"): falls back to the second
rm -f "$T"/distro-debian*; : > "$LOG_CALLS"
FAKE_PD_FAIL_IMAGE=public.ecr.aws/docker/library/debian:trixie sh "$HERE/../dev-setup.sh" "$DEVKEY" > "$T/out" 2>&1; rc=$?
ok "image refused: falls back to the other registry" "[ $rc -eq 0 ] && grep -qx 'proot-distro install debian:trixie --name debian' '$LOG_CALLS'"
touch "$T/distro-debian.broken"; : > "$LOG_CALLS"
sh "$HERE/../dev-setup.sh" "$DEVKEY" > "$T/out" 2>&1; rc=$?
ok "login error other than not-installed: shown, no reinstall" "[ $rc -eq 3 ] && grep -q 'lock held' '$T/out' && ! grep -q 'proot-distro install' '$LOG_CALLS'"
: > "$LOG_CALLS"
S10_DEV_RESET=1 sh "$HERE/../dev-setup.sh" "$DEVKEY" > "$T/out" 2>&1; rc=$?
ok "S10_DEV_RESET=1 removes and reinstalls a broken container" "[ $rc -eq 0 ] && grep -qx 'proot-distro remove debian' '$LOG_CALLS' && grep -q '^proot-distro install .* --name debian$' '$LOG_CALLS' && ! grep -q 'proot-distro reset' '$LOG_CALLS'"
rm -f "$T/distro-debian.broken"
rm -f "$PREFIX/bin/s10-dev-shell"
sh -s -- "$DEVKEY" < "$HERE/../dev-setup.sh" > "$T/out" 2>&1; rc=$?
ok "dev-setup through sh -s writes the embedded wrapper" "[ $rc -eq 0 ] && grep -q 'proot-distro login \"\$DISTRO\" -- /bin/bash -lc \"\$SSH_ORIGINAL_COMMAND\"' '$PREFIX/bin/s10-dev-shell'"
# s10-dev-shell: the client command goes into the guest, an empty one opens a login shell
: > "$LOG_CALLS"
SSH_ORIGINAL_COMMAND='echo hi' sh "$HERE/../s10-dev-shell"
ok "s10-dev-shell runs the command in the guest" "grep -qx 'proot-distro login debian -- /bin/bash -lc echo hi' '$LOG_CALLS'"
: > "$LOG_CALLS"
SSH_ORIGINAL_COMMAND='' sh "$HERE/../s10-dev-shell"
ok "s10-dev-shell without command opens a shell" "grep -qx 'proot-distro login debian' '$LOG_CALLS'"

echo "--- $n checks, $fail failed"
[ "$fail" -eq 0 ]
