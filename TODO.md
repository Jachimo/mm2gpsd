# TODO: In-Process Modem Reconnect on Suspend/Resume (Option C)

## Problem

After suspend/resume, ModemManager re-enumerates the Sierra Wireless EM7355 and
assigns it a new D-Bus object path (e.g. `/org/freedesktop/ModemManager1/Modem/13`
→ `/Modem/22`).  The running bridge holds stale `dbus.Interface` objects bound to
the old path.  `poll_nmea` catches the resulting `DBusException`, logs it, and
returns `True` — so the GLib timer keeps firing but no NMEA is written.  The
process never exits, `Restart=on-failure` never triggers, and gpsd quietly loses
its fix while the service shows "active (running)".

---

## Goal

Keep the bridge process alive across suspend/resume cycles.  When the modem
disappears, pause NMEA polling.  When a new GPS-capable modem appears under a
different path, re-bind to it — without touching the PTY or gpsd — so GPS
resumes with no device interruption.

---

## Proposed Implementation

### 1. Track reconnect state in module-level variables

```python
# Add alongside master_fd at module level
_props_iface      = None   # current dbus.Interface for Properties
_location_iface   = None   # current dbus.Interface for Modem.Location
_modem_path       = None   # current D-Bus object path string
_polling_active   = False  # False while modem is absent
```

### 2. Subscribe to ObjectManager signals at startup

In `main()`, after the initial modem discovery, register handlers on the MM
ObjectManager for `InterfacesAdded` and `InterfacesRemoved`:

```python
bus.add_signal_receiver(
    on_interfaces_removed,
    signal_name="InterfacesRemoved",
    dbus_interface="org.freedesktop.DBus.ObjectManager",
    bus_name=MM_SERVICE,
    path=MM_OBJ_PATH,
)
bus.add_signal_receiver(
    on_interfaces_added,
    signal_name="InterfacesAdded",
    dbus_interface="org.freedesktop.DBus.ObjectManager",
    bus_name=MM_SERVICE,
    path=MM_OBJ_PATH,
)
```

### 3. Handler: modem removed

```python
def on_interfaces_removed(object_path, interfaces):
    global _polling_active, _modem_path
    if str(object_path) == _modem_path and MM_LOC_IFACE in interfaces:
        log(f"Modem removed: {_modem_path} — pausing NMEA polling")
        _polling_active = False
        _modem_path = None
```

### 4. Handler: modem added

```python
def on_interfaces_added(object_path, interfaces_and_props):
    global _props_iface, _location_iface, _modem_path, _polling_active
    if MM_LOC_IFACE not in interfaces_and_props:
        return
    caps = int(interfaces_and_props[MM_LOC_IFACE].get("Capabilities", 0))
    if not (caps & int(GPS_NMEA)):
        return

    new_path = str(object_path)
    log(f"New GPS modem appeared: {new_path} — reconnecting")

    # Give ModemManager a moment to finish probing before we call Setup()
    GLib.timeout_add_seconds(3, lambda: _reconnect(new_path))
```

### 5. Reconnect helper

```python
def _reconnect(new_path: str) -> bool:
    """Bind to new modem path, re-enable GPS NMEA, resume polling.
    Called via GLib.timeout_add_seconds so it runs in the main loop.
    Returns False to prevent GLib from repeating the one-shot timer.
    """
    global _props_iface, _location_iface, _modem_path, _polling_active

    bus = dbus.SystemBus()
    modem_obj = bus.get_object(MM_SERVICE, new_path)
    new_loc_iface   = dbus.Interface(modem_obj, MM_LOC_IFACE)
    new_props_iface = dbus.Interface(modem_obj, dbus.PROPERTIES_IFACE)

    for attempt in range(10):
        try:
            new_loc_iface.Setup(GPS_NMEA, True)
            break
        except dbus.DBusException as exc:
            if attempt == 9:
                log(f"Reconnect: Setup failed after 10 attempts: {exc}")
                return False
            log(f"Reconnect: Setup attempt {attempt+1}/10 failed, retrying…")
            time.sleep(2)

    # Update globals — poll_nmea will pick these up on next tick
    _location_iface = new_loc_iface
    _props_iface    = new_props_iface
    _modem_path     = new_path
    _polling_active = True

    # Re-subscribe to PropertiesChanged on the new path
    bus.add_signal_receiver(
        on_properties_changed,
        signal_name="PropertiesChanged",
        dbus_interface="org.freedesktop.DBus.Properties",
        path=new_path,
    )

    log(f"Reconnected to modem at {new_path}")
    return False  # one-shot timer
```

