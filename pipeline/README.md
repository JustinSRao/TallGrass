# Creature pack pipeline (runs on the Windows PC)

Builds `TallGrass.creaturepack` from **your own** Pokémon Violet dump, using
the readers in the Violet modding repo (`C:\Games\Pokemon Scarlet-Violet\_project`).
Everything it writes goes to `work_dir` from `config.toml`, **outside** this repo.

```sh
copy pipeline\config.example.toml pipeline\config.toml   # once; check the paths
python pipeline\build_all.py                            # everything; re-runs skip finished work
```

Then zip `<work_dir>\pack\TallGrass.creaturepack` (or just the folder) into
iCloud Drive / OneDrive and use **Import Pack…** in the app.

## Stages

| Stage | Script | Output (in `work_dir`) |
|---|---|---|
| 1 | `index_species.py` | `species_index.json`: every species/form with a model (joins the game's model catalog on the **internal** species number) |
| 2 | `extract_models.py --all` | `raw/<dex>_<form>/`: mesh, skeleton, materials, `.bntx` textures |
| 3a | `convert_models.py` | `models/<dex>_00.usdz` + `_rare.usdz` (shiny) + `previews/<dex>_00.png` |
| 3b | `species_data.mjs` | `species_data.json`: names, types, abilities, Gen 9 move pools from Showdown |
| 4 | `build_pack.py [--no-shiny]` | `pack/TallGrass.creaturepack/` (manifest + models) |

Helpers: `bntx.py` (Switch texture → PNG), `blender_convert.py` (runs inside
Blender), `catalog.py` (model catalog reader), `common.py` (config + dump access).

## One-time tool setup

- Python 3.11+ with `pip install numpy pillow texture2ddecoder pyooz`
  (`pyooz` is GPL and only ever runs in a separate process).
- The Violet repo's Oodle decoder: `pip install -r requirements-oodle.txt` there.
- Node, with `npm ci` done in `BattleEngine/`.
- Blender 5.2, plus in `<work_dir>\tools\`:
  - `sv_importer\`: `git clone https://github.com/ChicoEevee/Pokemon-Switch-Model-Importer-Blender sv_importer`
    (no licence, so it's run locally as a tool and never copied into this repo)
  - `blender_site\`: `"<blender>\5.2\python\bin\python.exe" -m pip install flatbuffers --target blender_site`

## Things this pipeline learned the hard way

- Model folders are keyed by the game's **internal** species number, which
  differs from the dex number for 92 Gen 9 species (Pawmot: dex 923, internal 956).
- `kraken-decompressor` 0.2.1 overruns its buffer on ~50 small files; `pyooz`
  decodes those (byte-identical on files both can read).
- The importer's shader uses Eevee-only nodes that bake black in Cycles, so the
  converter bakes the shader's *base colour* as emission instead.
- Materials sit in different UV tiles (Pikachu's hands at v 1..2), so each
  material's UVs are shifted into 0..1 before baking.
- Converted models are Y-up, in metres, feet at y = 0, facing +Z.
- Alternate forms are left out until game form → Showdown forme is verified.
