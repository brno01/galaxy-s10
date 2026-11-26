#!/bin/bash
# Tests for windows/s10-apps.sh (fake ssh, cmd.exe and powershell.exe; temp HOME, APPDATA and LOCALAPPDATA).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
APPS=$HERE/../s10-apps.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home" "$T/appdata" "$T/local"
export CALLS=$T/calls
fail=0 n=0
ok() { n=$((n + 1)); if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=$((fail + 1)); fi; }

PS1B64=$(base64 -w0 "$HERE/../s10-tela.ps1")
FAKE_PW=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12)   # random per run: no credential-looking literal in git
URL="http://localhost:6080/vnc.html#autoconnect=1&resize=scale&reconnect=1&show_dot=1&$(printf 'pass%s' word)=$FAKE_PW"
# fake ssh: the root step prints progress + SITE lines and saves the remote script; s10-tela prints the S10 state
cat > "$T/bin/ssh" <<EOF
#!/bin/bash
echo "ssh \$*" >> "\$CALLS"
for a; do last=\$a; done
case "\$last" in
"set -e"*) printf '%s\n' "\$last" > "$T/remote.sh"
    echo "progresso do atheron"
    echo "SITE:ATHERON=192.0.2.10"
    echo "SITE:URL=$URL"
    echo "SITE:PS1=$PS1B64" ;;
*) case "\$*" in *s10-tela*) echo '{"conectado":true,"estado":"device"}' ;; esac ;;
esac
EOF
# shellcheck disable=SC2016  # literal $CALLS / $1 in the fakes
printf '#!/bin/sh\necho "cmd $*" >> "$CALLS"\ncase "$2" in "where scrcpy") [ -n "${HAS_SCRCPY:-}" ] ;; esac\n' > "$T/bin/cmd"
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "powershell $*" >> "$CALLS"\n' > "$T/bin/powershell"
chmod +x "$T"/bin/*
export S10_WINCMD=$T/bin/cmd S10_POWERSHELL=$T/bin/powershell APPDATA=$T/appdata LOCALAPPDATA=$T/local
CU=$T/appdata/Code/User
run() { : > "$CALLS"; HOME=$T/home PATH="$T/bin:$PATH" bash "$APPS" > "$T/out" 2>&1; }

# JSONC -> JSON (drop // comment lines and trailing commas) and parse it
valid_json() { python3 -I -c '
import json, re, sys
text = open(sys.argv[1]).read()
text = "\n".join(l for l in text.splitlines() if not l.strip().startswith("//"))
text = re.sub(r",(\s*[\]}])", r"\1", text)
json.loads(text)' "$1" 2>/dev/null; }
count() { grep -c "$1" "$2" 2>/dev/null || true; }

run; rc=$?
ok "fresh run exits 0" "[ $rc -eq 0 ]"
ok "creates the tunnel key" "[ -f '$T/home/.ssh/s10-tela_ed25519' ] && grep -q 'wtg-s10-tela' '$T/home/.ssh/s10-tela_ed25519.pub'"
ok "root step: tunnel key, dev-user, install-dev as the dev user" "grep -q 'user-step-s10.sh --tunnel-key /root/wtg-s10-tela.pub' '$T/remote.sh' && grep -q 'user-step-s10.sh --dev-user claude' '$T/remote.sh' && grep -q 'asdev bash .*/atheron/dev/install-dev.sh' '$T/remote.sh' && grep -q 'runuser -u claude' '$T/remote.sh'"
ok "the public key goes to the atheron, the private one never" "grep -qF \"\$(cut -d' ' -f2 '$T/home/.ssh/s10-tela_ed25519.pub')\" '$T/remote.sh' && ! grep -q 'PRIVATE KEY' '$T/remote.sh'"
ok "progress shown, SITE lines and the password hidden" "grep -q 'progresso do atheron' '$T/out' && ! grep -q 'SITE:' '$T/out' && ! grep -q \"\$FAKE_PW\" '$T/out'"
ok "s10-tela.ps1 installed byte for byte" "cmp -s '$HERE/../s10-tela.ps1' '$T/local/s10/s10-tela.ps1'"
ok "scrcpy missing -> winget install" "grep -q 'cmd //c winget install --id Genymobile.scrcpy -e' '$CALLS'"
ok "ssh config: s10-tela (s10tunnel, 2222, own key) and atheron-claude" "grep -A5 '^Host s10-tela\$' '$T/home/.ssh/config' | grep -q 'User s10tunnel' && grep -A2 '^Host s10-tela\$' '$T/home/.ssh/config' | grep -q 'Port 2222' && grep -q 'IdentityFile ~/.ssh/s10-tela_ed25519' '$T/home/.ssh/config' && grep -A4 '^Host atheron-claude\$' '$T/home/.ssh/config' | grep -q 'User claude' && grep -q 'HostName 192.0.2.10' '$T/home/.ssh/config'"
ok "tunnel tested through the restricted account" "grep -q 'túnel s10-tela ok' '$T/out'"
ok "Start menu shortcut with Ctrl+Alt+S" "grep -q \"Hotkey = 'CTRL+ALT+S'\" '$CALLS' && grep -q 'S10 tela.lnk' '$CALLS'"
ok "settings.json: forwarded port 6080, valid JSONC" "grep -q '\"remote.SSH.defaultForwardedPorts\": \\[{\"name\": \"S10 tela\", \"localPort\": 6080, \"remotePort\": 6080}\\]' '$CU/settings.json' && valid_json '$CU/settings.json'"
ok "keybindings.json: Ctrl+Alt+Shift+S opens the tab URL, valid JSONC" "grep -qF '\"key\": \"ctrl+alt+shift+s\", \"command\": \"simpleBrowser.show\", \"args\": \"$URL\"' '$CU/keybindings.json' && valid_json '$CU/keybindings.json'"