### 6. Update poll_nmea to gate on _polling_active

```python
def poll_nmea() -> bool:
    if not _polling_active:
        return True
    try:
        location = _props_iface.Get(MM_LOC_IFACE, "Location")
        nmea = str(location.get(GPS_NMEA, ""))
        if nmea:
            write_nmea(nmea)
    except Exception as exc:
        log(f"Poll error: {exc}")
    return True
```

The GLib timer callback signature changes to `lambda: poll_nmea()` (no argument)
since `props_iface` is now a global.

### 7. Update cleanup to use _location_iface global

```python
def cleanup(signum=None, _frame=None) -> None:
    log("Shutting down…")
    try:
        if _location_iface:
            _location_iface.Setup(dbus.UInt32(0), False)
    except Exception:
        pass
    ...
```

---

## Potential Issues and Mitigations

### Race: `InterfacesAdded` fires before MM finishes probing

ModemManager emits `InterfacesAdded` as soon as the D-Bus object is published,
but `Setup()` may fail with `org.freedesktop.ModemManager1.Error.Core.WrongState`
for a second or two while MM is still initialising the modem.  The `_reconnect`
helper already retries `Setup()` up to 10 times with 2-second delays.  The
`GLib.timeout_add_seconds(3, ...)` in `on_interfaces_added` adds a head-start
delay before the first attempt, reducing retry churn.

### Race: multiple InterfacesAdded events for the same path

MM may emit `InterfacesAdded` more than once as it layers interfaces onto the
object.  Guard against double-reconnect by checking `_modem_path` at the top of
`on_interfaces_added`:

```python
if new_path == _modem_path:
    return  # already connected to this path
```

### Stale PropertiesChanged subscriptions

Each call to `bus.add_signal_receiver` for `PropertiesChanged` stacks a new
handler; the old one (bound to the previous path) is never removed.  After
several suspend/resume cycles this leaks handlers.  Fix by tracking the match
rule and calling `bus.remove_signal_receiver` in `on_interfaces_removed`, or by
using `bus.add_signal_receiver` with an explicit `sender_keyword` and filtering
by path inside `on_properties_changed`.  Alternatively, since `poll_nmea` is the
primary data path and `on_properties_changed` is belt-and-suspenders, the leak
is low-impact but should still be addressed.

### time.sleep() inside _reconnect blocks the main loop

`_reconnect` is called via `GLib.timeout_add_seconds`, so it runs on the GLib
main loop thread.  Calling `time.sleep(2)` inside the retry loop will block the
entire event loop (no NMEA writes, no signal handling) for up to 20 seconds in
the worst case.  Better approach: on failure, schedule another one-shot
`GLib.timeout_add_seconds(2, lambda: _reconnect(new_path))` instead of looping
with `time.sleep`.

### D-Bus SystemBus instance in _reconnect

`dbus.SystemBus()` inside `_reconnect` returns the existing shared connection
(dbus-python caches it) so this is safe, but it is cleaner to pass the `bus`
instance down from `main()` as a module-level variable or closure rather than
calling `SystemBus()` again.

### cleanup signal handler signature

`signal.signal` passes `(signum, frame)` to the handler.  After refactoring
`cleanup` to use globals instead of a `location_iface` argument, update the
lambda:

```python
for sig in (signal.SIGTERM, signal.SIGINT):
    signal.signal(sig, cleanup)
```

---

## Testing Plan

1. Start service, verify GPS fix in `gpspipe -w`.
2. `systemctl suspend` — verify service stays in "active" state during suspend.
3. On wake, watch `journalctl -u mm-nmea-bridge -f` for "Modem removed" then
   "Reconnected" messages.
4. Verify `gpspipe -w` resumes producing TPV sentences within ~15 seconds of wake.
5. Repeat steps 2–4 several times to check for handler leak / double-reconnect.
6. Kill `ModemManager` and restart it to simulate a manual MM restart (exercises
   the same code path as suspend/resume).
