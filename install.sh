#!/bin/bash
# install.sh — SatNOGS Meteor LRPT + ISS SSTV + ISS APRS ground station installer
#
# Tested on Raspberry Pi OS Bookworm (64-bit, arm64)
# Run as your normal user (not root) — the script uses sudo where needed.
#
# What this installs:
#   - Docker + satnogs-client:lsf-addons container
#   - SatDump (Meteor LRPT decoder)
#   - multimon-ng + sox (APRS/AFSK decoder)
#   - Python venv with sstv + aprslib
#   - All decode/upload scripts + crontab
#
# Usage:
#   git clone https://github.com/Xyleneuk/satnogs ~/satnogs-station
#   cd ~/satnogs-station
#   bash install.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATION_DIR="$HOME/station"
VENV="$HOME/satnogs-venv"
SCRIPTS=(satdump_trigger.sh satdump_decode_lrpt.sh satnogs_upload.py
         sstv_decode.sh aprs_decode.sh aprs_upload.py)

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; B='\033[1;34m'; N='\033[0m'
info()  { echo -e "${G}[+]${N} $*"; }
warn()  { echo -e "${Y}[!]${N} $*"; }
die()   { echo -e "${R}[✗]${N} $*" >&2; exit 1; }
title() { echo -e "\n${B}=== $* ===${N}"; }

# ── 0. Sanity checks ────────────────────────────────────────────────────────
[ "$(id -u)" = "0" ] && die "Run as a normal user, not root."
command -v sudo >/dev/null || die "sudo is required."

title "SatNOGS Ground Station Installer"
echo "This installs Meteor LRPT + ISS SSTV + ISS APRS igate on a Raspberry Pi."
echo "You will need: RTL-SDR Blog V4, VHF antenna (137/145 MHz), USB storage."
echo ""

# ── 1. Gather configuration ──────────────────────────────────────────────────
title "Station Configuration"
read -rp "SatNOGS API token (network.satnogs.org → Profile → API key): " API_TOKEN
read -rp "Station ID (from network.satnogs.org): " STATION_ID
read -rp "Latitude  (decimal degrees, e.g. 51.438): " LAT
read -rp "Longitude (decimal degrees, e.g. -0.458): " LON
read -rp "Elevation (metres above sea level):       " ELEV
read -rp "RF gain   (0-49, suggest 35 for RTL-SDR Blog V4): " RF_GAIN
read -rp "PPM error correction (0 if unsure):       " PPM
read -rp "APRS igate callsign (e.g. M0XYZ-10):     " APRS_CALLSIGN

[[ -z "$API_TOKEN" || -z "$STATION_ID" || -z "$LAT" || -z "$LON" ]] && \
    die "API token, station ID, latitude and longitude are required."

# ── 2. USB storage ───────────────────────────────────────────────────────────
title "USB Storage"
if mountpoint -q /mnt/satnogs 2>/dev/null; then
    info "/mnt/satnogs is mounted — $(df -h /mnt/satnogs | tail -1 | awk '{print $4}') free"
else
    warn "/mnt/satnogs is not mounted."
    echo ""
    echo "  Label your USB drive 'satnogs_data' and add to /etc/fstab:"
    echo "    LABEL=satnogs_data  /mnt/satnogs  ext4  defaults,noatime  0  2"
    echo ""
    echo "  Then mount it:"
    echo "    sudo mkdir -p /mnt/satnogs && sudo mount /mnt/satnogs"
    echo ""
    read -rp "Press Enter once mounted, or Ctrl+C to abort..."
    mountpoint -q /mnt/satnogs || die "/mnt/satnogs still not mounted."
fi

info "Creating data directories..."
sudo mkdir -p /mnt/satnogs/{pending,sstv,decoded,iq,meteor}
sudo chmod 1777 /mnt/satnogs/pending /mnt/satnogs/sstv
sudo chown "$USER": /mnt/satnogs/decoded /mnt/satnogs/meteor 2>/dev/null || true

# ── 3. System packages ───────────────────────────────────────────────────────
title "System Packages"
info "Updating package lists..."
sudo apt-get update -qq

info "Installing multimon-ng, sox, python3-venv, git..."
sudo apt-get install -y -qq multimon-ng sox python3-venv git wget curl \
    2>&1 | grep -E "^(Setting up|Installed)" || true

