#!/bin/bash
# ISS SSTV decode + upload script.
# Run every 2 min: */2 * * * * /home/<user>/sstv_decode.sh
#
# meteor.sh (post-obs script in container) copies the OGG audio for each ISS
# pass to /mnt/satnogs/sstv/<obsid>.ogg and writes a .sstv trigger file.
# This script picks up triggers, decodes with the sstv Python decoder, and
# uploads the image to network.satnogs.org.
#
# Requires: python3 venv at ~/satnogs-venv with 'sstv' package installed:
#   python3 -m venv ~/satnogs-venv
#   ~/satnogs-venv/bin/pip install git+https://github.com/colaclanth/sstv.git

SSTV_DIR=/mnt/satnogs/sstv
PENDING_DIR=/mnt/satnogs/pending
DECODED_DIR=/mnt/satnogs/decoded
LOG=/mnt/satnogs/sstv_decode.log
UPLOAD=/home/james/satnogs_upload.py
PYTHON=/home/james/satnogs-venv/bin/python

mkdir -p "$SSTV_DIR" "$DECODED_DIR"

for trigger in "$PENDING_DIR"/*.sstv; do
    [ -f "$trigger" ] || continue
    OBS_ID=$(head -1 "$trigger" | tr -d '[:space:]')
    AUDIO="$SSTV_DIR/${OBS_ID}.ogg"

    if [ ! -f "$AUDIO" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SKIP: no audio for obs $OBS_ID" >> "$LOG"
        rm -f "$trigger"
        continue
    fi

    outdir="$DECODED_DIR/sstv_${OBS_ID}"
    mkdir -p "$outdir"
    PNG="$outdir/sstv_${OBS_ID}.png"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Decoding SSTV obs $OBS_ID..." >> "$LOG"
    "$PYTHON" -m sstv -d "$AUDIO" -o "$PNG" >> "$LOG" 2>&1

    if [ -f "$PNG" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Uploading obs $OBS_ID..." >> "$LOG"
        python3 "$UPLOAD" "$OBS_ID" "$PNG" >> "$LOG" 2>&1 \
            && echo "[$(date '+%Y-%m-%d %H:%M:%S')] Uploaded obs $OBS_ID" >> "$LOG"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: no image for obs $OBS_ID" >> "$LOG"
    fi

    rm -f "$trigger" "$AUDIO"
done
