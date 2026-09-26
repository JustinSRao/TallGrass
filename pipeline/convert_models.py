"""Stage 3a: raw model folders -> .usdz (normal + shiny), in parallel.

    python pipeline/convert_models.py              # every extracted base form
    python pipeline/convert_models.py 25 923       # just these national numbers
    python pipeline/convert_models.py --redo       # reconvert even if a .usdz exists

For each <work_dir>/raw/<nnnn>_00/ folder: decode every .bntx to PNG
(bntx.py), then run headless Blender (blender_convert.py) to write
<work_dir>/models/<nnnn>_00.usdz and <nnnn>_00_rare.usdz, plus a front-view
preview PNG for spot checks. Results go to <work_dir>/models/convert_log.json.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

from bntx import BntxError, convert as bntx_to_png
from common import HERE, load_config


def decode_textures(folder: Path) -> list[str]:
    problems = []
    for tex in folder.glob("*.bntx"):
        png = tex.with_suffix(".png")
        if png.exists():
            continue
        try:
            bntx_to_png(tex, png)
        except (BntxError, ValueError) as err:
            problems.append(f"{tex.name}: {err}")
    return problems


ROLE_ORDER = ["idle", "walk", "run", "attack", "special", "damage", "faint",
              "glad", "notice", "roar", "eat", "rest", "sleep"]


def run_blender(cfg, trmdl: Path, out: Path, rare: bool, preview: Path | None) -> tuple[bool, str]:
    cmd = [str(cfg.blender), "-b", "--factory-startup", "--python", str(HERE / "blender_convert.py"), "--",
           str(cfg.work_dir / "tools"), str(trmdl), str(out)]
    if rare:
        # Shiny: only the baked textures; the app swaps them onto the animated model.
        cmd += ["--rare", "--bake-only"]
    else:
        roles_file = trmdl.parent / "clips.json"
        if roles_file.exists():
            roles = json.loads(roles_file.read_text())
            anims = [{"role": r, "path": str(trmdl.parent / roles[r])} for r in ROLE_ORDER if r in roles]
            anim_list = out.with_suffix(".anims.json")
            anim_list.write_text(json.dumps(anims))
            cmd += ["--anims", str(anim_list)]
    if preview:
        cmd += ["--render", str(preview)]
    proc = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=900)
    stats = " ".join(line for line in proc.stdout.splitlines() if line.startswith(("TG_STATS", "TG_CLIPS")))
    produced = out.with_name(out.stem + "_tex") if rare else out
    ok = "TG_OK" in proc.stdout and produced.exists()
    if not ok:
        tail = [line for line in (proc.stdout + proc.stderr).splitlines() if line.strip()][-6:]
        return False, " | ".join(tail)[-600:]
    return True, stats


def convert_one(cfg, folder: Path, redo: bool) -> dict:
    key = folder.name
    models, previews = cfg.work_dir / "models", cfg.work_dir / "previews"
    result = {"key": key, "problems": decode_textures(folder)}
    trmdl = next(iter(sorted(folder.glob("*.trmdl"))), None)
    if trmdl is None:
        result["ok"] = False
        result["error"] = "no .trmdl"
        return result
    for rare in (False, True):
        out = models / f"{key}{'_rare' if rare else ''}.usdz"
        done_marker = out.with_name(out.stem + "_tex") if rare else out.with_suffix(".json")
        if done_marker.exists() and not redo:
            result["rare" if rare else "normal"] = "exists"
            continue
        ok, info = run_blender(cfg, trmdl, out, rare, None if rare else previews / f"{key}.png")
        if not ok and "failed to open blend file" in info:
            # Several Blenders opening the importer's shader library at once
            # occasionally collide; a retry is enough.
            time.sleep(2)
            ok, info = run_blender(cfg, trmdl, out, rare, None if rare else previews / f"{key}.png")
        result["rare" if rare else "normal"] = info
        if not ok:
            result["ok"] = False
            result["error"] = info
            return result
    result["ok"] = True
    return result


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("species", nargs="*", type=int)
    ap.add_argument("--redo", action="store_true")
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 4) // 2))
    args = ap.parse_args()

    cfg = load_config()
    (cfg.work_dir / "models").mkdir(parents=True, exist_ok=True)
    (cfg.work_dir / "previews").mkdir(parents=True, exist_ok=True)
    folders = sorted(p for p in cfg.raw_dir.iterdir() if p.is_dir() and p.name.endswith("_00"))
    if args.species:
        wanted = {f"{n:04d}_00" for n in args.species}
        folders = [f for f in folders if f.name in wanted]

    log_path = cfg.work_dir / "models" / "convert_log.json"
    log = json.loads(log_path.read_text()) if log_path.exists() else {}
    start, done = time.time(), 0
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {pool.submit(convert_one, cfg, f, args.redo): f for f in folders}
        for fut in as_completed(futures):
            r = fut.result()
            log[r["key"]] = r
            done += 1
            status = "ok " if r["ok"] else "ERR"
            print(f"[{done}/{len(folders)}] {status} {r['key']} {'' if r['ok'] else r.get('error', '')[:160]}", flush=True)
            if done % 10 == 0:
                log_path.write_text(json.dumps(log, indent=1))
    log_path.write_text(json.dumps(log, indent=1))
    failed = [k for k, r in log.items() if not r["ok"]]
    print(f"done in {time.time() - start:.0f}s: {len(log) - len(failed)} ok, {len(failed)} failed")


if __name__ == "__main__":
    main()
