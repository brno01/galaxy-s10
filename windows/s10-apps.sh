#!/bin/bash
# Testar apps no S10 a partir do atheron, no Windows (terminal MSYS2 UCRT64 ou Git Bash). Idempotente.
#   1. chave ~/.ssh/s10-tela_ed25519 (túnel do scrcpy, usuário restrito s10tunnel)
#   2. root@atheron (um ssh só):
#        user-step-s10.sh --tunnel-key  (autoriza a chave no s10tunnel: só túnel para o adb e o vídeo)
#        user-step-s10.sh --dev-user claude  (claude no grupo cerberus-s10 + cópia da senha do VNC)
#        atheron/dev/install-dev.sh como claude  (adb de proteção, ambiente, tela na aba: noVNC em 127.0.0.1:6080)
#   3. Windows: scrcpy (winget), %LOCALAPPDATA%\s10\s10-tela.ps1, apelidos s10-tela e atheron-claude no ~/.ssh/config,
#      atalho "S10 tela" no menu Iniciar com Ctrl+Alt+S, e no VS Code: encaminhamento da 6080 no Remote-SSH e
#      Ctrl+Alt+Shift+S abrindo a tela numa aba.
#   --trabalho: também a conta de trabalho (clubpetro), pelo intermediário s10-trabalho-adb (sem entrar no grupo do
#      adb; janela de 8 h aberta com `ssh atheron-claude s10-trabalho liga`) e o apelido atheron-trabalho.
# Uso: ssh root@atheron cat /home/claude/development/personal/galaxy-s10/windows/s10-apps.sh > /tmp/s10-apps.sh && bash /tmp/s10-apps.sh [--trabalho]
set -euo pipefail

REPO=${S10_REPO:-/home/claude/development/personal/galaxy-s10}
ATHERON=${S10_ATHERON:-root@atheron}
DEV_USER=${S10_DEV_USER:-claude}
WORK_USER=${S10_WORK_USER:-clubpetro}
TRABALHO=0
case "${1:-}" in
--trabalho) TRABALHO=1 ;;
'') ;;
*) echo "uso: $0 [--trabalho]" >&2; exit 2 ;;
esac
WORK_STEP=":"
[ "$TRABALHO" -eq 0 ] || WORK_STEP="S10_WORK_USER=$WORK_USER S10_PERSONAL_USER=$DEV_USER bash $REPO/atheron/user-step-s10-trabalho.sh"
KEY=$HOME/.ssh/s10-tela_ed25519
CFG=$HOME/.ssh/config
WEB_PORT=6080
to_unix() { if command -v cygpath > /dev/null 2>&1; then cygpath -u "$1"; else printf '%s\n' "$1"; fi; }
to_win() { if command -v cygpath > /dev/null 2>&1; then cygpath -w "$1"; else printf '%s\n' "$1"; fi; }
WINCMD=${S10_WINCMD:-/c/Windows/System32/cmd.exe}
POWERSHELL=${S10_POWERSHELL:-/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe}
LOCAL_S10=$(to_unix "${LOCALAPPDATA:?LOCALAPPDATA não definido: rode no MSYS2/Git Bash do Windows}")/s10
CODE_USER=${S10_CODE_USER:-$(to_unix "${APPDATA:?APPDATA não definido}")/Code/User}
START_MENU=${S10_START_MENU:-$(to_unix "$APPDATA")/Microsoft/Windows/Start Menu/Programs}

mkdir -p "$HOME/.ssh"
if [ ! -f "$KEY" ]; then
    echo "== 1/4 criando a chave $KEY"
    ssh-keygen -q -t ed25519 -N '' -C wtg-s10-tela -f "$KEY"
else
    echo "== 1/4 chave $KEY já existe"
fi
PUB=$(head -n 1 "$KEY.pub")

