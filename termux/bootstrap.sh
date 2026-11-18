#!/data/data/com.termux/files/usr/bin/sh
# Bootstrap do Termux no Galaxy S10 (rodar UMA vez, DENTRO do app Termux; idempotente).
# Uso:  sh bootstrap.sh <arquivo-de-chaves-publicas> [10-sshd.sh] [20-guardian.sh]
#       sh bootstrap.sh --remove-key <comentario>     (tira uma chave do authorized_keys)
# Como chegar aqui (sem teclado no S10): no atheron/nomad, com o S10 via adb/scrcpy:
#   adb push termux/bootstrap.sh termux/boot/10-sshd.sh termux/boot/20-guardian.sh /sdcard/Download/
#   adb push minhas-chaves.pub /sdcard/Download/s10-keys.pub
#   (no Termux, via scrcpy)  termux-setup-storage   # uma vez, aceita a permissão
#   sh ~/storage/downloads/bootstrap.sh ~/storage/downloads/s10-keys.pub
# Só a chave pública do NOMAD entra no arquivo de chaves (uma por linha; formato em authorized_keys.example).
# O atheron nunca faz login no Termux (o guardião só confere o banner do sshd): não coloque a chave dele aqui.
# Reexecutar com um arquivo novo só ACRESCENTA chaves (nunca remove nem duplica).
# Requer o Termux e o Termux:Boot do F-Droid (o Termux da Play Store está obsoleto).
set -eu

# Remover uma chave pelo comentário (último campo da linha), p.ex. a do atheron que não deve mais ter acesso:
#   sh bootstrap.sh --remove-key atheron-s10
if [ "${1:-}" = "--remove-key" ]; then
    COMMENT=${2:-}
    [ -n "$COMMENT" ] || { echo "uso: sh $0 --remove-key <comentario-da-chave>"; exit 1; }
    AK="$HOME/.ssh/authorized_keys"
    [ -f "$AK" ] || { echo "sem $AK"; exit 1; }
    removed=0
    : > "$AK.tmp"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
        *" $COMMENT") removed=$((removed + 1)) ;;
        *) printf '%s\n' "$line" >> "$AK.tmp" ;;
        esac
    done < "$AK"
    chmod 600 "$AK.tmp"
    mv -f "$AK.tmp" "$AK"
    echo "$removed chave(s) com o comentário '$COMMENT' removida(s)."
    exit 0
fi

KEYS=${1:-}
SELF=$(dirname "$0")
first_file() { for f in "$@"; do [ -f "$f" ] && { echo "$f"; return; }; done; }
BOOT_SRC=${2:-$(first_file "$SELF/10-sshd.sh" "$SELF/boot/10-sshd.sh")}
GUARD_SRC=${3:-$(first_file "$SELF/20-guardian.sh" "$SELF/boot/20-guardian.sh")}
[ -n "$KEYS" ] && [ -f "$KEYS" ] || { echo "uso: sh $0 <arquivo-de-chaves-publicas> [10-sshd.sh]"; exit 1; }
[ -n "$GUARD_SRC" ] && [ -f "$GUARD_SRC" ] || { echo "20-guardian.sh não encontrado (passe o caminho como 3º argumento)"; exit 1; }
grep -qE '^(ssh-(ed25519|rsa)|ecdsa-sha2-) ' "$KEYS" || { echo "nenhuma chave pública válida em $KEYS"; exit 1; }

pkg update -y
pkg install -y openssh termux-api termux-services socat

# sshd: porta 8022, somente chave
CONF="$PREFIX/etc/ssh/sshd_config"
mkdir -p "$PREFIX/etc/ssh"
touch "$CONF"
set_opt() { # set_opt Key value: removes EVERY line of the key (commented or not), then appends one (idempotent)
    sed -i -E "/^#?[[:space:]]*$1[[:space:]]/d" "$CONF"
    echo "$1 $2" >> "$CONF"
}
set_opt Port 8022
set_opt PasswordAuthentication no
set_opt KbdInteractiveAuthentication no
set_opt PermitRootLogin no
# endurecimento: só a interface da tailnet (o 20-guardian.sh reinicia o sshd até o tun0 existir), só este usuário,
# só chave pública, poucas tentativas
TAILNET_IP=${S10_TAILNET_IP:-100.64.0.10}
set_opt ListenAddress "$TAILNET_IP"
set_opt AllowUsers "$(whoami)"
set_opt MaxAuthTries 2
set_opt LoginGraceTime 15
set_opt AuthenticationMethods publickey

