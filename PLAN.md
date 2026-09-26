# TallGrass: plan

A private iOS game for you and a friend: the camera opens, creatures appear
in the room around you, and you each get a few minutes to catch up to six.
Then you battle with real moves and real mechanics. There's no levelling, so
winning comes from luck in the hunt plus how you play the battle.

Private use only: installed through internal TestFlight, never on the App Store.

---

## 1. How a match plays

1. **Lobby.** You and your friend open the app next to each other. One taps
   *Host*, the other *Join* (MultipeerConnectivity, no server or accounts).
   The host picks the rules (hunt length, team size, luck) and a random
   **match seed** is shared.
2. **Hunt (default 3:00).** Both phones start the timer together. Each player
   gets their own spawn schedule, built from the match seed with the same odds
   but a separate stream, so luck is fair without being identical. Walk around, find
   creatures, tap to throw. The hunt ends at time-up or at 6 catches.
3. **Reveal.** Both teams are shown. Each catch was rolled at catch time with a
   random nature, IVs, ability (1 in 8 hidden) and 4 moves from its real Gen 9
   learnset. Shinies are 1 in 128 and cosmetic only.
4. **Battle.** A 6v6 singles battle at level 50 under Scarlet/Violet rules. Each
   phone picks its move. Only the choices are sent between phones; both run the
   same engine from the same seed, so they stay in sync without a server.
5. **Rematch** with the same teams, or **hunt again**.

Solo mode (in the build now): hunt, then battle a CPU team rolled from the same pack.

### Rarity (tuned on the real 476 Violet species)

The tier comes from the game's own catch rate plus base stat total
(`Rarity.classify`). Catch rate alone isn't enough: 139 species share rate 45.

| Tier | Species | Spawn odds | Distance | Stays | 1st-throw catch (perfect aim) | Flee per miss |
|---|---|---|---|---|---|---|
| Common | 133 (Pikachu, Psyduck…) | 52% | 1–3 m | 40–70 s | 85% | 5% |
| Uncommon | 113 (Charmander, Eevee…) | 28% | 1.5–4 m | 30–55 s | 65% | 10% |
| Rare | 143 (Charizard, Gengar…) | 13% | 2.5–5 m | 22–40 s | 45% | 18% |
| Epic | 44 (Dragonite, Garchomp…) | 6% | 3–6 m | 15–30 s | 28% | 25% |
| Legendary | 43 (Mewtwo, Koraidon…) | 1% | 4–7 m | 10–20 s | 12% | 35% |

Rarer creatures also spawn all around you (including behind you), while commons
favour the direction you started facing. A bad throw scales the catch chance down
to 35% of the above; each earlier miss adds +10% (up to +50%). All of these
numbers live in `Packages/TallGrassKit/Sources/TallGrassKit/Rarity.swift` and `Hunt.swift`.

---

## 2. Architecture

```
 PC (Windows)                                   iPhone
 ─────────────────────────────────────          ──────────────────────────────────────
 Violet dump (your NSP, already extracted)       TallGrass.app  (TestFlight, no game art)
   │  Violet repo readers (trpfd/trpfs/Oodle)      ├─ TallGrassKit   rules: seeds, rarity, spawns,
   ▼                                               │                 catching, loadouts, pack format
 pipeline/                                         ├─ Hunt           ARKit + RealityKit camera view
   1 index_species   catalog + personal table      ├─ Battle         JavaScriptCore running
   2 extract_models  raw .trmdl/.trmsh/.bntx…      │                 battle-engine.js (Showdown sim)
   3a convert        → .usdz  (M2)                 └─ Multiplayer    MultipeerConnectivity (M4)
   3b species_data   Showdown names/moves
   4 build_pack      TallGrass.creaturepack ── copied by Files / Apple Devices ──►  Documents/
```

**Why the pack is separate from the app.** TestFlight builds are uploaded to
Apple. Keeping the models out of the binary means Apple's servers and the GitHub
repo never hold game assets, and the app still runs without them (demo pack +
placeholder orbs). The pack stays on your devices.

**Battle engine.** `BattleEngine/` bundles `@pkmn/sim`, the simulator from
Pokémon Showdown (MIT licence), into one 6 MB script, run in JavaScriptCore. That
gives every Gen 9 move, ability, type interaction and damage roll without
reimplementing them. Checked on this PC: it runs with no Node APIs, a full 6v6
finishes, and the same seed plus the same choices produce a byte-identical log
(`npm test`). Two guards keep that true: `Math.random` throws inside the engine,
and wall-clock `|t:|` lines are stripped.

