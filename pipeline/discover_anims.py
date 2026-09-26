"""Find which animation clips a species has, by name.

Animation files aren't listed anywhere readable (the .tracn named in the
catalog isn't in the archive), but archive paths hash deterministically, so a
guessed path can be checked against the index without reading anything.
Names follow `<model>_<5-digit number>_<action>.tranm`; the number varies a
little between species, so each action is tried against every number.

    python pipeline/discover_anims.py 25 661 129      # research: print what exists
"""

from __future__ import annotations

import json
import sys

# Actions the app uses, in priority order within each role. The first one a
# species has wins; e.g. a species with no walk cycle still gets a flying one.
ROLES: dict[str, list[str]] = {
    "idle":    ["defaultwait01_loop", "battlewait01_loop", "fieldwait01_loop"],
    "walk":    ["walk01_loop", "fly01_loop", "swim01_loop", "hover01_loop"],
    "run":     ["run01_loop", "dash01_loop", "fly02_loop", "swim02_loop"],
    "attack":  ["attack01"],
    "special": ["rangeattack01", "attack02"],
    "damage":  ["damage01"],
    "faint":   ["down01_start", "down01"],
    "glad":    ["glad01"],
    "notice":  ["notice01"],
    "roar":    ["roar01"],
    "eat":     ["eat01_loop"],
    "rest":    ["rest01_loop"],
    "sleep":   ["sleep01_loop"],
}
# Clip numbers come in sets: 0xxxx on the ground, 1xxxx in water, 2xxxx in the
# air (Dragonite's attacks exist only as 20400_attack01; Glimmora only has the
# airborne set). A species uses the first set that has an idle loop, and any
# role missing from it is borrowed from the other sets.
SETS = [range(0, 1000), range(10000, 11000), range(20000, 21000)]


def _first(model_base: str, action: str, numbers: range, hashes: set[int], file_hash) -> str | None:
    for n in numbers:
        path = f"{model_base}_{n:05d}_{action}.tranm"
        if file_hash(path) in hashes:
            return path
    return None


def find_clips(model_base: str, hashes: set[int], file_hash) -> dict[str, str]:
    """role -> archive path of the best clip this model has."""
    home = next((s for s in SETS
                 if any(_first(model_base, a, s, hashes, file_hash) for a in ROLES["idle"])), SETS[0])
    order = [home] + [s for s in SETS if s is not home]
    found: dict[str, str] = {}
    for role, actions in ROLES.items():
        for numbers in order:
            path = next((p for a in actions if (p := _first(model_base, a, numbers, hashes, file_hash))), None)
            if path:
                found[role] = path
                break
    return found


def main() -> None:
    from common import load_config, open_violet
    cfg = load_config()
    fs, _, _ = open_violet(cfg)
    from trinity_hash import file_hash
    hashes = set(fs.trpfd.file_hashes)
    index = json.loads(cfg.index_path.read_text())
    for national in map(int, sys.argv[1:]):
        entry = next((e for e in index if e["national"] == national and e["form"] == 0), None)
        if entry is None:
            print(national, "not in this game")
            continue
        clips = find_clips(entry["modelBase"], hashes, file_hash)
        print(national, len(clips), {r: p.rsplit("_", 2)[-2] + "_" + p.rsplit("_", 1)[-1] for r, p in clips.items()},
              "missing:", [r for r in ROLES if r not in clips], flush=True)


if __name__ == "__main__":
    main()
