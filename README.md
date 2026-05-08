# SatNOGS Multi-Mode Ground Station

Automated ground station for **Meteor M2-3/M2-4 LRPT weather imagery**, **ISS SSTV** (Robot 36), and **ISS APRS/AX.25 igating** on a Raspberry Pi with an RTL-SDR dongle.

Full build guide: https://chertseyradioclub.blogspot.com/2026/02/build-satnogs-on-raspberry-pi-and.html

---

## Hardware

| Item | Notes |
|---|---|
| Raspberry Pi 3B+ or 4 | Tested on 3B+ |
| RTL-SDR Blog V4 | V3 also works |
| Antenna — VHF 137 MHz | Turnstile or QFH for Meteor |
| Antenna — VHF 145 MHz | Egg-beater or turnstile for ISS |
| USB drive ≥ 29 GB | Storage for recordings and decoded images |

A dual-band 137/145 MHz turnstile can serve both purposes from one antenna.

---

## Quick Install (fresh Raspberry Pi)

```bash
git clone https://github.com/Xyleneuk/satnogs ~/satnogs-station
cd ~/satnogs-station
bash install.sh
```

The installer handles everything: Docker, SatDump, decoders, venv, scripts, crontab.

---

## How It Works

### Meteor M2-3 / M2-4 — LRPT Weather Imagery

The `knegge/satnogs-client:lsf-addons` container demodulates the LRPT signal and writes an LSF soft-symbol file (`LRPT_*.s`). After the pass, `meteor.sh` writes a trigger, and within 2 minutes `satdump_trigger.sh` decodes the `.s` file using satdump's `meteor_m2-x_lrpt` pipeline, selects the best PNG (false-colour preferred), and uploads it to network.satnogs.org via `PUT /api/observations/{id}/`.

> **Why not meteor_decode?** The lsf-addons container writes LSF-format `.s` files, which meteor_decode cannot handle (Viterbi ~1400, 0 MPDUs). satdump decodes them correctly.

### ISS SSTV — Robot 36 Imagery

When the ISS is observed at **145.800 MHz**, the FM audio is captured as an OGG file. After the pass, `meteor.sh` copies the audio to the shared volume and writes a trigger. Within 2 minutes, `sstv_decode.sh` decodes the Robot 36 signal using the `sstv` Python decoder and uploads the resulting PNG to network.satnogs.org.

### ISS APRS — AX.25 Packet Igating

When the ISS is observed at **145.825 MHz**, the audio is decoded by `aprs_decode.sh` using `multimon-ng` (AFSK1200). Decoded TNC2 packets are submitted to APRS-IS (rotate.aprs2.net) by `aprs_upload.py` under your configured callsign, making your station a satellite igate visible on aprs.fi.

---

## Pipelines at a Glance

```
Container (lsf-addons)
  └─ meteor.sh (post-obs, every pass)
       ├─ Meteor LRPT  →  pending/LRPT_*.pending
       ├─ ISS 145.800  →  pending/<obsid>.sstv  +  sstv/<obsid>.ogg
       └─ ISS 145.825  →  pending/<obsid>.aprs  +  sstv/<obsid>.ogg

Host cron (every 2 min)
  ├─ satdump_trigger.sh   → satdump → satnogs_upload.py → SatNOGS network
  ├─ sstv_decode.sh       → sstv    → satnogs_upload.py → SatNOGS network
  └─ aprs_decode.sh       → multimon-ng → aprs_upload.py → APRS-IS (aprs.fi)
```

---

## File Reference

| File | Purpose |
|---|---|
| `install.sh` | One-shot installer for a fresh Raspberry Pi |
| `docker-compose.yml` | satnogs-client + rigctld containers |
| `station.env` | Station credentials and SDR settings — **edit for your station** |
| `meteor.sh` | Post-observation script (runs inside container); routes passes to triggers |
| `satdump_trigger.sh` | Cron every 2 min: decode LRPT .s → upload image to SatNOGS |
| `satdump_decode_lrpt.sh` | Cron every 30 min: fallback decode for missed passes (no upload) |
| `satnogs_upload.py` | Upload PNG to SatNOGS observation via API |
| `sstv_decode.sh` | Cron every 2 min: decode ISS SSTV OGG → upload image to SatNOGS |
| `aprs_decode.sh` | Cron every 2 min: decode ISS APRS OGG → submit packets to APRS-IS |
| `aprs_upload.py` | Submit TNC2 packets to APRS-IS igate |

---

## Manual Setup

### 1. Mount the USB drive

Label the drive `satnogs_data`, then add to `/etc/fstab`:

```
LABEL=satnogs_data  /mnt/satnogs  ext4  defaults,noatime  0  2
```

```bash
sudo mkdir -p /mnt/satnogs
sudo mount /mnt/satnogs
sudo mkdir -p /mnt/satnogs/{pending,sstv,decoded,iq,meteor}
sudo chmod 1777 /mnt/satnogs/pending /mnt/satnogs/sstv
```

