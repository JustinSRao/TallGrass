"""Tiny App Store Connect API helper (read-mostly), for checking TestFlight
state from Windows.

    set ASC_KEY_PATH=C:\\path\\AuthKey_XXXXXXXXXX.p8
    set ASC_ISSUER_ID=...
    python scripts/asc.py apps
    python scripts/asc.py builds com.justinsrao.tallgrass.TallGrass
    python scripts/asc.py bundle-ids

The key never leaves this machine except as a signed, 15-minute JWT.
Needs: pip install pyjwt cryptography
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.request
from pathlib import Path

import jwt

API = "https://api.appstoreconnect.apple.com/v1"


def token() -> str:
    key_path = Path(os.environ["ASC_KEY_PATH"])
    key_id = key_path.stem.removeprefix("AuthKey_")
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        key_path.read_text(), algorithm="ES256", headers={"kid": key_id, "typ": "JWT"})


def call(path: str, method: str = "GET", body: dict | None = None) -> dict:
    req = urllib.request.Request(API + path, method=method,
                                 data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": f"Bearer {token()}",
                                          "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as err:
        sys.exit(f"{err.code} {err.reason}: {err.read().decode()[:500]}")


def main(argv: list[str]) -> None:
    cmd = argv[0] if argv else "apps"
    if cmd == "apps":
        for a in call("/apps?limit=50")["data"]:
            print(a["id"], a["attributes"]["bundleId"], "-", a["attributes"]["name"])
    elif cmd == "bundle-ids":
        for b in call("/bundleIds?limit=50")["data"]:
            print(b["id"], b["attributes"]["identifier"], "-", b["attributes"]["name"])
    elif cmd == "builds":
        apps = call(f"/apps?filter[bundleId]={argv[1]}")["data"]
        if not apps:
            sys.exit("no app record for that bundle ID")
        for b in call(f"/builds?filter[app]={apps[0]['id']}&sort=-uploadedDate&limit=10")["data"]:
            at = b["attributes"]
            print(at["version"], at["processingState"], at["uploadedDate"], "expired" if at.get("expired") else "")
    elif cmd == "testers":
        apps = call(f"/apps?filter[bundleId]={argv[1]}")["data"]
        for g in call(f"/apps/{apps[0]['id']}/betaGroups")["data"]:
            print("group", g["id"], g["attributes"]["name"], "internal" if g["attributes"]["isInternalGroup"] else "external")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
