# Creature pack pipeline (runs on the Windows PC)

Builds `TallGrass.creaturepack` from **your own** Pokémon Violet dump, using
the readers in the Violet modding repo (`C:\Games\Pokemon Scarlet-Violet\_project`).
Everything it writes goes to `work_dir` from `config.toml`, **outside** this repo.

```sh
copy pipeline\config.example.toml pipeline\config.toml   # once; check the paths
python pipeline\index_species.py                        # 1. what has a model
python pipeline\extract_models.py 25 923                # 2. raw model files (or --all)
#                                                         3a. convert to .usdz (not built yet, see PLAN.md M2)
node   pipeline\species_data.mjs                        # 3b. names/types/moves from Showdown
python pipeline\build_pack.py                           # 4. TallGrass.creaturepack
```

Needs Python 3.11+, Node (with `npm ci` done in `BattleEngine/`), and the
Violet repo's Oodle decompressor (`pip install -r requirements-oodle.txt` there).

| Stage | Status | Output |
|---|---|---|
| 1 `index_species.py` | ✅ works | `species_index.json`: 609 forms / 476 species, all with complete model files |
| 2 `extract_models.py` | ✅ works (see caveats) | `raw/<national>_<form>/`: mesh, skeleton, materials, textures |
| 3a model → `.usdz` | ❌ not built | `models/<key>.usdz` |
| 3b `species_data.mjs` | ✅ works | `species_data.json`: 476 base forms with Gen 9 move pools |
| 4 `build_pack.py` | ✅ works | pack with manifest; placeholders where models are missing |

Caveats found while building this (details in `PLAN.md` › Risks):
- Model folder numbers are **not** national dex numbers for some species
  (Pyroar is in `pm0705`). Stage 1 reads the game's own catalog
  (`pokemon/catalog/catalog/poke_resource_table.trpmcatalog`) instead of guessing.
- Some mesh files fail to decode with `kraken-decompressor` 0.2.1 (Pawmot's
  `pm1027_00_00.trmsh`, for example). `extract_models.py --all` prints every failure.
- Animation (`.tranm`) files aren't named by the model files, so stage 2
  doesn't find them yet.
- Alternate forms (regional forms, Rotom appliances …) are left out until the
  game-form → Showdown-forme mapping is verified.
