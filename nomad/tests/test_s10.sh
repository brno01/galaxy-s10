#!/bin/bash
# Plain-bash tests for nomad/s10: fake ssh/adb/scrcpy/krdc on PATH, check command lines, fallback order and timeouts.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S10=$HERE/../s10
TMP=$(mktemp -d)
LISTENERS=()
# shellcheck disable=SC2329  # called via trap
cleanup() { for p in "${LISTENERS[@]}"; do kill "$p" 2>/dev/null; done; pkill -f "$TMP/bin" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
mkdir "$TMP/bin"
export LOG="$TMP/log" TMPDIR_FAKE="$TMP" HOME="$TMP/home" XDG_CACHE_HOME="$TMP/cache"
mkdir -p "$HOME"

# ssh falso: decide pelo conteúdo dos argumentos
cat > "$TMP/bin/ssh" <<'F'
#!/bin/bash
echo "ssh $*" >> "$LOG"
case "$*" in
*"cat /run/cerberus-s10/estado.json"*)
    [ -n "${FAKE_ATHERON_DOWN:-}" ] && exit 255
    printf '%s\n' "${FAKE_STATE:-}"; exit 0 ;;
*"cat /etc/cerberus-s10/vnc-password"*)
    [ -n "${FAKE_ADMIN_DOWN:-}" ] && exit 255
    printf '%s\n' "${FAKE_VNC_PASS:-Zx9Qp2Lm}"; exit 0 ;;
*":127.0.0.1:5900"*)
    [ -n "${FAKE_PHONE_DOWN:-}" ] && exit 255
    all="$*"; rest=${all#* -L 127.0.0.1:}; port=${rest%%:*}
    exec python3 -I -c '
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(5); time.sleep(30)' "$port" ;;
*" -L /"*)
    [ -n "${FAKE_ATHERON_DOWN:-}" ] && exit 255
    all="$*"; rest=${all#* -L }; sock=${rest%%:*}
    [ -n "${FAKE_TUNNEL_SLOW:-}" ] && sleep 1
    exec python3 -I -c '
import os, socket, sys, time
try: os.unlink(sys.argv[1])
except OSError: pass
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(5); time.sleep(30)' "$sock" ;;
esac
exit 0
F
cat > "$TMP/bin/adb" <<'F'
#!/bin/bash
echo "adb[${ADB_SERVER_SOCKET:-}] $*" >> "$LOG"
case "$1" in
devices)
    if [ -n "${ADB_SERVER_SOCKET:-}" ]; then printf '%b' "${FAKE_USB_DEVICES:-}"; else printf '%b' "${FAKE_LOCAL_DEVICES:-}"; fi ;;
connect)
    case " ${FAKE_CONNECT_OK:-} " in *" $2 "*) echo "connected to $2" ;; *) echo "failed to connect to '$2'" ;; esac ;;
