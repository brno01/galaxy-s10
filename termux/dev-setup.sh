#!/data/data/com.termux/files/usr/bin/sh
# Ambiente de desenvolvimento no S10 para o VS Code Remote-SSH (roda DENTRO do Termux; idempotente).
# Uso (do nomad, pelo sshd do Termux com a chave de sempre):
#   ssh s10-termux 'sh -s -- "<chave pública s10-dev>" [shell]' < termux/dev-setup.sh
# Com o arquivo no celular: sh dev-setup.sh "<chave pública>" [caminho do s10-dev-shell]
#
# O que faz:
#   1. instala o proot-distro e um Debian (S10_DEV_DISTRO, padrão debian) com git, curl, wget, procps e afins;
#   2. instala $PREFIX/bin/s10-dev-shell (o comando forçado da chave);
#   3. autoriza a chave no ~/.ssh/authorized_keys com `restrict,port-forwarding,pty,command="..."`: a sessão
#      dessa chave cai no Debian (root falso do proot), só com encaminhamento de porta e terminal.
# A chave de sempre (nomad_ed25519) continua no Termux puro: o `s10` (VNC, acordar-atheron) não muda.
# Não abre porta nova: o VS Code entra pela 8022 e encaminha para o servidor dele em 127.0.0.1.
set -eu

KEY=${1:-}
DISTRO=${S10_DEV_DISTRO:-debian}
SELF=$(dirname "$0")
SHELL_SRC=${2:-$SELF/s10-dev-shell}
WRAPPER="$PREFIX/bin/s10-dev-shell"
# Imagem OCI do Debian (proot-distro 5 instala de registries). Docker Hub recusa pulls anônimos do S10 com
# "Unauthorized" (limite por IP, termux/proot-distro#692); o espelho público da AWS das imagens oficiais não.
IMAGE=${S10_DEV_IMAGE:-public.ecr.aws/docker/library/debian:trixie}
FALLBACK_IMAGE=${S10_DEV_FALLBACK_IMAGE:-debian:trixie}
PKGS=${S10_DEV_PKGS:-"ca-certificates curl wget git procps tar gzip less openssh-client"}

case "$KEY" in
ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *) ;;
*) echo "uso: sh $0 \"<chave pública ssh-ed25519 ...>\" [s10-dev-shell]"; exit 1 ;;
esac
# só a linha da chave (tipo, base64, comentário): nada de opções vindas de fora
KEY=$(printf '%s\n' "$KEY" | head -n 1 | awk '{print $1, $2, $3}' | sed 's/ *$//')
KEY_BODY=$(printf '%s\n' "$KEY" | awk '{print $2}')
case "$KEY_BODY" in ''|*[!A-Za-z0-9+/=]*) echo "chave inválida"; exit 1 ;; esac

pkg install -y proot-distro < /dev/null

install_distro() {
    proot-distro install "$IMAGE" --name "$DISTRO" < /dev/null && return 0
    echo "a instalação a partir de $IMAGE falhou; tentando $FALLBACK_IMAGE"
    proot-distro install "$FALLBACK_IMAGE" --name "$DISTRO" < /dev/null
}

# instalado = o proot-distro consegue entrar (o diretório do rootfs mudou entre versões: não olhe o caminho).
# Só instala quando ele diz "not installed"; outro erro (instalação pela metade, trava de outra sessão) é mostrado
# e o script para: reinstalar apagaria o que houver no container.
if ! out=$(proot-distro login "$DISTRO" -- /bin/true < /dev/null 2>&1); then
    case "$out" in
    *"not installed"*) install_distro ;;
    *) if [ "${S10_DEV_RESET:-}" = 1 ]; then
        # remove + install: `reset` only works for containers installed from an OCI image (proot-distro 5)
        echo "o login no container '$DISTRO' falhou; S10_DEV_RESET=1: reinstalando do zero (remove + install)"
        printf '%s\n' "$out"
        proot-distro remove "$DISTRO" < /dev/null
        install_distro
        proot-distro login "$DISTRO" -- /bin/true < /dev/null || { echo "o login falhou de novo depois do reset"; exit 3; }
    else
        echo "o container '$DISTRO' existe, mas o login falhou:"
        printf '%s\n' "$out"
        echo "Se for instalação pela metade: rode de novo com S10_DEV_RESET=1 (apaga o conteúdo do container)."
        exit 3
    fi ;;
    esac
fi
proot-distro login "$DISTRO" -- /bin/sh -c \
    "export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y --no-install-recommends $PKGS" < /dev/null

# comando forçado (o arquivo vem ao lado deste script; via `sh -s` ele é gravado a partir do texto embutido)
mkdir -p "$PREFIX/bin"
if [ -f "$SHELL_SRC" ]; then
    cp "$SHELL_SRC" "$WRAPPER.tmp"
else
    cat > "$WRAPPER.tmp" <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
# Forced command of the s10-dev key (see termux/s10-dev-shell in the galaxy-s10 repository).
DISTRO=${S10_DEV_DISTRO:-debian}
if [ -n "${SSH_ORIGINAL_COMMAND:-}" ]; then
    exec proot-distro login "$DISTRO" -- /bin/bash -lc "$SSH_ORIGINAL_COMMAND"
fi
exec proot-distro login "$DISTRO"
EOF
fi
chmod 700 "$WRAPPER.tmp"
mv -f "$WRAPPER.tmp" "$WRAPPER"

# authorized_keys: troca qualquer linha da mesma chave (com ou sem opções) pela versão restrita
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
AK="$HOME/.ssh/authorized_keys"
touch "$AK"
grep -vF " $KEY_BODY" "$AK" > "$AK.tmp" || true
printf 'restrict,port-forwarding,pty,command="%s" %s\n' "$WRAPPER" "$KEY" >> "$AK.tmp"
chmod 600 "$AK.tmp"
mv -f "$AK.tmp" "$AK"

cat <<MSG

Pronto. Debian '$DISTRO' pronto; chave s10-dev autorizada com comando forçado $WRAPPER.
Teste no cliente:  ssh s10-dev 'uname -a; cat /etc/debian_version; id -un'   (espera root e a versão do Debian)
VS Code: Remote-SSH: Connect to Host... > s10-dev
MSG