**Data sources.**
| Data | Source |
|---|---|
| Which species exist and have models, catch rates, base stats | your Violet 1.0.1 dump |
| 3D models, textures | your Violet 1.0.1 dump |
| Names, types, abilities, learnsets, battle rules | Showdown via `@pkmn/sim` (MIT) |

---

## 3. Milestones

| # | Milestone | Status | Done when |
|---|---|---|---|
| M0 | Project skeleton | ✅ this commit | XcodeGen project, Kit + tests, CI + TestFlight workflows, pipeline stages 1/2/3b/4, battle engine with determinism test |
| M1 | **First TestFlight build** | ⏭ next | CI green; the app installs; the demo pack hunt works in a real room; CPU battle plays to the end |
| M2 | **Real models** | ⏳ spike | 20 species convert to `.usdz` with textures and look right in AR (see Risks 1–3) |
| M3 | Hunt polish | | throw gesture (swipe with arc), off-screen arrows / radar, catch animation, haptics, sound, results screen with rarity art |
| M4 | **Two-phone match** | | lobby, shared seed, synced timer, team reveal, lockstep battle over MultipeerConnectivity, reconnect handling |
| M5 | Battle presentation | | both creatures shown on a table in AR, HP bars, move animations (or model "attack" clips once animations work), battle log |
| M6 | Extras | | alternate forms, items, Terastallization toggle, best-of-3, match history, in-app "Import Pack" from a zip |

Order of work: **M1 first** (proves the whole Windows → GitHub → TestFlight →
phone loop with zero asset risk), then the **M2 spike** in parallel with M3.
M4 is the core of the game, but it's built on the M1/M3 pieces.

---

## 4. Risks and open questions (found while setting this up)

1. **Model conversion (the big one).** Nothing turns `.trmdl/.trmsh/.trmbf/.trskl/.trmtr`
   into `.usdz` yet, and no Blender importer is installed. Options, in order:
   a. an existing community Trinity importer for Blender, used as an outside tool
      (check its licence; don't copy its code), then Blender 5.2 → USDZ export headless;
   b. our own Blender importer written from the format documentation: pkNX's
      Legends: Arceus schemas (`FlatBuffers/Arceus/Schemas/Poke/Model/*.fbs`) cover
      the same file family, and the Violet catalog layout was already mapped this way.
   Spike goal: Pikachu + Pawmot + Fletchling textured in Blender, then as `.usdz`
   in AR Quick Look on the phone.
2. **Decompression failures.** Some files (e.g. Pawmot's `pm1027_00_00.trmsh`)
   fail with `kraken-decompressor` 0.2.1. `extract_models.py --all` lists every
   one. If the failures turn out to be widespread, look for a better Kraken
   decoder (GPL is fine as a separate process, like the Violet repo does today).
3. **Textures.** `.bntx` is Switch-tiled BC-compressed data and needs
   deswizzling and decoding to PNG before USDZ. Part of the same spike.
4. **Animations.** `.tranm` files aren't referenced by name from the model
   files, so stage 2 doesn't find them yet. Each model has one `.tracn`
   (animation container) that probably holds them by hash. Until solved, models
   are static with a procedural bob/turn, which is fine for M1–M4.
5. **Form mapping.** Game form indices don't always match Showdown's forme order
   (game Pikachu form 1 ≠ "Pikachu-Original"). Only base forms (476 species)
   ship until a mapping table is verified.
6. **AR placement.** Spawns are placed relative to the starting pose and dropped
   onto the nearest detected floor. Cramped rooms will put some inside walls;
   M3 should clamp distance with scene reconstruction or raycasts.
7. **JavaScriptCore start-up.** Parsing the 6 MB bundle takes some time on a
   phone. Measure it in M1; if it's slow, create the context during the hunt.
8. **Nothing has compiled yet.** All Swift here was written on Windows. Expect
   a round of compiler fixes on the first CI run, same as DeckMemo.

---

## 5. Ground rules

- Game assets (anything from the dump, converted models, packs) never go in
  this repo, in a TestFlight build, or anywhere public. `.gitignore` backs this
  up; `pipeline/config.toml` keeps outputs outside the repo.
- TestFlight stays **internal-only** (you + your friend as team members).
- The repo is **public** (for free Mac builds), so it must never contain game
  assets, keys or anything from the dump. If it's ever taken down, make it
  private and pay for minutes.
- The Violet modding repo is only read from, never modified from here.