mdns) printf '%b' "${FAKE_MDNS:-}" ;;
esac
exit 0
F
cat > "$TMP/bin/scrcpy" <<'F'
#!/bin/bash
echo "scrcpy[${ADB_SERVER_SOCKET:-}] $*" >> "$LOG"
if [ -n "${FAKE_REJECT_H265:-}" ]; then case "$*" in *h265*) exit 1 ;; esac; fi
if [ -n "${FAKE_SCRCPY_FAIL_USB:-}" ] && [ -n "${ADB_SERVER_SOCKET:-}" ]; then exit 1; fi
exit 0
F
cat > "$TMP/bin/krdc" <<'F'
#!/bin/bash
echo "krdc $*" >> "$LOG"
exit 0
F
cat > "$TMP/bin/avahi-browse" <<'F'
#!/bin/bash
echo "avahi-browse $*" >> "$LOG"
printf '%b' "${FAKE_AVAHI:-}"
F
chmod +x "$TMP"/bin/*
# PATH enxuto-primeiro: os falsos vêm antes de qualquer krdc/adb real
export PATH="$TMP/bin:$PATH"
export S10_WAIT_TRIES=3 S10_CONNECT_TIMEOUT=1
export S10_ATHERON=root@atheron-test S10_VNC_LPORT=15901 XDG_RUNTIME_DIR="$TMP/run"
mkdir -m 700 "$TMP/run"
SOCK="$TMP/run/s10-adb.sock"
SOCKRE="localfilesystem:$SOCK"
unset S10_TERMUX_USER
export S10_PHONE=celular-test S10_TAILNET_IP=100.64.0.9

DEV='List of devices attached\nR58M12ABCDE\tdevice\n\n'
STATE_NOPORT='{"estado":"device","caminhos":{"adb_sem_fio":{"ip":null,"porta":null,"ok":false},"vnc":{"ok":true}}}'

# listener TCP local para as sondas de status (porta efêmera)
python3 -I -c '
import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(5)
open(sys.argv[1], "w").write(str(s.getsockname()[1])); sys.stdout.flush()
time.sleep(60)' "$TMP/port" &
LISTENERS+=($!)
for _ in $(seq 20); do [ -s "$TMP/port" ] && break; sleep 0.1; done
LPORT_OK=$(cat "$TMP/port")

fail=0 n=0
check() { n=$((n + 1)); if grep -qE -- "$2" "${3:-$LOG}"; then echo "ok   $1"; else echo "FAIL $1 (sem /$2/)"; fail=$((fail + 1)); fi; }
refute() { n=$((n + 1)); if grep -qE -- "$2" "${3:-$LOG}"; then echo "FAIL $1 (achou /$2/)"; fail=$((fail + 1)); else echo "ok   $1"; fi; }
expect_rc() { n=$((n + 1)); if test "$RC" "-$2" "$3"; then echo "ok   $1"; else echo "FAIL $1 (rc=$RC)"; fail=$((fail + 1)); fi; }
line_no() { grep -nE -- "$1" "$LOG" | head -n1 | cut -d: -f1; }
before() { # before <desc> <pat-a> <pat-b>: a aparece antes de b
    n=$((n + 1)); local a b; a=$(line_no "$2"); b=$(line_no "$3")
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then echo "ok   $1"; else echo "FAIL $1 (a=$a b=$b)"; fail=$((fail + 1)); fi
}
run() { : > "$LOG"; "$S10" "$@" > "$TMP/out" 2> "$TMP/err"; RC=$?; }
reset_env() { unset FAKE_ATHERON_DOWN FAKE_PHONE_DOWN FAKE_STATE FAKE_USB_DEVICES FAKE_LOCAL_DEVICES FAKE_CONNECT_OK FAKE_MDNS FAKE_AVAHI FAKE_SCRCPY_FAIL_USB FAKE_REJECT_H265; rm -rf "$XDG_CACHE_HOME"; }

# ---------------------------------------------------------------- caminho 1 (--usb), perfis
reset_env
FAKE_USB_DEVICES=$DEV run --usb
check "usb: ssh -CN unix-socket forward + video forward" 'ssh -CN .*StreamLocalBindUnlink=yes.* -L '"$SOCK"':/home/s10tunnel/adb\.sock -L 127\.0\.0\.1:27183:127\.0\.0\.1:27183 root@atheron-test'
refute "usb: no TCP 5037 forward" '5037'
check "usb: no control master" 'ControlMaster=no.*ControlPath=none.*ControlPersist=no'
check "usb: fail-fast ConnectTimeout" 'ConnectTimeout=1'
check "usb: adb uses 15038 socket" 'adb\['"$SOCKRE"'\] devices'
check "usb: scrcpy via tunnel socket" 'scrcpy\['"$SOCKRE"'\] -s R58M12ABCDE'
check "usb: turn-screen-off + stay-awake" 'scrcpy.*--turn-screen-off --stay-awake'
check "usb: quality args (h264 default)" 'scrcpy.*--max-size=1440 --video-bit-rate=8M --max-fps=60 --video-codec=h264'
check "usb: forward mode + no audio" 'scrcpy.*--force-adb-forward --no-audio'
refute "usb: no reverse tunnel" ' -R '
refute "usb: no power-off-on-close" 'power-off-on-close'
refute "usb: no h265" 'h265'
refute "usb: no new-display" 'new-display'
refute "usb: no adb -a / tcpip" 'adb.*(-a |tcpip)'
expect_rc "usb: exit 0" eq 0
FAKE_USB_DEVICES=$DEV run --usb --audio
refute "usb --audio: audio left on" '--no-audio'
FAKE_USB_DEVICES=$DEV run --usb --rapido
check "rapido: args" 'scrcpy.*--max-size=1024 --video-bit-rate=4M --video-codec=h264'
refute "rapido: no 60fps" 'max-fps'
FAKE_USB_DEVICES=$DEV run --usb --desktop
check "desktop: new-display" 'scrcpy.*--new-display=1920x1080/160'
check "desktop: force_desktop_mode setting" 'adb\['"$SOCKRE"'\] -s R58M12ABCDE shell settings put global force_desktop_mode_on_external_displays 1'
check "desktop: freeform setting" 'shell settings put global enable_freeform_support 1'
before "desktop: settings before scrcpy" 'enable_freeform_support' '^scrcpy'
FAKE_USB_DEVICES=$DEV S10_SERIAL=R58M12ABCDE run --usb
check "serial env honored" 'scrcpy.* -s R58M12ABCDE'
FAKE_USB_DEVICES='List of devices attached\nR58M12ABCDE\tdevice\nEXAMPLESERIAL\tdevice\n\n' run --usb
check "default serial preferred when listed" 'scrcpy.* -s EXAMPLESERIAL'
FAKE_USB_DEVICES=$DEV S10_SERIAL=OUTRO run --usb
expect_rc "wrong serial fails" ne 0
refute "wrong serial: scrcpy not run" '^scrcpy'
FAKE_USB_DEVICES=$DEV run --usb -- --record=/tmp/x.mkv
check "passthrough args" 'scrcpy.*--record=/tmp/x.mkv'
FAKE_USB_DEVICES=$DEV FAKE_REJECT_H265=1 S10_CODEC=h265 run --usb
check "fallback: tried h265" 'scrcpy.*--video-codec=h265'
check "fallback: retried h264" 'scrcpy.*--video-codec=h264'
check "fallback: message" 'h265 recusado' "$TMP/err"
expect_rc "fallback exit 0" eq 0
FAKE_USB_DEVICES='List of devices attached\n\n' run --usb
expect_rc "usb no device: exit 1" eq 1
check "usb no device: PT error" 'atheron-test\) não enxerga o S10' "$TMP/err"
refute "usb no device: scrcpy not run" '^scrcpy'
FAKE_USB_DEVICES='List of devices attached\nR58M12ABCDE\tunauthorized\n\n' run --usb
check "unauthorized hint" 'unauthorized' "$TMP/err"
FAKE_ATHERON_DOWN=1 run --usb
expect_rc "usb: atheron down fails fast" eq 1
check "usb: PT message tunnel" 'túnel SSH para root@atheron-test não subiu' "$TMP/err"

# race: o adb só é chamado depois que a porta do túnel aceita conexões
reset_env
FAKE_TUNNEL_SLOW=1 FAKE_USB_DEVICES=$DEV run --usb
expect_rc "slow tunnel: still works" eq 0
check "slow tunnel: no adb before the port is up (first adb is devices via tunnel)" 'adb\['"$SOCKRE"'\] devices'
refute "slow tunnel: no adb fork-server on the tunnel port" 'fork-server'
# socket velho de uma sessão anterior é removido antes do ssh (e o ssh usa StreamLocalBindUnlink)
rm -f "$SOCK"
python3 -I -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$SOCK"
FAKE_USB_DEVICES=$DEV FAKE_TUNNEL_SLOW=1 run --usb
expect_rc "stale socket: still works" eq 0
check "stale socket: tunnel opened anyway" 'ssh -CN'
# host do túnel: padrão restrito; S10_TUNNEL manda; S10_ATHERON só vale se explícito
( unset S10_ATHERON; FAKE_USB_DEVICES=$DEV; export FAKE_USB_DEVICES; : > "$LOG"; "$S10" --usb >/dev/null 2>&1 )
check "default tunnel user" ' s10tunnel@atheron$'
( S10_TUNNEL=t@h FAKE_USB_DEVICES=$DEV; export S10_TUNNEL FAKE_USB_DEVICES; : > "$LOG"; "$S10" --usb >/dev/null 2>&1 )
check "S10_TUNNEL honored" ' t@h$'

# ---------------------------------------------------------------- --lan
reset_env
FAKE_LOCAL_DEVICES='List of devices attached\n192.0.2.60:37123\tdevice\nR58M12ABCDE\tdevice\n\n' run --lan
refute "lan: no ssh" '^ssh'
check "lan: wireless serial" 'scrcpy\[\] -s 192\.168\.0\.50:37123'
FAKE_LOCAL_DEVICES=$DEV run --lan
expect_rc "lan without wireless device fails" eq 1
check "lan: PT error" 'Wi-Fi' "$TMP/err"

# ---------------------------------------------------------------- automático: ordem de fallback
reset_env
FAKE_USB_DEVICES=$DEV run
check "auto: path 1 first, scrcpy via tunnel" 'scrcpy\['"$SOCKRE"'\]'
refute "auto: path 2 not tried when USB works" 'adb\[\] connect'
refute "auto: path 3 not tried when USB works" 'ssh .*-L 15901'
expect_rc "auto/usb: exit 0" eq 0

# USB sem device -> sem fio via estado do atheron (LAN responde)
reset_env
FAKE_USB_DEVICES='List of devices attached\n\n' FAKE_STATE='{"estado":"ausente","caminhos":{"adb_sem_fio":{"ip":"192.0.2.20","porta":37215,"ok":true}}}' \
    FAKE_CONNECT_OK="192.0.2.20:37215" run
check "auto: usb failed message" 'caminho 1 falhou' "$TMP/err"
check "auto: state fetched over ssh" 'ssh .*atheron-test cat /run/cerberus-s10/estado.json'
check "state fetch: forwardings cleared" 'ClearAllForwardings=yes.*cat /run/cerberus-s10/estado.json'
check "auto: adb connect LAN ip:port" 'adb\[\] connect 192\.168\.1\.249:37215'
check "auto: scrcpy -s wireless, local adb" 'scrcpy\[\] -s 192\.168\.1\.249:37215'
refute "auto: vnc not tried" 'ssh .*-L 15901'
before "auto: path 1 before path 2" 'adb\['"$SOCKRE"'\] devices' 'adb\[\] connect'
n=$((n + 1)); if grep -q '"porta":37215' "$XDG_CACHE_HOME/s10/estado.json" 2>/dev/null; then echo "ok   cache written"; else echo "FAIL cache written"; fail=$((fail + 1)); fi

# tailnet primeiro: o adbd escuta em todas as interfaces, então vale fora de casa
reset_env
FAKE_USB_DEVICES='List of devices attached\n\n' FAKE_STATE='{"estado":"ausente","caminhos":{"adb_sem_fio":{"ip_lan":"192.0.2.30","porta":37215,"ip_tailnet":"100.64.0.9"}}}' \
    FAKE_CONNECT_OK="100.64.0.9:37215" run
check "auto: tailnet ip:port tried" 'adb\[\] connect 100\.64\.0\.9:37215'
refute "auto: LAN not tried when tailnet works" 'connect 192\.168'
check "auto: scrcpy on tailnet" 'scrcpy\[\] -s 100\.64\.0\.9:37215'
refute "auto: mDNS not needed" 'mdns services'
FAKE_USB_DEVICES='List of devices attached\n\n' FAKE_STATE='{"caminhos":{"adb_sem_fio":{"ip_lan":"192.0.2.30","porta":37215,"ip_tailnet":"100.64.0.9"}}}' \
    FAKE_CONNECT_OK="192.0.2.30:37215" run
before "auto: tailnet before LAN" 'connect 100\.64\.0\.9' 'connect 192\.168\.1\.243'
check "auto: LAN as fallback" 'scrcpy\[\] -s 192\.168\.1\.243:37215'

# atheron fora do ar: mDNS
reset_env
FAKE_ATHERON_DOWN=1 FAKE_MDNS='adb-R58M-abc\t_adb-tls-connect._tcp\t192.0.2.20:40001\n' FAKE_CONNECT_OK="192.0.2.20:40001" run
check "auto: atheron down -> path 2 via mDNS" 'adb\[\] mdns services'
check "auto: mDNS candidate connected" 'scrcpy\[\] -s 192\.168\.1\.249:40001'
refute "auto: no tailnet attempt before mDNS" 'connect 100\.64\.0\.9'

# avahi-browse como segunda fonte
reset_env
FAKE_ATHERON_DOWN=1 FAKE_AVAHI='=;wlan0;IPv4;adb-R58M;_adb-tls-connect._tcp;local;s10.local;192.0.2.20;40002;"x"\n=;wlan0;IPv6;adb-R58M;_adb-tls-connect._tcp;local;s10.local;fe80::1;40002;"x"\n' \
    FAKE_CONNECT_OK="192.0.2.20:40002" run
check "auto: avahi-browse used" 'avahi-browse -rtp _adb-tls-connect\._tcp'
check "auto: avahi candidate connected" 'scrcpy\[\] -s 192\.168\.1\.249:40002'

# cache: tailnet + última porta
reset_env
mkdir -p "$XDG_CACHE_HOME/s10"; echo '{"ip":"192.0.2.20","porta":45678}' > "$XDG_CACHE_HOME/s10/estado.json"
FAKE_ATHERON_DOWN=1 FAKE_CONNECT_OK="100.64.0.9:45678" run
check "auto: cached port on tailnet ip" 'adb\[\] connect 100\.64\.0\.9:45678'
check "auto: scrcpy from cache" 'scrcpy\[\] -s 100\.64\.0\.9:45678'

# tudo de adb falha -> VNC (krdc)
reset_env
FAKE_USB_DEVICES='List of devices attached\n\n' FAKE_STATE=$STATE_NOPORT run
check "auto: path 2 failed message" 'caminho 2 falhou' "$TMP/err"
check "auto: vnc tunnel to phone name, default Termux user" 'ssh -N -p 8022 .*-L 127\.0\.0\.1:15901:127\.0\.0\.1:5900 u0_a999@celular-test'
check "auto: krdc on forwarded port" 'krdc vnc://127\.0\.0\.1:15901'
refute "auto: no scrcpy when only vnc works" '^scrcpy'
before "auto: path 2 before path 3" 'ssh .*cat /run/cerberus-s10' 'ssh -N -p 8022'
expect_rc "auto/vnc: exit 0" eq 0

# nome do celular não resolve -> IP da tailnet; usuário do Termux
reset_env
FAKE_ATHERON_DOWN=1 S10_TERMUX_USER=u0_a345 run --vnc
check "vnc: user@host" 'ssh -N -p 8022 .* u0_a345@celular-test'
S10_TERMUX_USER=u0_a345 FAKE_PHONE_DOWN=1 run --vnc
expect_rc "vnc: phone down fails" eq 1
check "vnc: tried name then tailnet ip" 'u0_a345@100\.64\.0\.9'
check "vnc: PT error" 'Termux' "$TMP/err"

# ---------------------------------------------------------------- senha do VNC
mkdir "$TMP/tiger" "$TMP/wl"
cat > "$TMP/tiger/vncpasswd" <<'F'
#!/bin/bash
read -r pw; printf 'OBF%s' "${#pw}"
F
cat > "$TMP/tiger/vncviewer" <<'F'
#!/bin/bash
echo "vncviewer $*" >> "$LOG"
f=$2; echo "passwd-mode $(stat -c %a "$f") content $(cat "$f")" >> "$LOG"; echo "$f" > "$TMPDIR_FAKE/pwfile"
F
cat > "$TMP/wl/wl-copy" <<'F'
#!/bin/bash
echo "wl-copy $*" >> "$LOG"
[ $# -eq 0 ] && cat > "$TMPDIR_FAKE/clip"
exit 0
F
chmod +x "$TMP"/tiger/* "$TMP"/wl/*
export S10_VNC_PASSWORD_FILE="$TMP/cfg/s10/vnc-password" S10_CLIP_SECONDS=1

reset_env
run setup-vnc
expect_rc "setup-vnc ok" eq 0
n=$((n + 1)); if [ "$(stat -c %a "$S10_VNC_PASSWORD_FILE")" = 600 ] && [ "$(cat "$S10_VNC_PASSWORD_FILE")" = Zx9Qp2Lm ]; then echo "ok   setup-vnc: 0600 file with the password"; else echo "FAIL setup-vnc file"; fail=$((fail + 1)); fi
check "setup-vnc: ssh to admin host" 'ssh .*root@atheron-test cat /etc/cerberus-s10/vnc-password'
refute "setup-vnc: password not echoed" 'Zx9Qp2Lm' "$TMP/out"
refute "setup-vnc: password not in stderr" 'Zx9Qp2Lm' "$TMP/err"
refute "setup-vnc: password not in argv" 'Zx9Qp2Lm'
FAKE_ADMIN_DOWN=1 FAKE_VNC_PASS=x run setup-vnc
expect_rc "setup-vnc fails when admin ssh fails" ne 0
n=$((n + 1)); if [ "$(cat "$S10_VNC_PASSWORD_FILE")" = Zx9Qp2Lm ]; then echo "ok   failed setup keeps the old file"; else echo "FAIL old file clobbered"; fail=$((fail + 1)); fi

# krdc + wl-copy: senha na área de transferência por 30 s (aqui 1 s), depois limpa
FAKE_ATHERON_DOWN=1 PATH="$TMP/wl:$PATH" run --vnc
check "krdc path" 'krdc vnc://127\.0\.0\.1:15901'
check "clipboard filled" '^wl-copy $' 
n=$((n + 1)); if [ "$(cat "$TMP/clip")" = Zx9Qp2Lm ]; then echo "ok   clipboard got the password via stdin"; else echo "FAIL clipboard content"; fail=$((fail + 1)); fi
check "clipboard message" 'senha do VNC copiada por 1 s \(Ctrl\+V na janela\)' "$TMP/err"
sleep 2
check "clipboard cleared after the delay" 'wl-copy --clear'
refute "password never in a command line" 'Zx9Qp2Lm'

# tigervnc preferido, com arquivo de senha 0600 removido ao sair
FAKE_ATHERON_DOWN=1 PATH="$TMP/tiger:$TMP/wl:$PATH" run --vnc
check "tigervnc preferred over krdc" '^vncviewer -passwd .* 127\.0\.0\.1::15901'
refute "tigervnc: krdc not used" '^krdc'
check "tigervnc: obfuscated 0600 passwd file" 'passwd-mode 600 content OBF8'
n=$((n + 1)); if [ ! -e "$(cat "$TMP/pwfile")" ]; then echo "ok   passwd temp file removed on exit"; else echo "FAIL temp passwd file left"; fail=$((fail + 1)); fi
refute "tigervnc: password not in argv" 'Zx9Qp2Lm'

# sem arquivo de senha: aviso e segue
rm -f "$S10_VNC_PASSWORD_FILE"
FAKE_ATHERON_DOWN=1 run --vnc
check "no password file: hint to run setup-vnc" "s10 setup-vnc" "$TMP/err"
refute "no password: no clipboard" 'wl-copy'

# chave SSH do nomad usada se existir
reset_env
mkdir -p "$HOME/.ssh"; : > "$HOME/.ssh/nomad_ed25519"
FAKE_ATHERON_DOWN=1 run --vnc
check "vnc: identity key used" 'ssh -N -p 8022 -i .*nomad_ed25519 -o IdentitiesOnly=yes'
FAKE_USB_DEVICES=$DEV run --usb
check "usb tunnel uses the nomad key" 'ssh -CN -i .*nomad_ed25519 -o IdentitiesOnly=yes'
run setup-vnc
check "setup-vnc uses the nomad key" 'ssh -i .*nomad_ed25519 -o IdentitiesOnly=yes .*cat /etc/cerberus-s10/vnc-password'
FAKE_USB_DEVICES=$DEV S10_SSH_KEY="$HOME/.ssh/outra" run --usb
refute "S10_SSH_KEY override: missing file means no -i" 'nomad_ed25519'
FAKE_ATHERON_DOWN=1 run status
check "state fetch uses the nomad key" 'ssh -i .*nomad_ed25519 .*cat /run/cerberus-s10/estado.json'
rm -f "$HOME/.ssh/nomad_ed25519"

# sem krdc nem vncviewer: imprime a URL (esconde o krdc do PATH)
reset_env
mkdir "$TMP/nokrdc"
for b in ssh adb scrcpy avahi-browse; do ln -s "$TMP/bin/$b" "$TMP/nokrdc/$b"; done
for b in bash env python3 sleep date timeout grep sed awk sort cat mkdir mv rm head cut paste kill pkill dirname printf tr; do p=$(command -v "$b") && ln -sf "$p" "$TMP/nokrdc/$b"; done
: > "$LOG"; PATH="$TMP/nokrdc" S10_ATHERON=x timeout 6 "$S10" --vnc > "$TMP/out" 2> "$TMP/err" &
VP=$!; sleep 3; kill "$VP" 2>/dev/null; wait "$VP" 2>/dev/null
check "vnc: no viewer prints URL" 'vnc://127\.0\.0\.1:15901' "$TMP/err"

# tudo falha
reset_env
FAKE_ATHERON_DOWN=1 FAKE_PHONE_DOWN=1 run
expect_rc "all paths fail: exit 1" eq 1
check "all fail: PT summary" 'os três caminhos falharam' "$TMP/err"
check "all fail: points to status" "s10 status" "$TMP/err"

# scrcpy quebra logo no USB -> cai para o sem fio
reset_env
FAKE_SCRCPY_FAIL_USB=1 FAKE_USB_DEVICES=$DEV FAKE_STATE='{"caminhos":{"adb_sem_fio":{"ip":"192.0.2.20","porta":37215}}}' \
    FAKE_CONNECT_OK="192.0.2.20:37215" run
check "auto: scrcpy usb failure -> path 2" 'scrcpy\[\] -s 192\.168\.1\.249:37215'
check "auto: reason reported" 'scrcpy falhou logo' "$TMP/err"

# flags forçam um caminho só
reset_env
FAKE_USB_DEVICES='List of devices attached\n\n' run --usb
refute "--usb never tries path 2" 'adb\[\] connect'
refute "--usb never tries path 3" 'ssh -N -p'
FAKE_USB_DEVICES=$DEV FAKE_STATE=$STATE_NOPORT run --sem-fio
refute "--sem-fio never opens the usb tunnel" 's10-adb.sock'
refute "--sem-fio never tries vnc" 'ssh -N -p'
expect_rc "--sem-fio fails without candidates" eq 1
check "--sem-fio PT error mentions pairing" 'pareamento' "$TMP/err"
FAKE_ATHERON_DOWN=1 run --vnc
check "--vnc only vnc" 'krdc'
refute "--vnc no adb" '^adb'

# ---------------------------------------------------------------- status
reset_env
ST='{"estado":"device","caminhos":{"adb_sem_fio":{"ip_lan":"127.0.0.1","porta":'$LPORT_OK',"ok":true},"vnc":{"ok":true}}}'
FAKE_STATE=$ST S10_SSH_PORT=$LPORT_OK S10_TAILNET_IP=127.0.0.1 run status
expect_rc "status: ok exits 0" eq 0
check "status: usb ok with latency" '✓ 1\) USB via atheron.* ms' "$TMP/out"
check "status: wireless ok with latency" '✓ 2\) adb sem fio: 127\.0\.0\.1:[0-9]+ aceita conexão \([0-9]+ ms\)' "$TMP/out"
check "status: vnc ok" '✓ 3\) VNC via Termux.*VNC ativo' "$TMP/out"
FAKE_ATHERON_DOWN=1 S10_SSH_PORT=1 S10_TAILNET_IP=127.0.0.1 run status
expect_rc "status: all down exits 1" eq 1
check "status: usb down reason" '✗ 1\) USB via atheron: root@atheron-test inacessível' "$TMP/out"
check "status: wireless unknown port" '✗ 2\) adb sem fio: porta desconhecida' "$TMP/out"
check "status: ssh down reason" '✗ 3\) VNC via Termux.*não responde' "$TMP/out"
FAKE_STATE='{"estado":"unauthorized"}' S10_SSH_PORT=1 run status
check "status: S10 not device" "✗ 1\) .*'unauthorized'" "$TMP/out"

run --nada
expect_rc "unknown option rejected" ne 0

echo "--- $n checks, $fail failed"
[ "$fail" -eq 0 ]