echo "== 2/4 no atheron (root): túnel do scrcpy, adb do S10 para o $DEV_USER, tela na aba"
OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT
# SITE: lines carry data back (atheron address, tab URL with the VNC password, the .ps1) and are never printed
ssh -n "$ATHERON" "set -e
printf '%s\n' '$PUB' > /root/wtg-s10-tela.pub
bash $REPO/atheron/user-step-s10.sh --tunnel-key /root/wtg-s10-tela.pub
bash $REPO/atheron/user-step-s10.sh --dev-user $DEV_USER
dh=\$(getent passwd $DEV_USER | cut -d: -f6)
asdev() { runuser -u $DEV_USER -- env HOME=\"\$dh\" XDG_RUNTIME_DIR=/run/user/\$(id -u $DEV_USER) PATH=\"\$dh/.local/bin:/usr/local/bin:/usr/bin:/bin\" \"\$@\"; }
asdev bash $REPO/atheron/dev/install-dev.sh
$WORK_STEP
sed -n 's/^S10_ATHERON_ADDR=/SITE:ATHERON=/p' $REPO/nomad/s10.local.conf
printf 'SITE:URL=%s\n' \"\$(asdev s10-tela-web url)\"
printf 'SITE:PS1=%s\n' \"\$(base64 -w0 $REPO/windows/s10-tela.ps1)\"" > "$OUT" || {
    grep -v '^SITE:' "$OUT" || true
    echo "o passo no atheron falhou (saída acima); nada foi mudado no Windows. Corrija e rode de novo (é idempotente)."
    exit 1
}
grep -v '^SITE:' "$OUT" || true
site() { sed -n "s/^SITE:$1=//p" "$OUT" | head -n 1 | tr -d '\r'; }
ATHERON_ADDR=$(site ATHERON)
TELA_URL=$(site URL)
[ -n "$ATHERON_ADDR" ] && [ -n "$TELA_URL" ] || { echo "não consegui ler o endereço do atheron ou a URL da tela"; exit 1; }

echo "== 3/4 Windows: scrcpy, s10-tela e apelidos SSH"
mkdir -p "$LOCAL_S10"
site PS1 | base64 -d > "$LOCAL_S10/s10-tela.ps1.tmp"
[ -s "$LOCAL_S10/s10-tela.ps1.tmp" ] || { echo "s10-tela.ps1 veio vazio do atheron"; exit 1; }
mv -f "$LOCAL_S10/s10-tela.ps1.tmp" "$LOCAL_S10/s10-tela.ps1"
if "$WINCMD" //c "where scrcpy" > /dev/null 2>&1; then
    echo "scrcpy já instalado"
else
    "$WINCMD" //c "winget install --id Genymobile.scrcpy -e --accept-source-agreements --accept-package-agreements"
fi
# our Host entries live in a "# s10-begin ... # s10-end" block that is rebuilt on every run (a new atheron address is
# picked up); a Host with the same name written by hand outside the block wins and is left alone
touch "$CFG"
outside=$(awk '/^# s10-begin/ { s = 1; next } /^# s10-end/ { s = 0; next } !s' "$CFG")
hosts=""
add_host() { # add_host <name> <block>
    if printf '%s\n' "$outside" | grep -qx "Host $1"; then
        echo "$CFG: Host $1 já existe fora do bloco do s10-apps; mantido como está"
    else
        hosts="$hosts
$2
"
    fi
}
add_host s10-tela "Host s10-tela
    HostName $ATHERON_ADDR
    Port 2222
    User s10tunnel
    IdentityFile ~/.ssh/s10-tela_ed25519
    IdentitiesOnly yes
    ConnectTimeout 8"
add_host atheron-claude "Host atheron-claude
    HostName $ATHERON_ADDR
    Port 2222
    User $DEV_USER
    ServerAliveInterval 30"
if [ "$TRABALHO" -eq 1 ]; then
    add_host atheron-trabalho "Host atheron-trabalho
    HostName $ATHERON_ADDR
    Port 2222
    User $WORK_USER
    ServerAliveInterval 30"
fi
{
    printf '%s\n' "$outside"
    if [ -n "$hosts" ]; then
        printf '# s10-begin (galaxy-s10 windows/s10-apps.sh; refeito a cada execução)%s# s10-end\n' "$hosts"
    fi
} > "$CFG.tmp"
mv -f "$CFG.tmp" "$CFG"
echo "$CFG: apelidos s10-tela, atheron-claude$([ "$TRABALHO" -eq 0 ] || echo ' e atheron-trabalho')"
# the restricted account only prints the S10 state: a good end-to-end test of the key and the port
if ssh -n -o StrictHostKeyChecking=accept-new s10-tela 2>/dev/null | grep -q '"conectado"'; then
    echo "túnel s10-tela ok"
else
    echo "aviso: ssh s10-tela não respondeu com o estado do S10 (teste: ssh s10-tela)"
fi

echo "== 4/4 atalhos: menu Iniciar (Ctrl+Alt+S) e VS Code (Ctrl+Alt+Shift+S, porta $WEB_PORT)"
ps_quote() { printf '%s' "${1//\'/\'\'}"; }   # inside a PowerShell '...' string, ' is written ''
PS1_WIN=$(ps_quote "$(to_win "$LOCAL_S10/s10-tela.ps1")")
LNK_WIN=$(ps_quote "$(to_win "$START_MENU/S10 tela.lnk")")
"$POWERSHELL" -NoProfile -Command "
\$pw = (Get-Command pwsh -ErrorAction SilentlyContinue).Source; if (-not \$pw) { \$pw = 'powershell.exe' }
\$s = (New-Object -ComObject WScript.Shell).CreateShortcut('$LNK_WIN')
\$s.TargetPath = \$pw
\$s.Arguments = '-NoProfile -ExecutionPolicy Bypass -File \"$PS1_WIN\"'
\$s.Hotkey = 'CTRL+ALT+S'
\$s.Description = 'S10 pelo adb do atheron (scrcpy)'
\$s.Save()" && echo "atalho: $LNK_WIN (Ctrl+Alt+S)"

# JSONC files of VS Code: our entries live between marker comments and are replaced on every run
put_block() { # put_block <file> <opening char [ or {> <block text>; 1 = file left untouched (format not recognized)
    local f=$1 open=$2 block=$3 b e
    mkdir -p "$(dirname "$f")"
    [ -s "$f" ] || { if [ "$open" = '[' ]; then printf '[\n]\n'; else printf '{\n}\n'; fi; } > "$f"
    b=$(grep -c 's10-begin' "$f" || true); e=$(grep -c 's10-end' "$f" || true)
    if [ "$b" != "$e" ]; then
        echo "aviso: $f tem marcadores s10-begin/s10-end desemparelhados; não mexi (conserte à mão ou apague o bloco)"
        return 1
    fi
    # the first line that is not blank or a // comment must be the bare opening bracket (or a compact empty "[]"/"{}");
    # anything else (e.g. a whole object on one line) is left alone instead of risking invalid JSON
    BLOCK=$block OPEN=$open awk '
        BEGIN { open = ENVIRON["OPEN"]; block = ENVIRON["BLOCK"]; close_ch = (open == "[") ? "]" : "}" }
        /\/\/ s10-begin/ { skip = 1; next }
        /\/\/ s10-end/ { skip = 0; next }
        skip { next }
        {
            t = $0; gsub(/^[ \t]+|[ \t]+$/, "", t)
            if (!done && t != "" && substr(t, 1, 2) != "//") {
                if (t == open) { print; print block; done = 1; next }
                if (t == open close_ch) { print open; print block; print close_ch; done = 1; next }
                bad = 1; exit
            }
            print
        }
        END { if (bad || !done) exit 3 }
    ' "$f" > "$f.tmp" || {
        rm -f "$f.tmp"
        echo "aviso: $f não começa com '$open' numa linha só; não mexi (acrescente o bloco à mão, veja o README)"
        return 1
    }
    [ -e "$f.antes-s10" ] || cp -p "$f" "$f.antes-s10"   # one-time backup of the user's file
    mv -f "$f.tmp" "$f"
}
SETTINGS=$CODE_USER/settings.json
if awk '/\/\/ s10-begin/ { s = 1; next } /\/\/ s10-end/ { s = 0; next } !s' "$SETTINGS" 2>/dev/null | grep -q '"remote.SSH.defaultForwardedPorts"'; then
    echo "aviso: settings.json já tem remote.SSH.defaultForwardedPorts; acrescente à mão {\"name\": \"S10 tela\", \"localPort\": $WEB_PORT, \"remotePort\": $WEB_PORT}"
