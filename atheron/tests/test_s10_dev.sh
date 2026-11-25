#!/bin/bash
# Tests for atheron/user-step-s10-dev.sh with a fake adb that simulates the phone (Termux writes log + rc).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
STEP=$HERE/../user-step-s10-dev.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir "$T/bin" "$T/phone"
export LOG_CALLS=$T/calls PHONE=$T/phone S10_ALLOW_NONROOT=1 S10_DEV_POLL=0 S10_DEV_OPEN_WAIT=0 S10_SERIAL=TESTSERIAL
# fake adb: records the calls; `input keyevent 66` "runs" the typed command (writes log + rc from $FAKE_RC)
cat > "$T/bin/adb" <<'EOF'
#!/bin/bash
echo "adb $*" >> "$LOG_CALLS"
[ "$1" = -s ] && shift 2
case "$1" in
get-state) echo "${FAKE_STATE:-device}" ;;
push) shift; n=$#; for ((i = 1; i < n; i++)); do cp "${!i}" "$PHONE/"; done ;;
shell)
    case "$2" in
    cat) if [ -f "$PHONE/rc" ]; then cat "$PHONE/rc"; else echo "cat: $3: No such file or directory"; exit 1; fi ;;
    tail) cat "$PHONE/log" 2>/dev/null ;;
    ls) [ -f "$PHONE/log" ] ;;
    input) if [ "$3 $4" = "keyevent 66" ] && [ -z "${FAKE_NEVER:-}" ]; then echo "setup ok" > "$PHONE/log"; echo "${FAKE_RC:-0}" > "$PHONE/rc"; fi ;;
    esac ;;
esac
exit $?
EOF
chmod +x "$T/bin/adb"
mkdir "$T/nosleep"; printf '#!/bin/sh\nexit 0\n' > "$T/nosleep/sleep"; chmod +x "$T/nosleep/sleep"
export PATH="$T/bin:$PATH"
fail=0 n=0
ok() { n=$((n + 1)); if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=$((fail + 1)); fi; }
reset() { : > "$LOG_CALLS"; rm -f "$PHONE"/*; }

printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest wtg-s10-dev\n' > "$T/k.pub"

bash "$STEP" > "$T/out" 2>&1; rc=$?
ok "without a key file: usage, exit 2" "[ $rc -eq 2 ] && grep -q uso '$T/out'"
printf 'command="sh" ssh-ed25519 AAAA x\n' > "$T/bad.pub"
reset; bash "$STEP" "$T/bad.pub" > "$T/out" 2>&1; rc=$?
ok "key with options refused before touching the phone" "[ $rc -eq 2 ] && [ ! -s '$LOG_CALLS' ]"

reset; FAKE_STATE=unauthorized bash "$STEP" "$T/k.pub" > "$T/out" 2>&1; rc=$?
ok "phone not ready: stops before pushing" "[ $rc -ne 0 ] && grep -q unauthorized '$T/out' && ! grep -q push '$LOG_CALLS'"

reset; bash "$STEP" "$T/k.pub" > "$T/out" 2>&1; rc=$?
ok "success exits 0" "[ $rc -eq 0 ] && grep -q 'pronto' '$T/out' && grep -q 'wtg-s10-dev' '$T/out'"
ok "uses the serial" "grep -q '^adb -s TESTSERIAL push' '$LOG_CALLS'"
ok "pushes setup, wrapper, runner and key" "for f in dev-setup.sh s10-dev-shell run.sh key.pub; do [ -f '$PHONE/'\$f ] || exit 1; done"
ok "pushed key is the given key" "cmp -s '$T/k.pub' '$PHONE/key.pub'"
ok "runner calls dev-setup with the key and the wrapper" "grep -qF 'sh \"\$D/dev-setup.sh\" \"\$(cat \"\$D/key.pub\")\" \"\$D/s10-dev-shell\"' '$PHONE/run.sh'"
ok "typed command has only safe characters" "grep '^adb -s TESTSERIAL shell input text ' '$LOG_CALLS' | sed 's/.*input text //' | grep -qxE '[A-Za-z0-9/%._-]+'"
ok "opens Termux before typing" "[ \$(grep -n 'am start -n com.termux' '$LOG_CALLS' | cut -d: -f1) -lt \$(grep -n 'input text' '$LOG_CALLS' | cut -d: -f1) ]"
ok "grants storage to Termux" "grep -q 'pm grant com.termux android.permission.READ_EXTERNAL_STORAGE' '$LOG_CALLS'"
ok "shows the log" "grep -q 'setup ok' '$T/out'"
ok "cleans the pushed files on success" "grep -q 'shell rm -rf /sdcard/Download/s10-dev\$' '$LOG_CALLS'"

ok "without --reset-distro the runner passes S10_DEV_RESET=0" "grep -q '^S10_DEV_RESET=0 sh' '$PHONE/run.sh'"
reset; bash "$STEP" --reset-distro "$T/k.pub" > "$T/out" 2>&1; rc=$?
ok "--reset-distro reaches dev-setup" "[ $rc -eq 0 ] && grep -q '^S10_DEV_RESET=1 sh' '$PHONE/run.sh'"

reset; FAKE_RC=3 bash "$STEP" "$T/k.pub" > "$T/out" 2>&1; rc=$?
ok "dev-setup failure is reported" "[ $rc -ne 0 ] && grep -q 'código 3' '$T/out'"

reset; FAKE_NEVER=1 S10_DEV_TIMEOUT=400 S10_DEV_POLL=10 PATH="$T/nosleep:$PATH" bash "$STEP" "$T/k.pub" > "$T/out" 2>&1; rc=$?
ok "Termux never ran the command: clear message" "[ $rc -ne 0 ] && grep -q 'não começou' '$T/out'"

echo "--- $n checks, $fail failed"
[ "$fail" -eq 0 ]
