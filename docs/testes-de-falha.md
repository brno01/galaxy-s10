# Testes de falha (drills)

Rode com o dono em casa (o S10 ainda alcançável por USB) e **uma falha por vez**. Cada teste diz como provocar, o que deve voltar sozinho e em quanto tempo. Os tempos assumem o ciclo padrão do guardião (30 s) e o laço do Termux (60 s). Comandos `adb` rodam como o usuário do guardião (`sudo -u cerberus-s10 -H env HOME=/var/lib/cerberus-s10 adb -s <serial> shell ...`) ou, do nomad, com `ADB_SERVER_SOCKET=tcp:localhost:5038` com o túnel do `s10 --usb` aberto. Acompanhe: `ssh root@atheron journalctl -fu cerberus-s10` e `s10 status`.

Antes de cada drill: `s10 status` com os 3 caminhos ✓ e `jq .caminhos /run/cerberus-s10/estado.json` tudo `ok: true`.

| # | Falha | Como provocar | Recuperação esperada | Tempo máx. |
|---|---|---|---|---|
| 1 | Wi-Fi desligado | `adb shell svc wifi disable` | Guardião: `REPAIR wifi`; depois Tailscale/ssh/adb sem fio voltam. Log `path tailscale: down` e depois `up`, uma vez cada | 30 s para religar + 30 s (reassociar/Tailscale) = 1 min; caminhos 2 e 3 em até 90 s |
| 2 | Tailscale morto | `adb shell am force-stop com.tailscale.ipn` | Guardião: `REPAIR tailscale_start` (am start do launcher). Sem isso o caminho 3 não existe | 30 s (+ cooldown de 120 s entre tentativas) e ~20 s para a VPN subir: 1 min típico, 3 min no pior caso |
| 3 | Depuração sem fio desligada | `adb shell settings put global adb_wifi_enabled 0` | `REPAIR adb_wifi`; `estado.json` publica a NOVA porta (`getprop service.adb.tls.port`), `s10 --sem-fio` a encontra pelo atheron | 30 s para religar, 60 s até a porta publicada e testada |
| 4 | adb server do atheron morto | `ssh root@atheron 'pkill -x adb'` | O próprio `start-server` do ciclo sobe de novo (no socket unix, `-L localfilesystem:/run/cerberus-s10/adb.sock`); se o S10 ficar `offline`: backoff `adb reconnect` 30/60/120/240/300 s e `kill-server`+`start-server` no máx. a cada 5 min | 30 s no caso comum; 5 min no pior |
| 5 | Reinício do celular (ver o drill medido abaixo) | `adb reboot` | Termux:Boot roda `10-sshd.sh` e `20-guardian.sh`; Tailscale (VPN sempre ativa) sobe; o atheron reaplica as configurações. **Exige PIN** se o aparelho tiver criptografia por arquivo e nunca foi desbloqueado desde o boot: a USB (path 1) funciona antes do PIN, o resto não | USB 1 min; Wi-Fi/Tailscale/ssh 2 a 3 min após o PIN; VNC 1 min depois |
| 6 | Reinício do atheron | `ssh root@atheron reboot` | systemd sobe `cerberus-s10`, o udev reconhece o S10 e o adb não pede autorização de novo (a chave fica em `/var/lib/cerberus-s10/.android`). Caminhos 2 e 3 não dependem do atheron e ficam ✓ durante todo o reboot | 3 a 5 min (boot) + 30 s do primeiro ciclo |
| 7 | droidVNC-NG morto | `adb shell am force-stop net.christianbeier.droidvnc_ng` | Com chave: `REPAIR vnc_start` (intent `ACTION_START` pelo stdin, sem a chave em argv). Sem chave: o guardião abre o app (`.MainActivity`), toca no botão `:id/toggle` só se disser COMEÇAR/START (até 2 rolagens; nunca toca em PARAR), aceita o consentimento de MediaProjection só se essa activity estiver em foco, volta ao HOME e relê :5900. `path vnc: up` | 30 s; 3 min no pior caso (cooldown de 120 s com chave, 180 s pela UI) |
| 8 | sshd do Termux morto | dentro do Termux, `pkill sshd`; ou `adb shell am force-stop com.termux` (mata também o vigia) | Vigia do Termux: `sshd down: restarting` em `~/guardian.log`. Se o app inteiro morreu: `REPAIR termux_start` (o atheron abre `com.termux/.app.TermuxActivity`, o gancho do `~/.bashrc` sobe sshd + wake lock + vigia, e o guardião volta ao HOME). O `RUN_COMMAND` é recusado ao uid shell | 60 s (vigia); 35 s + 5 s de espera no caso do app (cooldown de 180 s) |
| 9 | Cabo USB removido | tirar o cabo | `estado=ausente`, backoff de `adb reconnect`; caminhos 2 e 3 seguem. Ao recolocar, `path usb: up` | 30 s após recolocar |
| 10 | Mudança de rede (Wi-Fi novo/DHCP) | trocar o IP no roteador ou reiniciar o AP | A depuração sem fio costuma desligar sozinha: drill 3; o IP novo é republicado | 1 a 2 min |

