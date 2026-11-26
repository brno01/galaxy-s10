#!/bin/bash
# Prepares a development account on the atheron (e.g. claude) to test apps on the S10. No root: run AS that account,
# after root ran `user-step-s10.sh --dev-user <account>` (cerberus-s10 group + copy of the VNC password).
#   bash install-dev.sh            install / update (idempotent)
#   bash install-dev.sh --check    show what is missing
#   bash install-dev.sh --undo     remove what this script installed
# Installs:
#   ~/.local/bin/adb                      guard in front of /usr/bin/adb (refuses kill-server, tcpip, -a, ...)
#   ~/.config/dev/env.d/s10-adb.sh        ADB_SERVER_SOCKET -> the cerberus-s10 socket (sourced by ~/.bashrc)
#   ~/.config/environment.d/s10-adb.conf  the same for systemd --user services
#   ~/.local/bin/s10-tela-web + ~/.config/systemd/user/s10-tela-web.service   noVNC on 127.0.0.1:6080 (VS Code tab)
#   websockify (uv tool, pinned) and noVNC (pinned release, sha256 checked) in ~/.local/share/s10-tela-web
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
BIN=${S10_DEV_BIN:-$HOME/.local/bin}
ENVD=${S10_DEV_ENVD:-$HOME/.config/dev/env.d}
UNITD=${S10_DEV_UNITD:-$HOME/.config/systemd/user}
SHARE=${S10_DEV_SHARE:-$HOME/.local/share/s10-tela-web}
ENVIRONMENTD=${S10_DEV_ENVIRONMENTD:-$HOME/.config/environment.d}
SYSTEMCTL=${S10_SYSTEMCTL:-systemctl}
UV=${S10_UV:-$(command -v uv || echo "$HOME/.local/bin/uv")}
CURL=${S10_CURL:-curl}
SOCK=${S10_ADB_SOCK:-/run/cerberus-s10/adb.sock}
WEBSOCKIFY_VERSION=0.13.0
NOVNC_VERSION=1.7.0
NOVNC_URL=${S10_NOVNC_URL:-https://github.com/novnc/noVNC/archive/refs/tags/v$NOVNC_VERSION.tar.gz}
NOVNC_SHA256=${S10_NOVNC_SHA256:-b1003a11b6e6e8d8f7f5e5586daae7f8ca651d8aee0aa155ff9ac841c48f52c6}

[ "$(id -u)" -ne 0 ] || { echo "rode como a conta de desenvolvimento (ex.: claude), não como root"; exit 1; }

check() {
    local rc=0
    ok() { echo "ok:     $*"; }
    bad() { echo "FALTA:  $*"; rc=1; }
    if id -nG | tr ' ' '\n' | grep -qx cerberus-s10; then ok "grupo cerberus-s10 nesta sessão"
    elif id -nG "$(id -un)" | tr ' ' '\n' | grep -qx cerberus-s10; then bad "grupo cerberus-s10 já concedido, mas esta sessão é anterior: faça login de novo"
    else bad "grupo cerberus-s10 (root: bash user-step-s10.sh --dev-user $(id -un))"; fi
    if [ -r "$SOCK" ] && [ -w "$SOCK" ]; then ok "socket do adb $SOCK"; else bad "acesso ao socket $SOCK"; fi
    if cmp -s "$HERE/adb" "$BIN/adb"; then ok "$BIN/adb (proteção)"; else bad "$BIN/adb"; fi
    if cmp -s "$HERE/s10-adb.env.sh" "$ENVD/s10-adb.sh"; then ok "$ENVD/s10-adb.sh"; else bad "$ENVD/s10-adb.sh"; fi
    if cmp -s "$HERE/s10-tela-web" "$BIN/s10-tela-web"; then ok "$BIN/s10-tela-web"; else bad "$BIN/s10-tela-web"; fi
    if cmp -s "$HERE/s10-tela-web.service" "$UNITD/s10-tela-web.service"; then ok "unit s10-tela-web"; else bad "unit s10-tela-web"; fi
    if [ -x "$BIN/websockify" ]; then ok "websockify"; else bad "websockify (uv tool)"; fi
    if [ -f "$SHARE/novnc/vnc.html" ]; then ok "noVNC $(cat "$SHARE/novnc/.version" 2>/dev/null)"; else bad "noVNC em $SHARE/novnc"; fi
    if [ -s "$HOME/.config/s10/vnc-password" ]; then ok "senha do VNC (cópia 0600)"
    else echo "aviso:  sem $HOME/.config/s10/vnc-password: a aba vai pedir a senha do VNC"; fi
    if "$SYSTEMCTL" --user is-active --quiet s10-tela-web.service; then ok "s10-tela-web ativo"; else bad "s10-tela-web parado (s10-tela-web start)"; fi
    return "$rc"
}

install_novnc() {
    if [ "$(cat "$SHARE/novnc/.version" 2>/dev/null)" = "$NOVNC_VERSION" ] && [ -f "$SHARE/novnc/vnc.html" ]; then
        return 0
    fi
    local tmp sum
    tmp=$(mktemp -d)
    "$CURL" -sSfL -o "$tmp/novnc.tgz" "$NOVNC_URL"
    sum=$(sha256sum "$tmp/novnc.tgz" | cut -d' ' -f1)
    if [ "$sum" != "$NOVNC_SHA256" ]; then
        rm -rf "$tmp"
        echo "noVNC baixado com sha256 inesperado ($sum); nada foi instalado" >&2
        return 1
    fi
    mkdir -p "$tmp/x"
    tar -xzf "$tmp/novnc.tgz" -C "$tmp/x" --strip-components=1 --no-same-owner
    [ -f "$tmp/x/vnc.html" ] || { rm -rf "$tmp"; echo "pacote do noVNC sem vnc.html" >&2; return 1; }
    echo "$NOVNC_VERSION" > "$tmp/x/.version"
    mkdir -p "$SHARE"
    rm -rf "$SHARE/novnc.old"
    [ -d "$SHARE/novnc" ] && mv "$SHARE/novnc" "$SHARE/novnc.old"
    mv "$tmp/x" "$SHARE/novnc"
    rm -rf "$SHARE/novnc.old" "$tmp"
}

case "${1:-}" in
--check) check; exit $? ;;
--undo)
    "$SYSTEMCTL" --user disable --now s10-tela-web.service 2>/dev/null || true
    cmp -s "$HERE/adb" "$BIN/adb" && rm -f "$BIN/adb"
    [ -e "$BIN/adb.antes-s10" ] && [ ! -e "$BIN/adb" ] && mv "$BIN/adb.antes-s10" "$BIN/adb"
    for f in "$BIN/s10-tela-web" "$ENVD/s10-adb.sh" "$UNITD/s10-tela-web.service" "$ENVIRONMENTD/s10-adb.conf"; do rm -f "$f"; done
    [ -e "$SHARE/.websockify-ours" ] && { "$UV" tool uninstall websockify > /dev/null 2>&1 || true; }
    rm -rf "$SHARE"
    "$SYSTEMCTL" --user daemon-reload 2>/dev/null || true
    echo "removido (o grupo cerberus-s10 continua: root, user-step-s10.sh --dev-user-undo $(id -un))."
    exit 0 ;;
