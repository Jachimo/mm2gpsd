# Copilot Instructions

## What This Project Does

Bridges GPS data from a Sierra Wireless EM7355 LTE module (on a Panasonic FZ-G1 Toughpad, Ubuntu 24.04) to gpsd via a PTY. ModemManager owns the modem and exposes NMEA sentences over D-Bus; gpsd expects a serial-like device. The bridge fills that gap.

```
ModemManager ──(D-Bus)──► mm-nmea-bridge.py ──(PTY)──► gpsd ──(TCP 2947)──► OpenCPN
```

## Key Commands

```bash
# Install everything (packages, systemd units, gpsd config)
sudo bash install.sh

# Run the bridge manually (auto-discovers modem; optional index arg)
sudo python3 mm-nmea-bridge.py [modem-index]

# End-to-end diagnostic check
bash check-gps.sh

# Service management
systemctl status mm-nmea-bridge gpsd
journalctl -u mm-nmea-bridge -f
systemctl restart mm-nmea-bridge.service

# Inspect GPS data
gpspipe -r -n 20          # raw NMEA from gpsd
gpspipe -w -n 10          # JSON TPV/fix data
mmcli -m <index> --location-get  # NMEA direct from ModemManager
gpsmon /run/nmea-bridge   # live satellite + sentence view
```

## Architecture Details

- **`mm-nmea-bridge.py`** — the bridge. Runs as root. Uses `dbus.mainloop.glib.DBusGMainLoop` + `GLib.MainLoop`. Polls `props.Get(MM_LOC_IFACE, "Location")` every second via `GLib.timeout_add_seconds`; also subscribes to `PropertiesChanged` signals as a supplement.
- **PTY** — created with `pty.openpty()`. Slave end is symlinked to `/run/nmea-bridge` (the fixed path gpsd uses). Master end receives NMEA writes from the bridge.
- **`mm-nmea-bridge.service`** — systemd unit. Runs after `ModemManager.service`, before `gpsd.service`. `ExecStopPost` cleans up the `/run/nmea-bridge` symlink.
- **gpsd integration** — gpsd is started from *inside* the Python script (after the PTY exists) with `systemctl start --no-block gpsd.service`, then `gpsdctl add /run/nmea-bridge` is retried up to 10 times.

## Critical Non-Obvious Conventions

**Do not deduplicate NMEA writes.** The EM7355 updates its fix epoch only every ~30 seconds. If writes are suppressed when NMEA content hasn't changed, gpsd sees a 30-second silence, treats the device as dead, and drops the fix. Always write the current NMEA block on every 1-second poll.

**GPS_NMEA bitmask is `0x04`, not `0x08`.** The `MM_MODEM_LOCATION_SOURCE_*` values are: `0x01` = 3GPP LAC/CI, `0x02` = GPS Raw, `0x04` = GPS NMEA, `0x08` = CDMA Base Station. Using `0x08` causes: `DBusException: Cannot enable unsupported location sources: 'cdma-bs'`.

**Disable `gpsd.socket`, never mask it.** `gpsd.service` has `Requires=gpsd.socket`. Masking the socket prevents gpsd from starting entirely. Disabling prevents auto-start at boot while still allowing `gpsd.service` to bring up the socket as a dependency.

**`DEVICES=""` in `/etc/default/gpsd`.** Listing `/run/nmea-bridge` there causes gpsd to try opening it before the bridge has created the symlink. The bridge hands the device to gpsd via `gpsdctl add` after setup.

**PTY slave permissions must be `root:dialout 660`.** PTY slaves are created `root:tty 660` by default. gpsd runs as user `gpsd` (group `dialout`), which is not in group `tty`, so it cannot open the device. Fix immediately after `pty.openpty()`:
```python
os.chown(slave_name, 0, grp.getgrnam("dialout").gr_gid)
os.chmod(slave_name, 0o660)
```

**The current `mm-nmea-bridge.py` auto-discovers the modem index** by querying `org.freedesktop.DBus.ObjectManager.GetManagedObjects()` and checking `Capabilities & 0x04`. The HOWTO.md contains an older hardcoded version (index 13) — treat `mm-nmea-bridge.py` as the authoritative source.

## Runtime Dependencies

```bash
apt-get install -y python3-dbus python3-gi gpsd gpsd-clients
```

Services that must be running: `ModemManager`, `mm-nmea-bridge`, `gpsd`.