## Drill de reinício do celular (medido ao vivo)

Gatilho: `adb -s <serial> reboot`. Sem bloqueio de tela. Tempos medidos desde o comando:

| Marco | Tempo |
|---|---|
| USB volta (`estado=device` no atheron, caminho 1) | 33 s |
| Tailscale volta (ping na tailnet ok) | 44 s |
| sshd do Termux volta (Termux:Boot, caminho 3) | 115 s |

Esperado depois, sem tocar no aparelho: em até 1 ou 2 ciclos do guardião (30 s) `REPAIR adb_wifi` seguido de `REPAIR adb_wifi_confirm` (diálogo "Permitir a depuração por Wi-Fi nesta rede?"), `REPAIR shizuku` e, se o droidVNC-NG pedir, `REPAIR grant_*_EXTERNAL_STORAGE` e `REPAIR vnc_start`. O IP da LAN pode mudar (ex.: .249 para .243): `s10 --sem-fio` o acha por mDNS ou pelo estado do atheron. Aprovação: os três caminhos ✓ em `s10 status` em até 5 min.

## Critério de aprovação

- Depois de cada drill, os 3 caminhos voltam ✓ em `s10 status` dentro do tempo máximo.
- O log tem **uma** linha `REPAIR ...` por reparo e **uma** linha `path X: down` / `path X: up` por transição, nunca uma por ciclo.
- `journalctl -u cerberus-s10 | grep -c "$(cat /etc/cerberus-s10/vnc-access-key)"` retorna 0 (como root); `ps aux | grep -c "$(cat /etc/cerberus-s10/vnc-access-key)"` no atheron também 0.
- `ss -ltn 'sport = :5037'` continua vazio (o adb usa só o socket unix).
- Caminho 2 (`s10 --sem-fio`) e 3 (`s10 --vnc`) abrem uma sessão de verdade, com toque: clique e arraste.

## Drills de falha (medidos ao vivo em 16/11/2026)

Script: quebra cada item pelo adb USB do atheron e mede até a sonda voltar (vigia com ciclo de 30 s).

| Falha provocada | Comando | Sonda | Recuperou em |
|---|---|---|---|
| Wi-Fi desligado | `svc wifi disable` | `tailscale ping` | 30 s |
| Tailscale encerrado | `am force-stop com.tailscale.ipn` | `tailscale ping` | 21 s |
| Depuração sem fio desligada | `settings put global adb_wifi_enabled 0` | `adb_wifi_enabled=1` | 15 s |
| droidVNC-NG encerrado | `am force-stop net.christianbeier.droidvnc_ng` | `:5900` em loopback | 20 s (pelo botão do app; com chave, pela intent) |
| Termux encerrado | `am force-stop com.termux` | ssh na 8022 | 19 s |

## Rodada final (16/11/2026, com adb por socket, VNC com senha e tag:s10)

| Falha | Recuperou em |
|---|---|
| Wi-Fi desligado | 21 s |
| Tailscale encerrado | 21 s |
| Depuração sem fio desligada | 14 s |
| droidVNC-NG encerrado | 25 s (pela intent, com senha) |
| Termux encerrado | 95 s |
| VPN reiniciada (sshd "vivo" sem porta) | 101 s (vigia do celular confere a porta) |
| Reinício completo | 97 s até os 3 caminhos ✓; VNC com senha logo depois |

Depois de cada reinício o Android pede de novo "Permitir a depuração por Wi-Fi nesta rede?"; o vigia aceita sozinho só com SSID e BSSID de casa. Duas pegadinhas vistas ao vivo: o diálogo mostra o SSID **entre aspas** e, logo após o boot, `mCurrentFocus` vem `null` enquanto o diálogo é o `mResumedActivity` — o vigia usa esse como reserva.
