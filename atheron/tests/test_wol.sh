#!/bin/bash
# Tests for atheron/wol-atheron.sh (non-root, fake /sys and ethtool, no udevadm/apt) and termux/acordar-atheron --dump.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
INST=$HERE/../wol-atheron.sh
WAKE=$HERE/../../termux/acordar-atheron
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/sys/enp9s0/device/power"
printf "02:00:00:00:00:%s\n" AA > "$T/sys/enp9s0/address"
echo disabled > "$T/sys/enp9s0/device/power/wakeup"
# ethtool falso: guarda o último "wol X" e o devolve no Wake-on
cat > "$T/bin/ethtool" <<F
#!/bin/bash
echo "ethtool \$*" >> "$T/calls"
if [ "\$2" = "-s" ] || [ "\$1" = "-s" ]; then echo "\${4}" > "$T/wol"; exit 0; fi
echo "	Supports Wake-on: pumbg"
echo "	Wake-on: \$(cat "$T/wol" 2>/dev/null || echo d)"
F
chmod +x "$T/bin/ethtool"
export PATH="$T/bin:$PATH" WOL_ALLOW_NONROOT=1 WOL_SYSNET="$T/sys" WOL_IFACE=enp9s0 WOL_RULE="$T/rules/81-cerberus-wol.rules"
fail=0 n=0
ok() { n=$((n + 1)); if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=$((fail + 1)); fi; }

bash "$INST" --check > "$T/out" 2>&1; rc=$?
ok "check fails before install" "[ $rc -ne 0 ] && grep -q '✗ Wake-on: d' '$T/out'"
bash "$INST" > "$T/out" 2>&1; rc=$?
ok "install exits 0" "[ $rc -eq 0 ]"
ok "wol g applied now" "grep -qx 'ethtool -s enp9s0 wol g' '$T/calls'"
ok "rule matches the MAC in lowercase" "grep -qF 'ATTR{address}==\"02:00:00:00:00:aa\"' '$WOL_RULE'"
ok "rule runs ethtool on \$name" "grep -qF 'RUN+=\"/usr/sbin/ethtool -s \$name wol g\"' '$WOL_RULE'"
ok "rule only on add of a net device" "grep -qF 'ACTION==\"add\", SUBSYSTEM==\"net\"' '$WOL_RULE'"
ok "rule 0644" "[ \"\$(stat -c %a '$WOL_RULE')\" = 644 ]"
ok "check passes after install" "grep -q '✓ Wake-on: g' '$T/out' && grep -q '✓ regra udev' '$T/out'"
ok "prints the S10 command" "grep -q 'acordar-atheron 02:00:00:00:00:aa' '$T/out'"
cp "$WOL_RULE" "$T/rule.1"
bash "$INST" > "$T/out" 2>&1
ok "idempotent (same rule, not rewritten)" "cmp -s '$T/rule.1' '$WOL_RULE' && ! grep -q 'regra gravada' '$T/out'"
echo "02:00:00:00:00:bb" > "$T/sys/enp9s0/address"
bash "$INST" --check > "$T/out" 2>&1; rc=$?
ok "check notices a different MAC" "[ $rc -ne 0 ] && grep -q '✗ regra udev' '$T/out'"
bash "$INST" > /dev/null 2>&1
ok "reinstall follows the new MAC" "grep -qF '02:00:00:00:00:bb' '$WOL_RULE' && [ \$(grep -c ATTR '$WOL_RULE') -eq 1 ]"
WOL_IFACE=nada bash "$INST" > "$T/out" 2>&1; rc=$?
ok "missing interface rejected" "[ $rc -ne 0 ] && grep -q 'não encontrada' '$T/out'"
bash "$INST" --undo > /dev/null 2>&1; rc=$?
ok "undo removes the rule and turns wol off" "[ $rc -eq 0 ] && [ ! -e '$WOL_RULE' ] && grep -qx 'ethtool -s enp9s0 wol d' '$T/calls'"
bash "$INST" --bogus > /dev/null 2>&1; rc=$?
ok "unknown option rejected" "[ $rc -eq 2 ]"

# termux/acordar-atheron: packet = 6 x ff + 16 x MAC (102 bytes), under dash when available
SH=$(command -v dash || command -v sh)
printf 'ATHERON_MAC=02:00:00:00:00:aa\nATHERON_BCAST=192.0.2.255\n' > "$T/s10.conf"
export S10_CONF="$T/s10.conf"
"$SH" "$WAKE" --dump "$(printf "02:00:00:00:00:%s" Aa)" > "$T/pkt"; rc=$?
ok "dump exits 0" "[ $rc -eq 0 ]"
ok "packet has 102 bytes" "[ \$(wc -c < '$T/pkt') -eq 102 ]"
expected=ffffffffffff$(printf '0200000000aa%.0s' $(seq 16))
ok "packet bytes are the magic packet" "[ \"\$(od -An -tx1 -v '$T/pkt' | tr -d ' \n')\" = '$expected' ]"
"$SH" "$WAKE" --dump > "$T/pkt2"
ok "default MAC comes from the config file" "[ \"\$(od -An -tx1 -v -j6 -N6 '$T/pkt2' | tr -d ' \n')\" = 0200000000aa ]"
ATHERON_MAC=00-11-22-33-44-ff "$SH" "$WAKE" --dump > "$T/pkt3"
ok "ATHERON_MAC with dashes" "[ \"\$(od -An -tx1 -v -j96 -N6 '$T/pkt3' | tr -d ' \n')\" = 0011223344ff ]"
"$SH" "$WAKE" --dump 98:29:a6:e7:d5 > /dev/null 2>&1; rc=$?
ok "short MAC rejected" "[ $rc -eq 2 ]"
"$SH" "$WAKE" --dump 'zz:29:a6:e7:d5:a6' > /dev/null 2>&1; rc=$?
ok "non-hex MAC rejected" "[ $rc -eq 2 ]"
mkdir "$T/nosocat"; for b in tr sed head; do ln -s "$(command -v $b)" "$T/nosocat/$b"; done
PATH="$T/nosocat" "$SH" "$WAKE" > "$T/out" 2>&1; rc=$?
ok "without socat: clear error" "[ $rc -ne 0 ] && grep -q 'pkg install socat' '$T/out'"

echo "--- $n checks, $fail failed"
[ "$fail" -eq 0 ]
