#!/bin/bash
# Passo do USUÁRIO: instala o monitor/guardião do Galaxy S10 (adb por USB) no atheron (Debian).
# Uso: bash user-step-s10.sh [--check|--undo|--vnc-key|--tunnel-key <arquivo.pub>]      Detalhes: ../README.md
#   (sem args)            instala o serviço, o usuário do túnel, a senha do VNC (aleatória, só se faltar) e a regra udev
#   --vnc-key             pede (entrada oculta) a "Chave de acesso da API de Intent" do droidVNC-NG e grava em
#                         /etc/cerberus-s10/vnc-access-key (0600), reiniciando o serviço
#   --tunnel-key <.pub>   autoriza uma chave pública do nomad para o usuário s10tunnel (só túnel + estado)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=/usr/local/sbin/cerberus-s10
ESTADO_BIN=/usr/local/sbin/cerberus-s10-estado
UNIT=/etc/systemd/system/cerberus-s10.service
RULE=/etc/udev/rules.d/51-cerberus-s10.rules
SSHD_DIR=${S10_SSHD_DIR:-/etc/ssh/sshd_config.d}
DROPIN=$SSHD_DIR/50-s10tunnel.conf
SHELLS=${S10_SHELLS:-/etc/shells}
SVC_USER=cerberus-s10
TUN_USER=s10tunnel
STATE=/var/lib/cerberus-s10
# sobrescrevíveis só para os testes (S10_ALLOW_NONROOT=1 pula root/chown/systemctl nos modos --vnc-key e --tunnel-key)
KEYDIR=${S10_ETC:-/etc/cerberus-s10}
KEYFILE=$KEYDIR/vnc-access-key
PWFILE=$KEYDIR/vnc-password
TUN_HOME=${S10_TUNNEL_HOME:-/home/$TUN_USER}
NONROOT=${S10_ALLOW_NONROOT:-}
KEY_RE='^[A-Za-z0-9._~-]{4,128}$'
PUB_RE='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/=]+( .*)?$'

need_root() { [ "$(id -u)" -eq 0 ] || [ -n "$NONROOT" ] || { echo "rode como root"; exit 1; }; }

