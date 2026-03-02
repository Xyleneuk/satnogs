#!/bin/bash
# Meteor LRPT demod+decode helper for SatNOGS
# Expected args: {start|stop} {ID} {FREQ} {TLE_JSON} {TIMESTAMP} {BAUD} {SCRIPT_NAME}

set -euo pipefail

CMD="${1:-}"
ID="${2:-}"
FREQ="${3:-}"          # may be unused, but keep positional compatibility
TLE="${4:-}"
DATE="${5:-}"
BAUD="${6:-}"
SCRIPT="${7:-}"

PRG="Meteor demod+decode"

# Defaults (allow override via env)
: "${METEOR_NORAD:=57166 59051}"
: "${SATNOGS_APP_PATH:=/tmp/.satnogs}"
: "${SATNOGS_OUTPUT_PATH:=/tmp/.satnogs/data}"
: "${SATNOGS_STATION_ID:=0}"

# Tools we rely on
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "$PRG: missing required command: $1" >&2; exit 1; }; }

need_cmd awk
need_cmd sed
need_cmd jq
need_cmd meteor_demod
need_cmd meteor_decode

METEOR_PID="$SATNOGS_APP_PATH/meteor_${SATNOGS_STATION_ID}.pid"
IMAGE="$SATNOGS_OUTPUT_PATH/data_${ID}_${DATE}.png"

# Extract sat name and NORAD from SatNOGS-provided TLE JSON
# (jq -r to avoid quotes)
SATNAME="$(echo "$TLE" | jq -r '.tle0 // "UNKNOWN"' | sed -e 's/ /_/g' -e 's/[^A-Za-z0-9._-]//g')"
NORAD="$(echo "$TLE" | jq -r '.tle2 // ""' | awk '{print $2}' | tr -cd '0-9')"

is_meteor_target() {
  # If METEOR_NORAD is unset => treat as enabled for all
  # If set => only run when NORAD is in list
  if [ -z "${METEOR_NORAD+x}" ]; then
    return 0
  fi
  case " ${METEOR_NORAD} " in
    *" ${NORAD} "*) return 0 ;;
    *) return 1 ;;
  esac
}

log_header() {
  echo "$PRG: Observation: $ID, Norad: ${NORAD:-UNKNOWN}, Name: $SATNAME, Script: $SCRIPT, Baud: $BAUD, Freq: $FREQ MHz"
}

# Determine IQ path.
# Prefer SATNOGS_IQ_FILE if your SatNOGS setup exports it.
# Fallback to the common output naming pattern.
IQ_FILE="${SATNOGS_IQ_FILE:-$SATNOGS_OUTPUT_PATH/iq_${ID}_${DATE}.raw}"

case "${CMD^^}" in
  START)
    # START is typically just logging/marker; actual decode happens on STOP once IQ exists.
    if is_meteor_target; then
      log_header
      echo "$PRG: START received. Will decode on STOP if IQ exists at: $IQ_FILE"
      # Optional marker file so you can confirm hooks ran
      mkdir -p "$SATNOGS_APP_PATH" "$SATNOGS_OUTPUT_PATH"
      echo "$ID" > "$METEOR_PID"
 else
      echo "$PRG: START received but NORAD ${NORAD:-UNKNOWN} not in METEOR_NORAD list; skipping."
    fi
    ;;

  STOP)
    if ! is_meteor_target; then
      echo "$PRG: STOP received but NORAD ${NORAD:-UNKNOWN} not in METEOR_NORAD list; skipping."
      exit 0
    fi

    log_header

    if [ ! -s "$IQ_FILE" ]; then
      echo "$PRG: ERROR: IQ file not found or empty: $IQ_FILE" >&2
      echo "$PRG: Hint: ensure IQ dumping is enabled and SATNOGS_IQ_FILE (or naming) matches your pipeline." >&2
      exit 2
    fi

    mkdir -p "$(dirname "$IMAGE")"

    # Your known-good settings (note -r 72000)
    # meteor_demod writes frames to stdout; meteor_decode reads from stdin
    echo "$PRG: Decoding IQ -> $IMAGE"
    meteor_demod --batch --quiet -O 8 -f 128 -s 160000 -r 72000 -m oqpsk --bps 16 "$IQ_FILE" - \
      | meteor_decode --diff -a 65,65,64 -o "$IMAGE" -

    if [ -s "$IMAGE" ]; then
      echo "$PRG: OK: wrote $IMAGE"
    else
      echo "$PRG: ERROR: decode completed but image missing/empty: $IMAGE" >&2
      exit 3
    fi

    rm -f "$METEOR_PID" || true
    ;;

  *)
    echo "Usage: $0 {start|stop} {ID} {FREQ} {TLE_JSON} {TIMESTAMP} {BAUD} {SCRIPT_NAME}" >&2
    exit 1
    ;;
esac
