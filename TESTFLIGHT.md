# Getting TallGrass onto your phone

Same pipeline as DeckMemo: you push from Windows, GitHub's Macs build it,
and TestFlight installs it. The one difference is the **creature pack**,
which never goes through GitHub or Apple. It's copied straight onto the phone.

## One-time setup

1. **GitHub repo** (done): `JustinSRao/TallGrass`, **public** so GitHub's Macs
   are free (private repos bill macOS minutes). That makes it doubly important
   that no game assets are ever committed; `.gitignore` backs this up. A public
   Pokémon fan repo can still get a DMCA takedown. If that happens, make it
   private again and pay for minutes.
2. **Secrets** (done): `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8`, the same
   App Store Connect API key as DeckMemo.
3. **App record** (done): "TallGrass", bundle ID `com.justinsrao.tallgrass.TallGrass`.
4. **Testers: internal only.** The "Internal Testing" group gets every build
   automatically, and you're in it. For your friend: invite them to your team
   (App Store Connect › Users and Access › **+**, role *Developer* or *Marketing*).
   Once they accept, add them to that group. Internal builds skip Beta App Review,
   and the workflow sets `testFlightInternalTestingOnly`, so a build can't be sent
   to external testers by mistake.
5. **Phones:** iPhone XS / XR or newer, updated to iOS 18 or later.

## Every build

```sh
gh workflow run TestFlight          # ~15 min on a GitHub Mac, then 10–30 min processing
gh run watch                        # optional: follow it
```
Open TestFlight on the phone and install.

CI (`Build & Test`) runs on every push to `main` and on pull requests. It's free
because the repo is public.

## Installing the creature pack

Build it on the PC (`python pipeline\build_all.py`, see `pipeline/README.md`), then:

- **Easiest:** copy the `TallGrass.creaturepack` folder into iCloud Drive or
  OneDrive. On the phone, open TallGrass › **Import Pack…** and pick that folder.
- **Cable:** in the Apple Devices app on Windows, go to your iPhone › Files › TallGrass,
  drag the folder in, then tap **Reload Pack** in the app.

Without a pack the app uses a 6-species demo with coloured placeholder orbs.

For two-player games your friend needs the pack on their phone too. That's
your call: it's a copy of your game's assets, so give it only to them.
