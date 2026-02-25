#!/usr/bin/env python3
"""
Bridge ModemManager NMEA output to gpsd via a PTY.

Creates a PTY, symlinks the slave end to PTY_LINK, writes NMEA sentences
received from ModemManager's D-Bus Location interface to the master end.
gpsd (or any NMEA consumer) is pointed at PTY_LINK.

Usage:
    sudo python3 mm-nmea-bridge.py [modem-index]

If modem-index is omitted, the first modem with GPS NMEA capability is used.
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

# ── configuration ──────────────────────────────────────────────────────────────
MM_SERVICE    = "org.freedesktop.ModemManager1"
MM_OBJ_PATH   = "/org/freedesktop/ModemManager1"
MM_LOC_IFACE  = "org.freedesktop.ModemManager1.Modem.Location"
PTY_LINK      = "/run/nmea-bridge"          # fixed path gpsd will use

# MM_MODEM_LOCATION_SOURCE_GPS_NMEA = 0x04  (1 << 2; 0x08 is CDMA_BS)
GPS_NMEA = dbus.UInt32(0x04)
# ───────────────────────────────────────────────────────────────────────────────

master_fd = None

def log(msg: str) -> None:
    print(msg, flush=True)
    syslog.syslog(syslog.LOG_INFO, f"mm-nmea-bridge: {msg}")


def find_gps_modem(bus, retries: int = 15, delay: int = 2) -> tuple:
    """Return (modem_index, modem_path) for the first GPS NMEA-capable modem.

    Retries up to `retries` times with `delay` seconds between attempts so
    that ModemManager has time to finish probing the modem after boot.
    """
    for attempt in range(retries):
        mm_obj  = bus.get_object(MM_SERVICE, MM_OBJ_PATH)
        obj_mgr = dbus.Interface(mm_obj, "org.freedesktop.DBus.ObjectManager")
        objects = obj_mgr.GetManagedObjects()
        for path, interfaces in objects.items():
            if MM_LOC_IFACE in interfaces:
                caps = int(interfaces[MM_LOC_IFACE].get("Capabilities", 0))
                if caps & int(GPS_NMEA):
                    index = int(str(path).rsplit("/", 1)[-1])
                    return index, str(path)
        if attempt < retries - 1:
            log(f"No GPS modem found yet, retrying in {delay}s… "
                f"({attempt + 1}/{retries})")
            time.sleep(delay)
    raise RuntimeError(
        "No modem with GPS NMEA capability found after "
        f"{retries * delay}s.\n"
        "Check:  mmcli -L && mmcli -m <index> --location-status"
    )

def setup_pty() -> str:
    """Create a PTY pair and symlink the slave to PTY_LINK."""
    global master_fd
    master_fd, slave_fd = pty.openpty()
    slave_name = os.ttyname(slave_fd)
    os.close(slave_fd)          # gpsd opens the slave; we only need master_fd

    # gpsd runs as user 'gpsd' in group 'dialout'; grant dialout rw access
    dialout_gid = grp.getgrnam("dialout").gr_gid
    os.chown(slave_name, 0, dialout_gid)
    os.chmod(slave_name, 0o660)

    # Replace stale symlink if present
    if os.path.islink(PTY_LINK) or os.path.exists(PTY_LINK):
        os.unlink(PTY_LINK)
    os.symlink(slave_name, PTY_LINK)

    log(f"PTY slave: {slave_name}  →  {PTY_LINK}")
    return slave_name


def write_nmea(sentences: str) -> None:
    """Write one or more NMEA sentences to the PTY master."""
    for line in sentences.strip().splitlines():
        line = line.strip()
        if line.startswith("$"):
            try:
                os.write(master_fd, (line + "\r\n").encode())
            except OSError as exc:
                log(f"PTY write error: {exc}")


_last_nmea: str = ""

def poll_nmea(props_iface) -> bool:
    """Poll ModemManager for NMEA data every second via GLib timer."""
    global _last_nmea
    try:
        location = props_iface.Get(MM_LOC_IFACE, "Location")
        nmea = str(location.get(GPS_NMEA, ""))
        if nmea:
            # Always write — gpsd needs a continuous stream to maintain fix.
            # If the GPS epoch hasn't changed, repeat the last sentences so
            # gpsd doesn't time out and drop back to NO FIX.
            write_nmea(nmea)
            _last_nmea = nmea
    except Exception as exc:
        log(f"Poll error: {exc}")
    return True  # keep the timer running


def on_properties_changed(iface, changed, _invalidated):
    """D-Bus PropertiesChanged handler — belt-and-suspenders alongside polling."""
    if iface != MM_LOC_IFACE:
        return
    location = changed.get("Location", {})
    nmea = str(location.get(GPS_NMEA, ""))
    if nmea:
        write_nmea(nmea)


def notify_gpsd() -> None:
    """Start gpsd (if not running) then add the PTY device."""
    # Fire gpsd start non-blocking; it has no DEVICES= so it won't race us
    subprocess.run(["systemctl", "start", "--no-block", "gpsd.service"],
                   check=False)
    # Wait for gpsd socket to become available (up to 10 s)
    for i in range(10):
        time.sleep(1)
        r = subprocess.run(["gpsdctl", "add", PTY_LINK],
                           capture_output=True)
        if r.returncode == 0:
            log(f"gpsdctl: added {PTY_LINK}")
            return
        if b"reached a running gpsd" in r.stdout:
            # gpsd is up but rejected the add — already has the device
            log(f"gpsdctl: gpsd already tracking {PTY_LINK}")
            return
    log(f"Warning: could not add {PTY_LINK} to gpsd after 10 s; "
        f"run manually:  gpsdctl add {PTY_LINK}")


def cleanup(location_iface, signum=None, _frame=None) -> None:
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


def main() -> None:
    setup_pty()

    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()

    # Determine modem: use CLI arg if provided, otherwise auto-discover
    if len(sys.argv) > 1:
        modem_index = int(sys.argv[1])
        modem_path  = f"/org/freedesktop/ModemManager1/Modem/{modem_index}"
    else:
        modem_index, modem_path = find_gps_modem(bus)
        log(f"Auto-discovered GPS modem: index {modem_index} ({modem_path})")

    modem_obj      = bus.get_object(MM_SERVICE, modem_path)
    location_iface = dbus.Interface(modem_obj, MM_LOC_IFACE)
    props_iface    = dbus.Interface(modem_obj, dbus.PROPERTIES_IFACE)

    # Enable GPS NMEA — retry in case ModemManager is still initialising
    for attempt in range(10):
        try:
            location_iface.Setup(GPS_NMEA, True)
            break
        except dbus.DBusException as exc:
            if attempt == 9:
                raise
            log(f"Setup failed ({exc.get_dbus_name()}), retrying in 2s… "
                f"({attempt + 1}/10)")
            time.sleep(2)
    log(f"GPS NMEA enabled on modem {modem_index} ({modem_path})")

    # Poll every second (reliable fallback if signals aren't delivered)
    GLib.timeout_add_seconds(1, lambda: poll_nmea(props_iface))

    # Also subscribe to D-Bus signals as a belt-and-suspenders bonus
    bus.add_signal_receiver(
        on_properties_changed,
        signal_name="PropertiesChanged",
        dbus_interface="org.freedesktop.DBus.Properties",
        path=modem_path,
    )

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda s, f: cleanup(location_iface, s, f))

    notify_gpsd()

    log(f"Forwarding NMEA → {PTY_LINK}  (Ctrl-C to stop)")
    GLib.MainLoop().run()


if __name__ == "__main__":
    if os.geteuid() != 0:
        sys.exit("Must run as root (needs D-Bus system bus + PTY_LINK in /run)")
    main()