else
    put_block "$SETTINGS" '{' "    // s10-begin (galaxy-s10 windows/s10-apps.sh): tela do S10 na aba, porta do noVNC do atheron
    \"remote.SSH.defaultForwardedPorts\": [{\"name\": \"S10 tela\", \"localPort\": $WEB_PORT, \"remotePort\": $WEB_PORT}],
    // s10-end" && echo "VS Code: encaminhamento da $WEB_PORT em $SETTINGS"
fi
put_block "$CODE_USER/keybindings.json" '[' "    // s10-begin (galaxy-s10 windows/s10-apps.sh): tela do S10 numa aba (a senha do VNC vai no #, nunca ao servidor)
    { \"key\": \"ctrl+alt+shift+s\", \"command\": \"simpleBrowser.show\", \"args\": \"$TELA_URL\" },
    // s10-end" && echo "VS Code: Ctrl+Alt+Shift+S em $CODE_USER/keybindings.json"

echo
echo "Pronto."
echo "  VS Code: Remote-SSH: Connect to Host... > atheron-claude (adb do S10 já funciona no terminal: adb devices)"
echo "  Tela na aba: Ctrl+Alt+Shift+S (com a janela conectada ao atheron)"
echo "  Janela nativa: Ctrl+Alt+S, ou menu Iniciar > S10 tela"
if [ "$TRABALHO" -eq 1 ]; then
    echo "  Trabalho: abra a janela de 8 h com: ssh atheron-claude s10-trabalho liga"
    echo "    no VS Code conectado em atheron-trabalho: s10-adb devices, s10-run flutter run (a tela é o Ctrl+Alt+S)"
fi