'') ;;
*) echo "uso: $0 [--check|--undo]" >&2; exit 2 ;;
esac

mkdir -p "$BIN" "$ENVD" "$UNITD" "$SHARE" "$ENVIRONMENTD"
# an adb that is not ours (an older copy of the guard is fine) is kept once as adb.antes-s10
if [ -e "$BIN/adb" ] && ! grep -q 'cerberus-s10 adb server' "$BIN/adb" 2>/dev/null && [ ! -e "$BIN/adb.antes-s10" ]; then
    mv "$BIN/adb" "$BIN/adb.antes-s10"
fi
install -m 0755 "$HERE/adb" "$BIN/adb"
# systemd --user services and anything they start (not only interactive shells) see the socket too
printf 'ADB_SERVER_SOCKET=localfilesystem:%s\n' "$SOCK" > "$ENVIRONMENTD/s10-adb.conf"
install -m 0755 "$HERE/s10-tela-web" "$BIN/s10-tela-web"
install -m 0644 "$HERE/s10-adb.env.sh" "$ENVD/s10-adb.sh"
install -m 0644 "$HERE/s10-tela-web.service" "$UNITD/s10-tela-web.service"
# remember whether websockify was ours, so --undo does not remove one the account already had
if [ ! -e "$SHARE/.websockify-preexisting" ] && [ ! -e "$SHARE/.websockify-ours" ]; then
    if "$UV" tool list 2> /dev/null | grep -q '^websockify '; then touch "$SHARE/.websockify-preexisting"; else touch "$SHARE/.websockify-ours"; fi
fi
"$UV" tool install --quiet "websockify==$WEBSOCKIFY_VERSION"
install_novnc
if ! "$SYSTEMCTL" --user daemon-reload 2> /dev/null; then
    echo "arquivos instalados, mas o systemd --user desta conta não respondeu (sem sessão nem linger?)."
    echo "Ative uma vez (root): loginctl enable-linger $(id -un); depois rode este script de novo."
    exit 1
fi
# the unit enters the group with sg (from /etc/group), so it works right after --dev-user, without a new login
if id -nG "$(id -un)" | tr ' ' '\n' | grep -qx cerberus-s10; then
    "$SYSTEMCTL" --user enable s10-tela-web.service
    "$SYSTEMCTL" --user restart s10-tela-web.service
    echo "pronto: tela do S10 em $("$BIN/s10-tela-web" url | sed 's/password=[^&]*/password=***/')"
    id -nG | tr ' ' '\n' | grep -qx cerberus-s10 || echo "o adb no terminal vale a partir do próximo login (ou já: sg cerberus-s10 -c 'adb devices')."
else
    "$SYSTEMCTL" --user enable s10-tela-web.service
    echo "instalado, mas esta conta ainda não está no grupo cerberus-s10 (root: user-step-s10.sh --dev-user $(id -un));"
    echo "depois: systemctl --user restart s10-tela-web."
fi
