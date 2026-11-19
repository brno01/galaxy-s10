# galaxy-s10

<!-- Gerado por dev-project em 2026-11-16. Mantenha curto (< 200 linhas): só o que o Claude não descobre sozinho lendo o código. -->

## Visão geral
- Área: personal
- O que é: um Galaxy S10 (Exynos, Android 12, tela quebrada) vira nó do homelab Cerberus: fica no USB do atheron 24/7 (adb = âncora de emergência), roda Termux (sshd 8022, só chave) e Tailscale; o nomad o controla por scrcpy através de túnel SSH até o adb do atheron.

## Stack
Python 3 só stdlib (atheron = Debian, python3.13), bash, sh do Termux. Sem gerenciador de pacotes. scrcpy 5.0.1 (Homebrew) e adb (`/usr/bin/adb`) no nomad.

## Comandos
| Ação | Comando |
|---|---|
| Testes do monitor | `python3 -I atheron/tests/test_cerberus_s10.py` |
| Testes do Termux | `bash termux/tests/test_termux.sh` |
| Testes do instalador | `bash atheron/tests/test_installer.sh` |
| Testes do wrapper `s10` | `bash nomad/tests/test_s10.sh` |
| Testes do Wake-on-LAN | `bash atheron/tests/test_wol.sh` |
| Lint | `shellcheck atheron/user-step-s10.sh atheron/wol-atheron.sh atheron/tests/test_wol.sh nomad/s10 nomad/tests/test_s10.sh termux/tests/test_termux.sh atheron/tests/test_installer.sh && shellcheck -s sh termux/bootstrap.sh termux/boot/*.sh termux/acordar-atheron` |
| Wake-on-LAN no atheron (root) | `/usr/local/sbin/cerberus-wol` (cópia de `atheron/wol-atheron.sh`; `--check`, `--undo`) |
| Instalar no atheron (USUÁRIO) | `bash atheron/user-step-s10.sh` (`--check`, `--undo`) |
| Bootstrap do Termux (USUÁRIO) | ver README.md, seção Termux |
| Instalar o wrapper (nomad) | `install -m755 nomad/s10 ~/.local/bin/s10; install -m644 nomad/s10.desktop ~/.local/share/applications/` |

## Estrutura
- `atheron/`: `cerberus-s10` (serviço Python), `cerberus-s10.service`, `51-cerberus-s10.rules`, `user-step-s10.sh`, `tests/` (+ `fixtures/` com saídas reais de dumpsys).
- `termux/`: `bootstrap.sh` (roda dentro do Termux), `boot/10-sshd.sh`, `boot/20-guardian.sh` (vigia do celular), `tests/`, `authorized_keys.example`.
- `nomad/`: `s10` (wrapper scrcpy), `s10.desktop`, `tests/test_s10.sh` (ssh/adb/scrcpy falsos no PATH).
- Wake-on-LAN: `atheron/wol-atheron.sh` (regra udev `81-cerberus-wol.rules`, não mexe em `/etc/network/interfaces`, que é gerado pelo cerberus-ia/net) + `termux/acordar-atheron` (pacote mágico por `socat`, dash sem `\x`) + `s10 acordar-atheron` (fala direto com o Termux, nunca via atheron). Automático no `20-guardian.sh`: Wi-Fi de casa caído → de volta dispara `acordar-atheron` se o atheron não responde (`~/.acordar-atheron.off` desliga). Não dá para simular a queda pelo adb: o `cerberus-s10` religa o Wi-Fi em ≤30 s, antes do ciclo de 60 s do vigia.

- Resumo público: `public_summary()` publica `/run/cerberus-s10-publico/resumo.json` (0644) por LISTA PERMITIDA (sem IP/porta/serial); nunca copie/filtre o `estado.json` (privado, 0640) para ele. O formato é contrato do painel do Kindle (`versao: 1`).
- Guardião: `cerberus-s10` repara o celular (read-then-write) e publica `caminhos` em estado.json; segredo do droidVNC-NG só via `LoadCredential` + stdin do `adb shell`, nunca argv/log. Drills em `docs/testes-de-falha.md`.

## Convenções
- Branch padrão: `master`. Trabalhe em branches de feature.
- Código e comentários em inglês; docs e mensagens ao usuário em pt-BR. Instaladores no estilo cerberus: "Passo do USUÁRIO", `--check`/`--undo`, backup `*.antes-s10` uma vez, testes antes de instalar, idempotente.
- Parsing do dumpsys é puro (testado com fixtures); IO fica atrás de `run` injetável.

## Cuidados
- O adb server do atheron fica SÓ no socket unix `/run/cerberus-s10/adb.sock` (0660); não pode existir listener TCP :5037. Nunca usar `adb -a`/`adb tcpip`. Verifique: `ss -ltn 'sport = :5037'` vazio. O nomad entra pelo usuário restrito `s10tunnel` (chave com `restrict,...,command=`).
- Serviço roda como usuário `cerberus-s10` (grupo `cerberus-s10`, sem plugdev) com regra udev só para 04e8:6860; a chave adb fica em `/var/lib/cerberus-s10/.android`.
- scrcpy: `--power-off-on-close` só liga o comportamento (sem `=false`); por isso o wrapper não o passa. Túnel: socket local `$XDG_RUNTIME_DIR/s10-adb.sock` + `--force-adb-forward` por 127.0.0.1:27183; áudio desligado nesse caminho. Segredos do VNC: `/etc/cerberus-s10/{vnc-access-key,vnc-password}` (0600, LoadCredential); nunca em argv/log. Sem chave: VNC fica desligado (o fallback por UI, sem senha, só com `S10_ALLOW_UNPROTECTED_VNC=1`); VNC exposto sem senha é derrubado. `s10tunnel` tem como shell o `cerberus-s10-estado` (Tailscale SSH ignora authorized_keys); permitopen de socket unix exige colchetes `[/caminho]:*`. Consentimento de MediaProjection nunca é tocado.
- Chaves públicas reais não entram no git (só `authorized_keys.example`).
- Validado no aparelho real em 16/11/2026 (três caminhos + drills de falha; tempos em `docs/testes-de-falha.md`). Ainda sem teste real: VNC pela intent com chave e senha (depende de `--vnc-key`).
