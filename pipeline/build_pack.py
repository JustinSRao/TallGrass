"""Stage 4: assemble TallGrass.creaturepack for the phone.

Joins species_data.json (stage 3) with any converted models in
<work_dir>/models/<modelKey>.usdz and writes:

    <work_dir>/pack/TallGrass.creaturepack/
        manifest.json          (read by TallGrassKit.CreaturePack)
        models/<modelKey>.usdz

Species without a converted model are still included; the app draws a
placeholder for them, so the pack is playable before model conversion works.

    python pipeline/build_pack.py                 # all base forms
    python pipeline/build_pack.py --only-modeled  # just species with a .usdz
"""

from __future__ import annotations

import argparse
import json
import shutil
from datetime import datetime, timezone

from common import load_config

FORMAT_VERSION = 1  # must match CreaturePack.formatVersion in TallGrassKit
AIR_ABILITIES = {"Levitate"}


def habitat(s: dict) -> str:
    if s["types"][0] == "Flying" or AIR_ABILITIES & set(s["abilities"]):
        return "air"
    if s["types"] == ["Water"]:
        return "water"
    return "ground"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--only-modeled", action="store_true")
    args = ap.parse_args()

    cfg = load_config()
    data = json.loads((cfg.work_dir / "species_data.json").read_text(encoding="utf-8"))
    models_in = cfg.work_dir / "models"
    out = cfg.pack_dir
    if out.exists():
        shutil.rmtree(out)
    (out / "models").mkdir(parents=True)

    species, with_model = [], 0
    for s in data:
        if s["form"] != 0:  # alternate forms need a verified form mapping first
            continue
        usdz = models_in / f"{s['modelKey']}.usdz"
        has_model = usdz.exists()
        if args.only_modeled and not has_model:
            continue
        if has_model:
            shutil.copy2(usdz, out / "models" / usdz.name)
            with_model += 1
        species.append({
            "id": s["id"], "name": s["name"], "national": s["national"],
            "types": s["types"], "abilities": s["abilities"],
            "hiddenAbility": s["hiddenAbility"], "catchRate": s["catchRate"],
            "baseStatTotal": s["baseStatTotal"], "isLegendary": s["isLegendary"],
            "isMythical": s["isMythical"], "isParadox": s["isParadox"],
            "modelKey": s["modelKey"] if has_model else None,
            "habitat": habitat(s), "movePool": s["movePool"],
        })

    manifest = {
        "formatVersion": FORMAT_VERSION,
        "name": "Violet 1.0.1",
        "builtAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "species": species,
    }
    (out / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
    size = sum(f.stat().st_size for f in out.rglob("*") if f.is_file())
    print(f"{len(species)} species, {with_model} with 3D models, {size / 1e6:.1f} MB")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
