"""Run the whole pack pipeline in order (each stage skips work already done).

    python pipeline/build_all.py            # index, extract, data, convert, pack
    python pipeline/build_all.py --no-shiny # smaller pack without shiny models

Takes a while the first time (extraction ~30 min, conversion ~30-60 min);
re-runs only redo what's missing.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def run(*cmd: str) -> None:
    print(f"\n=== {' '.join(Path(c).name if i < 2 else c for i, c in enumerate(cmd))}", flush=True)
    subprocess.run(cmd, check=True)


def main() -> None:
    py = sys.executable
    run(py, str(HERE / "index_species.py"))
    run(py, str(HERE / "extract_models.py"), "--all", "--skip-existing")
    run("node", str(HERE / "species_data.mjs"))
    run(py, str(HERE / "convert_models.py"))
    run(py, str(HERE / "build_pack.py"), *(a for a in sys.argv[1:] if a == "--no-shiny"))


if __name__ == "__main__":
    main()
