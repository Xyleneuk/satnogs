#!/bin/bash
# Post-observation script — Meteor LRPT + ISS SSTV + ISS APRS
#
# Runs inside the satnogs-client container after every observation.
# Routes each pass to the correct host-side decode pipeline via trigger files
# written to /var/lib/satnogs-client/pending/ (= /mnt/satnogs/pending/ on host).
#
# Pipelines (all run every 2 min as host cron jobs):
#   Meteor LRPT  → satdump_trigger.sh  → satnogs_upload.py
#   ISS SSTV     → sstv_decode.sh      → satnogs_upload.py
#   ISS APRS     → aprs_decode.sh      → aprs_upload.py → APRS-IS igate
#
# Args: stop {ID} {FREQ} {TLE_JSON} {TIMESTAMP} {BAUD} {SCRIPT_NAME}

set -euo pipefail

CMD="${1:-}"
ID="${2:-}"
FREQ="${3:-}"
TLE="${4:-}"
DATE="${5:-}"
BAUD="${6:-}"
SCRIPT="${7:-}"

PRG="satnogs-post"

: "${METEOR_NORAD:=57166 59051}"
: "${SATNOGS_APP_PATH:=/var/lib/satnogs-client/meteor}"
PENDING_DIR="/var/lib/satnogs-client/pending"
SSTV_DIR="/var/lib/satnogs-client/sstv"

mkdir -p "$SATNOGS_APP_PATH" "$PENDING_DIR" "$SSTV_DIR"
exec > >(tee -a "$SATNOGS_APP_PATH/obs_${ID:-noobs}.log") 2>&1

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "$PRG: missing: $1" >&2; exit 1; }; }
need_cmd jq
need_cmd awk

NORAD="$(echo "$TLE" | jq -r '.tle2 // ""' | awk '{print $2}' | tr -cd '0-9')"
SATNAME="$(echo "$TLE" | jq -r '.tle0 // "UNKNOWN"' | sed -e 's/ /_/g' -e 's/[^A-Za-z0-9._-]//g')"
FREQ_INT=$(echo "${FREQ:-0}" | awk '{printf "%d", $1+0}')

is_meteor() {
  case " ${METEOR_NORAD} " in *" ${NORAD} "*) return 0;; *) return 1;; esac
}
is_iss() { [ "${NORAD}" = "25544" ]; }

echo "$PRG: CMD=$CMD Obs=$ID NORAD=${NORAD:-?} Name=$SATNAME Freq=${FREQ_INT}Hz"

case "${CMD^^}" in
  START)
    is_meteor && echo "$PRG: Meteor LRPT pass starting" && exit 0
    is_iss    && echo "$PRG: ISS pass starting (freq ${FREQ_INT}Hz)" && exit 0
    echo "$PRG: NORAD ${NORAD:-?} not tracked; skipping"
    ;;

  STOP)
    if is_meteor; then
      # Demodulate IQ dump → LRPT_DATE.s (the only mechanism that creates .s files)
      IQ_FILE="${IQ_DUMP_FILENAME:-/var/lib/satnogs-client/iq/iq.raw}"
      IQ_SIZE=$(stat -c%s "$IQ_FILE" 2>/dev/null || echo 0)
      if [ "$IQ_SIZE" -gt 52428800 ]; then
        _ts="${DATE:-$(date -u '+%Y-%m-%dT%H-%M-%S')}"
        DATE_FMT=$(echo "$_ts" | sed 's/-/_/g; s/T/-/; s/_[0-9]*$//')
        SFILE="/var/lib/satnogs-client/LRPT_${DATE_FMT}.s"
        echo "$PRG: Demodulating IQ ($IQ_SIZE bytes) → $SFILE"
        if meteor_demod -B -q -O 8 -f 128 -s 160000 -r 72000 -m oqpsk --bps 16 \
            -o "$SFILE" "$IQ_FILE" 2>&1; then
          echo "$PRG: meteor_demod done ($(stat -c%s "$SFILE" 2>/dev/null || echo 0) bytes)"
        else
          echo "$PRG: meteor_demod failed (exit $?)"
          rm -f "$SFILE"
          SFILE=""
        fi
      else
        echo "$PRG: IQ dump missing or too small ($IQ_SIZE bytes) — weak/no signal"
        SFILE=""
      fi
      # Fall back to any pre-existing .s (e.g. written by a pre-script)
      if [ -z "${SFILE:-}" ]; then
        SFILE=$(find /var/lib/satnogs-client -maxdepth 1 -name "LRPT_*.s" \
                  -size +5M -mmin -60 2>/dev/null | sort | tail -1)
      fi
      if [ -z "${SFILE:-}" ] || [ ! -f "$SFILE" ]; then
        echo "$PRG: No usable .s file — skipping"; exit 0
      fi
      FSIZE=$(stat -c%s "$SFILE")
      if [ "$FSIZE" -lt 5242880 ]; then
        echo "$PRG: .s too small ($FSIZE bytes) — skipping"; exit 0
      fi
      SBASE=$(basename "$SFILE" .s)
      echo "$PRG: Queuing $SBASE ($FSIZE bytes) for satdump"
      echo "$ID" > "${PENDING_DIR}/${SBASE}.pending"

    elif is_iss; then
      AUDIO=$(find /tmp/.satnogs/data -name "data_${ID}_*.ogg" 2>/dev/null | head -1)
      [ -z "$AUDIO" ] && AUDIO=$(find /tmp/.satnogs/data -name "*.ogg" \
                                   -mmin -90 2>/dev/null | sort | tail -1)
      if [ -z "$AUDIO" ]; then
        echo "$PRG: No audio file found for ISS obs $ID"
        exit 0
      fi
      cp "$AUDIO" "${SSTV_DIR}/${ID}.ogg"

      if [ "$FREQ_INT" -gt 145810000 ]; then
        echo "$ID" > "${PENDING_DIR}/${ID}.aprs"
        echo "$PRG: ISS APRS queued obs $ID (145.825 MHz)"
      else
        echo "$ID" > "${PENDING_DIR}/${ID}.sstv"
        echo "$PRG: ISS SSTV queued obs $ID (145.800 MHz)"
      fi

    else
      echo "$PRG: NORAD ${NORAD:-?} not tracked; skipping"
    fi
    ;;

  *)
    echo "Usage: $0 {start|stop} ID FREQ TLE TIMESTAMP BAUD SCRIPT" >&2
    exit 1
    ;;
esac