check() {
    local rc=0
    ok() { echo "ok:     $*"; }
    bad() { echo "FALTA:  $*"; rc=1; }
    if command -v adb >/dev/null; then ok "adb instalado"; else bad "adb não instalado"; fi
    if id "$SVC_USER" >/dev/null 2>&1; then ok "usuário $SVC_USER ($(id -nG "$SVC_USER"))"; else bad "usuário $SVC_USER"; fi
    if id "$TUN_USER" >/dev/null 2>&1; then ok "usuário do túnel $TUN_USER ($(id -nG "$TUN_USER"))"; else bad "usuário $TUN_USER"; fi
    if grep -qs 'permitopen="/run/cerberus-s10/adb.sock:' "$TUN_HOME/.ssh/authorized_keys"; then
        bad "authorized_keys com o formato antigo (inválido) do permitopen: rode --tunnel-key de novo"
    fi
    if [ -f "$DROPIN" ]; then ok "drop-in do sshd $DROPIN"; else bad "drop-in do sshd $DROPIN"; fi
    if grep -qs '^Include .*sshd_config.d' /etc/ssh/sshd_config; then ok "sshd_config inclui sshd_config.d"; else echo "aviso:  /etc/ssh/sshd_config não inclui sshd_config.d: o drop-in não vale"; fi
    if [ "$(getent passwd "$TUN_USER" | cut -d: -f7)" = "$ESTADO_BIN" ]; then ok "shell de $TUN_USER = $ESTADO_BIN (vale também no Tailscale SSH)"
    else bad "shell de $TUN_USER deveria ser $ESTADO_BIN (o Tailscale SSH ignora o authorized_keys)"; fi
    if grep -qs '^restrict,port-forwarding' "$TUN_HOME/.ssh/authorized_keys"; then
        ok "$TUN_HOME/.ssh/authorized_keys restrito ($(grep -c '^restrict' "$TUN_HOME/.ssh/authorized_keys") chave(s))"
    else bad "nenhuma chave do nomad em $TUN_HOME/.ssh/authorized_keys (use --tunnel-key <arquivo.pub>)"; fi
    if [ -f "$RULE" ]; then ok "regra udev"; else bad "regra udev $RULE"; fi
    if [ -x "$BIN" ]; then ok "$BIN"; else bad "$BIN"; fi
    if [ -x "$ESTADO_BIN" ]; then ok "$ESTADO_BIN"; else bad "$ESTADO_BIN"; fi
    if [ -f "$UNIT" ]; then ok "unit"; else bad "unit $UNIT"; fi
    if systemctl is-active --quiet cerberus-s10; then ok "serviço ativo"; else bad "serviço inativo"; fi
    if command -v ping >/dev/null; then ok "ping (sonda do Tailscale)"; else bad "ping (apt install iputils-ping)"; fi
    if command -v avahi-browse >/dev/null; then ok "avahi-browse (fallback mDNS)"; else echo "aviso:  avahi-utils ausente (o guardião usa só 'adb mdns services')"; fi
    if [ -s "$PWFILE" ]; then ok "senha do VNC existe (não exibida)"; else bad "$PWFILE vazio/ausente (rode o instalador)"; fi
    if [ -s "$KEYFILE" ]; then ok "chave de acesso do droidVNC-NG em $KEYFILE ($(stat -c %a "$KEYFILE"))"
    else echo "aviso:  $KEYFILE vazio/ausente: o VNC só sobe pelo botão do app, SEM senha, até você rodar --vnc-key"; fi
    if command -v ss >/dev/null; then
        local l
        l=$(ss -ltnH 'sport = :5037' 2>/dev/null || true)
        if [ -n "$l" ]; then bad "há um listener TCP em :5037 ($(echo "$l" | awk '{print $4}' | tr '\n' ' ')): o adb deve usar só o socket unix"
        else ok "nenhum listener TCP :5037"; fi
    fi
    if [ -S /run/cerberus-s10/adb.sock ]; then ok "socket do adb $(stat -c '%a %U:%G' /run/cerberus-s10/adb.sock)"
    else bad "/run/cerberus-s10/adb.sock ausente (adb server parado?)"; fi
    if [ -f /run/cerberus-s10/estado.json ]; then
        echo "estado: $(tr -d '\n ' < /run/cerberus-s10/estado.json | cut -c1-200)"
    else bad "/run/cerberus-s10/estado.json ainda não existe"; fi
    return "$rc"
}

# monta a linha de authorized_keys do túnel para uma chave pública (stdout)
tunnel_line() {
    printf 'restrict,port-forwarding,permitlisten="127.0.0.1:1",permitopen="127.0.0.1:27183",permitopen="[/run/cerberus-s10/adb.sock]:*",permitopen="[%s/adb.sock]:*",command="%s" %s\n' "$TUN_HOME" "$ESTADO_BIN" "$1"
}

# reescreve linhas no formato antigo (permitopen="/run/...:*" é inválido para o sshd: a porta é lida após o '/')
migrate_ak() {
    local ak=$1
    [ -f "$ak" ] || return 0
    sed -i 's#permitopen="/run/cerberus-s10/adb.sock:\*"#permitopen="[/run/cerberus-s10/adb.sock]:*"#' "$ak"
}

# reload do sshd só se a configuração validar (sshd -t); devolve 1 se inválida
reload_sshd() {
    if command -v sshd >/dev/null 2>&1 && ! sshd -t; then return 1; fi
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
}

case "${1:-}" in
--check) check; exit $? ;;
--vnc-key)
    need_root
    printf 'Chave de acesso da API de Intent do droidVNC-NG (copie do app; não aparece na tela): ' >&2
    IFS= read -rs key || true
    echo >&2
    [[ "$key" =~ $KEY_RE ]] || { echo "chave inválida (4 a 128 caracteres de A-Za-z0-9._~-)" >&2; exit 1; }
    install -d -m 0700 "$KEYDIR"
    ( umask 077; printf '%s\n' "$key" > "$KEYFILE.tmp" )
    chmod 600 "$KEYFILE.tmp"
    mv -f "$KEYFILE.tmp" "$KEYFILE"
    [ -n "$NONROOT" ] || systemctl restart cerberus-s10
    echo "chave gravada em $KEYFILE (0600). O guardião passa a iniciar o VNC com chave + senha."
    exit 0 ;;