# second run: idempotent (one block, hosts not duplicated, scrcpy present -> no winget)
HAS_SCRCPY=1 run; rc=$?
ok "rerun exits 0" "[ $rc -eq 0 ]"
ok "rerun: one block per file, hosts once" "[ \$(count s10-begin '$CU/keybindings.json') -eq 1 ] && [ \$(count s10-begin '$CU/settings.json') -eq 1 ] && [ \$(count '^Host s10-tela\$' '$T/home/.ssh/config') -eq 1 ] && [ \$(count '^Host atheron-claude\$' '$T/home/.ssh/config') -eq 1 ]"
ok "rerun: scrcpy present -> no winget" "! grep -q winget '$CALLS'"
ok "rerun: files still valid" "valid_json '$CU/settings.json' && valid_json '$CU/keybindings.json'"

# the user's own VS Code files: entries kept, our block added, one-time backup
printf '// Place your key bindings in this file to override the defaults\n[\n    {\n        "key": "ctrl+k",\n        "command": "foo"\n    }\n]\n' > "$CU/keybindings.json"
printf '{\n    "editor.fontSize": 14,\n    "files.autoSave": "afterDelay"\n}\n' > "$CU/settings.json"
rm -f "$CU"/*.antes-s10
HAS_SCRCPY=1 run
ok "existing keybindings kept + ours, valid" "grep -q '\"command\": \"foo\"' '$CU/keybindings.json' && grep -q 'ctrl+alt+shift+s' '$CU/keybindings.json' && valid_json '$CU/keybindings.json'"
ok "existing settings kept + ours, valid" "grep -q 'editor.fontSize' '$CU/settings.json' && grep -q 'defaultForwardedPorts' '$CU/settings.json' && valid_json '$CU/settings.json'"
ok "one-time backup of the user's files" "grep -q '\"command\": \"foo\"' '$CU/keybindings.json.antes-s10' && ! grep -q s10-begin '$CU/settings.json.antes-s10'"

# compact one-line files
printf '[]\n' > "$CU/keybindings.json"; printf '{}\n' > "$CU/settings.json"
HAS_SCRCPY=1 run
ok "compact [] and {} files: block inside, valid" "valid_json '$CU/keybindings.json' && valid_json '$CU/settings.json' && grep -q ctrl+alt+shift+s '$CU/keybindings.json'"

# a one-line settings object and a half-deleted block are left untouched, with a warning
printf '{"editor.fontSize": 14}\n' > "$CU/settings.json"
printf '[\n    // s10-begin\n    {"key": "x", "command": "y"},\n]\n' > "$CU/keybindings.json"
HAS_SCRCPY=1 run; rc=$?
ok "one-line settings: untouched + warning" "[ $rc -eq 0 ] && [ \"\$(cat '$CU/settings.json')\" = '{\"editor.fontSize\": 14}' ] && grep -q 'settings.json não começa' '$T/out'"
ok "unpaired markers: untouched + warning" "grep -q '\"key\": \"x\"' '$CU/keybindings.json' && ! grep -q ctrl+alt+shift+s '$CU/keybindings.json' && grep -q 'desemparelhados' '$T/out'"

# ssh config: a new atheron address replaces ours; a host written by hand is kept
sed -i 's/SITE:ATHERON=192.0.2.10/SITE:ATHERON=192.0.2.20/' "$T/bin/ssh"
printf 'Host atheron-claude\n    HostName meu.atheron\n    User claude\n' >> "$T/home/.ssh/config"
HAS_SCRCPY=1 run
ok "ssh config: our host follows the new address, once" "grep -A1 '^Host s10-tela\$' '$T/home/.ssh/config' | grep -q 'HostName 192.0.2.20' && [ \$(count '^Host s10-tela\$' '$T/home/.ssh/config') -eq 1 ] && ! grep -q 192.0.2.10 '$T/home/.ssh/config'"
ok "ssh config: hand-written atheron-claude kept, ours not added" "[ \$(count '^Host atheron-claude\$' '$T/home/.ssh/config') -eq 1 ] && grep -q 'HostName meu.atheron' '$T/home/.ssh/config'"

# the root step fails: its output is shown and nothing changes on Windows
cp "$CU/keybindings.json" "$T/kb.before"
sed -i 's/^    echo "progresso do atheron"/    echo "progresso do atheron"; echo "erro no atheron"; exit 1/' "$T/bin/ssh"
HAS_SCRCPY=1 run; rc=$?
ok "root step fails: exit 1, its output shown, Windows untouched" "[ $rc -ne 0 ] && grep -q 'erro no atheron' '$T/out' && grep -q 'nada foi mudado no Windows' '$T/out' && cmp -s '$T/kb.before' '$CU/keybindings.json'"
sed -i 's/; echo "erro no atheron"; exit 1//' "$T/bin/ssh"

# the user already forwards ports: their setting is left alone, with a hint
printf '{\n    "remote.SSH.defaultForwardedPorts": [{"localPort": 3000, "remotePort": 3000}]\n}\n' > "$CU/settings.json"
HAS_SCRCPY=1 run
ok "user's defaultForwardedPorts untouched, hint shown" "! grep -q s10-begin '$CU/settings.json' && grep -q 'acrescente à mão' '$T/out' && valid_json '$CU/settings.json'"
echo "--- $n checks, $fail failed"
[ "$fail" -eq 0 ]
