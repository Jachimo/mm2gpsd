# HOWTO: LTE Module GPS with ModemManager, gpsd, and OpenCPN on Ubuntu 24.04

## Hardware

- **Tablet:** Panasonic FZ-G1 (Toughpad)
- **LTE module:** Sierra Wireless EM7355 (internal, USB-attached via `cdc_mbim` / `qcserial`)
- **OS:** Ubuntu 24.04.4 LTS
- **Kernel:** 6.17.0-14-generic

The EM7355 is a combined LTE modem and GPS receiver. On this tablet it appears
as two USB serial ports and one MBIM control interface:

```
ports: cdc-wdm2 (mbim), ttyUSB2 (at), wwan0 (net)
```

ModemManager 1.23.4 claims the device automatically at boot. gpsd 3.25 is used
to present the GPS fix to applications. OpenCPN connects to gpsd out of the box
via `localhost:2947`.

---

## Overview

The challenge is that the GPS data lives inside ModemManager — accessible over
D-Bus — while gpsd expects to read from a serial-like device. The solution is a
small Python bridge (`mm-nmea-bridge.py`) that:

1. Enables GPS NMEA output on the modem via the ModemManager D-Bus API
2. Creates a **PTY** (pseudo-terminal) and symlinks its slave end to a fixed
   path (`/run/nmea-bridge`)
3. Polls ModemManager for NMEA sentences once per second and writes them to the
   PTY master
4. Starts gpsd and hands it the PTY slave path

```
ModemManager  ──(D-Bus)──►  mm-nmea-bridge  ──(PTY)──►  gpsd  ──(TCP 2947)──►  OpenCPN
```

---

## Prerequisites

```bash
sudo apt-get install -y python3-dbus python3-gi gpsd gpsd-clients
```

---

## The Bridge Script

Save as `/usr/local/bin/mm-nmea-bridge.py` (or in another location of your choice):

```python
#!/usr/bin/env python3
"""
Bridge ModemManager NMEA output to gpsd via a PTY.

Creates a PTY, symlinks the slave end to PTY_LINK, writes NMEA sentences
received from ModemManager's D-Bus Location interface to the master end.
gpsd (or any NMEA consumer) is pointed at PTY_LINK.

Usage:
    sudo python3 mm-nmea-bridge.py [modem-index]   (default: 13)
"""

import dbus
import dbus.mainloop.glib
from gi.repository import GLib
import grp
import os
import pty
import signal
import subprocess
import sys
import syslog
import time

MODEM_INDEX   = int(sys.argv[1]) if len(sys.argv) > 1 else 13
MODEM_PATH    = f"/org/freedesktop/ModemManager1/Modem/{MODEM_INDEX}"
MM_SERVICE    = "org.freedesktop.ModemManager1"
MM_LOC_IFACE  = "org.freedesktop.ModemManager1.Modem.Location"
PTY_LINK      = "/run/nmea-bridge"

# MM_MODEM_LOCATION_SOURCE_GPS_NMEA = 0x04  (1 << 2; 0x08 is CDMA_BS)
GPS_NMEA = dbus.UInt32(0x04)

master_fd = None

def log(msg):
    print(msg, flush=True)
    syslog.syslog(syslog.LOG_INFO, f"mm-nmea-bridge: {msg}")

def setup_pty():
    global master_fd
    master_fd, slave_fd = pty.openpty()
    slave_name = os.ttyname(slave_fd)
    os.close(slave_fd)
    dialout_gid = grp.getgrnam("dialout").gr_gid
    os.chown(slave_name, 0, dialout_gid)
    os.chmod(slave_name, 0o660)
    if os.path.islink(PTY_LINK) or os.path.exists(PTY_LINK):
        os.unlink(PTY_LINK)
    os.symlink(slave_name, PTY_LINK)
    log(f"PTY slave: {slave_name}  →  {PTY_LINK}")

def write_nmea(sentences):
    for line in sentences.strip().splitlines():
        line = line.strip()
        if line.startswith("$"):
            try:
                os.write(master_fd, (line + "\r\n").encode())
            except OSError as exc:
                log(f"PTY write error: {exc}")

def poll_nmea(props_iface):
    try:
        location = props_iface.Get(MM_LOC_IFACE, "Location")
        nmea = str(location.get(GPS_NMEA, ""))
        if nmea:
            write_nmea(nmea)
    except Exception as exc:
        log(f"Poll error: {exc}")
    return True

def on_properties_changed(iface, changed, _invalidated):
    if iface != MM_LOC_IFACE:
        return
    nmea = str(changed.get("Location", {}).get(GPS_NMEA, ""))
    if nmea:
        write_nmea(nmea)

def notify_gpsd():
    subprocess.run(["systemctl", "start", "--no-block", "gpsd.service"], check=False)
    for i in range(10):
        time.sleep(1)
        r = subprocess.run(["gpsdctl", "add", PTY_LINK], capture_output=True)
        if r.returncode == 0 or b"reached a running gpsd" in r.stdout:
            log(f"gpsdctl: added {PTY_LINK}")
            return
    log(f"Warning: could not add {PTY_LINK} to gpsd after 10 s")

def cleanup(location_iface, signum=None, _frame=None):
    log("Shutting down…")
    try:
        location_iface.Setup(dbus.UInt32(0), False)
    except Exception:
        pass
    if os.path.islink(PTY_LINK):
        os.unlink(PTY_LINK)
    if master_fd is not None:
        os.close(master_fd)
    sys.exit(0)

def main():
    setup_pty()
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    modem_obj      = bus.get_object(MM_SERVICE, MODEM_PATH)
    location_iface = dbus.Interface(modem_obj, MM_LOC_IFACE)
    props_iface    = dbus.Interface(modem_obj, dbus.PROPERTIES_IFACE)
    location_iface.Setup(GPS_NMEA, True)
    log(f"GPS NMEA enabled on modem {MODEM_INDEX}")
    GLib.timeout_add_seconds(1, lambda: poll_nmea(props_iface))
    bus.add_signal_receiver(on_properties_changed,
        signal_name="PropertiesChanged",
        dbus_interface="org.freedesktop.DBus.Properties",
        path=MODEM_PATH)
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda s, f: cleanup(location_iface, s, f))
    notify_gpsd()
    log(f"Forwarding NMEA → {PTY_LINK}  (Ctrl-C to stop)")
    GLib.MainLoop().run()

if __name__ == "__main__":
    if os.geteuid() != 0:
        sys.exit("Must run as root")
    main()
```

