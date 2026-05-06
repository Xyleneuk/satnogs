#!/bin/bash
# Auto-decode new Meteor LRPT .s files using satdump
# Run as a cron job (every 30 min): */30 * * * * /path/to/satdump_decode_lrpt.sh
# Produces full-colour PNG images in DECODED_DIR for local archiving/review.
# Note: SatNOGS network uploads are handled separately by meteor.sh (via meteor_decode).
#
# Crontab entries needed:
#   */30 * * * * /home/james/satdump_decode_lrpt.sh
#   # Clean LRPT soft-symbol files older than 4 days (owned by Docker user)
#   0 3 * * * docker exec station-351_satnogs_client_1 bash -c "find /var/lib/satnogs-client -maxdepth 1 -name 'LRPT_*.s' -mtime +4 -delete" 2>/dev/null
#   # Clean decoded image directories older than 7 days
#   30 3 * * * find /mnt/satnogs/decoded -maxdepth 1 -mindepth 1 -type d -mtime +7 -exec rm -rf {} +

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
