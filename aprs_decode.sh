#!/bin/bash
# ISS APRS decode + APRS-IS igate script.
# Run every 2 min: */2 * * * * /home/<user>/aprs_decode.sh
#
# meteor.sh writes a .aprs trigger file when an ISS pass at 145.825 MHz ends.
# This script decodes the OGG audio with multimon-ng (AFSK1200) and submits
# the packets to APRS-IS via aprs_upload.py.
#
# Requires: multimon-ng, sox  (sudo apt-get install -y multimon-ng sox)
#           aprslib in ~/satnogs-venv  (pip install aprslib)
#           ~/.aprs_config with APRS_CALLSIGN, SATNOGS_STATION_LAT/LON

SSTV_DIR=/mnt/satnogs/sstv
PENDING_DIR=/mnt/satnogs/pending
LOG=/mnt/satnogs/aprs_decode.log
PYTHON="$(echo ~)/satnogs-venv/bin/python"
UPLOAD="$(echo ~)/aprs_upload.py"

for trigger in "$PENDING_DIR"/*.aprs; do
    [ -f "$trigger" ] || continue
    OBS_ID=$(head -1 "$trigger" | tr -d '[:space:]')
    AUDIO="$SSTV_DIR/${OBS_ID}.ogg"

    if [ ! -f "$AUDIO" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SKIP: no audio for obs $OBS_ID" >> "$LOG"
        rm -f "$trigger"
        continue
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Decoding APRS obs $OBS_ID..." >> "$LOG"

    sox "$AUDIO" -t raw -r 22050 -e signed-integer -b 16 -c 1 - 2>/dev/null \
        | multimon-ng -t raw -A -a AFSK1200 - 2>/dev/null \
        | "$PYTHON" "$UPLOAD" >> "$LOG" 2>&1

    rm -f "$trigger" "$AUDIO"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Done obs $OBS_ID" >> "$LOG"
done
