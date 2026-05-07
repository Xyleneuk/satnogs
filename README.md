# SatNOGS Meteor LRPT Ground Station

Scripts for running a SatNOGS ground station that receives and decodes **Meteor M2-3 and M2-4** LRPT weather satellite images on a Raspberry Pi with an RTL-SDR dongle.

Full setup guide: https://chertseyradioclub.blogspot.com/2026/02/build-satnogs-on-raspberry-pi-and.html

---

## Hardware

- Raspberry Pi 3B+ or 4 (tested on 3B+)
- RTL-SDR Blog V4 dongle
- VHF antenna tuned to 137 MHz (turnstile or QFH recommended)
- USB drive for observation storage (29 GB or larger recommended)

---

## How It Works

After each Meteor pass, the pipeline runs in two stages:

### 1. Decode + network upload (satdump_trigger.sh, every 2 min)
The Docker container (`knegge/satnogs-client:lsf-addons`) demodulates the satellite signal and saves an LRPT soft-symbol file (`LRPT_*.s`) to the USB drive. When the pass ends, `meteor.sh` (the post-observation script) writes a trigger file containing the SatNOGS observation ID. Within 2 minutes, `satdump_trigger.sh` (running as a cron job on the host) picks up the trigger, decodes the `.s` file with satdump using the `meteor_m2-x_lrpt` pipeline, selects the best PNG (false-colour composite preferred), and uploads it to [network.satnogs.org](https://network.satnogs.org) via `PUT /api/observations/{id}/`. The image then appears on the observation page alongside the waterfall and audio.

> **Why not meteor_decode?** The `lsf-addons` container writes files in LSF (LRPT Soft-symbol Format), which is incompatible with `meteor_decode`. satdump handles LSF correctly.

### 2. Backup decode (satdump_decode_lrpt.sh, every 30 min)
A fallback cron job scans for any `.s` files that were not processed by the trigger script (e.g., Pi was offline during a pass) and decodes them locally. These images are saved to `/mnt/satnogs/decoded/` for review but are not uploaded to SatNOGS automatically.

---

## File Structure

| File | Purpose |
|---|---|
| `docker-compose.yml` | Defines the SatNOGS client and rigctld containers |
| `station.env` | Station configuration — **edit this for your station** |
| `meteor.sh` | Post-observation script (bind-mounted into container); writes decode trigger |
| `satdump_trigger.sh` | Cron script (every 2 min): decode + upload to SatNOGS network |
| `satnogs_upload.py` | Python helper called by satdump_trigger.sh to upload via API |
| `satdump_decode_lrpt.sh` | Fallback cron script (every 30 min): local-only decode for missed passes |

---

## Setup

### 1. Mount the USB drive

Label the USB drive `satnogs_data` (or adjust the paths below), then add it to `/etc/fstab` for auto-mount:

```
LABEL=satnogs_data  /mnt/satnogs  ext4  defaults,noatime  0  2
```

Create the directory and mount it:

```bash
sudo mkdir -p /mnt/satnogs
sudo mount /mnt/satnogs
```

Create the trigger directory (world-writable so both the Docker container and the host user can create files):

```bash
sudo mkdir -p /mnt/satnogs/pending
sudo chmod 1777 /mnt/satnogs/pending
```

### 2. Clone this repo

```bash
mkdir -p ~/station-<your_station_id>
cd ~/station-<your_station_id>
git clone https://github.com/Xyleneuk/satnogs .
```

### 3. Configure station.env

Edit `station.env` and set your values:

```bash
SATNOGS_API_TOKEN=<your_token_from_network.satnogs.org>
SATNOGS_STATION_ID=<your_station_id>
SATNOGS_STATION_LAT=<latitude>
SATNOGS_STATION_LON=<longitude>
SATNOGS_STATION_ELEV=<elevation_metres>
SATNOGS_RF_GAIN=<gain_0_to_49>       # start around 30-40, tune for your setup
SATNOGS_PPM_ERROR=<ppm>              # RTL-SDR frequency correction
```

Everything else can stay as-is. The `SATNOGS_POST_OBSERVATION_SCRIPT` line must remain pointing to `/opt/scripts/meteor.sh` — that matches the bind mount in `docker-compose.yml`.

### 4. Install Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
# log out and back in
```

Install Docker Compose plugin:

```bash
sudo apt-get install -y docker-compose-plugin
```

### 5. Install satdump

Follow the build instructions at https://github.com/SatDump/SatDump. The binary should end up at `/usr/bin/satdump`.

Verify:

```bash
satdump --help
```

### 6. Install the host scripts

```bash
cp satdump_trigger.sh ~/satdump_trigger.sh
cp satdump_decode_lrpt.sh ~/satdump_decode_lrpt.sh
cp satnogs_upload.py ~/satnogs_upload.py
chmod +x ~/satdump_trigger.sh ~/satdump_decode_lrpt.sh ~/satnogs_upload.py
```

Set your API token in `satnogs_upload.py` (or set the `SATNOGS_API_TOKEN` environment variable).

### 7. Set up crontab

```bash
crontab -e
```

Add these lines:

```
# Decode + upload new LRPT captures within 2 min of pass end
*/2 * * * * /home/<user>/satdump_trigger.sh

# Fallback: decode any .s files missed by the trigger (local only)
*/30 * * * * /home/<user>/satdump_decode_lrpt.sh

# Disk cleanup: remove IQ dumps older than 2 days
0 3 * * * find /mnt/satnogs/iq -type f -mtime +2 -delete

# Disk cleanup: remove LRPT .s files older than 4 days (must use docker exec — Docker owns them)
0 3 * * * docker exec station-<id>_satnogs_client_1 bash -c "find /var/lib/satnogs-client -maxdepth 1 -name 'LRPT_*.s' -mtime +4 -delete" 2>/dev/null

# Disk cleanup: remove decoded image directories older than 7 days
30 3 * * * find /mnt/satnogs/decoded -maxdepth 1 -mindepth 1 -type d -mtime +7 -exec rm -rf {} +

# Docker housekeeping
0 4 * * * /usr/bin/docker container prune -f >/dev/null
10 4 * * * /usr/bin/docker image prune -a -f >/dev/null
20 4 * * * /usr/bin/docker volume prune -f >/dev/null
30 4 * * * /usr/bin/docker network prune -f >/dev/null
```

### 8. Start the containers

```bash
docker compose up -d
docker compose logs -f
```

The SatNOGS client will contact the network, fetch scheduled observations, and start receiving passes automatically.

---

## Satellites

Both Meteor M2-3 and M2-4 are tracked:

| Satellite | NORAD | Frequency | Notes |
|---|---|---|---|
| Meteor M2-3 | 57166 | 137.900 MHz | 72k standard mode |
| Meteor M2-4 | 59051 | 137.900 MHz | 80k interleaved mode |

`satdump` handles both satellites automatically via the `meteor_m2-x_lrpt` pipeline.

---

## Disk Usage

With multiple passes per day, the USB fills up quickly without cleanup. Approximate sizes:

- Each LRPT `.s` file (good pass): 60–100 MB
- Each decoded satdump directory: ~20 MB
- IQ dump (`iq.raw`, single shared file): ~500 MB

The crontab entries in step 7 handle automatic cleanup. On a 29 GB USB with the defaults (4-day `.s` retention, 7-day decoded retention) you will typically use 3–5 GB.

---

## Troubleshooting

**No images appearing on SatNOGS network**

Check the satdump log:
```bash
tail -50 /mnt/satnogs/satdump_autodecode.log
```

Check the meteor post-obs log for a specific observation:
```bash
cat /mnt/satnogs/meteor/meteor_<obs_id>.log
```

Common causes:
- Weak pass — the `.s` file is under 5 MB, nothing to decode
- `satdump_trigger.sh` not running — check `crontab -l` and that the script is executable
- `satnogs_upload.py` token wrong — test with `python3 ~/satnogs_upload.py <obs_id> <png_path>`
- `meteor.sh` not bind-mounted — verify with `docker exec <container> cat /opt/scripts/meteor.sh`

**Verify the bind mount is active:**
```bash
docker exec station-<id>_satnogs_client_1 grep 'PENDING_DIR' /opt/scripts/meteor.sh
```
If that returns nothing, the container needs to be recreated:
```bash
docker compose up -d --force-recreate
```

**Satdump not producing images**

If you see `WARN: no images produced` in the log, the pass was too weak for satdump to decode even if the `.s` file exists (typically < 5 MB or poor Viterbi lock).

**USB disk filling up**

Check usage:
```bash
df -h /mnt/satnogs
du -sh /mnt/satnogs/LRPT_*.s | sort -h | tail -10
```

The `.s` files are owned by the Docker container user and cannot be deleted directly as the host user. Use `docker exec` as shown in the crontab above.

**Container not seeing the RTL-SDR**

```bash
lsusb | grep RTL
docker exec station-<id>_satnogs_client_1 SoapySDRUtil --find
```

**GNURadio crash (FATAL: exception not rethrown)**

This silently stops `.s` file output while the container keeps running. Fix with:
```bash
docker compose restart
```
Check for a large core dump file in `/mnt/satnogs/` and delete it if present.