---

## Finding Your Modem Index

ModemManager assigns a numeric index to each modem. Find yours with:

```bash
mmcli -L
```

Example output:
```
/org/freedesktop/ModemManager1/Modem/13 [Sierra Wireless, Incorporated] EM7355
```

The index is the trailing number (`13` here). Pass it as an argument to the
script if it differs from the default of 13:

```bash
sudo python3 mm-nmea-bridge.py 15   # if your modem is index 15
```

The index can change after a reboot if other modems are present.

---

## The systemd Service

Save as `/etc/systemd/system/mm-nmea-bridge.service`:

```ini
[Unit]
Description=ModemManager → gpsd NMEA PTY bridge
After=ModemManager.service
Wants=ModemManager.service
Before=gpsd.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /home/<user>/Documents/GPS/mm-nmea-bridge.py 13
Restart=on-failure
RestartSec=5s
ExecStopPost=/bin/rm -f /run/nmea-bridge

[Install]
WantedBy=multi-user.target
```

---

## gpsd Configuration

Edit `/etc/default/gpsd`:

```bash
GPSD_OPTIONS="-n"
DEVICES=""
USBAUTO="false"
```

- `DEVICES=""` — leave empty; the bridge hands gpsd the device via `gpsdctl add`
  *after* the PTY exists, avoiding a startup race condition.
- `-n` — poll the GPS without waiting for a client to connect.
- `USBAUTO="false"` — prevent gpsd from auto-probing USB serial ports
  (ModemManager owns them).

---

## gpsd Socket Configuration

Add a drop-in to prevent gpsd from starting before the bridge:

```bash
sudo mkdir -p /etc/systemd/system/gpsd.service.d
sudo tee /etc/systemd/system/gpsd.service.d/wait-for-bridge.conf <<'EOF'
[Unit]
After=mm-nmea-bridge.service
Wants=mm-nmea-bridge.service
EOF
```

Disable (but do **not** mask) `gpsd.socket` to prevent socket activation from
racing the bridge at boot:

```bash
sudo systemctl disable gpsd.socket
```

---

## Enable and Start

