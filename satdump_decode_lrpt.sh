#!/bin/bash
# Backup decode script: decodes any .s files not already handled by satdump_trigger.sh.
# Run every 30 min: */30 * * * * /home/<user>/satdump_decode_lrpt.sh
#
# satdump_trigger.sh (run every 2 min) is the primary path — it decodes and uploads
# immediately after each pass. This script is a fallback for any files satdump_trigger.sh
# missed (e.g., system was offline when the pass ended). Files decoded here are NOT
# automatically uploaded; they stay in DECODED_DIR for local review.

LRPT_DIR=/mnt/satnogs
DECODED_DIR=/mnt/satnogs/decoded
MIN_SIZE=10000000   # 10 MB threshold - skip noisy/empty passes
SATDUMP=/usr/bin/satdump
PIPELINE=meteor_m2-x_lrpt
LOG=/mnt/satnogs/satdump_autodecode.log

mkdir -p "$DECODED_DIR"

for sfile in "$LRPT_DIR"/LRPT_*.s; do
    [ -f "$sfile" ] || continue

    filesize=$(stat -c%s "$sfile")
    [ "$filesize" -lt "$MIN_SIZE" ] && continue

    basename=$(basename "$sfile" .s)
    outdir="$DECODED_DIR/$basename"

    # Skip if already decoded
    [ -d "$outdir" ] && continue

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Decoding $basename (${filesize} bytes)..." >> "$LOG"
    mkdir -p "$outdir"

    "$SATDUMP" legacy "$PIPELINE" soft "$sfile" "$outdir/" >> "$LOG" 2>&1

    if ls "$outdir"/*.png "$outdir"/MSU-MR/*.png 2>/dev/null | head -1 | grep -q .; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] OK: images produced in $outdir" >> "$LOG"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: no images produced for $basename" >> "$LOG"
    fi
done
