#!/bin/bash
# Post-observation script for Meteor LRPT (lsf-addons container)
#
# On STOP: finds the .s soft-symbol file written during this pass and queues it
# for satdump decoding + SatNOGS network upload on the host by writing a trigger
# file to /var/lib/satnogs-client/pending/ (= /mnt/satnogs/pending/ on host).
# The host-side satdump_trigger.sh cron (every 2 min) processes the trigger.
#
# Args: {start|stop} {ID} {FREQ} {TLE_JSON} {TIMESTAMP} {BAUD} {SCRIPT_NAME}
#
# Why this approach instead of running meteor_decode inside the container:
#   - knegge/satnogs-client:lsf-addons writes LSF-format .s files, which are
#     incompatible with the meteor_decode tool (Viterbi avg ~1400, 0 MPDUs).
#   - satdump (host-installed) correctly decodes LSF files via meteor_m2-x_lrpt.
#   - The decoded PNG is uploaded directly to network.satnogs.org via API.

set -euo pipefail

CMD="${1:-}"
ID="${2:-}"
FREQ="${3:-}"
TLE="${4:-}"
DATE="${5:-}"
BAUD="${6:-}"
SCRIPT="${7:-}"

PRG="meteor-lrpt"

: "${METEOR_NORAD:=57166 59051}"
: "${SATNOGS_APP_PATH:=/var/lib/satnogs-client/meteor}"
PENDING_DIR="/var/lib/satnogs-client/pending"

mkdir -p "$SATNOGS_APP_PATH" "$PENDING_DIR"
exec > >(tee -a "$SATNOGS_APP_PATH/meteor_${ID:-noobs}.log") 2>&1

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "$PRG: missing: $1" >&2; exit 1; }; }
need_cmd jq
need_cmd awk

NORAD="$(echo "$TLE" | jq -r '.tle2 // ""' | awk '{print $2}' | tr -cd '0-9')"
SATNAME="$(echo "$TLE" | jq -r '.tle0 // "UNKNOWN"' | sed -e 's/ /_/g' -e 's/[^A-Za-z0-9._-]//g')"

is_meteor_target() {
  case " ${METEOR_NORAD} " in
    *" ${NORAD} "*) return 0 ;;
    *) return 1 ;;
  esac
}

echo "$PRG: CMD=$CMD Obs=$ID NORAD=${NORAD:-?} Name=$SATNAME"

case "${CMD^^}" in
  START)
    if is_meteor_target; then
      echo "$PRG: START - lsf-addons capturing .s file"
    else
      echo "$PRG: NORAD ${NORAD:-?} not in target list; skipping"
    fi
    ;;

  STOP)
    if ! is_meteor_target; then
      echo "$PRG: NORAD ${NORAD:-?} not in target list; skipping"
      exit 0
    fi

    # Find the .s soft-symbol file from this pass (>5 MB, written in last 60 min)
    SFILE=$(find /var/lib/satnogs-client -maxdepth 1 -name "LRPT_*.s" \
              -size +5M -mmin -60 2>/dev/null | sort | tail -1)

    if [ -z "$SFILE" ]; then
      echo "$PRG: No recent LRPT .s file found (weak/no signal this pass)"
      exit 0
    fi

    SSIZE=$(stat -c%s "$SFILE")
    SBASE=$(basename "$SFILE" .s)
    echo "$PRG: Pass captured: $SBASE (${SSIZE} bytes)"

    # Write trigger file - host satdump_trigger.sh reads from /mnt/satnogs/pending/
    TRIGGER="${PENDING_DIR}/${SBASE}.pending"
    echo "$ID" > "$TRIGGER"
    echo "$PRG: Queued obs $ID for satdump decode + upload -> $TRIGGER"
    ;;

  *)
    echo "Usage: $0 {start|stop} ID FREQ TLE TIMESTAMP BAUD SCRIPT" >&2
    exit 1
    ;;
esac