```bash
sudo systemctl daemon-reload
sudo systemctl enable mm-nmea-bridge.service gpsd.service
sudo systemctl start mm-nmea-bridge.service
```

---

## Verifying It Works

### Check service status
```bash
systemctl status mm-nmea-bridge gpsd
```

Expected bridge log lines (no errors):
```
PTY slave: /dev/pts/N  →  /run/nmea-bridge
GPS NMEA enabled on modem 13
gpsdctl: added /run/nmea-bridge
Forwarding NMEA → /run/nmea-bridge
```

### Verify NMEA is flowing
```bash
gpspipe -r -n 10     # raw NMEA sentences from gpsd
```

### Verify gpsd has a fix
```bash
gpspipe -w -n 5      # JSON — look for "class":"TPV","mode":3
cgps -s              # live display
gpsmon               # detailed satellite + sentence view
```

### Check ModemManager directly
```bash
mmcli -m 13 --location-get
```

### Run the diagnostic script
```bash
bash ~/Documents/GPS/check-gps.sh
```

---

## OpenCPN

OpenCPN connects to gpsd automatically. In **Preferences → Connections**, add:

- **Type:** Network
- **Protocol:** TCP
- **Address:** `localhost`
- **Port:** `2947`
- **Input sentence filter:** leave blank

OpenCPN will receive NMEA sentences from gpsd and display the vessel position.

---

## Problems Encountered and Solutions

### 1. Wrong bitmask for GPS_NMEA source

**Symptom:**
```
DBusException: Cannot enable unsupported location sources: 'cdma-bs'
```

**Cause:** The `MM_MODEM_LOCATION_SOURCE_*` bitmask values are:

| Value  | Source       |
|--------|--------------|
| `0x01` | 3GPP LAC/CI  |
| `0x02` | GPS Raw      |
| `0x04` | **GPS NMEA** |
| `0x08` | CDMA Base Station |

The initial implementation used `0x08` (CDMA Base Station) instead of `0x04`
(GPS NMEA). The EM7355 supports CDMA but not CDMA base-station location, so it
rejected the `Setup()` call.

**Fix:** Use `GPS_NMEA = dbus.UInt32(0x04)`.

---

### 2. Race condition: gpsd opens the PTY before it exists

**Symptom:**
```
gpsd:ERROR: SER: stat(/run/nmea-bridge) failed: No such file or directory
gpsd:ERROR: initial GPS device /run/nmea-bridge open failed
```

**Cause:** When gpsd was listed in `DEVICES=` in `/etc/default/gpsd`, it tried
to open `/run/nmea-bridge` at startup — before the bridge script had run
`setup_pty()` to create the symlink. Similarly, using `ExecStartPost=` in the
bridge service unit to start gpsd fired the systemd job before Python had
executed a single line.

**Fix:**
- Set `DEVICES=""` in `/etc/default/gpsd` so gpsd starts with no pre-configured
  device.
- Start gpsd from *inside* the Python script, after `setup_pty()` creates the
  symlink, using `systemctl start --no-block gpsd.service`.
- Use `gpsdctl add /run/nmea-bridge` (with retry loop) to hand the device to
  gpsd once it is running.

---

### 3. systemctl deadlock in ExecStartPost

**Symptom:** `sudo systemctl restart mm-nmea-bridge.service` hung indefinitely.

**Cause:** `ExecStartPost=/bin/systemctl start gpsd.service` caused a deadlock:
systemd was busy managing the bridge unit's startup and could not respond to the
inner `systemctl start` call, which was waiting for systemd.

**Fix:** Use `--no-block`: `ExecStartPost=/bin/systemctl start --no-block gpsd.service`.
This submits the gpsd start job to systemd asynchronously and returns
immediately. This approach was later superseded by starting gpsd from within the
Python script instead.

---

### 4. PTY slave permissions prevent gpsd from opening the device

**Symptom:**
```
gpsd:ERROR: SER: device open of /run/nmea-bridge failed: Permission denied(13)
gpsd:ERROR: SER: read-only device open of /run/nmea-bridge failed: Permission denied(13)
```

**Diagnosis:**
```bash
ls -la $(readlink /run/nmea-bridge)   # crw-rw---- root tty
id gpsd                                # uid=122(gpsd) gid=20(dialout)
```

**Cause:** PTY slaves are created with `root:tty 660` permissions. gpsd drops
privileges to user `gpsd` (group `dialout`) and is not a member of the `tty`
group, so it cannot open the slave.