# chaves autorizadas (sem duplicar)
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
AK="$HOME/.ssh/authorized_keys"
touch "$AK"
while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    grep -qxF "$line" "$AK" || echo "$line" >> "$AK"
done < "$KEYS"
chmod 600 "$AK"

# inicialização no boot (Termux:Boot)
mkdir -p "$HOME/.termux/boot"
if [ -n "$BOOT_SRC" ] && [ -f "$BOOT_SRC" ]; then
    cp "$BOOT_SRC" "$HOME/.termux/boot/10-sshd.sh"
else
    printf '#!/data/data/com.termux/files/usr/bin/sh\ntermux-wake-lock\nsshd\n' > "$HOME/.termux/boot/10-sshd.sh"
fi
chmod 700 "$HOME/.termux/boot/10-sshd.sh"

# vigia do lado do celular (loop de 60 s: sshd vivo, wake lock, log com rotação)
cp "$GUARD_SRC" "$HOME/.termux/boot/20-guardian.sh"
chmod 700 "$HOME/.termux/boot/20-guardian.sh"

# Wake-on-LAN do atheron: 's10 acordar-atheron' (nomad) chama este comando por ssh (socat manda o broadcast)
WAKE_SRC=$(first_file "$SELF/acordar-atheron")
if [ -n "$WAKE_SRC" ]; then
    mkdir -p "$PREFIX/bin"
    cp "$WAKE_SRC" "$PREFIX/bin/acordar-atheron"
    chmod 700 "$PREFIX/bin/acordar-atheron"
fi
# rede de segurança: ao abrir uma sessão do Termux (o atheron abre o app quando o sshd cai, p.ex. após force-stop),
# o ~/.bashrc sobe o sshd, o wake lock e o vigia (instância única). Migra o gancho antigo de 2 linhas.
BRC="$HOME/.bashrc"
touch "$BRC"
sed -i '/^# s10-guardian$/,+1d' "$BRC"
# shellcheck disable=SC2016  # as aspas simples são intencionais: o texto é gravado literalmente no ~/.bashrc
grep -q '# s10-guardian v2' "$BRC" || printf '%s\n' \
    '# s10-guardian v2' \
    'pgrep -x sshd >/dev/null || sshd' \
    'termux-wake-lock' \
    'pgrep -f 20-guardian.sh >/dev/null || (sh "$HOME/.termux/boot/20-guardian.sh" >/dev/null 2>&1 &)' >> "$BRC"

# o RUN_COMMAND é recusado ao uid shell e deixaria qualquer app instalado rodar comandos no Termux:
# allow-external-apps fica FALSE (migra um true antigo)
TP="$HOME/.termux/termux.properties"
touch "$TP"
if grep -qE '^#?[[:space:]]*allow-external-apps[[:space:]]*=' "$TP"; then
    sed -i -E 's|^#?[[:space:]]*allow-external-apps[[:space:]]*=.*|allow-external-apps=false|' "$TP"
else
    echo "allow-external-apps=false" >> "$TP"
fi
command -v termux-reload-settings >/dev/null 2>&1 && termux-reload-settings || true

# (re)inicia o sshd com a configuração nova
pkill -x sshd 2>/dev/null || true
# se o tun0 ainda não existe o ListenAddress não liga: o vigia (20-guardian.sh) tenta de novo a cada 60 s
sshd || echo "aviso: o sshd não subiu agora (tailnet fora?); o vigia tenta de novo."

cat <<MSG

Pronto. Verifique:
  sshd -T | grep -Ei '^(port|listenaddress|allowusers|maxauthtries|logingracetime|authenticationmethods|passwordauthentication|kbdinteractiveauthentication|permitrootlogin) '
  pgrep -x sshd && echo sshd ativo
  whoami                      # usuário (uXX_aNNN) que vai no ssh -p 8022 <usuario>@<ip-tailscale>
  ls -l ~/.termux/boot/10-sshd.sh ~/.termux/boot/20-guardian.sh ~/.ssh/authorized_keys
  grep allow-external-apps ~/.termux/termux.properties   # deve ser false
  sh ~/.termux/boot/20-guardian.sh &   # ou reinicie o celular; log em ~/guardian.log
Falta (manual, no Android): instalar o Termux:Boot, abri-lo UMA vez, e tirar o Termux da
otimização de bateria (Configurações > Aplicativos > Termux > Bateria > Sem restrições).
MSG
