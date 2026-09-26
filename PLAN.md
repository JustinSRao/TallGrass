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

Status legend: ✅ built and passing CI (compiled + automated tests on GitHub's Macs)
· 📱 needs a real-phone check (AR, camera, two phones can't run in CI).

| # | Milestone | Status | What exists |
|---|---|---|---|
| M0 | Project skeleton | ✅ | XcodeGen project, Kit + tests, CI + TestFlight workflows, pipeline, battle engine with determinism test |
| M1 | First TestFlight build | ✅ | Build 1 uploaded and valid; internal group created with you in it |
| M2 | Real models | ✅ 📱 | All 476 species: extract → decode textures → Blender import → bake colours → USDZ (+ shiny). Spot-checked renders; looks in AR need your eyes |
| M3 | Hunt polish | ✅ 📱 | Swipe throw on an arc (aim + power), capture sequence, creatures face you, rarer ones wander, edge arrows, haptics, team strip |
| M4 | Two-phone match | ✅ 📱 | MultipeerConnectivity lobby, host rules, synced countdown, live progress, reveal, lockstep battle (two simulated phones stay identical in CI), rematch / hunt again, disconnect handling |
| M5 | Battle presentation | ✅ 📱 | 3D stage with both creatures, send-out / lunge / hit / faint animations, HP bars, status, readable log |
| M6 | Extras | partial | Done: import pack from Files, remembered team, shiny models. Not done: alternate forms, held items, Terastallization, best-of-3, match history, real animations |

---

## 4. Findings and remaining risks

1. **Model conversion works.** The community importer
   (ChicoEevee/Pokemon-Switch-Model-Importer-Blender, no licence, so run as a
   local tool only, never copied) imports models into headless Blender. Two
   traps were solved: its shader uses Eevee-only nodes that bake black in
   Cycles (fixed by baking the base colour as emission), and materials live in
   different UV tiles (fixed by shifting each material into 0..1 before baking).
   Models come out Y-up, metres, feet at y=0, facing +Z.
2. **Species numbering.** The model catalog uses the game's *internal* species
   number, which differs from the dex number for 92 Gen 9 species (Pawmot is
   dex 923 but internal 956). The index joins on the internal number.
3. **Decompression.** ~50 files crash kraken-decompressor 0.2.1 (buffer
   overrun). pyooz (GPL, separate process) decodes them; verified byte-identical
   on files both handle.
   First full run: 476/476 species converted (normal + shiny, 952 files,
   1.5 GB pack) in 20 minutes with 8 Blender processes. Known cosmetic issues:
   a few models carry a stray effect mesh (a thin bar beside Sylveon and
   Mimikyu), and some show their rest "T-pose" (Koraidon, Miraidon).
4. **Animations** are still not extracted: models are static with a procedural
   bob, turn, wander and battle lunges. Real idle/attack clips would need the
   .tracn/.tranm layout worked out plus armature export to USD.
5. **Form mapping.** Only base forms ship (476 species) until game-form →
   Showdown-forme mapping is verified.
6. **AR placement** in cramped rooms can put a creature inside a wall. Worth
   checking on the phone; a fix is clamping spawn distance with raycasts.
7. **Real-device checks still needed:** AR placement and throwing feel,
   two-phone connection, JavaScriptCore start-up time on an XS, memory with
   many models on screen.

---

## 5. Ground rules

- **Oldest supported phone: iPhone XS / XS Max / XR** (A12, iOS 18 max). The
  deployment target stays at iOS 18.0 and no iOS 26-only API may be used
  without an `if #available` fallback. The iPhone X (iOS 16 max) is not supported.

- Game assets (anything from the dump, converted models, packs) never go in
  this repo, in a TestFlight build, or anywhere public. `.gitignore` backs this
  up; `pipeline/config.toml` keeps outputs outside the repo.
- TestFlight stays **internal-only** (you + your friend as team members).
- The repo is **public** (for free Mac builds), so it must never contain game
  assets, keys or anything from the dump. If it's ever taken down, make it
  private and pay for minutes.
- The Violet modding repo is only read from, never modified from here.
