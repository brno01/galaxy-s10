#!/bin/bash
# Tudo de uma vez, no Windows (terminal MSYS2 UCRT64 ou Git Bash): prepara o VS Code Remote-SSH para o S10.
#   1. cria ~/.ssh/s10-dev_ed25519 (se faltar)
#   2. root@atheron: reinstala o cerberus-s10 e roda atheron/user-step-s10-dev.sh (autoriza a chave pelo USB)
#   3. acrescenta `Host s10-dev` ao ~/.ssh/config (se faltar) e testa a conexão
# Uso: ssh root@atheron cat /home/claude/development/personal/galaxy-s10/windows/s10-dev.sh > /tmp/s10-dev.sh && bash /tmp/s10-dev.sh
#      bash /tmp/s10-dev.sh --reset-distro    (reinstala um Debian quebrado no S10; apaga o conteúdo dele)
# Idempotente: pode rodar de novo.
set -euo pipefail

REPO=/home/claude/development/personal/galaxy-s10
ATHERON=${S10_ATHERON:-root@atheron}
KEY=$HOME/.ssh/s10-dev_ed25519
RESET_ARG=""
[ "${1:-}" = --reset-distro ] && RESET_ARG=--reset-distro

mkdir -p "$HOME/.ssh"
if [ ! -f "$KEY" ]; then
    echo "== 1/3 criando a chave $KEY"
    ssh-keygen -q -t ed25519 -N '' -C wtg-s10-dev -f "$KEY"
else
    echo "== 1/3 chave $KEY já existe"
fi
PUB=$(head -n 1 "$KEY.pub")

echo "== 2/3 no atheron (root): reinstalar o serviço do S10 e autorizar a chave pelo USB (alguns minutos na 1ª vez)"
# os valores do site (IP do S10 na tailnet, usuário do Termux) vêm do arquivo local do checkout, fora do git
OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT
ssh -n "$ATHERON" "set -e
printf '%s\n' '$PUB' > /root/wtg-s10-dev.pub
cp -a $REPO/atheron/. /root/s10-atheron/
bash /root/s10-atheron/user-step-s10.sh
bash $REPO/atheron/user-step-s10-dev.sh $RESET_ARG /root/wtg-s10-dev.pub
sed -n 's/^\\(S10_TAILNET_IP\\|S10_TERMUX_USER\\)=/SITE:&/p' $REPO/nomad/s10.local.conf" | tee "$OUT"
S10_IP=$(sed -n 's/^SITE:S10_TAILNET_IP=//p' "$OUT" | tr -d '\r')
S10_USER=$(sed -n 's/^SITE:S10_TERMUX_USER=//p' "$OUT" | tr -d '\r')
[ -n "$S10_IP" ] && [ -n "$S10_USER" ] || { echo "não consegui ler o IP/usuário do S10 no atheron"; exit 1; }

echo "== 3/3 atalho s10-dev no ~/.ssh/config"
CFG=$HOME/.ssh/config
if grep -qx 'Host s10-dev' "$CFG" 2>/dev/null; then
    echo "já existe"
else
    cat >> "$CFG" <<EOF

Host s10-dev
    HostName $S10_IP
    HostKeyAlias [galaxy-s10]:8022
    Port 8022
    User $S10_USER
    IdentityFile ~/.ssh/s10-dev_ed25519
    IdentitiesOnly yes
    ConnectTimeout 8
    ServerAliveInterval 30
EOF
    echo "acrescentado em $CFG"
fi

echo "== teste"
ssh -n -o StrictHostKeyChecking=accept-new s10-dev 'echo "arquitetura: $(uname -m)"; echo "debian: $(cat /etc/debian_version)"; echo "usuário: $(id -un)"'
echo
echo "Pronto. No VS Code: Remote-SSH: Connect to Host... > s10-dev (se perguntar a plataforma, escolha Linux)."