### 2. Install Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
# log out and back in
sudo apt-get install -y docker-compose-plugin
```

### 3. Install SatDump

Download the latest `.deb` for your architecture from https://github.com/SatDump/SatDump/releases and install:

```bash
sudo apt-get install -y ./satdump_*.deb
satdump --version
```

### 4. Install system packages

```bash
sudo apt-get install -y multimon-ng sox python3-venv git
```

### 5. Install Python decoders

```bash
python3 -m venv ~/satnogs-venv
~/satnogs-venv/bin/pip install git+https://github.com/colaclanth/sstv.git aprslib
```

### 6. Configure station

Edit `station.env` with your SatNOGS API token, station ID, coordinates, and RF gain.

Copy files to your station directory:

```bash
mkdir -p ~/station
cp docker-compose.yml meteor.sh station.env ~/station/
```

### 7. Configure APRS igate

Create `~/.aprs_config`:

```
APRS_CALLSIGN=M0XYZ-10
SATNOGS_STATION_LAT=51.438
SATNOGS_STATION_LON=-0.458
```

Use an SSID of `-10` for igate stations (APRS convention).

### 8. Install host scripts

```bash
cp satdump_trigger.sh satdump_decode_lrpt.sh satnogs_upload.py \
   sstv_decode.sh aprs_decode.sh aprs_upload.py ~/
chmod +x ~/satdump_trigger.sh ~/satdump_decode_lrpt.sh \
         ~/sstv_decode.sh ~/aprs_decode.sh
```

### 9. Set up crontab

```bash
crontab -e
```

Add:

```
# SatNOGS decode and upload
*/2 * * * * /home/<user>/satdump_trigger.sh
*/2 * * * * /home/<user>/sstv_decode.sh
*/2 * * * * /home/<user>/aprs_decode.sh
*/30 * * * * /home/<user>/satdump_decode_lrpt.sh

# Disk cleanup
0 3 * * * find /mnt/satnogs/iq -type f -mtime +2 -delete
0 3 * * * docker compose -f ~/station/docker-compose.yml exec -T satnogs_client bash -c "find /var/lib/satnogs-client -maxdepth 1 -name 'LRPT_*.s' -mtime +4 -delete" 2>/dev/null
30 3 * * * find /mnt/satnogs/decoded -maxdepth 1 -mindepth 1 -type d -mtime +7 -exec rm -rf {} +
0 4 * * * /usr/bin/docker container prune -f >/dev/null
10 4 * * * /usr/bin/docker image prune -a -f >/dev/null
```

### 10. Start containers

```bash
docker compose -f ~/station/docker-compose.yml up -d
docker compose -f ~/station/docker-compose.yml logs -f
```

---

## Satellites

| Satellite | NORAD | Frequency | Mode | Pipeline |
|---|---|---|---|---|
| Meteor M2-3 | 57166 | 137.900 MHz | LRPT | satdump → SatNOGS image |
| Meteor M2-4 | 59051 | 137.900 MHz | LRPT | satdump → SatNOGS image |
| ISS | 25544 | 145.800 MHz | FM/SSTV | sstv decoder → SatNOGS image |
| ISS | 25544 | 145.825 MHz | FM/APRS | multimon-ng → APRS-IS |

Schedule ISS observations on network.satnogs.org — the station's auto-scheduler will pick them up automatically once the satellites are in your tracked list.

---

## Disk Usage

| File type | Size per pass |
|---|---|
| LRPT `.s` file (good pass) | 60–100 MB |
| Decoded satdump directory | ~20 MB |
| IQ dump (shared, overwritten) | ~500 MB |

On a 29 GB USB with default retention (4-day `.s`, 7-day decoded) expect 3–6 GB used.

---

## Troubleshooting

**No Meteor images on SatNOGS**

```bash
tail -50 /mnt/satnogs/satdump_autodecode.log
```

Common causes:
- `.s` file under 5 MB — pass too weak, nothing to decode
- `satdump_trigger.sh` not running — check `crontab -l` and that the script is executable
- API token wrong — test with `python3 ~/satnogs_upload.py <obs_id> <png_path>`
- `meteor.sh` not bind-mounted — check with `docker compose -f ~/station/docker-compose.yml exec satnogs_client cat /opt/scripts/meteor.sh`

**No SSTV images**

```bash
tail -30 /mnt/satnogs/sstv_decode.log
```

Check that ISS (NORAD 25544) observations at 145.800 MHz are scheduled and that the audio file is being saved (`ls /mnt/satnogs/sstv/`).

**No APRS packets on aprs.fi**

```bash
tail -30 /mnt/satnogs/aprs_decode.log
```

Check `~/.aprs_config` has the correct callsign and coordinates. Verify APRS-IS passcode is valid for your callsign (aprslib computes this automatically from the callsign).

**No signal / blank waterfalls**

The RTL-SDR is sampling (IQ file is written) but receiving only noise — physical antenna issue. Check coax connections at the RTL-SDR SMA port and at the antenna feedpoint.

**GNURadio crash (FATAL: exception not rethrown)**

```bash
docker compose -f ~/station/docker-compose.yml restart
```

Check for a large core dump in `/mnt/satnogs/` and delete it.

**Container not seeing RTL-SDR**

```bash
lsusb | grep RTL
docker compose -f ~/station/docker-compose.yml exec satnogs_client SoapySDRUtil --find
```
