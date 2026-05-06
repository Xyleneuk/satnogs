# SatNOGS Meteor LRPT Ground Station

Scripts for running a SatNOGS ground station that receives and decodes **Meteor M2-3 and M2-4** LRPT weather satellite images on a Raspberry Pi with an RTL-SDR dongle.

Full setup guide: https://www.blogger.com/blog/post/edit/4032540601938620656/6351701598909335521

---

## Hardware

- Raspberry Pi 3B+ or 4 (tested on 3B+)
- RTL-SDR Blog V4 dongle
- VHF antenna tuned to 137 MHz (turnstile or QFH recommended)
- USB drive for observation storage (29 GB or larger recommended)

---

## How It Works

There are two independent decode pipelines running in parallel:

### 1. SatNOGS network upload (meteor_decode)
The Docker container (`knegge/satnogs-client:lsf-addons`) receives the satellite signal, demodulates it, and saves LRPT soft-symbol files (`LRPT_*.s`) to the USB drive. After each pass the `meteor.sh` post-observation script decodes the `.s` file into a PNG image and places it in `/tmp/.satnogs/data/` named `data_<obs_id>_<timestamp>.png`. The SatNOGS client automatically picks up any `data_*` file in that directory and uploads it to [network.satnogs.org](https://network.satnogs.org) alongside the waterfall and audio, so the decoded image appears on the observation page.

### 2. Local high-quality decode (satdump)
A cron job runs `satdump_decode_lrpt.sh` every 30 minutes. It scans the USB drive for new `.s` files over 10 MB, decodes them with satdump using the `meteor_m2-x_lrpt` pipeline, and saves full-colour MSU-MR channel images to `/mnt/satnogs/decoded/<pass_name>/MSU-MR/`. These stay local â€” they are not uploaded to SatNOGS.

---

## File Structure

| File | Purpose |
|---|---|
| `docker-compose.yml` | Defines the SatNOGS client and rigctld containers |
| `station.env` | Station configuration â€” **edit this for your station** |
| `meteor.sh` | Post-observation script mounted into the container; decodes `.s` files and places images for upload |
| `satdump_decode_lrpt.sh` | Cron script for local satdump decoding |

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

Everything else can stay as-is. The `SATNOGS_POST_OBSERVATION_SCRIPT` line must remain pointing to `/opt/scripts/meteor.sh` â€” that matches the bind mount in `docker-compose.yml`.

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

```bash
sudo apt-get install -y cmake build-essential libfftw3-dev libpng-dev
# Follow https://github.com/SatDump/SatDump for current build instructions
# Binary should end up at /usr/bin/satdump
```

Verify:

```bash
satdump --help
```

### 6. Install the satdump decode script

```bash
cp satdump_decode_lrpt.sh ~/satdump_decode_lrpt.sh
chmod +x ~/satdump_decode_lrpt.sh
```

### 7. Set up crontab

```bash
crontab -e
```

Add these lines:

```
# Decode new LRPT captures with satdump every 30 minutes
*/30 * * * * /home/<user>/satdump_decode_lrpt.sh

# Disk cleanup: remove IQ dumps older than 2 days
0 3 * * * find /mnt/satnogs/iq -type f -mtime +2 -delete

# Disk cleanup: remove LRPT .s files older than 4 days (must use docker exec â€” Docker owns them)
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
| Meteor M2-3 | 57166 | 137.900 MHz | 72k mode (no `-i` flag) |
| Meteor M2-4 | 59051 | 137.900 MHz | 80k interleaved mode (requires `-i` flag in meteor_decode) |

`meteor.sh` automatically detects which satellite is being decoded from the TLE and applies the correct flags.

---

## Disk Usage

With multiple passes per day, the USB fills up quickly without cleanup. Approximate sizes:

- Each LRPT `.s` file (good pass): 60â€“100 MB
- Each decoded satdump directory: ~20 MB
- IQ dump (`iq.raw`, single shared file): ~500 MB

The crontab entries in step 7 handle automatic cleanup. On a 29 GB USB with the defaults (4-day `.s` retention, 7-day decoded retention) you will typically use 3â€“5 GB.

---

## Troubleshooting

**No images on SatNOGS network**

Check the meteor log for the failing observation:
```bash
cat /mnt/satnogs/meteor/meteor_<obs_id>_*.log
```

Common causes:
- Weak pass â€” the `.s` file is under 10 MB, no data to decode
- Wrong NORAD in `METEOR_NORAD` env var
- `meteor.sh` not mounted â€” verify with `docker exec <container> cat /opt/scripts/meteor.sh`

**Verify the bind mount is active:**
```bash
docker exec station-<id>_satnogs_client_1 grep 'deinterleave' /opt/scripts/meteor.sh
```
If that returns nothing, the container needs to be recreated:
```bash
docker compose up -d --force-recreate
```

**Satdump not producing images**

Check the log:
```bash
tail -50 /mnt/satnogs/satdump_autodecode.log
```

If you see `WARN: no images produced`, the pass was too weak for satdump to decode even if the `.s` file exists.

**USB disk filling up**

Check usage:
```bash
df -h /mnt/satnogs
du -sh /mnt/satnogs/LRPT_*.s | sort -h | tail -10
```

The `.s` files are owned by the Docker container user and cannot be deleted directly as the host user. Use `docker exec` as shown in the crontab above.

**Container not seeing the RTL-SDR**

Check USB device permissions and that the dongle appears:
```bash
lsusb | grep RTL
docker exec station-<id>_satnogs_client_1 SoapySDRUtil --find
```
