#!/bin/bash
# Process pending satdump decode requests written by meteor.sh after each pass.
# For each .pending file, decodes the .s file with satdump and uploads the best
# PNG image to network.satnogs.org via the SatNOGS API.
#
# Run every 2 min: */2 * * * * /home/<user>/satdump_trigger.sh
#
# Requires: satdump at /usr/bin/satdump, python3 with requests

LRPT_DIR=/mnt/satnogs
PENDING_DIR=/mnt/satnogs/pending
DECODED_DIR=/mnt/satnogs/decoded
MIN_SIZE=5000000
SATDUMP=/usr/bin/satdump
PIPELINE=meteor_m2-x_lrpt
LOG=/mnt/satnogs/satdump_autodecode.log
UPLOAD=/home/james/satnogs_upload.py

mkdir -p "$DECODED_DIR"

for pending in "$PENDING_DIR"/*.pending; do
    [ -f "$pending" ] || continue

    SBASE=$(basename "$pending" .pending)
    SFILE="$LRPT_DIR/${SBASE}.s"
    OBS_ID=$(head -1 "$pending" | tr -d '[:space:]')

    if [ ! -f "$SFILE" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SKIP: $SBASE.s missing" >> "$LOG"
        rm -f "$pending"
        continue
    fi

    SSIZE=$(stat -c%s "$SFILE")
    if [ "$SSIZE" -lt "$MIN_SIZE" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SKIP: $SBASE too small (${SSIZE}B)" >> "$LOG"
        rm -f "$pending"
        continue
    fi

    outdir="$DECODED_DIR/$SBASE"

    if [ ! -d "$outdir" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Decoding $SBASE (${SSIZE}B obs $OBS_ID)..." >> "$LOG"
        mkdir -p "$outdir"
        "$SATDUMP" legacy "$PIPELINE" soft "$SFILE" "$outdir/" >> "$LOG" 2>&1
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $SBASE already decoded, uploading obs $OBS_ID..." >> "$LOG"
    fi

    # Find best image: false colour > MSU-MR-2 > any PNG
    BEST=$(find "$outdir" -name "*.png" 2>/dev/null \
           | grep -i 'false.color\|falsecolor' | head -1)
    [ -z "$BEST" ] && BEST=$(find "$outdir/MSU-MR" -name "MSU-MR-2.png" 2>/dev/null | head -1)
    [ -z "$BEST" ] && BEST=$(find "$outdir" -name "*.png" 2>/dev/null | head -1)

    if [ -n "$BEST" ] && [ -n "$OBS_ID" ]; then
        python3 "$UPLOAD" "$OBS_ID" "$BEST" >> "$LOG" 2>&1 \
            && echo "[$(date '+%Y-%m-%d %H:%M:%S')] Uploaded obs $OBS_ID: $(basename "$BEST")" >> "$LOG"
    elif [ -z "$BEST" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: no PNG produced for $SBASE" >> "$LOG"
    fi

    rm -f "$pending"
done
