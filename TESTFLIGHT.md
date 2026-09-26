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
2. **Secrets.** Use the same App Store Connect API key as DeckMemo. GitHub
   won't show the old secret values, so paste them in again from the `.p8`
   file you downloaded:
   ```sh
   gh secret set ASC_KEY_ID      --repo JustinSRao/TallGrass
   gh secret set ASC_ISSUER_ID   --repo JustinSRao/TallGrass
   gh secret set ASC_KEY_P8      --repo JustinSRao/TallGrass < path/to/AuthKey_XXXXXXXXXX.p8
   ```
3. **App record.** At <https://appstoreconnect.apple.com>, go to Apps › **+ New App** and
   pick iOS, name "TallGrass" (or anything unique), bundle ID
   `com.justinsrao.tallgrass.TallGrass`, SKU `TALLGRASS-001`. The first
   TestFlight run registers the bundle ID automatically if it doesn't exist yet.
   Leave the listing empty, because this never goes to the App Store.
4. **Testers: internal only.** In TestFlight › Internal Testing, add yourself.
   For your friend, first invite them to your team (Users and Access › **+**,
   role *Developer* or *Marketing*). Once they accept, add them to the internal group.
   Internal builds skip Beta App Review. The workflow also sets
   `testFlightInternalTestingOnly`, so a build can't be sent to external testers by mistake.

## Every build

```sh
gh workflow run TestFlight          # ~15 min on a GitHub Mac, then 10–30 min processing
gh run watch                        # optional: follow it
```
Open TestFlight on the phone and install.

CI (`Build & Test`) runs on every push to `main` and on pull requests. It's free
because the repo is public.

## Installing the creature pack

Build it on the PC (see `pipeline/README.md`), then:

- **Easiest:** zip `TallGrass.creaturepack` and put the zip in iCloud Drive
  or OneDrive. On the phone, open the zip in the Files app to expand it, then move
  the folder to **On My iPhone › TallGrass**.
- **Cable:** in the Apple Devices app on Windows, go to your iPhone › Files › TallGrass
  and drag the folder in.

Then open TallGrass, go to Creature Pack, and tap **Reload Pack**. Without a pack the
app uses a 6-species demo with coloured placeholder orbs.

For two-player games your friend needs the pack on their phone too. That's
your call: it's a copy of your game's assets, so give it only to them.