# ── 4. Docker ────────────────────────────────────────────────────────────────
title "Docker"
if command -v docker &>/dev/null; then
    info "Docker already installed: $(docker --version)"
else
    info "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER"
    warn "Docker installed. You MUST log out and back in before running Docker commands."
    warn "After re-login, re-run: cd $REPO_DIR && bash install.sh --skip-docker"
    NEEDS_RELOGIN=1
fi

if ! command -v docker &>/dev/null || ! docker compose version &>/dev/null 2>&1; then
    info "Installing docker-compose-plugin..."
    sudo apt-get install -y -qq docker-compose-plugin 2>&1 | grep "Setting up" || true
fi

# ── 5. SatDump ───────────────────────────────────────────────────────────────
title "SatDump"
if command -v satdump &>/dev/null; then
    info "SatDump already installed: $(satdump --version 2>&1 | head -1)"
else
    info "Fetching latest SatDump release..."
    ARCH=$(dpkg --print-architecture)
    TMP=$(mktemp -d)

    DEB_URL=$(curl -s https://api.github.com/repos/SatDump/SatDump/releases/latest \
        | grep "browser_download_url" \
        | grep -i "${ARCH}.*\.deb\|\.deb.*${ARCH}" \
        | head -1 \
        | cut -d'"' -f4)

    if [ -n "$DEB_URL" ]; then
        info "Downloading $DEB_URL..."
        wget -q --show-progress -O "$TMP/satdump.deb" "$DEB_URL"
        sudo apt-get install -y "$TMP/satdump.deb"
        rm -rf "$TMP"
        info "SatDump installed: $(satdump --version 2>&1 | head -1)"
    else
        warn "Could not find a SatDump .deb for arch '$ARCH'."
        warn "Install manually from: https://github.com/SatDump/SatDump/releases"
        warn "Then re-run this script."
    fi
fi

# ── 6. Python venv ───────────────────────────────────────────────────────────
title "Python Environment"
info "Creating venv at $VENV..."
python3 -m venv "$VENV"

info "Installing sstv decoder..."
"$VENV/bin/pip" install -q git+https://github.com/colaclanth/sstv.git

info "Installing aprslib..."
"$VENV/bin/pip" install -q aprslib

"$VENV/bin/python" -m sstv --version 2>&1 | head -1 && info "sstv decoder OK"
"$VENV/bin/python" -c "import aprslib; print('aprslib OK')"

# ── 7. Station config ────────────────────────────────────────────────────────
title "Station Configuration Files"
mkdir -p "$STATION_DIR"

info "Writing station.env..."
cat > "$STATION_DIR/station.env" << EOF
SATNOGS_API_TOKEN=${API_TOKEN}
SATNOGS_SOAPY_RX_DEVICE=driver=rtlsdr
SATNOGS_ANTENNA=RX
SATNOGS_RX_SAMP_RATE=2.048e6
SATNOGS_PPM_ERROR=${PPM}
SATNOGS_RF_GAIN=${RF_GAIN}
SATNOGS_STATION_ELEV=${ELEV}
SATNOGS_STATION_ID=${STATION_ID}
SATNOGS_STATION_LAT=${LAT}
SATNOGS_STATION_LON=${LON}
SATNOGS_LOG_LEVEL=INFO
SATNOGS_POST_OBSERVATION_SCRIPT=/opt/scripts/meteor.sh stop {{ID}} {{FREQ}} {{TLE}} {{TIMESTAMP}} {{BAUD}} {{SCRIPT_NAME}}
UDP_DUMP_HOST=0.0.0.0
METEOR_NORAD=57166 59051
ENABLE_IQ_DUMP=True
IQ_DUMP_FILENAME=/var/lib/satnogs-client/iq/iq.raw
SATNOGS_RIG_IP=rigctld
SATNOGS_RIG_PORT=4532
EOF
chmod 600 "$STATION_DIR/station.env"

info "Writing APRS config..."
cat > "$HOME/.aprs_config" << EOF
APRS_CALLSIGN=${APRS_CALLSIGN}
SATNOGS_STATION_LAT=${LAT}
SATNOGS_STATION_LON=${LON}
EOF
chmod 600 "$HOME/.aprs_config"

