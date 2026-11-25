#!/bin/bash
# Passo do USUÁRIO (root no atheron): prepara o ambiente do VS Code no S10 e autoriza uma chave pública,
# sem precisar de nenhuma chave já aceita pelo Termux. Vai pelo USB: o adb do cerberus-s10 empurra os arquivos
# para /sdcard/Download/s10-dev, abre o Termux e digita UM comando curto (só letras, '/', '.', '-'), que roda
# termux/dev-setup.sh dentro do Termux. O resultado volta por arquivo (log + código de saída).
#
# Uso: bash user-step-s10-dev.sh [--reset-distro] <arquivo-de-chave-publica>
#   ex. (do Windows):  scp ~/.ssh/s10-dev_ed25519.pub root@atheron:/root/s10-dev.pub
#                      ssh root@atheron 'bash /home/claude/development/personal/galaxy-s10/atheron/user-step-s10-dev.sh /root/s10-dev.pub'
# Requer: cerberus-s10 rodando (socket do adb), S10 no USB com estado `device`, Termux com o bootstrap feito.
# Variáveis (testes): S10_ADB_SOCKET, S10_SERIAL, S10_DEV_TIMEOUT (s, padrão 1800), S10_DEV_POLL (s, padrão 10),
#                     S10_ALLOW_NONROOT=1 (pula a checagem de root).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TERMUX_DIR=$HERE/../termux
RESET=0
if [ "${1:-}" = --reset-distro ]; then RESET=1; shift; fi   # reinstala um Debian quebrado (apaga o conteúdo dele)
PUB=${1:-}
SOCK=${S10_ADB_SOCKET:-/run/cerberus-s10/adb.sock}
TIMEOUT=${S10_DEV_TIMEOUT:-3600}
POLL=${S10_DEV_POLL:-10}
REMOTE=/sdcard/Download/s10-dev
TERMUX_PATH=/storage/emulated/0/Download/s10-dev   # o mesmo diretório visto de dentro do Termux

[ "$(id -u)" -eq 0 ] || [ -n "${S10_ALLOW_NONROOT:-}" ] || { echo "rode como root"; exit 1; }
[ -n "$PUB" ] && [ -f "$PUB" ] || { echo "uso: $0 [--reset-distro] <arquivo-de-chave-publica>"; exit 2; }
grep -qE '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[a-z0-9]+) [A-Za-z0-9+/=]+( [^ ]+)?$' "$PUB" \
    || { echo "não parece uma chave pública OpenSSH de uma linha: $PUB"; exit 2; }
for f in dev-setup.sh s10-dev-shell; do
    [ -f "$TERMUX_DIR/$f" ] || { echo "faltando $TERMUX_DIR/$f"; exit 1; }
done

if [ -z "${S10_SERIAL:-}" ] && [ -r /etc/default/cerberus-s10 ]; then
    S10_SERIAL=$(sed -n 's/^S10_SERIAL=//p' /etc/default/cerberus-s10 | head -n 1)
fi
export ADB_SERVER_SOCKET=localfilesystem:$SOCK
adb_() { if [ -n "${S10_SERIAL:-}" ]; then adb -s "$S10_SERIAL" "$@"; else adb "$@"; fi; }

state=$(adb_ get-state 2>/dev/null || true)
[ "$state" = device ] || { echo "S10 não está pronto no USB (estado: ${state:-ausente}); confira: systemctl status cerberus-s10"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# o comando que o Termux executa: dev-setup.sh com a chave do arquivo e o s10-dev-shell ao lado
cat > "$TMP/run.sh" <<EOF
#!/data/data/com.termux/files/usr/bin/sh
D=$TERMUX_PATH
rm -f "\$D/rc"
S10_DEV_RESET=$RESET sh "\$D/dev-setup.sh" "\$(cat "\$D/key.pub")" "\$D/s10-dev-shell" > "\$D/log" 2>&1
echo \$? > "\$D/rc"
EOF
head -n 1 "$PUB" > "$TMP/key.pub"

echo "1/4 enviando arquivos para $REMOTE"
adb_ shell "rm -rf $REMOTE && mkdir -p $REMOTE"
adb_ push "$TERMUX_DIR/dev-setup.sh" "$TERMUX_DIR/s10-dev-shell" "$TMP/run.sh" "$TMP/key.pub" "$REMOTE/" > /dev/null
# o Termux lê e escreve no /sdcard só com a permissão de armazenamento
adb_ shell pm grant com.termux android.permission.READ_EXTERNAL_STORAGE > /dev/null 2>&1 || true
adb_ shell pm grant com.termux android.permission.WRITE_EXTERNAL_STORAGE > /dev/null 2>&1 || true

echo "2/4 abrindo o Termux e digitando o comando"
adb_ shell input keyevent 224          # KEYCODE_WAKEUP
adb_ shell am start -n com.termux/.app.TermuxActivity > /dev/null
sleep "${S10_DEV_OPEN_WAIT:-4}"
adb_ shell input text "sh%s$TERMUX_PATH/run.sh"
adb_ shell input keyevent 66           # Enter

echo "3/4 aguardando o dev-setup.sh (baixa o Debian na 1ª vez; até ${TIMEOUT}s)"
waited=0 rc=""
while [ "$waited" -lt "$TIMEOUT" ]; do
    rc=$(adb_ shell cat "$REMOTE/rc" 2>/dev/null | tr -d '\r[:space:]' || true)
    case "$rc" in [0-9]*) break ;; esac
    rc=""
    # the Termux session may still be busy with an older command: the typed line waits in its input queue
    if [ "$waited" -ge "${S10_DEV_START_WAIT:-300}" ] && ! adb_ shell ls "$REMOTE/log" > /dev/null 2>&1; then
        echo "o Termux não começou a rodar o comando em ${S10_DEV_START_WAIT:-300} s (sem $REMOTE/log); a sessão dele pode estar ocupada."
        echo "Veja a tela: adb exec-out screencap -p > /tmp/s10.png (com ADB_SERVER_SOCKET=$ADB_SERVER_SOCKET)"
        exit 1
    fi
    sleep "$POLL"
    waited=$((waited + POLL))
done

echo "4/4 resultado (fim do log):"
adb_ shell tail -n 25 "$REMOTE/log" 2>/dev/null || true
if [ -z "$rc" ]; then
    echo "tempo esgotado sem resultado; o log continua em $REMOTE/log"
    exit 1
fi
adb_ shell rm -rf "$REMOTE" || true
adb_ shell input keyevent 3 || true    # volta para a tela inicial
if [ "$rc" != 0 ]; then
    echo "dev-setup.sh falhou (código $rc)"
    exit 1
fi
echo "pronto: chave '$(awk '{print $3}' "$TMP/key.pub")' autorizada; teste com: ssh s10-dev 'uname -m; id -un'"
