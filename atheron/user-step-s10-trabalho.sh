#!/bin/bash
# Passo do USUÁRIO (root no atheron): a conta de trabalho testa apps no S10 pelo intermediário s10-trabalho-adb,
# sem entrar no grupo cerberus-s10 (o firewall dela continua valendo; ver README, "Conta de trabalho").
# Uso: bash user-step-s10-trabalho.sh [--check|--undo]
#   (sem args)  grupo s10-trabalho com a conta de trabalho, intermediário + unit (NÃO sobe no boot: janela de 8 h
#               aberta com `s10-trabalho liga`), /etc/default/s10-trabalho, s10-adb e s10-run (para a conta de
#               trabalho), s10-trabalho (para a conta pessoal) e sudoers só para ligar/desligar a janela
# Variáveis: S10_WORK_USER (clubpetro), S10_PERSONAL_USER (claude, quem abre a janela). Só para os testes:
#   S10_ALLOW_NONROOT=1, S10_TRABALHO_ROOT (prefixo dos caminhos), S10_SKIP_TESTS=1, e os comandos
#   S10_SYSTEMCTL, S10_VISUDO, S10_GROUPADD, S10_USERMOD, S10_GPASSWD, S10_GROUPDEL, S10_GETENT
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
R=${S10_TRABALHO_ROOT:-}
WORK=${S10_WORK_USER:-clubpetro}
PERSONAL=${S10_PERSONAL_USER:-claude}
GROUP=s10-trabalho
UNIT=s10-trabalho-adb.service
SBIN=$R/usr/local/sbin
BIN=$R/usr/local/bin
UNITF=$R/etc/systemd/system/$UNIT
DEFAULTS=$R/etc/default/s10-trabalho
SUDOERS=$R/etc/sudoers.d/s10-trabalho
SYSTEMCTL=${S10_SYSTEMCTL:-systemctl}
VISUDO=${S10_VISUDO:-visudo}
GROUPADD=${S10_GROUPADD:-groupadd}
USERMOD=${S10_USERMOD:-usermod}
GPASSWD=${S10_GPASSWD:-gpasswd}
GROUPDEL=${S10_GROUPDEL:-groupdel}
GETENT=${S10_GETENT:-getent}

[ "$(id -u)" -eq 0 ] || [ -n "${S10_ALLOW_NONROOT:-}" ] || { echo "rode como root"; exit 1; }
for u in "$WORK" "$PERSONAL"; do
    case "$u" in root|cerberus-s10|s10tunnel|'') echo "conta inválida: '$u'"; exit 2 ;; esac
done
[ "$WORK" != "$PERSONAL" ] || { echo "a conta de trabalho e a pessoal precisam ser diferentes"; exit 2; }

sudoers_text() {
    printf '# galaxy-s10 atheron/user-step-s10-trabalho.sh: %s abre e fecha a janela do S10 para a conta de trabalho.\n' "$PERSONAL"
    printf '%s ALL=(root) NOPASSWD: /usr/bin/systemctl restart %s, /usr/bin/systemctl stop %s\n' "$PERSONAL" "$UNIT" "$UNIT"
}

check() {
    local rc=0
    ok() { echo "ok:     $*"; }
    bad() { echo "FALTA:  $*"; rc=1; }
    if "$GETENT" group "$GROUP" | cut -d: -f4 | tr ',' '\n' | grep -qx "$WORK"; then ok "$WORK no grupo $GROUP"
    else bad "$WORK no grupo $GROUP"; fi
    if "$GETENT" group cerberus-s10 | cut -d: -f4 | tr ',' '\n' | grep -qx "$WORK"; then
        bad "$WORK está no grupo cerberus-s10 (acesso cru ao adb, por fora do intermediário): gpasswd -d $WORK cerberus-s10"
    else ok "$WORK fora do grupo cerberus-s10"; fi
    for f in "$SBIN/s10-trabalho-adb" "$BIN/s10-adb" "$BIN/s10-run" "$BIN/s10-trabalho" "$UNITF" "$DEFAULTS" "$SUDOERS"; do
        if [ -e "$f" ]; then ok "$f"; else bad "$f"; fi
    done
    if "$SYSTEMCTL" is-enabled --quiet "$UNIT" 2>/dev/null; then bad "$UNIT habilitada no boot (deveria abrir só com s10-trabalho liga)"
    else ok "$UNIT só com s10-trabalho liga (não sobe no boot)"; fi
    if "$SYSTEMCTL" is-active --quiet "$UNIT"; then echo "info:   janela ABERTA agora"; else echo "info:   janela fechada"; fi
    return "$rc"
}