**Fix:** After `pty.openpty()`, immediately re-own the slave to `root:dialout`
and set mode `660`:

```python
dialout_gid = grp.getgrnam("dialout").gr_gid
os.chown(slave_name, 0, dialout_gid)
os.chmod(slave_name, 0o660)
```

---

### 5. gpsd socket masked, preventing gpsd.service from starting

**Symptom:**
```
Failed to start gpsd.service: Unit gpsd.socket is masked.
```

**Cause:** `gpsd.service` has `Requires=gpsd.socket` in its upstream unit file.
Masking `gpsd.socket` (to prevent socket activation racing the bridge) also
prevented `gpsd.service` from starting at all.

**Fix:** Do not mask `gpsd.socket` — only **disable** it:

```bash
sudo systemctl unmask gpsd.socket   # if previously masked
sudo systemctl disable gpsd.socket  # prevents auto-start at boot
```

Disabling prevents the socket from activating gpsd independently at boot, while
still allowing `gpsd.service` to start `gpsd.socket` as a dependency when the
bridge triggers it.

---

### 6. D-Bus PropertiesChanged signals not delivered to the bridge

**Symptom:** The bridge ran without errors, `mmcli --location-get` showed valid
NMEA, but nothing was written to the PTY (`cat /run/nmea-bridge` produced no
output).

**Diagnosis:**
```bash
dbus-monitor --system \
  "type='signal',interface='org.freedesktop.DBus.Properties',\
path='/org/freedesktop/ModemManager1/Modem/13'"
```

This confirmed that ModemManager *was* emitting `PropertiesChanged` signals with
NMEA data (key `uint32 4`), but the bridge's `add_signal_receiver` handler was
not being called.

**Fix:** Replace the signal-driven approach with a `GLib.timeout_add_seconds(1,
...)` timer that polls `props.Get(Location)` every second. This is simpler and
more reliable than relying on D-Bus signal delivery.

---

### 7. cgps shows NO FIX despite gpsd having valid TPV data

**Symptom:** `gpspipe -w` returned `TPV mode:3` (3D fix) but `cgps -s` always
showed `NO FIX (0 secs)`.

**Diagnosis:** A raw TCP connection showed that after sending `?WATCH`, gpsd
did not stream any data for ~30 seconds:

```bash
(echo '?WATCH={"enable":true,"json":true};'; sleep 5) | nc localhost 2947
```

**Cause:** The EM7355 only updates its NMEA fix epoch every ~30 seconds. The
bridge was deduplicating writes (`if nmea != _last_nmea`) so gpsd received data
only when the GPS epoch changed — roughly once every 30 seconds. gpsd interprets
a 30-second silence as a dead device and clears the fix.

**Fix:** Remove the deduplication and write the current NMEA block to the PTY
on every 1-second poll, even if the content hasn't changed. gpsd handles
repeated identical sentences without issue and maintains its fix state.

---

## Diagnostic Commands Reference

```bash
# Is the modem visible to ModemManager?
mmcli -L

# Full modem status
mmcli -m 13

# Current GPS NMEA from modem
mmcli -m 13 --location-get

# Bridge and gpsd service status
systemctl status mm-nmea-bridge gpsd

# Live bridge log
journalctl -u mm-nmea-bridge -f

# Raw NMEA from gpsd
gpspipe -r -n 20

# JSON fix data from gpsd
gpspipe -w -n 10

# Live fix display
cgps -s

# Detailed satellite view
gpsmon

# Run full automated check
bash ~/Documents/GPS/check-gps.sh
```

---

## File Summary

| File | Purpose |
|------|---------|
| `~/Documents/GPS/mm-nmea-bridge.py` | Python bridge: ModemManager D-Bus → PTY |
| `~/Documents/GPS/mm-nmea-bridge.service` | systemd unit (copy to `/etc/systemd/system/`) |
| `~/Documents/GPS/install.sh` | One-shot installer |
| `~/Documents/GPS/check-gps.sh` | End-to-end diagnostic script |
| `/etc/default/gpsd` | gpsd configuration (`DEVICES=""`, `-n`) |
| `/etc/systemd/system/gpsd.service.d/wait-for-bridge.conf` | gpsd ordering drop-in |
| `/run/nmea-bridge` | Symlink to PTY slave (created at runtime) |
