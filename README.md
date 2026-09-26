# TallGrass

A private AR creature-hunting and battling game for iPhone. The camera opens,
creatures appear around you, and you and a friend each have a few minutes to
catch up to six. Then you battle with real Scarlet/Violet moves and mechanics.

**Start with [PLAN.md](PLAN.md)** (design, architecture, milestones, risks).
To get it on your phone, see [TESTFLIGHT.md](TESTFLIGHT.md).

## Layout

| Path | What |
|---|---|
| `App/` | SwiftUI app: home, AR hunt (`Hunt/`), battle (`Battle/`) |
| `Packages/TallGrassKit/` | Game rules, no UI: seeded RNG, rarity, spawns, catching, loadouts, pack format. `swift test` |
| `BattleEngine/` | Showdown's simulator (`@pkmn/sim`, MIT) bundled for JavaScriptCore. `npm test` |
| `pipeline/` | PC-side tools that build the creature pack from your own Violet dump ([README](pipeline/README.md)) |
| `AppTests/` | Runs the real battle bundle through the Swift bridge |
| `.github/workflows/` | `Build & Test` and `TestFlight`, run on GitHub's Macs |

## Building (from Windows, like DeckMemo)

```sh
cd BattleEngine && npm ci && npm test        # bundles App/Resources/battle-engine.js
gh workflow run "Build & Test"               # compile + test on a GitHub Mac
gh workflow run TestFlight                   # ship a build
```

On a Mac: `npm ci && npm run build` in `BattleEngine/`, then `xcodegen generate` and open `TallGrass.xcodeproj`.

## Assets

This repo and every TestFlight build contain **no game assets**. The
creature pack (models + data) is built locally from your own dump and copied
straight onto the phone. Without a pack the app runs a small demo with
placeholder visuals.
