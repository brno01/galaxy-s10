#!/bin/bash
# Wake-on-LAN no cabo do atheron: o S10 (Termux, mesma LAN) manda o pacote mágico e liga/acorda a máquina.
# Uso (root no atheron): bash wol-atheron.sh [--check|--undo]
#   (sem args)  instala o ethtool se faltar, grava a regra udev (WoL "g" a cada vez que a placa aparece,
#               inclusive no boot) e liga agora. Idempotente.
#   --check     mostra o estado (Wake-on, regra, wakeup do dispositivo, modo de suspensão)
#   --undo      remove a regra e desliga o WoL
# Não mexe em /etc/network/interfaces (gerado pelo cerberus-ia/net). O WoL a partir de DESLIGADO depende do BIOS
# (Insyde do Acer A515-52G); a partir de SUSPENSO (deep/S3) costuma funcionar só com isto.
set -u

IFACE=${WOL_IFACE:-enp2s0f1}
# sobrescrevíveis só para os testes
SYSNET=${WOL_SYSNET:-/sys/class/net}
RULE=${WOL_RULE:-/etc/udev/rules.d/81-cerberus-wol.rules}
NONROOT=${WOL_ALLOW_NONROOT:-}

need_root() { [ "$(id -u)" -eq 0 ] || [ -n "$NONROOT" ] || { echo "rode como root"; exit 1; }; }

mac_of() { # lowercase MAC of the interface, or fail
    local m
    m=$(cat "$SYSNET/$1/address" 2>/dev/null) || return 1
    m=${m,,}
    [[ $m =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || return 1
    echo "$m"
}

wol_state() { ethtool "$IFACE" 2>/dev/null | sed -n 's/^[[:space:]]*Wake-on:[[:space:]]*//p'; }

rule_text() { # rule_text <mac>
    # 81-: after 80-net-setup-link, so $name is already the final name (enp2s0f1) when RUN executes
    printf '%s\n' \
        "# Wake-on-LAN (magic packet) no cabo: o S10 liga o atheron. Gerado por galaxy-s10/atheron/wol-atheron.sh" \
        "ACTION==\"add\", SUBSYSTEM==\"net\", ATTR{address}==\"$1\", RUN+=\"/usr/sbin/ethtool -s \$name wol g\""
}

check() {
    local mac st bad=0
    mac=$(mac_of "$IFACE") || { echo "✗ placa $IFACE não encontrada"; return 1; }
    echo "placa: $IFACE ($mac)"
    if ! command -v ethtool >/dev/null 2>&1; then
        echo "✗ ethtool não instalado"; bad=1
    else
        st=$(wol_state)
        case "$st" in
        *g*) echo "✓ Wake-on: $st (pacote mágico ligado)" ;;
        *) echo "✗ Wake-on: ${st:-?} (esperado g)"; bad=1 ;;
        esac
    fi
    if [ -f "$RULE" ] && grep -qF "ATTR{address}==\"$mac\"" "$RULE"; then
        echo "✓ regra udev $RULE"
    else
        echo "✗ regra udev ausente ou com outro MAC ($RULE)"; bad=1
    fi
    echo "wakeup do dispositivo: $(cat "$SYSNET/$IFACE/device/power/wakeup" 2>/dev/null || echo '?')"
    echo "suspensão: $(cat /sys/power/mem_sleep 2>/dev/null || echo '?')"
    echo "S10: acordar-atheron $mac"
    return "$bad"
}

case "${1:-}" in
--check) check; exit $? ;;
--undo)
    need_root
    rm -f "$RULE"
    [ -n "$NONROOT" ] || udevadm control --reload 2>/dev/null || true
    command -v ethtool >/dev/null 2>&1 && ethtool -s "$IFACE" wol d 2>/dev/null
    echo "WoL desligado e regra removida (o pacote ethtool fica instalado)."
    exit 0 ;;
'') ;;
*) echo "uso: $0 [--check|--undo]"; exit 2 ;;
esac

need_root
MAC=$(mac_of "$IFACE") || { echo "placa $IFACE não encontrada em $SYSNET (defina WOL_IFACE)"; exit 1; }
if ! command -v ethtool >/dev/null 2>&1; then
    [ -n "$NONROOT" ] && { echo "ethtool ausente"; exit 1; }
    DEBIAN_FRONTEND=noninteractive apt-get install -y ethtool || { echo "falha ao instalar o ethtool"; exit 1; }
fi
mkdir -p "$(dirname "$RULE")"
NEW=$(rule_text "$MAC")
if [ ! -f "$RULE" ] || [ "$(cat "$RULE")" != "$NEW" ]; then
    printf '%s\n' "$NEW" > "$RULE.tmp" && chmod 644 "$RULE.tmp" && mv -f "$RULE.tmp" "$RULE"
    echo "regra gravada: $RULE"
fi
[ -n "$NONROOT" ] || udevadm control --reload
ethtool -s "$IFACE" wol g || { echo "o driver recusou wol g em $IFACE"; exit 1; }
check