--tunnel-key)
    need_root
    pub=${2:-}
    [ -n "$pub" ] && [ -f "$pub" ] || { echo "uso: $0 --tunnel-key <arquivo-de-chave-publica>"; exit 2; }
    install -d -m 0700 "$TUN_HOME/.ssh"
    AK=$TUN_HOME/.ssh/authorized_keys
    touch "$AK"
    migrate_ak "$AK"
    n=0
    while IFS= read -r line; do
        case "$line" in ''|'#'*) continue ;; esac
        [[ "$line" =~ $PUB_RE ]] || { echo "linha ignorada (não é uma chave pública simples, sem opções): ${line:0:30}..." >&2; continue; }
        new=$(tunnel_line "$line")
        if ! grep -qxF "$new" "$AK"; then
            # troca qualquer linha restrita antiga da MESMA chave (outras opções/formatos) pela nova
            grep -vF -- " $line" "$AK" > "$AK.tmp" || true
            mv -f "$AK.tmp" "$AK"
            printf '%s\n' "$new" >> "$AK"
        fi
        n=$((n + 1))
    done < "$pub"
    [ "$n" -gt 0 ] || { echo "nenhuma chave válida em $pub" >&2; exit 1; }
    chmod 600 "$AK"
    [ -n "$NONROOT" ] || chown -R "$TUN_USER:$(id -gn "$TUN_USER")" "$TUN_HOME/.ssh"
    echo "$n chave(s) autorizada(s) para $TUN_USER (só túnel para o adb/27183 e leitura do estado)."
    exit 0 ;;
--undo)
    [ "$(id -u)" -eq 0 ] || { echo "rode como root"; exit 1; }
    systemctl disable --now cerberus-s10 2>/dev/null || true
    rm -f "$UNIT" "$BIN" "$RULE"
    if id "$TUN_USER" >/dev/null 2>&1; then usermod -s /bin/sh "$TUN_USER" || true; fi
    [ -L "$TUN_HOME/adb.sock" ] && rm -f "$TUN_HOME/adb.sock"
    rm -f "$ESTADO_BIN"
    if [ -f "$SHELLS" ]; then grep -vxF "$ESTADO_BIN" "$SHELLS" > "$SHELLS.tmp" || true; cat "$SHELLS.tmp" > "$SHELLS"; rm -f "$SHELLS.tmp"; fi
    if [ -f "$DROPIN" ]; then
        rm -f "$DROPIN"
        [ -f "$DROPIN.antes-s10" ] && cp -a "$DROPIN.antes-s10" "$DROPIN"
        reload_sshd || true
    fi
    for f in "$UNIT" "$RULE"; do
        [ -f "$f.antes-s10" ] && cp -a "$f.antes-s10" "$f"
    done
    systemctl daemon-reload
    udevadm control --reload-rules
    udevadm trigger --subsystem-match=usb --attr-match=idVendor=04e8 || true
    echo "removido. Mantidos de propósito: usuários $SVC_USER e $TUN_USER, $STATE (chave adb, pins), $KEYDIR (chave e senha do VNC) e $TUN_HOME/.ssh; apague à mão se quiser."
    exit 0 ;;
"") ;;
*) echo "uso: $0 [--check|--undo|--vnc-key|--tunnel-key <arquivo.pub>]"; exit 2 ;;
esac

need_root
# 1) testes e validações ANTES de mexer no sistema
python3 -I "$HERE/tests/test_cerberus_s10.py" >/dev/null 2>&1 || { echo "testes do cerberus-s10 falharam"; exit 1; }
python3 -I -m py_compile "$HERE/cerberus-s10" || { echo "cerberus-s10 não compila"; exit 1; }
if command -v systemd-analyze >/dev/null; then
    # o ExecStart ainda não existe: valida uma cópia apontando para o script local
    tmp=$(mktemp -d)
    sed "s#^ExecStart=.*#ExecStart=$HERE/cerberus-s10#" "$HERE/cerberus-s10.service" > "$tmp/cerberus-s10.service"
    systemd-analyze verify "$tmp/cerberus-s10.service" || { rm -rf "$tmp"; echo "unit inválida"; exit 1; }
    rm -rf "$tmp"
