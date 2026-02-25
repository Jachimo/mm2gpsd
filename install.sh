#!/usr/bin/env bash
# install.sh — install mm-nmea-bridge and wire up gpsd on Ubuntu 24.04
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 1. Python deps ─────────────────────────────────────────────────────────────
echo "==> Checking Python dependencies…"
apt-get install -y --no-install-recommends \
    python3-dbus \
    python3-gi \
    gpsd \
    gpsd-clients

# ── 2. Install bridge service ──────────────────────────────────────────────────
echo "==> Installing mm-nmea-bridge.service…"
cp "${SCRIPT_DIR}/mm-nmea-bridge.service" /etc/systemd/system/
systemctl daemon-reload

# ── 3. Configure gpsd ─────────────────────────────────────────────────────────
GPSD_DEFAULT=/etc/default/gpsd
echo "==> Configuring ${GPSD_DEFAULT}…"

# Preserve any existing extra options; just set DEVICES and ensure -n is set
cat > "${GPSD_DEFAULT}" <<'EOF'
# Managed by mm-nmea-bridge install.sh
# The PTY symlink /run/nmea-bridge is created by mm-nmea-bridge.service
GPSD_OPTIONS="-n"
DEVICES=""
USBAUTO="false"
EOF

# ── 4. gpsd socket / service ordering drop-in ─────────────────────────────────
echo "==> Adding gpsd.service drop-in to wait for bridge…"
mkdir -p /etc/systemd/system/gpsd.service.d
cat > /etc/systemd/system/gpsd.service.d/wait-for-bridge.conf <<'EOF'
[Unit]
After=mm-nmea-bridge.service
Wants=mm-nmea-bridge.service
EOF

systemctl daemon-reload

# ── 5. Disable gpsd socket activation ────────────────────────────────────────
# gpsd.socket would let random clients trigger gpsd before the bridge creates
# /run/nmea-bridge.  Disabling (not masking) prevents auto-start at boot while
# still allowing gpsd.service to start gpsd.socket as a Requires= dependency
# when the bridge triggers it.
echo "==> Disabling gpsd.socket auto-start…"
systemctl unmask gpsd.socket 2>/dev/null || true
systemctl disable gpsd.socket

# ── 6. Enable and start ────────────────────────────────────────────────────────
echo "==> Enabling services…"
systemctl enable mm-nmea-bridge.service
systemctl enable gpsd.service

echo "==> Starting bridge…"
systemctl restart mm-nmea-bridge.service

echo ""
echo "Done.  Check status with:"
echo "  systemctl status mm-nmea-bridge gpsd"
echo "  journalctl -u mm-nmea-bridge -f"
echo "  gpsmon /run/nmea-bridge"