info "Copying docker-compose.yml and meteor.sh..."
cp "$REPO_DIR/docker-compose.yml" "$STATION_DIR/"
cp "$REPO_DIR/meteor.sh" "$STATION_DIR/"

# ── 8. Host scripts ──────────────────────────────────────────────────────────
title "Decode Scripts"
info "Installing scripts to $HOME..."
for script in "${SCRIPTS[@]}"; do
    cp "$REPO_DIR/$script" "$HOME/$script"
done
chmod +x "$HOME/satdump_trigger.sh" "$HOME/satdump_decode_lrpt.sh" \
         "$HOME/sstv_decode.sh" "$HOME/aprs_decode.sh"

# Patch VENV path and USER into scripts
for script in satdump_trigger.sh sstv_decode.sh aprs_decode.sh; do
    sed -i "s|/home/james/|$HOME/|g" "$HOME/$script"
done

# ── 9. Crontab ───────────────────────────────────────────────────────────────
title "Crontab"
info "Setting up crontab..."
TMPCT=$(mktemp)
crontab -l 2>/dev/null \
    | grep -v "satdump_trigger\|satdump_decode_lrpt\|sstv_decode\|aprs_decode\|satnogs/iq\|satnogs/decoded\|docker.*prune" \
    > "$TMPCT" || true

cat >> "$TMPCT" << CRON
# SatNOGS decode + upload (every 2 min)
*/2 * * * * $HOME/satdump_trigger.sh
*/2 * * * * $HOME/sstv_decode.sh
*/2 * * * * $HOME/aprs_decode.sh
# SatNOGS fallback decode (every 30 min, no upload)
*/30 * * * * $HOME/satdump_decode_lrpt.sh
# Disk cleanup
0 3 * * * find /mnt/satnogs/iq -type f -mtime +2 -delete
0 3 * * * docker compose -f $STATION_DIR/docker-compose.yml exec -T satnogs_client bash -c "find /var/lib/satnogs-client -maxdepth 1 -name 'LRPT_*.s' -mtime +4 -delete" 2>/dev/null
30 3 * * * find /mnt/satnogs/decoded -maxdepth 1 -mindepth 1 -type d -mtime +7 -exec rm -rf {} +
# Docker housekeeping
0 4 * * * /usr/bin/docker container prune -f >/dev/null
10 4 * * * /usr/bin/docker image prune -a -f >/dev/null
CRON

crontab "$TMPCT"
rm "$TMPCT"
info "Crontab updated."

# ── 10. Start containers ─────────────────────────────────────────────────────
title "Docker Containers"
if [ "${NEEDS_RELOGIN:-0}" = "1" ]; then
    warn "Skipping container start — you need to log out/in first for Docker group access."
else
    info "Starting containers..."
    docker compose -f "$STATION_DIR/docker-compose.yml" up -d
    docker compose -f "$STATION_DIR/docker-compose.yml" ps
fi

# ── Done ─────────────────────────────────────────────────────────────────────
title "Installation Complete"
echo ""
echo "  Station ID : $STATION_ID"
echo "  Data path  : /mnt/satnogs/"
echo "  Station dir: $STATION_DIR/"
echo "  APRS igate : $APRS_CALLSIGN"
echo ""
echo "  Logs:"
echo "    Meteor/LRPT : /mnt/satnogs/satdump_autodecode.log"
echo "    ISS SSTV    : /mnt/satnogs/sstv_decode.log"
echo "    ISS APRS    : /mnt/satnogs/aprs_decode.log"
echo ""
echo "  Satellites tracked automatically:"
echo "    Meteor M2-3 (NORAD 57166) — 137.900 MHz LRPT"
echo "    Meteor M2-4 (NORAD 59051) — 137.900 MHz LRPT"
echo "    ISS (NORAD 25544)         — 145.800 MHz SSTV / 145.825 MHz APRS"
echo ""
if [ "${NEEDS_RELOGIN:-0}" = "1" ]; then
    echo -e "${Y}ACTION REQUIRED:${N}"
    echo "  Log out and back in, then start containers:"
    echo "    docker compose -f $STATION_DIR/docker-compose.yml up -d"
    echo ""
fi
echo "  Verify RTL-SDR is detected:"
echo "    docker compose -f $STATION_DIR/docker-compose.yml exec satnogs_client SoapySDRUtil --find"
echo ""
