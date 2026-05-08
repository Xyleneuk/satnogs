#!/usr/bin/env python3
"""
Read TNC2 APRS packets from stdin (multimon-ng -A output) and submit to APRS-IS.

Config read from ~/.aprs_config:
    APRS_CALLSIGN=M0XYZ-10
    SATNOGS_STATION_LAT=51.438
    SATNOGS_STATION_LON=-0.458

Or set via environment variables with the same names.
"""
import sys
import os
import aprslib


def load_config():
    cfg = {}
    try:
        with open(os.path.expanduser("~/.aprs_config")) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    cfg[k.strip()] = v.strip()
    except FileNotFoundError:
        pass
    callsign = os.environ.get("APRS_CALLSIGN", cfg.get("APRS_CALLSIGN", ""))
    lat = float(os.environ.get("SATNOGS_STATION_LAT", cfg.get("SATNOGS_STATION_LAT", "0")))
    lon = float(os.environ.get("SATNOGS_STATION_LON", cfg.get("SATNOGS_STATION_LON", "0")))
    return callsign, lat, lon


def to_aprs_lat(lat):
    h = "N" if lat >= 0 else "S"
    lat = abs(lat)
    return f"{int(lat):02d}{(lat % 1) * 60:05.2f}{h}"


def to_aprs_lon(lon):
    h = "E" if lon >= 0 else "W"
    lon = abs(lon)
    return f"{int(lon):03d}{(lon % 1) * 60:05.2f}{h}"


callsign, lat, lon = load_config()
if not callsign:
    print("Error: APRS_CALLSIGN not configured in ~/.aprs_config", file=sys.stderr)
    sys.exit(1)

packets = [line.strip() for line in sys.stdin if line.strip()]

if not packets:
    print("0 APRS packets decoded")
    sys.exit(0)

print(f"Decoded {len(packets)} packet(s); submitting to APRS-IS as {callsign}...")

try:
    AIS = aprslib.IS(
        callsign,
        passwd=aprslib.passcode(callsign),
        host="rotate.aprs2.net",
        port=14580,
    )
    AIS.connect()

    beacon = (
        f"{callsign}>APRS,TCPIP*:"
        f"={to_aprs_lat(lat)}/{to_aprs_lon(lon)}"
        f"iSatNOGS ISS APRS igate"
    )
    AIS.sendall(beacon)

    for pkt in packets:
        AIS.sendall(pkt)
        print(f"  TX: {pkt[:100]}")

    AIS.close()
    print(f"Submitted {len(packets)} packet(s) to APRS-IS")

except Exception as e:
    print(f"APRS-IS error: {e}", file=sys.stderr)
    sys.exit(1)
