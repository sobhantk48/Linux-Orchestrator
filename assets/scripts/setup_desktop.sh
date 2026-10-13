#!/bin/bash
set -e

BUNDLE_PATH="/tmp/desktop_bundle.tar.gz"

echo "[+] Checking offline desktop bundle..."
if [ -f "$BUNDLE_PATH" ]; then
    echo "[+] Extracting pre-installed desktop bundle..."
    tar -xzf "$BUNDLE_PATH" -C /
    echo "[+] Desktop bundle extracted successfully."
else
    echo "[!] Desktop bundle not found in /tmp!"
fi

chmod +x /usr/local/bin/start_desktop 2>/dev/null || true
chmod +x /usr/local/bin/touch_server 2>/dev/null || true
chmod +x /usr/local/bin/frame_server 2>/dev/null || true

echo "[✓] Offline setup completed successfully!"