fi
# 2) pacotes (só se faltarem)
command -v adb >/dev/null || apt-get install -y adb
command -v ping >/dev/null || apt-get install -y iputils-ping
command -v avahi-browse >/dev/null || apt-get install -y avahi-utils   # fallback do mDNS
# 3) usuários de sistema: o serviço (dono do USB e do socket do adb) e o do túnel SSH (mesmo grupo, sem plugdev)
getent group "$SVC_USER" >/dev/null || groupadd -r "$SVC_USER"
id "$SVC_USER" >/dev/null 2>&1 || useradd -r -M -d "$STATE" -s /usr/sbin/nologin -g "$SVC_USER" "$SVC_USER"
gpasswd -d "$SVC_USER" plugdev >/dev/null 2>&1 || true
# o túnel precisa de um shell real para o comando forçado; a conta fica sem senha ('*' em vez de '!': o sshd recusa contas '!')
id "$TUN_USER" >/dev/null 2>&1 || useradd -r -m -d "$TUN_HOME" -s /bin/sh -g "$SVC_USER" "$TUN_USER"
usermod -p '*' "$TUN_USER"
install -d -m 0700 -o "$TUN_USER" -g "$SVC_USER" "$TUN_HOME/.ssh"
# 3b) segredos do droidVNC-NG: só root lê; a unit repassa via LoadCredential
install -d -m 0700 -o root -g root "$KEYDIR"
[ -e "$KEYFILE" ] || install -m 0600 -o root -g root /dev/null "$KEYFILE"
if [ ! -s "$PWFILE" ]; then
    # 8 caracteres (a autenticação VNC só usa 8); gerada aqui, nunca impressa
    ( umask 077; python3 -I -c 'import secrets, string; print("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(8)))' > "$PWFILE" )
    chmod 600 "$PWFILE"
fi
# 4) cópia de segurança (uma vez) do que existir
for f in "$UNIT" "$RULE" "$DROPIN"; do
    [ -f "$f" ] && [ ! -f "$f.antes-s10" ] && cp -a "$f" "$f.antes-s10"
done
# 5) instala
install -m 0755 "$HERE/cerberus-s10" "$BIN"
install -m 0755 "$HERE/cerberus-s10-estado" "$ESTADO_BIN"
# O Tailscale SSH (porta 22 da tailnet) ignora authorized_keys e comando forçado: o último recurso é o SHELL do usuário,
# que só imprime o estado (os túneis -L continuam funcionando). Registrado em /etc/shells só se faltar.
grep -qxF "$ESTADO_BIN" "$SHELLS" || echo "$ESTADO_BIN" >> "$SHELLS"
usermod -s "$ESTADO_BIN" "$TUN_USER"
# Tailscale SSH (port 22 on the tailnet) only forwards unix sockets inside the user's home: link the adb socket there
ln -sfn /run/cerberus-s10/adb.sock "$TUN_HOME/adb.sock"
migrate_ak "$TUN_HOME/.ssh/authorized_keys"
# drop-in do OpenSSH para o s10tunnel: só encaminhamento local, sem TTY/X11/agente; valida antes de recarregar
install -d -m 0755 "$SSHD_DIR"
install -m 0644 "$HERE/50-s10tunnel.conf" "$DROPIN"
if ! reload_sshd; then
    rm -f "$DROPIN"; [ -f "$DROPIN.antes-s10" ] && cp -a "$DROPIN.antes-s10" "$DROPIN"
    echo "sshd -t reprovou o drop-in; removido."; exit 1
fi
install -m 0644 "$HERE/51-cerberus-s10.rules" "$RULE"
install -m 0644 "$HERE/cerberus-s10.service" "$UNIT"
udevadm control --reload-rules
udevadm trigger --subsystem-match=usb --attr-match=idVendor=04e8 || true
systemctl daemon-reload
systemctl enable --now cerberus-s10
systemctl restart cerberus-s10
sleep 8
check || true
echo "ligado. Próximos passos do dono, nesta ordem:"
echo "  1) bash $0 --vnc-key                      (cola a chave de acesso do droidVNC-NG)"
echo "  2) bash $0 --tunnel-key <nomad.pub>       (autoriza o nomad no usuário $TUN_USER)"
echo "  3) no nomad: s10 setup-vnc                (busca a senha do VNC)"
echo "Se o estado for 'unauthorized': aceite a chave RSA no S10 (scrcpy) e marque 'Sempre permitir'."
echo "Desfazer: bash $0 --undo"
