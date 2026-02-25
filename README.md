# mm2gpsd

> Bridge [ModemManager][] GPS NMEA output to [gpsd][] on Linux, using
> a PTY.

[ModemManager]: https://www.freedesktop.org/wiki/Software/ModemManager/
[gpsd]: https://gpsd.gitlab.io/gpsd/

Designed for the **Panasonic FZ-G1 Toughpad** and its OEM (optional)
Sierra Wireless EM7355 LTE module, which includes a GPS receiver
managed entirely by ModemManager on recent Systemd-based Linux.
Because ModemManager 'owns' the modem, `gpsd` cannot access the GPS'
NMEA feed directly (without disabling ModemManager). This bridge fills
that gap, and prevents having to persistently disable ModemManager for
the LTE module, which can affect using it as an actual LTE modem.

```
ModemManager ──(D-Bus)──► mm2gpsd ──(PTY)──► gpsd ──(TCP 2947)──► Application
```

Once running, any application that consumes a `gpsd` TCP feed should
"just work" when pointed at `localhost:2947`.

For example, [OpenCPN](https://opencpn.org/) for maritime navigation
has been confirmed to work, as have `cgps` and `gpsmon`, but in theory
many other applications that depend on NMEA from `gpsd` *should* work
fine. Pull requests to support other commonly-used Linux
location-aware applications are welcome.

## Quick Start

```bash
cd path/to/cloned/repo
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

- Computer running a recent, Systemd-based Linux (e.g. Ubuntu 24.04)
- ModemManager ≥ 1.18 (1.24+ recommended)
- Python 3 with `python3-dbus` and `python3-gi`
- gpsd ≥ 3.20
- Integrated WWAN+GNSS module supported by ModemManager

The reference platform used for initial development was:

- Panasonic Toughpad FZ-G1 Gen5
- Sierra Wireless EM7355 LTE modem (internal, factory installed, no SIM)
- Ubuntu Desktop 24.04 LTS

In theory, Ubuntu 22.04 LTS, Debian 12 "Bookworm" / Debian 13
"Trixie", Fedora 40 / 41, openSUSE "Tumbleweed", Arch/Manjaro, Mint
21.x, or RHEL (and derivatives) 9+ should work, although in some cases
package names are different and the installation process may need
tweaking.

Pull requests to broaden support are also welcome, so long as they do
not break support for the reference platform (Ubuntu 24.04 on the
FZ-G1 Gen 5 with the OEM Sierra WWAN card).

## License

MIT

## References / Further Reading

- Much inspiration for this project came from the series of articles
  ["Configuring the FZ-M1 for GPS"][k4sbc], by K4SBC.
- Official documentation for the Sierra AirPrime EM73xx LTE modules
  can be found in the [AirPrime EM73xx/MC73xx AT Command
  Reference][officialref] but only with a login from Sierra; an NDA is
  probably required for access.
- An *unofficial* copy of the same document can be found
  [here][haven], while it lasts.
- A [Youtube video showing how to access the Sierra module][yt] may be
  helpful for anyone who needs to install one, change antennas, etc.

[k4sbc]: https://k4sbc.com/configuring-the-fz-m1-for-gps/
[officialref]: https://source.sierrawireless.com/resources/airprime/software/airprime-em73xx_mc73xx-at-command-reference/
[haven]: https://the-wireless-haven-media.s3.us-east-2.amazonaws.com/wp-content/uploads/2017/12/26200216/4118014-AirPrime-EM73xx-MC73xx-AT-Command-Reference.pdf
[yt]: https://youtu.be/g2-gWtlfr4U
