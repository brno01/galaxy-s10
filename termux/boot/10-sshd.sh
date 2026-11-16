#!/data/data/com.termux/files/usr/bin/sh
# Termux:Boot script: keep the CPU awake and start sshd (port 8022) at device boot.
termux-wake-lock
sshd
