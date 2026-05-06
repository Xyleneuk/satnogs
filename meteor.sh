#!/bin/bash
# Meteor LRPT decode helper for SatNOGS (lsf-addons container)
# The knegge/lsf-addons container demodulates LRPT and saves soft symbol
# files (LRPT_*.s) to /var/lib/satnogs-client/. This script decodes those
# .s files into images, saves them to SATNOGS_OUTPUT_PATH so the SatNOGS
# client uploads them to network.satnogs.org, and archives a copy to USB.
#
# Args: {start|stop} {ID} {FREQ} {TLE_JSON} {TIMESTAMP} {BAUD} {SCRIPT_NAME}
#
# Key fixes vs IQ-based approach:
#   - Decodes directly from .s soft-symbol files (no meteor_demod needed)
#   - Meteor M2-4 (NORAD 59051) requires -i flag (80k interleaved mode)
#   - Image saved as data_${ID}_*.png so SatNOGS client uploads it to network

set -euo pipefail

CMD="${1:-}"
ID="${2:-}"
FREQ="${3:-}"
TLE="${4:-}"
DATE="${5:-}"
BAUD="${6:-}"
SCRIPT="${7:-}"

PRG="Meteor demod+decode"

: "${METEOR_NORAD:=57166 59051}"
: "${SATNOGS_OUTPUT_PATH:=/tmp/.satnogs/data}"
: "${SATNOGS_APP_PATH:=/var/lib/satnogs-client/meteor}"
: "${SATNOGS_STATION_ID:=0}"

# Log to persistent storage
ARCHIVE_DIR="${SATNOGS_APP_PATH}"
mkdir -p "$ARCHIVE_DIR"
exec > >(tee -a "$ARCHIVE_DIR/meteor_${ID:-noobs}.log") 2>&1

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "$PRG: missing command: $1" >&2; exit 1; }; }
need_cmd jq
need_cmd awk
need_cmd meteor_decode

METEOR_PID="$SATNOGS_APP_PATH/meteor_${SATNOGS_STATION_ID}.pid"

# Must be named data_* in SATNOGS_OUTPUT_PATH for SatNOGS client to upload it
IMAGE="${SATNOGS_OUTPUT_PATH}/data_${ID}_${DATE}.png"

# Persistent archive copy on USB
ARCHIVE_IMAGE="${ARCHIVE_DIR}/meteor_${ID}_${DATE}_raw.png"

SATNAME="$(echo "$TLE" | jq -r '.tle0 // "UNKNOWN"' | sed -e 's/ /_/g' -e 's/[^A-Za-z0-9._-]//g')"
NORAD="$(echo "$TLE" | jq -r '.tle2 // ""' | awk '{print $2}' | tr -cd '0-9')"

is_meteor_target() {
  case " ${METEOR_NORAD} " in
    *" ${NORAD} "*) return 0 ;;
    *) return 1 ;;
  esac
}

log_header() {
  echo "$PRG: Obs=$ID NORAD=${NORAD:-?} Name=$SATNAME Script=$SCRIPT Baud=$BAUD Freq=$FREQ"
}

case "${CMD^^}" in
  START)
    if is_meteor_target; then
      log_header
      mkdir -p "$SATNOGS_APP_PATH" "$SATNOGS_OUTPUT_PATH"
      echo "$ID" > "$METEOR_PID"
      echo "$PRG: START - waiting for lsf-addons to capture .s file"
    else
      echo "$PRG: START received but NORAD ${NORAD:-?} not in METEOR_NORAD list; skipping."
    fi
    ;;

  STOP)
    if ! is_meteor_target; then
      echo "$PRG: STOP received but NORAD ${NORAD:-?} not in METEOR_NORAD list; skipping."
      exit 0
    fi

    log_header

    # Find the .s soft-symbol file created by lsf-addons during this pass.
    # Look for a large (>5MB) .s file modified within the last 60 minutes.
    SFILE=$(find /var/lib/satnogs-client -maxdepth 1 -name "LRPT_*.s" \
              -size +5M -mmin -60 2>/dev/null \
            | sort | tail -1)

    if [ -z "$SFILE" ]; then
      echo "$PRG: No recent large LRPT .s file found (weak/no signal this pass)." >&2
      exit 2
    fi

    SSIZE=$(stat -c%s "$SFILE")
    echo "$PRG: Using .s file: $SFILE (${SSIZE} bytes)"

    mkdir -p "$SATNOGS_OUTPUT_PATH" "$ARCHIVE_DIR"

    # Decode flags:
    # -d  = differential decoding (all Meteor-M2)
    # -i  = deinterleave, aka 80k mode (Meteor M2-4 only, NORAD 59051)
    # -a  = APID channels for MSU-MR visible RGB
    DECODE_FLAGS="-d -a 65,65,64"
    if [ "${NORAD}" = "59051" ]; then
      DECODE_FLAGS="-d -i -a 65,65,64"
      echo "$PRG: Using 80k deinterleave mode for Meteor M2-4"
    fi

    echo "$PRG: Decoding -> $IMAGE"
    # shellcheck disable=SC2086
    meteor_decode $DECODE_FLAGS -o "$IMAGE" "$SFILE"

    if [ -s "$IMAGE" ]; then
      IMGSIZE=$(stat -c%s "$IMAGE")
      echo "$PRG: OK: image saved ($IMGSIZE bytes) -> $IMAGE"
      cp "$IMAGE" "$ARCHIVE_IMAGE" && echo "$PRG: Archived -> $ARCHIVE_IMAGE"
    else
      echo "$PRG: WARN: meteor_decode ran but image empty (poor signal?)" >&2
      rm -f "$IMAGE"
      exit 3
    fi

    rm -f "$METEOR_PID" 2>/dev/null || true
    ;;

  *)
    echo "Usage: $0 {start|stop} ID FREQ TLE TIMESTAMP BAUD SCRIPT" >&2
    exit 1
    ;;
esac
