# Galaxy S10 como nó do Cerberus

[![ci](https://github.com/brno01/galaxy-s10/actions/workflows/ci.yml/badge.svg)](https://github.com/brno01/galaxy-s10/actions/workflows/ci.yml)
[![security](https://github.com/brno01/galaxy-s10/actions/workflows/security.yml/badge.svg)](https://github.com/brno01/galaxy-s10/actions/workflows/security.yml)

Um Samsung Galaxy S10 (Exynos, Android 12 / One UI 4) com a tela quebrada vira um nó do homelab. Ele fica ligado na USB do **atheron** 24 h por dia, roda **Termux** (sshd na 8022, só chave) e o app **Tailscale**. Do **nomad** você o controla pelo scrcpy com baixa latência, através de um túnel SSH até o adb do atheron.

## Arquitetura

```
 nomad (Bazzite/KDE)                      atheron (Debian)                        Galaxy S10
 ┌───────────────────┐  ssh -CN s10tunnel ┌──────────────────────────┐  USB      ┌──────────────┐
 │ s10 (wrapper)     │ -L $XDG_RUNTIME_DIR│ adb server em socket unix │◀────────▶│ adbd         │
 │  └ scrcpy 5.0.1   │   /s10-adb.sock:   │ /run/cerberus-s10/adb.sock│  cabo    │ Termux sshd  │
 │ ADB_SERVER_SOCKET │   /run/cerberus-s10│  (0660 cerberus-s10)      │          │  :8022       │
 │ =localfilesystem: │   /adb.sock        │ cerberus-s10.service      │          │ Tailscale    │
 │   …/s10-adb.sock  │ -L 127.0.0.1:27183 │  └ estado.json (30 s)     │          │ droidVNC-NG  │
 └───────────────────┘   (vídeo)          └──────────────────────────┘          └──────────────┘
        └──────── ssh -p 8022 -L 127.0.0.1:5901:127.0.0.1:5900 (Tailscale, só chave) ───────┘
```

O adb do atheron **não tem listener TCP** (nem 5037): só o socket unix `/run/cerberus-s10/adb.sock` (0660, grupo `cerberus-s10`). O nomad entra com a chave restrita do usuário `s10tunnel` (ver "Segurança"). `/run/cerberus-s10` é 0750 (dono e grupo `cerberus-s10`) e a unit usa `UMask=0007` (o socket nunca nasce 0755); o `estado.json` fica nesse diretório com modo 0640, então só root, o serviço e o grupo (o `s10tunnel`) o leem; outros consumidores precisam entrar no grupo.

## Conteúdo

| Pasta | O que é |
|---|---|
| `atheron/` | `cerberus-s10` (monitor + guardião), unit systemd, regra udev, `user-step-s10.sh`, `user-step-s10-dev.sh` (VS Code pelo USB), testes |
| `termux/` | `bootstrap.sh`, `boot/10-sshd.sh`, `boot/20-guardian.sh`, `dev-setup.sh` + `s10-dev-shell` (VS Code), `authorized_keys.example`, testes |
| `docs/` | `testes-de-falha.md` (drills de recuperação) |
| `nomad/` | `s10` (wrapper com 3 caminhos e `status`), `s10.desktop`, testes |
| `windows/` | `s10-dev.sh` (VS Code no Debian do S10), `s10-apps.sh` + `s10-tela.ps1` (testar apps no S10 a partir do atheron: scrcpy e tela na aba), testes |
| `atheron/dev/` | conta de desenvolvimento no atheron: `adb` de proteção, ambiente, `s10-tela-web` (noVNC) e `install-dev.sh` |
| `atheron/s10-trabalho*`, `s10-adb`, `s10-run` | conta de trabalho: intermediário do adb com lista de permissões, janela de 8 h e instalador `user-step-s10-trabalho.sh` |

## Testes e CI

Nada disto toca em aparelho nem em serviço (os testes usam adb, ssh e scrcpy falsos). O workflow `ci` roda exatamente estes comandos em cada pull request e em cada push no `master`:

```
python3 -I atheron/tests/test_cerberus_s10.py
bash termux/tests/test_termux.sh
bash atheron/tests/test_installer.sh
bash nomad/tests/test_s10.sh
bash atheron/tests/test_wol.sh
shellcheck -S warning atheron/user-step-s10.sh atheron/wol-atheron.sh atheron/tests/test_wol.sh nomad/s10 nomad/tests/test_s10.sh termux/tests/test_termux.sh atheron/tests/test_installer.sh
shellcheck -S warning -s sh termux/bootstrap.sh termux/boot/*.sh termux/acordar-atheron
```

O workflow `security` procura segredos no histórico (gitleaks), dependências vulneráveis (osv-scanner), erros de código (semgrep) e problemas em scripts e workflows (shellcheck, actionlint, zizmor); roda em pull requests, no `master` e toda semana. O workflow `claude` responde a menções `@claude` em issues e pull requests, só para o dono do repositório. Os três usam Actions fixadas por SHA.

## Arquitetura redundante

Três caminhos **independentes** para a tela e o toque. Qualquer um sozinho basta; o `s10` sem argumentos tenta 1, depois 2, depois 3.

| # | Caminho | Depende de | Alcance | O que o guardião repara |
|---|---|---|---|---|
| 1 | **USB via atheron**: `s10 --usb` (scrcpy por túnel SSH até o adb do atheron) | atheron ligado e acessível por SSH, cabo, depuração USB, chave RSA do atheron | de qualquer lugar onde o nomad alcance o atheron (Tailscale) | tela sempre ligada ao carregar (`stay_on_while_plugged_in=7`); `adb reconnect` e reinício do server com backoff exponencial (30 s a 5 min) |
| 2 | **adb sem fio direto**: `s10 --sem-fio` (`adb connect` + scrcpy) | Wi-Fi do S10, "Depuração sem fio" ligada, pareamento prévio do nomad; LAN ou tailnet (a depuração sem fio escuta em todas as interfaces) | LAN, ou tailnet se o Tailscale estiver de pé | Wi-Fi ligado (`svc wifi enable`), `adb_wifi_enabled=1` (o Android a desliga em troca de rede) e publicação do IP e da porta TLS (muda a cada ativação) |
| 3 | **droidVNC-NG**: `s10 --vnc` (`ssh -L 5901:127.0.0.1:5900` ao sshd do Termux + krdc/vncviewer) | Tailscale + Termux sshd (8022) + droidVNC-NG; **não depende do atheron** | tailnet | Tailscale como VPN sempre ativa e app vivo; whitelist de Doze para Tailscale, Termux, Termux:Boot e droidVNC-NG; droidVNC-NG vivo (intent `ACTION_START`, interface `lo`); consentimento de MediaProjection (`appops PROJECT_MEDIA allow`); serviço de acessibilidade (entrada de toque); Shizuku vivo (`libshizuku.so` por USB); permissões de armazenamento do droidVNC-NG (`pm grant`); confirmação "Permitir a depuração por Wi-Fi nesta rede?" aceita sozinha por USB (uiautomator + `input tap`); sshd do Termux caído: abre o app Termux por `am start` (o `RUN_COMMAND` é recusado ao uid shell) e o gancho do `~/.bashrc` sobe o sshd e o vigia; sem a chave do VNC, aperta o botão COMEÇAR do próprio droidVNC-NG (`REPAIR vnc_start`, 3 min entre tentativas) |

O guardião é o `cerberus-s10` (usuário sem privilégios; tudo no celular passa por `adb shell`, uid `shell`). A cada `S10_INTERVAL` s (padrão 30) ele **lê** cada valor e **só escreve se houver desvio**, registrando `REPAIR <id>: <motivo>` no journald, sonda os três caminhos e publica `/run/cerberus-s10/estado.json`:

```json
"caminhos": {
  "usb": {"ok": true, "estado": "device"},
  "adb_sem_fio": {"ip": "192.0.2.20", "porta": 37215, "ok": true},
  "tailscale": {"ok": true, "ip": "100.64.0.10"},
  "ssh_termux": {"ok": true, "porta": 8022},
  "vnc": {"ok": true, "porta": 5900, "loopback": true}
}
```

`ok` do adb sem fio = TCP no ip:porta; Tailscale = `ping -c1 -W2 <ip da tailnet>` a partir do atheron (`S10_TS_PROBE=off` desliga); ssh = conexão TCP e banner `SSH-` em ip-tailnet:8022; VNC = porta 5900 escutando no celular (`ss -ltn` via adb; `null` sem USB). Transições `path X: up/down` entram no log uma vez, não a cada ciclo. Sem USB (`ausente`/`offline`/`unauthorized`) os caminhos 2 e 3 continuam sendo sondados e o IP/porta anteriores são mantidos.

Com o celular reiniciando, o **vigia do Termux** (`~/.termux/boot/20-guardian.sh`, a cada 60 s: sshd vivo, `termux-wake-lock`, log com rotação em `~/guardian.log`) mantém o caminho 3 sem o atheron.

### Notas de campo (testadas ao vivo)

- **Túnel do caminho 1**: um `ssh` como `s10tunnel` com `-L $XDG_RUNTIME_DIR/s10-adb.sock:/run/cerberus-s10/adb.sock` (socket unix do adb, `StreamLocalBindUnlink=yes`) e `-L 127.0.0.1:27183:127.0.0.1:27183` (vídeo), `ADB_SERVER_SOCKET=localfilesystem:$XDG_RUNTIME_DIR/s10-adb.sock` e `scrcpy --force-adb-forward`. O `s10` apaga o socket velho e espera o socket novo existir antes de chamar o adb (sem servidor ali o cliente adb subiria um servidor LOCAL nesse caminho).
- **Áudio** pelo túnel SSH derruba a sessão ("Demuxer 'audio'...", "Controller error"): o caminho USB usa `--no-audio`; `--audio` reativa. **Codec**: h264 por padrão (h265 com decodificação por software no nomad é mais lento; `S10_CODEC=h265` testa).
- **Depuração sem fio que se desliga sozinha**: no Wi-Fi da casa marque **"Sempre permitir nesta rede"** no diálogo de depuração sem fio. O guardião relê `adb_wifi_enabled` 3 s depois de religar e, se voltar a 0, registra `rede não confiável para depuração sem fio` (uma vez).
- **Porta TLS**: nesta versão do One UI `getprop service.adb.tls.port` vem vazio e o shell não enxerga o socket do adbd. O adbd escuta em **todas** as interfaces, então o `adb connect <ip-da-tailnet>:<porta>` funciona fora de casa; só a porta é aleatória (muda a cada ativação ou reinício). Quem a descobre é o **atheron**. O mDNS da LAN é invisível para ele (o firewall do host descarta o multicast 5353; não mexemos nisso), então a fonte **primária** é o logcat por USB: com a depuração sem fio ligada, o guardião lê `logcat -d -b all | grep -o 'Received tls port=[0-9]*' | tail -1` (o adbd registra a porta toda vez que liga; aceita 1024-65535) e confirma por TCP na tailnet (`ok_tailnet`). Se a linha saiu do buffer e nenhuma fonte conhece a porta, ele alterna `adb_wifi_enabled` 0, 2 s, 1, 3 s e relê (`REPAIR adb_wifi_port`, no máximo a cada 10 min; derruba uma sessão sem fio aberta, o que só acontece quando a porta é desconhecida). Reservas, nesta ordem: `getprop service.adb.tls.port`, `adb mdns services` e `avahi-browse -rpt _adb-tls-connect._tcp` (o instalador põe `avahi-utils` se faltar). O serviço é filtrado por `adb-<serial>-*` (`S10_MDNS_SERIAL`) e o guardião publica `caminhos.adb_sem_fio{ip_lan, porta, ip_tailnet, ok}` (`ok` = TCP na tailnet ou na LAN). O `s10 --sem-fio` lê isso pelo SSH, conecta na **tailnet primeiro**, depois na LAN, depois na última porta do cache `~/.cache/s10/`, e só então no mDNS local (em casa). O nomad já precisa estar pareado.
- **`s10 --desktop`**: antes do scrcpy liga `force_desktop_mode_on_external_displays=1` e `enable_freeform_support=1` por adb e abre `--new-display=1920x1080/160`. É o modo desktop do AOSP num display virtual; na primeira vez pode ser preciso reiniciar o celular. O Samsung DeX de verdade exige HDMI ou o app DeX do Windows.
- Padrões do nomad: chave `~/.ssh/nomad_ed25519` (usada se existir); usuário do Termux, serial preferido e IPs vêm da configuração local (ver "Valores do site"). O atheron **não** faz login no Termux (o guardião só sonda o banner do sshd), então a chave dele não entra no `authorized_keys` do celular; se ela já estiver lá, remova no Termux com `sh bootstrap.sh --remove-key <comentario>` (por exemplo `atheron-s10`).

### Segredo do droidVNC-NG (chave de acesso da interface de intents)

A chave fica em `/etc/cerberus-s10/vnc-access-key` (root, 0600) e a unit a entrega ao serviço sem root por `LoadCredential=` (`$CREDENTIALS_DIRECTORY/vnc-access-key`). O guardião a injeta no celular por **stdin do `adb shell`** (um script `am start-foreground-service ...`), então não aparece em `argv` nem em `/proc/<pid>/cmdline` do atheron, nem nos logs ou no `estado.json`. Limite: dentro do celular a chave aparece na linha de comando do `am` por um instante (só o uid `shell` enxerga). O servidor sobe com `EXTRA_INTERFACE=lo` (só loopback; o guardião avisa `non-loopback` se a porta aparecer em outra interface) e com **senha VNC** (8 caracteres aleatórios em `/etc/cerberus-s10/vnc-password`, entregue por `LoadCredential` e stdin, como a chave); além disso, só se chega nele pelo túnel SSH com chave. Se `lo` não for aceito por esta versão do app, o aviso aparece no log e o acesso continua restrito pela tailnet; ajuste `S10_VNC_IFACE`.

### Depois de cada reinício do celular

- O Android pergunta de novo "Permitir a depuração por Wi-Fi nesta rede?" e `adb_wifi_enabled` volta a 0 até alguém responder. O guardião relê o valor 3 s depois de religar; se reverteu **e** a janela em foco é exatamente `com.android.systemui/com.android.systemui.wifi.WifiDebuggingActivity`, faz `uiautomator dump`, acha `android:id/alwaysUse` (só toca se `checked="false"`) e `android:id/button1` ("Permitir"), toca os centros com `input tap`, apaga o dump e relê (log `REPAIR adb_wifi_confirm`). Nada é tocado se o foco ou algum dos dois ids não bater; no máximo uma vez a cada 2 min.
- O **Shizuku** (`moe.shizuku.privileged.api`) morre no reinício: se não há `shizuku_server`, o guardião roda `$d/lib/arm64/libshizuku.so` por USB (`REPAIR shizuku`, 2 min entre tentativas); `guardiao.shizuku.ok` no `estado.json`.
- O droidVNC-NG pode pedir `WriteStorageRequestActivity`: o guardião concede `READ/WRITE_EXTERNAL_STORAGE` com `pm grant` se `dumpsys package` mostrar `granted=false`.
- **IP da LAN muda** entre reinícios (DHCP: .249 → .243). O `s10` nunca fixa o IP da LAN: usa o publicado pelo atheron, mDNS e o IP da tailnet com a última porta. Recomendado: **reserva de DHCP** no roteador para o MAC Wi-Fi do S10. Como o Android randomiza o MAC por rede, fixe-o antes: Configurações > Conexões > Wi-Fi > (engrenagem da rede) > Avançado > **Tipo de endereço MAC > MAC do telefone**, e reserve esse MAC.

### Variáveis do guardião (`/etc/default/cerberus-s10`)

`S10_INTERVAL` (30), `S10_TAILNET_IP` (**obrigatório**: sem ele o serviço não sobe), `S10_HOME_SSID`, `S10_HOME_BSSID`, `S10_MDNS_SERIAL`, `S10_TS_PROBE` (`ping`|`off`), `S10_SSH_PORT` (8022), `S10_VNC_PORT` (5900), `S10_VNC_IFACE` (`lo`), `S10_REPAIR=0` (só observa e registra o desvio), `S10_COOLDOWN` (120 s entre tentativas de iniciar apps), `S10_WIFI_IFACE` (wlan0).

### Uma vez, com o S10 ainda utilizável

1. **Termux**: `sh bootstrap.sh <chaves.pub> [10-sshd.sh] [20-guardian.sh]` (instala o vigia, endurece o sshd e põe `allow-external-apps=false`). Só a chave pública do **nomad** vai no arquivo de chaves (uma por linha; reexecutar só acrescenta). A chave do nomad mantém acesso total (manutenção); opcionalmente adicione à mão uma segunda chave só para o túnel do VNC com `permitopen="127.0.0.1:5900",restrict,port-forwarding` (exemplo comentado em `termux/authorized_keys.example`). Para tirar uma chave: `sh bootstrap.sh --remove-key <comentario>`.
2. **Pareamento do adb sem fio** (o nomad precisa estar pareado; com a tela quebrada isso só é possível enquanto o toque ainda funciona, por exemplo via `s10 --usb`): Opções do desenvolvedor > Depuração sem fio > Parear com código; no nomad `adb pair <ip>:<porta>`.
3. **droidVNC-NG**: abra uma vez, defina a chave de acesso no painel e grave a mesma em `/etc/cerberus-s10/vnc-access-key` no atheron; depois `systemctl restart cerberus-s10`.
4. Comandos `adb shell` únicos: ver o relatório da entrega / o passo "Comandos únicos" abaixo.
5. Rode `docs/testes-de-falha.md`.

### Comandos únicos no celular (via USB, `adb -s <serial> shell`)

```
settings put global adb_allowed_connection_time 0            # não expira a autorização de depuração (7 dias)
dumpsys deviceidle whitelist +com.tailscale.ipn
dumpsys deviceidle whitelist +com.termux
dumpsys deviceidle whitelist +com.termux.boot
dumpsys deviceidle whitelist +net.christianbeier.droidvnc_ng
appops set net.christianbeier.droidvnc_ng PROJECT_MEDIA allow
settings put secure enabled_accessibility_services "$(settings get secure enabled_accessibility_services):net.christianbeier.droidvnc_ng/.InputService"
settings put secure accessibility_enabled 1
settings put secure always_on_vpn_app com.tailscale.ipn
settings put secure always_on_vpn_lockdown 0
settings put global stay_on_while_plugged_in 7
settings put global adb_wifi_enabled 1
for p in com.termux com.termux.boot net.christianbeier.droidvnc_ng com.tailscale.ipn; do appops set $p AUTO_REVOKE_PERMISSIONS_IF_UNUSED ignore; done
```

(O guardião refaz tudo isso sozinho a cada ciclo; rodar uma vez só garante o primeiro estado. Se o valor atual de `enabled_accessibility_services` for `null`, use apenas o serviço, sem o prefixo `null:`.)

## Guia: preparar o S10 (do zero)

Faça com o S10 ainda utilizável (espelhado por cabo/HDMI, ou com a tela quebrada por scrcpy depois do passo 4 se o toque ainda responder). Os nomes de menu são os da One UI 4.

1. **Desbloqueie** a tela (o dono não usa bloqueio de tela: veja "Sem bloqueio de tela: mitigação" em Segurança).
2. **Wi-Fi.** Configurações > Conexões > Wi-Fi: conecte na rede da casa. Toque na rede > Avançado > IP fixo (ou reserva de DHCP no roteador) ajuda.
3. **Libere o modo desenvolvedor.** Configurações > Sobre o telefone > Informações do software > toque **7 vezes** em **Número de compilação**. Aparece "Agora você é um desenvolvedor!" (pede o PIN de novo).
4. **Opções do desenvolvedor** (novo item no fim de Configurações):
   - **Depuração USB**: ligar. Ao plugar no atheron aparece "Permitir depuração USB?" com a impressão digital RSA: marque **Sempre permitir** e toque em Permitir.
   - **Depuração sem fio**: ligar (opcional, para o modo `--lan`). Toque no nome > **Parear dispositivo com código de pareamento**; anote IP:porta de pareamento e o código de 6 dígitos.
   - **Permanecer ativo**: ligar (a tela não apaga enquanto carrega).
   - **Atualizações automáticas do sistema**: desligar (evita reinício surpresa).
5. **Bateria.** Configurações > Cuidados com o dispositivo > Bateria > Mais configurações de bateria > **Proteção da bateria** > **Máximo 85%**. Um aparelho carregando 24/7 a 100% incha a bateria.
6. **Tailscale.** Instale o app, entre na tailnet e, nas configurações do app, deixe "Executar em segundo plano". Em Configurações > Aplicativos > Tailscale/Termux > Bateria: **Sem restrições**.
7. **Termux.** Instale **Termux** e **Termux:Boot** do F-Droid (a versão da Play Store é obsoleta). Abra o Termux:Boot uma vez.
8. **Pareamento sem fio (opcional, `--lan`).** No nomad: `adb pair <ip>:<porta-de-pareamento>` e digite o código; depois `adb connect <ip>:<porta-da-depuração-sem-fio>`.

### Termux (uma vez)

Sem teclado no S10, empurre os arquivos e rode pelo scrcpy (ou cole no Termux):

```
# no atheron (ou no nomad com o túnel): copia os arquivos
adb push termux/bootstrap.sh termux/boot/10-sshd.sh /sdcard/Download/
adb push termux/s10.local.conf /sdcard/Download/               # valores do site (modelo: termux/s10.conf.example)
adb push minhas-chaves.pub /sdcard/Download/s10-keys.pub     # formato: termux/authorized_keys.example

# dentro do Termux (via scrcpy)
termux-setup-storage          # aceite a permissão de arquivos
sh ~/storage/downloads/bootstrap.sh ~/storage/downloads/s10-keys.pub
```

O script instala `openssh termux-api termux-services`, fixa `Port 8022`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PermitRootLogin no`, acrescenta as chaves (0600, sem duplicar), cria `~/.termux/boot/10-sshd.sh` (`termux-wake-lock` + `sshd`) e reinicia o sshd. É idempotente. No fim imprime os comandos de verificação. Teste de fora: `ssh -p 8022 <usuario>@<ip-tailscale-do-s10>` (o usuário é o de `whoami` no Termux, tipo `u0_a345`).

## Instalar no atheron (passo do USUÁRIO)

```
scp -r atheron root@atheron:/root/s10-atheron      # ou git pull no atheron
ssh root@atheron 'bash /root/s10-atheron/user-step-s10.sh'
ssh root@atheron 'bash /root/s10-atheron/user-step-s10.sh --check'
```

O instalador roda os testes primeiro, valida a unit, instala `adb` só se faltar, cria o usuário de sistema `cerberus-s10` (dono do USB e do socket do adb; sem `plugdev`), o usuário do túnel `s10tunnel` (mesmo grupo), a regra udev só para `04e8:6860` (grupo `cerberus-s10`), gera a senha do VNC (8 caracteres aleatórios, `/etc/cerberus-s10/vnc-password`, 0600, nunca exibida) se faltar, instala a unit e faz `enable --now`. Faz cópia `*.antes-s10` uma vez. `--undo` remove tudo (mantém o usuário e a chave adb).

Na primeira conexão o S10 mostra o pedido de chave RSA do atheron (a chave do usuário `cerberus-s10`, em `/var/lib/cerberus-s10/.android`): marque **Sempre permitir**. Sem isso o estado fica `unauthorized`.

O serviço escreve `/run/cerberus-s10/estado.json` a cada 30 s (`S10_INTERVAL`):

```json
{"timestamp":"2026-11-16T12:00:00+00:00","conectado":true,"estado":"device","serial":"R58M...",
 "bateria":{"nivel":87,"temperatura_c":31.2,"status":"charging","plugado":["usb"],"saude":"good","tensao_mv":4123},
 "tela":"Awake","wifi":{"ligado":true,"conectado":true}}
```

`estado` é `device`, `unauthorized`, `offline` ou `ausente`. O guardião acrescenta `caminhos` e `guardiao` (últimos reparos). Avisos no journald (`journalctl -u cerberus-s10`): temperatura >= 45 °C, `unauthorized`/ausente (repete a cada hora) e bateria em 100% por mais de 24 h (proteção provavelmente desligada). Ajustes em `/etc/default/cerberus-s10` (`S10_SERIAL`, `S10_TEMP_MAX`, `S10_FULL_HOURS`).

**Resumo público** (`/run/cerberus-s10-publico/resumo.json`, 0644, diretório 0755 criado por `tmpfiles.d`): o `estado.json` é privado (IPs, portas, serial; o diretório dá acesso ao socket do adb). Para painéis rodando sem privilégio (por exemplo o do Kindle, como `nobody`), o serviço publica à parte um resumo montado campo a campo a partir de uma lista permitida, nunca copiando o estado completo:

```json
{"versao":1,"gerado_em":1763294400,
 "bateria":{"nivel":87,"status":"charging","temperatura_c":31.2,"saude":"good"},
 "caminhos":{"usb":true,"adb_sem_fio":false,"tailscale":true,"ssh_termux":true,"vnc":null},
 "avisos":["temperatura"]}
```

`bateria` é `null` sem celular; cada caminho é `true`/`false` ou `null` (desconhecido); `avisos` usa os códigos `temperatura` (>= `S10_TEMP_MAX`) e `carga_cheia` (100% por mais de `S10_FULL_HOURS`). Não há IP, porta, serial, SSID nem dados do guardião. O caminho padrão está no código (`S10_PUBLIC` só para testes); se a escrita falhar, só vai para o log e o `estado.json` segue.

Confirme que o adb não tem listener TCP (o `--check` do instalador também confere):

```
ss -ltn 'sport = :5037'     # deve sair VAZIO
ls -l /run/cerberus-s10/adb.sock    # srw-rw---- cerberus-s10 cerberus-s10
```

### Passos do dono, em ordem

```
# 1) no atheron (root): instala/atualiza tudo
bash user-step-s10.sh
# 2) chave de acesso do droidVNC-NG (app > "Chave de acesso da API de Intent"): colada com entrada oculta
bash user-step-s10.sh --vnc-key
# 3) autoriza a chave pública do nomad no usuário restrito do túnel (arquivo com a linha de ~/.ssh/nomad_ed25519.pub)
bash user-step-s10.sh --tunnel-key nomad.pub
# 4) no nomad: busca UMA vez a senha do VNC (ssh de manutenção; S10_ATHERON, padrão root@atheron)
s10 setup-vnc
# 5) no celular via Termux: sh bootstrap.sh <chaves.pub> ...   (sshd só na tailnet, só chave)
```

Enquanto o passo 2 não for feito, o guardião **não inicia o VNC** (registra uma vez "VNC desligado até rodar --vnc-key"). Se ele achar o droidVNC-NG escutando fora do loopback sem chave e senha configuradas, o derruba (`am force-stop`, `REPAIR vnc_exposed_stop`). O atalho de apertar o botão COMEÇAR do app (VNC sem senha) existe só como opt-in: `S10_ALLOW_UNPROTECTED_VNC=1`, também sujeito ao pin de assinatura; com chave configurada ele nunca é usado.

## Usar no nomad

```
install -m755 nomad/s10 ~/.local/bin/s10
install -D -m600 nomad/s10.local.conf ~/.config/s10/config      # valores do site (modelo: nomad/s10.conf.example)
install -m644 nomad/s10.desktop ~/.local/share/applications/
s10                 # automático (USB, depois sem fio, depois VNC); `s10 status` mostra cada caminho
s10 --usb | --sem-fio | --vnc   # força um caminho
s10 setup-vnc       # uma vez: baixa a senha do VNC para ~/.config/s10/vnc-password (0600)
s10                 # qualidade: 1440 px, 8 Mbps, 60 fps, h264
s10 --rapido        # 1024 px, 4 Mbps, h264: menor latência (o padrão também é h264 agora)
s10 --desktop       # display virtual 1920x1080/160 (estilo DeX)
s10 --lan           # direto pelo Wi-Fi, com adb local já conectado
s10 -- --record=s10.mkv    # argumentos extras vão ao scrcpy
```

Sempre: `--turn-screen-off --stay-awake`; áudio desligado no caminho USB (`--audio` liga). Variáveis: `S10_TUNNEL` (padrão `s10tunnel@atheron`: usuário restrito do túnel e do estado), `S10_ATHERON` (padrão `root@atheron`, só manutenção/`setup-vnc`; se definido sem `S10_TUNNEL`, também serve ao túnel), `S10_SERIAL`, `S10_PHONE` (galaxy-s10), `S10_TAILNET_IP`, `S10_TERMUX_USER` (usuário do Termux para o `--vnc`), `S10_VNC_LPORT` (5901). O caminho 2 pega IP/porta do `estado.json` do atheron, senão mDNS (`adb mdns services`/`avahi-browse`), senão o IP da tailnet com a última porta em `~/.cache/s10/estado.json`. O túnel segue a doc do scrcpy ("Remote ADB server"): `ssh -CN -L5038:localhost:5037 -R27183:localhost:27183`, com `ADB_SERVER_SOCKET=tcp:localhost:5038`; ao sair, o túnel é derrubado. Se o atheron não enxergar o S10 o script explica em português (cabo, `--check`, chave RSA).

## Desenvolver no S10 (VS Code Remote-SSH)

O servidor do VS Code não roda no Termux (libc bionic). Por isso o S10 ganha um Debian pelo `proot-distro`, e uma chave SSH só para isso entra direto nele:

```
VS Code (nomad) ── ssh s10-dev ──▶ sshd do Termux :8022 ── command= ──▶ s10-dev-shell ──▶ proot-distro login debian
                     └─ -D/-L (encaminhamento) ──▶ 127.0.0.1 do celular = servidor do VS Code dentro do Debian
```

- Sem porta nova e sem mudança na política da tailnet: tudo passa pela 8022.
- A chave `s10-dev_ed25519` fica no `authorized_keys` com `restrict,port-forwarding,pty,command="…/s10-dev-shell"`: só terminal e encaminhamento de porta, sem agent forwarding. A chave de sempre (`nomad_ed25519`) continua no Termux puro, e o `s10` não muda.
- Dentro do Debian você é root falso do proot (o dono real é o usuário do Termux). Sem `systemd`, sem módulos do kernel e sem montar nada; `apt install` funciona.
- Não dá para rodar um sshd *dentro* do proot: a separação de privilégios do OpenSSH faz `chroot`, que o proot recusa (testado em 24/11/2026).
- O Android 12 mata processos "fantasmas" (filhos de apps) acima de 32, e o VS Code abre muitos. O `cerberus-s10` agora mantém `device_config activity_manager max_phantom_processes` em `2147483647` e a sincronização desligada (`set_sync_disabled_for_tests persistent`), lendo antes e escrevendo só quando há desvio (reparo `phantom_procs`). Vale depois de reinstalar o serviço no atheron.
- O canal de execução fica aberto enquanto o servidor do VS Code vive, porque o proot espera todos os processos filhos. É esperado.

**Atalho (recomendado):** no Windows, terminal MSYS2 UCRT64 ou Git Bash, uma linha faz os passos 1 a 3 abaixo (idempotente; `--reset-distro` no fim reinstala um Debian quebrado):

```bash
ssh root@atheron cat <checkout-no-atheron>/windows/s10-dev.sh > /tmp/s10-dev.sh && bash /tmp/s10-dev.sh
```

O `windows/s10-dev.sh` cria a chave, roda o passo do atheron como root, lê o IP e o usuário do Termux do `nomad/s10.local.conf` do checkout (fora do git), acrescenta o `Host s10-dev` ao `~/.ssh/config` e testa. Na 1ª vez o download do Debian no S10 pode levar dezenas de minutos (o passo do atheron espera até 1 h).

O Debian vem do espelho público da AWS das imagens oficiais (`public.ecr.aws/docker/library/debian:trixie`, `S10_DEV_IMAGE`): o `proot-distro` 5 instala de registries OCI e o Docker Hub recusou os pulls anônimos do S10 com "Unauthorized" (termux/proot-distro#692). O Docker Hub fica como reserva (`S10_DEV_FALLBACK_IMAGE`).

**Passos do USUÁRIO, uma vez** (cliente: Windows 11 do `nomad-wtg`, terminal MSYS2 ou Git Bash):

1. No Windows, crie a chave e mande a parte pública para o atheron:
   ```bash
   ssh-keygen -t ed25519 -N '' -C wtg-s10-dev -f ~/.ssh/s10-dev_ed25519
   scp ~/.ssh/s10-dev_ed25519.pub root@atheron:/root/s10-dev.pub
   ```
2. No atheron, como root: reinstale o serviço (reparo `phantom_procs`) e autorize a chave pelo USB. O `atheron/user-step-s10-dev.sh` empurra os arquivos para `/sdcard/Download/s10-dev`, abre o Termux, digita um comando curto e espera o `dev-setup.sh` terminar (na 1ª vez baixa o Debian):
   ```bash
   ssh root@atheron 'cp -a /home/claude/development/personal/galaxy-s10/atheron/. /root/s10-atheron/ && bash /root/s10-atheron/user-step-s10.sh'
   ssh root@atheron 'bash /home/claude/development/personal/galaxy-s10/atheron/user-step-s10-dev.sh /root/s10-dev.pub'
   ```
   Não precisa de nenhuma chave já aceita pelo Termux. Com uma chave aceita, dá para rodar o `dev-setup.sh` direto: `ssh <termux> "sh -s -- '<chave pública>'" < termux/dev-setup.sh`.
3. No Windows, o apelido no `~/.ssh/config` (é o `C:\Users\<você>\.ssh\config` que o VS Code usa):
   ```
   Host s10-dev
       HostName <ip-tailscale-do-s10>
       HostKeyAlias [galaxy-s10]:8022
       Port 8022
       User <usuario-do-termux>
       IdentityFile ~/.ssh/s10-dev_ed25519
       IdentitiesOnly yes
       ConnectTimeout 8
       ServerAliveInterval 30
   ```
   Teste: `ssh s10-dev 'uname -m; cat /etc/debian_version; id -un'` (espera `aarch64`, a versão e `root`).
4. No VS Code: `"remote.SSH.remotePlatform": {"s10-dev": "linux"}` nas configurações e `Remote-SSH: Connect to Host...` → `s10-dev`.

Tirar o acesso: apague a linha da chave `wtg-s10-dev` no `~/.ssh/authorized_keys` do Termux (`sh bootstrap.sh --remove-key wtg-s10-dev`). Apagar o Debian: `proot-distro remove debian`.

## Testar apps no S10 a partir do atheron

Você desenvolve no atheron (VS Code Remote-SSH como `claude`) e roda o app no S10, que já está no USB do atheron. Não precisa parear nada: a conta de desenvolvimento usa o mesmo servidor adb do `cerberus-s10`, pelo socket unix.

```
VS Code (Windows) ── Remote-SSH :2222 ──▶ claude@atheron ── adb (guarda ~/.local/bin/adb) ──▶ /run/cerberus-s10/adb.sock ──▶ S10 (USB)
   Ctrl+Alt+Shift+S: aba ◀── 6080 encaminhada ── websockify + noVNC (127.0.0.1:6080) ── adb forward 15900 ──▶ droidVNC-NG (lo:5900, senha)
   Ctrl+Alt+S: scrcpy ◀── ssh -L 15037/27183 :2222 s10tunnel@atheron (só túnel) ──▶ mesmo servidor adb
```

- **adb no atheron:** `user-step-s10.sh --dev-user claude` (root) põe a conta no grupo `cerberus-s10` e copia a senha do VNC (0600). O `atheron/dev/install-dev.sh` (como a própria conta, sem root) instala o `adb` de proteção, que recusa `kill-server`, `tcpip`, `usb`, `-a`, `-L`, `server`/`nodaemon`, `disconnect` sem alvo e `forward --remove-all` (derrubariam o guardião ou abririam o celular para a rede). Ele também instala `ADB_SERVER_SOCKET` em `~/.config/dev/env.d/s10-adb.sh`, de modo que SDK, Flutter e Gradle usam o mesmo servidor. `adb devices`, `adb install`, `flutter run` funcionam direto.
- **Tela numa aba do VS Code:** serviço `systemd --user` `s10-tela-web` (noVNC 1.7.0 com sha256 conferido, websockify 0.13.0 por `uv tool`), só em `127.0.0.1:6080`. A senha do VNC vai no `#` da URL, que o navegador nunca manda ao servidor. A unit entra no grupo com `sg`, então funciona sem reiniciar o `systemd --user`. `s10-tela-web start|stop|status|url`.
- **Janela nativa (scrcpy):** `windows/s10-tela.ps1` sobe um ssh para o `s10tunnel` (usuário restrito: só túnel para o socket do adb e a 27183), roda o scrcpy com `ANDROID_ADB_SERVER_PORT=15037` e `--force-adb-forward`, e fecha o túnel junto. A porta 15037 não briga com um adb local do Windows (Android Studio).
- O grupo dá à conta (e aos agentes que rodam nela) controle total do S10 pelo adb e leitura do `estado.json`. O `adb` de proteção evita acidentes (uma IDE, um script, um reflexo), não um processo hostil: a conta sempre pode chamar `/usr/bin/adb` direto. A fronteira de verdade é o grupo no socket. Tirar: `user-step-s10.sh --dev-user-undo claude` e `install-dev.sh --undo`.
- A senha do VNC fica em texto puro no Windows (no `keybindings.json` do VS Code) e na cópia 0600 da conta no atheron. O VNC só escuta no loopback do celular, e chegar nele exige o adb do atheron ou o túnel restrito. Para não guardar a senha no Windows, troque o `args` da tecla por `http://localhost:6080/vnc.html#autoconnect=1&resize=scale`: aí o noVNC pede a senha (`cat ~/.config/s10/vnc-password` no atheron).
- A cópia da senha é escrita pela própria conta (`runuser`), com o conteúdo vindo do root por stdin: o root nunca grava num caminho que a conta controla.

**Passo do USUÁRIO, uma vez** (Windows, MSYS2 UCRT64 ou Git Bash; idempotente):

```bash
ssh root@atheron cat <checkout-no-atheron>/windows/s10-apps.sh > /tmp/s10-apps.sh && bash /tmp/s10-apps.sh
```

Ele cria a chave `s10-tela_ed25519` e, num ssh só como root, autoriza essa chave no `s10tunnel` (`--tunnel-key`), roda o `--dev-user claude` e o `install-dev.sh` como `claude`. No Windows, instala o scrcpy (winget) e o `%LOCALAPPDATA%\s10\s10-tela.ps1`, acrescenta os apelidos `s10-tela` e `atheron-claude` ao `~/.ssh/config` e cria o atalho "S10 tela" no menu Iniciar (Ctrl+Alt+S). No VS Code, acrescenta `remote.SSH.defaultForwardedPorts` (6080) e a tecla Ctrl+Alt+Shift+S. Os blocos dele nos JSON do VS Code ficam entre `// s10-begin` e `// s10-end` e são trocados a cada execução. Antes da primeira mudança ele guarda uma cópia `*.antes-s10`. Se o arquivo não começar com `{`/`[` numa linha só, ou se os marcadores estiverem desemparelhados, ele não mexe e avisa. Os apelidos SSH dele ficam num bloco `# s10-begin`/`# s10-end` do `~/.ssh/config`, refeito a cada execução; um `Host` com o mesmo nome escrito à mão fora do bloco é mantido.

## Conta de trabalho (clubpetro) testando apps no S10

A conta de trabalho do atheron é isolada de propósito (firewall do Cerberus, `net/user-step-clubpetro-firewall.sh`), porque o modelo de ameaça é "um agente hostil pode viver nela": sem LAN, sem tailnet e nunca o adb do `cerberus-s10`. Por isso ela **não** entra no grupo `cerberus-s10`. Ela fala com um intermediário, o `s10-trabalho-adb`: ele conversa no protocolo do servidor adb, deixa passar só o que um teste de app precisa, recusa o resto e registra tudo.

```
conta de trabalho ── s10-adb / s10-run ──▶ /run/s10-trabalho/adb.sock (grupo s10-trabalho) ──▶ s10-trabalho-adb ──▶ adb do cerberus-s10 ──▶ S10
                                                                                  (decide cada pedido, journal)
```

- **Passa:** `devices`, `install`/`uninstall`, `logcat` (só leitura: sem `-f`, `-c`, `-G`...), `am start|force-stop|kill|broadcast`, `pm list|path|install|uninstall|clear|dump`, `cmd package|activity` com as mesmas regras, `getprop`, `dumpsys` de `package`/`meminfo`/`gfxinfo`/`cpuinfo`/`activity`/`window`/`display`..., `settings get`, `run-as` do app de trabalho, `monkey -p <app> [-v] [--throttle N] <eventos>`, `forward` de portas locais `tcp:0` ou 30000-65535 para portas do celular, `push`/`pull` só de arquivos comuns em `/data/local/tmp`, depuração (`jdwp`), `screencap`/`screenrecord` em `/data/local/tmp`.
- **É recusado:**
  - no servidor: `host:connect`/`pair`/`mdns` (o servidor adb roda fora do firewall e conectaria onde mandassem), `kill-server`, `killforward-all`, serial com `:` (use o serial do USB);
  - no aparelho: `tcpip`, `usb`, `root`, `reboot`, `remount`, `dev:` (arquivos do aparelho), `reverse`, shell interativo;
  - comandos: qualquer um fora da lista ou com sintaxe de shell (`;`, `|`, `$()`, crases, globs, redirecionamento fora de `/data/local/tmp`), `input`, `monkey --port`/`-f`, `am instrument` (um APK de instrumentação roda comandos como o shell), `pm grant`/`revoke` (daria permissões de sistema a um app), `settings put`;
  - pacotes: qualquer coisa que cite Termux, Tailscale, droidVNC-NG ou Shizuku, e `clear`/`uninstall`/`force-stop`/`kill`/`run-as` em pacotes do sistema (`android`, `com.android.*`, `com.samsung.*`, `com.google.*`...). Com `S10_TRABALHO_PACOTES="br.com.empresa"` em `/etc/default/s10-trabalho`, só os pacotes com esses prefixos;
  - portas: `forward` para o adb por rede (5555), o VNC e o sshd do Termux (as portas vêm da configuração do guardião);
  - arquivos: links simbólicos e outros tipos especiais em `push` (o modo é lido como o `adbd` lê: octal, hexadecimal ou decimal).
- **Limites:** até 32 conexões por conta, `TasksMax=64`, `MemoryMax=256M`. A unit não enxerga a chave adb do guardião nem os segredos do VNC (`InaccessiblePaths`).
- **Janela de tempo:** o intermediário não sobe no boot. Na conta pessoal: `s10-trabalho liga` (abre por 8 h; rodar de novo reinicia as 8 h), `s10-trabalho desliga`, `s10-trabalho status`, `s10-trabalho log` (decisões OK/RECUSADO). Do Windows: `ssh atheron-claude s10-trabalho liga`. A conta de trabalho não consegue abrir a janela.
- **Unit endurecida:** roda como `cerberus-s10`, só com sockets unix (`RestrictAddressFamilies=AF_UNIX`, `IPAddressDeny=any`) e sem reiniciar sozinha (se cair, a janela fecha).
- **Na conta de trabalho:** `s10-adb devices`, `s10-adb install app.apk`, `s10-run flutter run`, `s10-run ./gradlew installDebug`. Só esses dois comandos usam o intermediário. O adb próprio da conta (o servidor dela em outra porta) continua como estava.
- **Tela:** na janela do VS Code de trabalho, use o scrcpy do Windows (Ctrl+Alt+S), que é você mesmo no Windows. A aba noVNC fica só na conta pessoal: ela daria toque livre no celular, por fora do intermediário.

**Risco que sobra (leia antes de ligar):** um APK instalado é um programa de verdade no S10. Com internet, ele alcança a LAN de casa, e um `forward` permitido dá à conta de trabalho um caminho até ele. Testar app exige instalar app, então o intermediário não fecha isso. Ele reduz e registra; o modelo "agente hostil na conta de trabalho" não vale para o S10 enquanto a janela estiver aberta. O que fecharia de vez é a rede: o S10 numa rede isolada do roteador (rede de convidados ou isolamento de clientes). Isso quebra o Wake-on-LAN do atheron e o adb sem fio pela LAN, que fazem parte deste projeto; fica como opção, não aplicada. O firewall da conta de trabalho é uma foto das portas do loopback no momento em que é aplicado: aplicá-lo de novo com a janela aberta pode bloquear um `forward` ativo.

Outros limites conhecidos:
- `screencap`, `screenrecord`, `uiautomator dump` e `framebuffer` leem o que estiver na tela do S10.
- `jdwp` só alcança apps depuráveis num aparelho de produção (Termux e Tailscale de loja não são); num build `userdebug` ou com root alcançaria todos.
- Um `forward` sem `norebind` numa porta 30000+ pode tomar um encaminhamento da conta pessoal na mesma porta.
- Sem `am instrument`, testes instrumentados do Android ficam só na conta pessoal.

**Passo do USUÁRIO:** `bash /tmp/s10-apps.sh --trabalho` (o mesmo comando da seção anterior, com a opção), ou direto no atheron, como root: `bash atheron/user-step-s10-trabalho.sh` (`--check`, `--undo`).

## Ligar o atheron pelo S10 (Wake-on-LAN)

O S10 fica na mesma LAN do atheron (o Wi-Fi de casa) e tem tailnet própria, então continua alcançável com o atheron
parado. `s10 acordar-atheron` (nomad) entra por SSH direto no Termux (nunca pelo atheron), roda `acordar-atheron`
(pacote mágico por `socat`, 3 rodadas para o broadcast da LAN e `255.255.255.255`, portas 9 e 7) e espera a porta 22
do atheron na tailnet (`S10_WAKE_WAIT`, padrão 180 s; `S10_ATHERON_ADDR`, o IP do atheron na tailnet, sem padrão).

```
# atheron (root), uma vez: ethtool + regra udev 81-cerberus-wol.rules (WoL "g" no enp2s0f1 a cada boot/hotplug)
ssh root@atheron 'cat > /usr/local/sbin/cerberus-wol && chmod 755 /usr/local/sbin/cerberus-wol && cerberus-wol' < atheron/wol-atheron.sh
ssh root@atheron cerberus-wol --check          # --undo desfaz
# Termux: o bootstrap.sh já instala socat e o acordar-atheron; à mão:
ssh -p 8022 <usuario-do-termux>@galaxy-s10 'cat > $PREFIX/bin/acordar-atheron && chmod 700 $PREFIX/bin/acordar-atheron' < termux/acordar-atheron
# nomad
s10 acordar-atheron
```

Só funciona pelo cabo (`enp2s0f1`, com o MAC dele em `ATHERON_MAC`); o `/etc/network/interfaces` é gerado pelo cerberus-ia/net,
por isso o WoL fica numa regra udev e não lá. Validado em 17/11/2026: os 12 pacotes chegam no cabo como broadcast
(captura AF_PACKET) e, **a partir da suspensão (deep/S3)**, o atheron voltou 5 s depois do pacote (`suspend entry`
22:23:23, `exit` 22:23:50; alarme RTC de segurança em +5 min). Em 18/11/2026, **a partir de desligado (S5,
`systemctl poweroff`)**: o boot anterior terminou 00:00:54, o pacote saiu ~00:01:27 e o boot novo começou 00:01:48;
`s10 acordar-atheron` levou 42 s até a porta 22 responder (alarme RTC em +6 min, então foi o WoL). Isso apesar de
o `/proc/acpi/wakeup` declarar só S4 para a `RP09` (porta da placa). O BIOS (Insyde V1.16) trava no `_` ao entrar
com F2, então não há como conferir a opção por lá; não precisa.

**Automático na volta da energia.** O vigia do Termux (`20-guardian.sh`, a cada 60 s) guarda se o `wlan0` tem IP
da LAN de casa (prefixo `GUARDIAN_WAKE_SUBNET`) em `~/.guardian-wifi`. Na transição caído → conectado (o AP voltou, logo a energia
voltou), se o atheron não responde ao ping (`GUARDIAN_ATHERON_IPS`: cabo e Wi-Fi), roda `acordar-atheron` a cada 30 s, até 10 vezes,
e para quando ele responde. Pacote para máquina ligada não faz nada, então repetir é inofensivo. O reinício do vigia
não dispara (o estado fica em arquivo). Log em `~/guardian.log` (`auto-wake: ...`, `home Wi-Fi lost/back`).
Desligar antes de uma manutenção com o atheron desligado de propósito: `touch ~/.acordar-atheron.off` no Termux
(apagar o arquivo religa). Variáveis `GUARDIAN_WAKE_*`, `GUARDIAN_ATHERON_IPS` (ver "Valores do site" abaixo).

Limites: só depois de um desligamento **limpo** pelo Linux (é o driver r8169 que deixa a placa armada; o
`cerberus-power-guard` desliga assim na falta de energia). Desligado à força (botão segurado) ou com a bateria
esgotada, o WoL provavelmente não arma: aí só o botão. O automático também depende de o S10 sobreviver à queda: com
o atheron desligado a USB pode parar de alimentá-lo, e o wake lock gasta a bateria; se o S10 apagar, nada dispara.

## Recuperação

| Sintoma | O que fazer |
|---|---|
| `s10` diz que o atheron não enxerga o S10 | `ssh root@atheron 'bash /root/s10-atheron/user-step-s10.sh --check'`; confira cabo/porta; `sudo -u cerberus-s10 -H env ADB_SERVER_SOCKET=localfilesystem:/run/cerberus-s10/adb.sock adb devices -l` |
| Estado `unauthorized` | aceite a chave RSA no S10 (scrcpy) ou, com a tela morta, revogue/recrie: apague `/var/lib/cerberus-s10/.android` e reinicie o serviço (vai pedir de novo) |
| Estado `offline` | `systemctl restart cerberus-s10`; religue o cabo |
| SSH 8022 não responde | pelo atheron (âncora): `s10`/scrcpy, abra o Termux e rode `sshd`; confira Termux:Boot e a bateria "sem restrições" |
| Tailscale caiu | abra o app pelo scrcpy; mantenha "Executar em segundo plano" |
| Aparelho travado | `adb -s <serial> reboot` a partir do atheron |
| Adb server preso | `systemctl restart cerberus-s10` (mata o adb filho) |

## Segurança

- **adb sem TCP.** O server do atheron usa só `/run/cerberus-s10/adb.sock` (0660, grupo `cerberus-s10`); não existe listener em :5037 (nunca `adb -a`/`tcpip`). O instalador `--check` falha se aparecer um.
- **Usuário do túnel `s10tunnel`.** Sem senha. Cada chave do nomad entra em `/home/s10tunnel/.ssh/authorized_keys` assim:
  `restrict,port-forwarding,permitlisten="127.0.0.1:1",permitopen="127.0.0.1:27183",permitopen="[/run/cerberus-s10/adb.sock]:*",command="/usr/local/sbin/cerberus-s10-estado" <chave>`.
  Semântica (lida no código do OpenSSH 9.2, `auth-options.c`/`channels.c`): `restrict` desliga tudo; `port-forwarding` religa o encaminhamento (TCP e streamlocal usam o mesmo flag); o `permitopen` vale também para caminhos de socket unix, mas **o caminho tem de vir entre colchetes** (`[/run/.../adb.sock]:*`): a forma sem colchetes é inválida (o sshd lê a porta depois do primeiro `/` e recusa a chave: "invalid permission port"). `permitlisten="none"` também não é válido (a porta tem de ser numérica ou `*`); o `127.0.0.1:1` (porta privilegiada) bloqueia os `-R`. O `command` é o único que roda (`cat estado.json`) e não vale com `ssh -N`. `--tunnel-key` reescreve linhas antigas (no formato sem colchetes) e o `--check` acusa se sobrar alguma. Para conferir no atheron depois de instalar: `sshd -ddd -p 2222` (outro terminal) e `ssh -p 2222 -i ~/.ssh/nomad_ed25519 s10tunnel@127.0.0.1`; um `bad key options` aparece no log do `sshd -ddd`.
  O instalador também grava o drop-in `/etc/ssh/sshd_config.d/50-s10tunnel.conf` (`Match User s10tunnel`: `AllowStreamLocalForwarding local`, `AllowTcpForwarding local`, `PermitTTY no`, `X11Forwarding no`, `AllowAgentForwarding no`), valida com `sshd -t` antes de recarregar (backup `*.antes-s10`, `--undo` desfaz).
  **Tailscale SSH**: a porta 22 da tailnet no atheron é servida pelo Tailscale SSH, que **ignora** `authorized_keys`, as opções acima e o drop-in. Por isso o shell do `s10tunnel` é o próprio `/usr/local/sbin/cerberus-s10-estado` (registrado em `/etc/shells`; `--undo` volta para `/bin/sh`): qualquer sessão só imprime o `estado.json`, e os túneis `-L` continuam funcionando. As restrições do `authorized_keys` e do drop-in valem para o OpenSSH (por exemplo no IP da LAN).
- **VNC com senha.** A senha de 8 caracteres (o VNC só usa 8) mora em `/etc/cerberus-s10/vnc-password` (root, 0600, repassada por `LoadCredential`) e a chave de intent em `vnc-access-key`; o guardião as injeta no celular por stdin do `adb shell` (nunca argv/log). No nomad a senha fica em `~/.config/s10/vnc-password` (0600): o tigervnc recebe um arquivo ofuscado (`vncpasswd -f`, 0600, apagado ao sair) e o krdc recebe a senha na área de transferência por 30 s (`wl-copy`, limpa depois). **Prefira o TigerVNC**: no caminho do krdc a senha passa pelo Klipper e pode ficar no histórico dele. Para instalar o `vncviewer`/`vncpasswd` no Bazzite: `brew install tiger-vnc` se a fórmula existir; senão o Flatpak do TigerVNC (`flatpak search tigervnc`) ou uma distrobox. Só documentado, não instalado por este repositório. O servidor escuta só em `lo` e o acesso é pelo túnel SSH do Termux.
- **Pins de assinatura.** Antes de iniciar o Shizuku ou enviar chave/senha ao droidVNC-NG, o guardião confere o resumo do certificado do pacote (`dumpsys package`) com `/var/lib/cerberus-s10/pins.json` (confiança no primeiro uso). Se mudar, recusa e avisa. O resumo é o `hashCode` que o Android expõe (32 bits), não um SHA-256: protege contra troca acidental e app falso comum, não contra um atacante que gere colisão.
- **Diálogos por UI.** O dump do `uiautomator` vai para `/data/local/tmp` (do uid shell, não `/sdcard`), é lido com limite de 512 KiB, recusa DTD/entidades e ids duplicados, e os nós têm de ser do pacote certo (`com.android.systemui` para o Wi-Fi, `net.christianbeier.droidvnc_ng` para o botão). O diálogo "Permitir a depuração por Wi-Fi nesta rede?" só é aceito se o SSID atual for **exatamente** `S10_HOME_SSID` (sem padrão; sem comparação por substring) **e** o BSSID for `S10_HOME_BSSID` (sem padrão), ambos lidos de `cmd wifi status`; o texto do diálogo, quando traz o nome da rede, precisa ter uma linha exatamente igual, e o foco é conferido de novo logo antes do toque. O consentimento de MediaProjection **nunca** é tocado (o `appops PROJECT_MEDIA allow` cobre).
- **Passphrase na chave do nomad.** Quem entra no socket do adb tem o shell do celular: proteja `~/.ssh/nomad_ed25519` com passphrase (`ssh-keygen -p -f ~/.ssh/nomad_ed25519`) e deixe o ssh-agent carregá-la. O `s10` usa essa chave em todo ssh (túnel USB, estado, `setup-vnc`, VNC) com `IdentitiesOnly=yes`; `S10_SSH_KEY` troca o caminho.
- **Chaves adb.** A chave do atheron mora em `/var/lib/cerberus-s10/.android` (0700). Quem a tiver controla o S10: não copie. Para revogar: Opções do desenvolvedor > Revogar autorizações de depuração USB.
- **sshd do Termux**: só chave (`AuthenticationMethods publickey`), sem root, `AllowUsers` só o usuário do Termux, `MaxAuthTries 2`, `LoginGraceTime 15`, escutando só no IP da tailnet (`ListenAddress`; o vigia do celular tenta de novo até o tun0 subir). `allow-external-apps=false`. Opcional: uma chave extra só para VNC com `permitopen="127.0.0.1:5900"` no `authorized_keys` do Termux.
- **Serviço sem root**, com `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `ProtectProc=invisible`, `ProcSubset=pid`, `MemoryDenyWriteExecute`, `SystemCallFilter=@system-service`, `DevicePolicy=closed` + só USB, `RuntimeDirectoryMode=0750`; regra udev só para `04e8:6860`, grupo `cerberus-s10` (sem `plugdev`).

### Sem bloqueio de tela: mitigação

O dono optou por **não ter bloqueio de tela** no S10 (a tela quebrada impede digitar o PIN). Isso significa que quem tiver o aparelho na mão o usa por inteiro, então o risco é reduzido em volta dele:

- **Sem contas nem segredos no celular**: nada de banco, e-mail, 2FA, gerenciador de senhas ou sessões logadas; só Termux, Tailscale, droidVNC-NG e Shizuku. Se algo sensível precisar existir, não deve ficar logado.
- **Find My Mobile / apagar remotamente**: mantenha a conta Samsung vinculada para localizar, travar e apagar o aparelho à distância se ele sumir.
- **Apps mínimos**: desinstale ou desative o resto; sem armazenamento com dados pessoais.
- **ACL do Tailscale (`tag:s10`, já aplicada)**: o S10 só alcança o DNS do Pi-hole (o IP do Pi-hole na tailnet, porta 53); os membros da tailnet o alcançam em qualquer porta. Um S10 comprometido não consegue andar pela rede interna.
- Criptografia de armazenamento continua ligada (padrão). Os segredos do VNC e a chave adb do atheron não ficam no celular.

## Usos sugeridos

1. **Vigia externo (watchdog) com push no ntfy**: um loop no Termux que pinga atheron/nomad/NAS e avisa por ntfy quando algo some, independente da rede do rack.
2. **Câmera de segurança**: app de câmera IP / `termux-camera-photo` (a câmera traseira funciona mesmo com a tela quebrada), via Tailscale.
3. **Cartão do Kindle**: o `estado.json` e a bateria como um cartão extra no painel e-ink do Kindle.
4. **Cópia fria do Syncthing**: nó Syncthing no Termux/app, só recebe; o armazenamento do S10 guarda uma cópia fora do servidor.
5. **Apps que só existem no celular**: banco, 2FA, WhatsApp web-less, controlados por `s10 --desktop`.

## Validação no aparelho real (16/11/2026)

Os três caminhos e o vigia foram testados no S10 de verdade, com o atheron. `s10 status` mostrou os três ✓ (USB, adb sem fio pela tailnet, VNC pelo túnel do Termux). Tempos de recuperação medidos (detalhes em `docs/testes-de-falha.md`): reinício do S10 — USB 33 s, Tailscale 44 s, sshd do Termux 115 s; Wi-Fi desligado 30 s; Tailscale encerrado 21 s; depuração sem fio desligada 15 s; droidVNC-NG encerrado 20 s; Termux encerrado 19 s.
Ainda sem teste real: o início do VNC pela intent (com chave e senha), que depende de o dono rodar `--vnc-key`.

## Valores do site (IPs, MAC, SSID, serial)

Nada disso fica no repositório. Cada parte lê de um arquivo **local, não versionado** (`.gitignore`), com um modelo fictício versionado ao lado:

| Parte | Modelo (versionado) | Arquivo real (local) | Onde é instalado |
|---|---|---|---|
| atheron | `atheron/s10.env.example` | `atheron/s10.local.env` | o instalador mescla em `/etc/default/cerberus-s10` (só as chaves do arquivo) |
| nomad | `nomad/s10.conf.example` | `nomad/s10.local.conf` | `install -D -m600 nomad/s10.local.conf ~/.config/s10/config` (ou `S10_CONFIG`) |
| celular | `termux/s10.conf.example` | `termux/s10.local.conf` | o `bootstrap.sh` grava em `~/.s10.conf` no celular, lido por `boot/20-guardian.sh` e `acordar-atheron` |

As variáveis de ambiente (`S10_*`, `GUARDIAN_*`) têm precedência sobre o arquivo. Sem configuração não há valor padrão real: o serviço do atheron recusa subir sem `S10_TAILNET_IP`, o `bootstrap.sh` exige `S10_TAILNET_IP`, o vigia do celular desliga a checagem de porta e o acordar automático, e o `acordar-atheron` pede o MAC.

## Licença

[MIT](LICENSE)
