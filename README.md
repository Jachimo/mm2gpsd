# mm2gpsd

Bridge [ModemManager](https://www.freedesktop.org/wiki/Software/ModemManager/) GPS NMEA output to [gpsd](https://gpsd.gitlab.io/gpsd/) on Linux, using a PTY.

Designed for the **Panasonic FZ-G1 Toughpad** running Ubuntu 24.04, whose internal Sierra Wireless EM7355 LTE module includes a GPS receiver managed entirely by ModemManager. Because ModemManager owns the modem, gpsd cannot access the GPS directly — this bridge fills that gap.

```
ModemManager ──(D-Bus)──► mm2gpsd ──(PTY)──► gpsd ──(TCP 2947)──► your app
```

Once running, any application that consumes a gpsd feed works normally — for example [OpenCPN](https://opencpn.org/) for chart navigation, but also `cgps`, `gpsmon`, or any other gpsd client.

## Quick Start

```bash
sudo apt-get install -y python3-dbus python3-gi gpsd gpsd-clients
sudo bash install.sh
```

Then check everything is working:

```bash
bash check-gps.sh
```

## Documentation

- [Full setup guide and troubleshooting](HOWTO-ModemManager-GPS-gpsd.md)

## Files

| File | Purpose |
|------|---------|
| `mm-nmea-bridge.py` | The bridge — auto-discovers the GPS modem and forwards NMEA to gpsd via a PTY |
| `mm-nmea-bridge.service` | systemd unit (installed to `/etc/systemd/system/`) |
| `install.sh` | One-shot installer |
| `check-gps.sh` | End-to-end diagnostic script |

## Requirements

- Ubuntu 24.04 (or similar systemd-based Linux)
- ModemManager ≥ 1.18
- Python 3 with `python3-dbus` and `python3-gi`
- gpsd ≥ 3.20

## License

MIT
