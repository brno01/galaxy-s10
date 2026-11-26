# Sourced by the shell of a development account on the atheron (~/.config/dev/env.d/s10-adb.sh, from install-dev.sh):
# every adb client (the ~/.local/bin/adb guard, the Android SDK's adb, Flutter...) talks to the S10's adb server
# through the cerberus-s10 unix socket. Requires membership in the cerberus-s10 group (user-step-s10.sh --dev-user).
export ADB_SERVER_SOCKET=localfilesystem:/run/cerberus-s10/adb.sock
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
