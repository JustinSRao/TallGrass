"""Stage 1: list every species/form in the Violet dump that has a 3D model.

Joins the game's model catalog (species/form -> model folder, animations)
with the personal table (catch rate, stats). Writes
<work_dir>/species_index.json for the later stages and the rarity model.

    python pipeline/index_species.py
"""

from __future__ import annotations

import json
from collections import Counter

from catalog import CATALOG_PATH, parse_catalog
from common import PERSONAL_PATH, load_config, open_violet

MODEL_PARTS = (".trmdl", ".trskl", ".trmsh", ".trmbf", ".trmtr")


def main() -> None:
    cfg = load_config()
    fs, read_file, PersonalTable = open_violet(cfg)
    from trinity_containers import FlatBuffer  # on sys.path via open_violet

    personal = PersonalTable.parse(read_file(PERSONAL_PATH))
    # The catalog is keyed by the game's INTERNAL species number. For 92 Gen 9
    # species that differs from the national dex number (Pawmot is national
    # 923 but internal 956; internal 923 is Rabsca), so join on internal.
    by_species_form = {(e.detail.species_internal, e.detail.form): e
                       for e in personal.entries}
    catalog = parse_catalog(read_file(CATALOG_PATH), FlatBuffer)

    found, skipped = [], Counter()
    for c in catalog:
        entry = by_species_form.get((c.species, c.form))
        if entry is None or not entry.present:
            skipped["not in personal table / not present"] += 1
            continue
        if c.gender == 1:  # female-difference model; keep the default one only
            skipped["female variant"] += 1
            continue
        base = c.folder + "/" + c.model_path.rsplit("/", 1)[1].removesuffix(".trmdl")
        found.append({
            "national": entry.detail.species_national,
            "internal": c.species,
            "form": c.form,
            "modelFolder": c.folder,
            "modelBase": base,
            "modelComplete": all(fs.has_file(base + ext) for ext in MODEL_PARTS),
            "animationSets": c.animations,
            "catchRate": entry.catch_rate,
            "baseStatTotal": entry.base_stats.total,
            "evolutionStage": entry.evolution_stage,
            "inPaldeaDex": entry.dex is not None,
            "types": [entry.type1, entry.type2],
        })

    cfg.work_dir.mkdir(parents=True, exist_ok=True)
    cfg.index_path.write_text(json.dumps(found, indent=1), encoding="utf-8")
    dex_species = {e.detail.species_national for e in personal.entries
                   if e.present and e.dex and e.detail.form == 0}
    modeled = {e["national"] for e in found}
    print(f"catalog entries:           {len(catalog)}")
    print(f"usable forms:              {len(found)}  ({len(modeled)} species)")
    print(f"skipped:                   {dict(skipped)}")
    print(f"incomplete model files:    {sum(not e['modelComplete'] for e in found)}")
    print(f"Paldea-dex species w/o model: {sorted(dex_species - modeled)}")
    print(f"wrote {cfg.index_path}")


if __name__ == "__main__":
    main()
