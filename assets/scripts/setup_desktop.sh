#!/bin/bash
set -e

echo "[+] Updating apt and installing desktop packages..."
apt update
apt install -y xvfb x11-utils x11-xserver-utils openbox xfce4-session xfce4 xfce4-terminal libx11-dev libxtst-dev gcc make dbus-x11

echo "[+] Compiling input/touch server..."
gcc -O2 /data/ubuntu/root/touch_server.c -o /usr/local/bin/touch_server -lX11 -lXtst 2>/dev/null || \
gcc -O2 /tmp/touch_server.c -o /usr/local/bin/touch_server -lX11 -lXtst

cp /tmp/start_desktop /usr/local/bin/start_desktop 2>/dev/null || true
chmod +x /usr/local/bin/start_desktop
chmod +x /usr/local/bin/touch_server

echo "[✓] Setup completed successfully!"
