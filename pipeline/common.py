"""Shared setup for the pack pipeline: config loading and access to the Violet
dump through the modding repo's existing, tested readers."""

from __future__ import annotations

import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
PERSONAL_PATH = "avalon/data/personal_array.bin"


@dataclass(frozen=True)
class Config:
    violet_project: Path
    violet_arc: Path
    work_dir: Path
    blender: Path

    @property
    def index_path(self) -> Path:
        return self.work_dir / "species_index.json"

    @property
    def raw_dir(self) -> Path:
        return self.work_dir / "raw"

    @property
    def pack_dir(self) -> Path:
        return self.work_dir / "pack" / "TallGrass.creaturepack"


def load_config() -> Config:
    path = HERE / "config.toml"
    if not path.exists():
        sys.exit(f"Missing {path}. Copy config.example.toml to config.toml first.")
    raw = tomllib.loads(path.read_text(encoding="utf-8"))
    cfg = Config(**{k: Path(v) for k, v in raw.items()})
    for name in ("violet_project", "violet_arc"):
        if not getattr(cfg, name).exists():
            sys.exit(f"config.toml: {name} does not exist: {getattr(cfg, name)}")
    return cfg


def open_violet(cfg: Config):
    """Return (fs, read_file, PersonalTable) from the Violet repo's modules."""
    sys.path.insert(0, str(cfg.violet_project / "tools"))
    sys.path.insert(0, str(cfg.violet_project / "src"))
    from trinity_hash import TrinityFileSystem  # noqa: E402
    import oodle  # noqa: E402
    from sv_randomizer.personal import PersonalTable  # noqa: E402

    if not oodle.is_available():
        sys.exit("Oodle decompressor missing: pip install -r "
                 f"{cfg.violet_project / 'requirements-oodle.txt'}")
    fs = TrinityFileSystem.open(cfg.violet_arc)

    def read_file(path: str) -> bytes:
        try:
            return oodle.read_packed_file(fs, path)
        except RuntimeError:
            # kraken-decompressor 0.2.1 overruns its output buffer on some
            # streams (~50 small model files). pyooz decodes them correctly.
            return _read_with_pyooz(fs, path)

    return fs, read_file, PersonalTable


# pyooz is GPL-3.0+, so like the Violet repo's decoder it only ever runs in a
# separate process and is never imported by this project's code.
_POOZ_WORKER = ("import sys, ooz; n=int(sys.argv[1]);"
                "sys.stdout.buffer.write(ooz.decompress(sys.stdin.buffer.read(), n))")


def _read_with_pyooz(fs, path: str) -> bytes:
    import subprocess
    from trinity_hash import file_hash
    from trinity_pack import Trpak

    entry = Trpak.parse(fs.pack_of_file(path)).by_hash(file_hash(path))
    proc = subprocess.run([sys.executable, "-c", _POOZ_WORKER, str(entry.decoded_size)],
                          input=entry.payload, capture_output=True, timeout=300)
    if proc.returncode != 0 or len(proc.stdout) != entry.decoded_size:
        raise RuntimeError(f"both Kraken decoders failed on {path}: "
                           f"{proc.stderr.decode('utf-8', 'replace')[-200:]}")
    return proc.stdout


def model_dir(model_id: int, form: int, variant: int = 0) -> str:
    stem = f"pm{model_id:04d}_{form:02d}_{variant:02d}"
    return f"pokemon/data/pm{model_id:04d}/{stem}/{stem}"
