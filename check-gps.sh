#!/usr/bin/env bash
# check-gps.sh — end-to-end signal chain verification for mm-nmea-bridge + gpsd
# Usage: bash check-gps.sh

set -euo pipefail

PASS=0; FAIL=0

ok()   { echo "  ✅  $*"; PASS=$((PASS+1)); }
fail() { echo "  ❌  $*"; FAIL=$((FAIL+1)); }
hdr()  { echo; echo "━━━  $*  ━━━"; }

# ── 1. Services ────────────────────────────────────────────────────────────────
hdr "Services"
for svc in mm-nmea-bridge gpsd; do
    if systemctl is-active --quiet "$svc"; then
        ok "$svc is active"
    else
        fail "$svc is NOT active"
        systemctl status "$svc" --no-pager -l || true
    fi
done

if systemctl is-masked --quiet gpsd.socket 2>/dev/null; then
    fail "gpsd.socket is masked (run: sudo systemctl unmask gpsd.socket)"
else
    ok "gpsd.socket not masked"
fi

# ── 2. PTY symlink ─────────────────────────────────────────────────────────────
hdr "PTY symlink"
if [[ -L /run/nmea-bridge ]]; then
    TARGET=$(readlink /run/nmea-bridge)
    ok "/run/nmea-bridge → $TARGET"
    PERMS=$(stat -c '%A %U %G' "$TARGET" 2>/dev/null || echo "unknown")
    if [[ "$PERMS" == crw-rw----\ root\ dialout ]]; then
        ok "$TARGET permissions: $PERMS"
    else
        fail "$TARGET permissions: $PERMS (want crw-rw---- root dialout)"
    fi
else
    fail "/run/nmea-bridge symlink missing"
fi

# ── 3. Raw NMEA via gpsd ──────────────────────────────────────────────────────
hdr "Raw NMEA (via gpsd)"
NMEA=$(gpspipe -r -n 10 2>/dev/null | grep '^\$G' | head -3 || true)
if [[ -n "$NMEA" ]]; then
    FIRST=$(echo "$NMEA" | head -1)
    ok "NMEA flowing: $FIRST"
else
    fail "No NMEA sentences from gpsd in 10 messages"
fi

# ── 4. ModemManager location ───────────────────────────────────────────────────
hdr "ModemManager NMEA (auto-discovered modem)"
MODEM_IDX=$(mmcli -L 2>/dev/null \
    | grep -oP '/org/freedesktop/ModemManager1/Modem/\K[0-9]+' \
    | head -1 || true)
if [[ -z "$MODEM_IDX" ]]; then
    fail "No modem found via mmcli -L"
else
    MM_OUT=$(mmcli -m "$MODEM_IDX" --location-get 2>&1)
    if echo "$MM_OUT" | grep -q '\$GPRMC'; then
        RMC=$(echo "$MM_OUT" | grep '\$GPRMC' | head -1 | xargs)
        ok "Modem $MODEM_IDX has NMEA: $RMC"
    else
        fail "No NMEA from ModemManager modem $MODEM_IDX — is GPS enabled?"
        echo "$MM_OUT"
    fi
fi

# ── 5. gpsd device + fix ───────────────────────────────────────────────────────
hdr "gpsd — device and fix"
TPV=$(gpspipe -w -n 15 2>/dev/null | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        o = json.loads(line)
        if o.get('class') == 'DEVICES' and o.get('devices'):
            d = o['devices'][0]
            print('DEVICE', d.get('path','?'), d.get('driver','?'), d.get('activated','not activated'))
        if o.get('class') == 'TPV' and o.get('mode', 0) >= 2:
            print('TPV', o['mode'], o.get('lat','?'), o.get('lon','?'),
                  o.get('altMSL','?'), o.get('speed','?'), o.get('time','?'))
            break
    except: pass
" 2>/dev/null || true)

if echo "$TPV" | grep -q '^DEVICE'; then
    DEV=$(echo "$TPV" | grep '^DEVICE')
    ok "gpsd device: ${DEV#DEVICE }"
else
    fail "gpsd has no active device"
fi

if echo "$TPV" | grep -q '^TPV'; then
    read -r _ MODE LAT LON ALT SPD TIME <<< "$(echo "$TPV" | grep '^TPV')"
    MODESTR=$( [[ "$MODE" == "3" ]] && echo "3D" || echo "2D" )
    ok "Fix: $MODESTR  lat=$LAT  lon=$LON  alt=${ALT}m  speed=${SPD}m/s  $TIME"
else
    fail "No GPS fix from gpsd within 15 s"
fi

# ── 6. Recent errors ───────────────────────────────────────────────────────────
hdr "Recent errors (last 60 s)"
SINCE=$(date -d '60 seconds ago' '+%H:%M:%S' 2>/dev/null || date -v-60S '+%H:%M:%S')
ERRS=$(journalctl -u mm-nmea-bridge -u gpsd --since "$SINCE" --no-pager -q 2>/dev/null \
       | grep -iE 'error|fail|denied' || true)
if [[ -z "$ERRS" ]]; then
    ok "No errors in journal in the last 60 s"
else
    fail "Errors found in journal:"
    echo "$ERRS" | sed 's/^/      /'
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Passed: $PASS   Failed: $FAIL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[[ $FAIL -eq 0 ]]
