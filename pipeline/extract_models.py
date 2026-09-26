"""Stage 2: copy each chosen species' raw model files out of the Violet dump.

The packed filesystem has no directory listing, so files are found by name:
start from the catalog's known parts, then scan those files for any other
file names they reference (meshes, textures, animations) and follow them.

    python pipeline/extract_models.py pawmot:923 pikachu:25     # national numbers
    python pipeline/extract_models.py --all

Output: <work_dir>/raw/<national>_<form>/...   (outside the repo, never committed)
"""

from __future__ import annotations

import argparse
import json
import re

from common import load_config, open_violet

START_EXTS = (".trmdl", ".trskl", ".trmsh", ".trmbf", ".trmtr", ".trmmt",
              ".trpokecfg", ".tracn")
REF = re.compile(rb"[A-Za-z0-9_./-]+\.(?:trmsh|trmbf|trskl|trmtr|trmmt|bntx|tranm|tracn|tracr|tracm|trslp|trmdt)")


def extract(fs, read_file, entry: dict, out_root) -> tuple[int, list[str]]:
    folder = entry["modelFolder"]
    stem = entry["modelBase"].rsplit("/", 1)[1]
    queue = [f"{folder}/{stem}{ext}" for ext in START_EXTS]
    seen, missing = set(), []
    dest = out_root / f"{entry['national']:04d}_{entry['form']:02d}"
    dest.mkdir(parents=True, exist_ok=True)
    while queue:
        path = queue.pop()
        if path in seen:
            continue
        seen.add(path)
        if not fs.has_file(path):
            missing.append(path)
            continue
        try:
            data = read_file(path)
        except RuntimeError as err:  # decompressor failure: record, keep going
            missing.append(f"{path} (decode failed: {err})")
            continue
        (dest / path.rsplit("/", 1)[1]).write_bytes(data)
        for ref in REF.findall(data):
            name = ref.decode("ascii")
            # References are either folder-relative names or romfs-relative paths.
            candidates = [name] if name.startswith("pokemon/") else \
                         [f"{folder}/{name.rsplit('/', 1)[-1]}", "pokemon/data/" + name]
            queue.extend(c for c in candidates if c not in seen)
    written = len(list(dest.iterdir()))
    return written, missing


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("species", nargs="*", help="name:national or national (form 0)")
    ap.add_argument("--all", action="store_true")
    args = ap.parse_args()

    cfg = load_config()
    index = json.loads(cfg.index_path.read_text(encoding="utf-8"))
    if args.all:
        chosen = index
    else:
        wanted = {int(s.rsplit(":", 1)[-1]) for s in args.species}
        chosen = [e for e in index if e["national"] in wanted and e["form"] == 0]
    if not chosen:
        ap.error("nothing selected (run index_species.py first?)")

    fs, read_file, _ = open_violet(cfg)
    for entry in chosen:
        n, missing = extract(fs, read_file, entry, cfg.raw_dir)
        # "missing" are guesses at how a reference resolves; one of each pair
        # usually misses by design, so only report when nothing was written.
        failed = [m for m in missing if "decode failed" in m]
        print(f"{entry['national']:4d}/{entry['form']}: {n} files"
              + ("" if n else f"  (none found; tried {missing[:3]})"))
        for f in failed:
            print(f"      ! {f}")


if __name__ == "__main__":
    main()