case "${1:-}" in
--check) check; exit $? ;;
--undo)
    "$SYSTEMCTL" stop "$UNIT" 2>/dev/null || true
    rm -f "$SBIN/s10-trabalho-adb" "$BIN/s10-adb" "$BIN/s10-run" "$BIN/s10-trabalho" "$UNITF" "$DEFAULTS" "$SUDOERS"
    "$SYSTEMCTL" daemon-reload || true
    if "$GETENT" group "$GROUP" > /dev/null; then
        "$GPASSWD" -d "$WORK" "$GROUP" > /dev/null 2>&1 || true
        "$GROUPDEL" "$GROUP" || true
    fi
    echo "removido: intermediário, comandos, sudoers e grupo $GROUP."
    exit 0 ;;
'') ;;
*) echo "uso: $0 [--check|--undo]" >&2; exit 2 ;;
esac

if [ -z "${S10_SKIP_TESTS:-}" ]; then
    python3 -I "$HERE/tests/test_s10_trabalho_adb.py" > /dev/null 2>&1 || { echo "testes do intermediário falharam; nada instalado"; exit 1; }
fi
work_uid=$("$GETENT" passwd "$WORK" | cut -d: -f3) || true
[ -n "$work_uid" ] || { echo "conta de trabalho '$WORK' não existe"; exit 2; }
"$GETENT" passwd "$PERSONAL" > /dev/null || { echo "conta pessoal '$PERSONAL' não existe"; exit 2; }

"$GETENT" group "$GROUP" > /dev/null || "$GROUPADD" --system "$GROUP"
"$GETENT" group "$GROUP" | cut -d: -f4 | tr ',' '\n' | grep -qx "$WORK" || "$USERMOD" -aG "$GROUP" "$WORK"

mkdir -p "$SBIN" "$BIN" "$(dirname "$UNITF")" "$(dirname "$DEFAULTS")" "$(dirname "$SUDOERS")"
install -m 0755 "$HERE/s10-trabalho-adb" "$SBIN/s10-trabalho-adb"
install -m 0755 "$HERE/s10-adb" "$BIN/s10-adb"
install -m 0755 "$HERE/s10-run" "$BIN/s10-run"
install -m 0755 "$HERE/s10-trabalho" "$BIN/s10-trabalho"
install -m 0644 "$HERE/s10-trabalho-adb.service" "$UNITF"
# phone ports never forwarded: adb tcpip, and the guardian's VNC and Termux sshd (read from its config)
guard_conf=$R/etc/default/cerberus-s10
vnc=$( (sed -n 's/^S10_VNC_PORT=//p' "$guard_conf" 2>/dev/null || true) | tr -dc '0-9')
ssh_port=$( (sed -n 's/^S10_SSH_PORT=//p' "$guard_conf" 2>/dev/null || true) | tr -dc '0-9')
deny_tcp="5555 ${vnc:-5900} ${ssh_port:-8022}"
keep_pkgs=$(grep -s '^S10_TRABALHO_PACOTES=' "$DEFAULTS" || true)   # the owner's package list survives reinstalls
{
    echo "# galaxy-s10 atheron/user-step-s10-trabalho.sh (reescrito a cada instalação)"
    echo "S10_TRABALHO_UIDS=$work_uid"
    echo "S10_TRABALHO_DENY_TCP=\"$deny_tcp\""
    echo "# opcional: prefixos dos pacotes do trabalho (clear/uninstall/force-stop/run-as/monkey só neles), ex.:"
    echo "# S10_TRABALHO_PACOTES=\"br.com.empresa\""
    [ -z "$keep_pkgs" ] || echo "$keep_pkgs"
} > "$DEFAULTS.tmp"
chmod 0644 "$DEFAULTS.tmp"
mv -f "$DEFAULTS.tmp" "$DEFAULTS"
# sudoers: validated before it goes live; a broken file would lock sudo for everyone
tmp=$(mktemp)
sudoers_text > "$tmp"
"$VISUDO" -cf "$tmp" > /dev/null || { rm -f "$tmp"; echo "sudoers gerado inválido; nada mudou em $SUDOERS"; exit 1; }
install -m 0440 "$tmp" "$SUDOERS"
rm -f "$tmp"
"$SYSTEMCTL" daemon-reload
echo "pronto. Janela FECHADA. Na conta $PERSONAL: s10-trabalho liga (8 h), s10-trabalho log."
echo "Na conta $WORK (login novo, por causa do grupo): s10-adb devices, s10-run flutter run."
