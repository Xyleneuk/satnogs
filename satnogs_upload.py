#!/usr/bin/env python3
"""Upload a decoded image to a SatNOGS observation via PUT /api/observations/{id}/."""
import sys
import os
import requests

API_TOKEN = os.environ.get("SATNOGS_API_TOKEN", "")
API_BASE = "https://network.satnogs.org/api"


def upload(obs_id, image_path, token):
    url = "{}/observations/{}/".format(API_BASE, obs_id)
    headers = {"Authorization": "Token " + token}
    with open(image_path, "rb") as f:
        r = requests.put(
            url,
            headers=headers,
            files={"demoddata": (os.path.basename(image_path), f, "image/png")},
            timeout=120,
        )
    return r.status_code


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: satnogs_upload.py <obs_id> <image_path>", file=sys.stderr)
        sys.exit(1)

    obs_id, image_path = sys.argv[1], sys.argv[2]

    # Token from env var or station.env file
    token = API_TOKEN
    if not token:
        env_file = os.path.expanduser("~/station-4113/station-351/station.env")
        try:
            with open(env_file) as f:
                for line in f:
                    if line.startswith("SATNOGS_API_TOKEN="):
                        token = line.split("=", 1)[1].strip()
        except FileNotFoundError:
            pass

    if not token:
        print("Error: SATNOGS_API_TOKEN not set", file=sys.stderr)
        sys.exit(1)

    print("Uploading {} to obs {}...".format(os.path.basename(image_path), obs_id))
    code = upload(obs_id, image_path, token)
    if code == 200:
        print("OK: HTTP {}".format(code))
    else:
        print("FAILED: HTTP {}".format(code))
        sys.exit(1)
