"""Zip the built pack for iCloud Drive / OneDrive (stored, not compressed:
the models and textures are already compressed, so this is fast).

    python pipeline/zip_pack.py
On the phone, tap the zip in Files to unpack it, then Import Pack… the folder.
"""

import zipfile

from common import load_config


def main() -> None:
    cfg = load_config()
    src = cfg.pack_dir
    out = src.with_name(src.name + ".zip")
    out.unlink(missing_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED, allowZip64=True) as z:
        for f in sorted(src.rglob("*")):
            if f.is_file():
                z.write(f, f.relative_to(src.parent).as_posix())
    with zipfile.ZipFile(out) as z:
        count, bad = len(z.namelist()), z.testzip()
    print(f"{count} files, integrity {'ok' if bad is None else 'BAD: ' + bad}, "
          f"{out.stat().st_size / 1e9:.2f} GB -> {out}")


if __name__ == "__main__":
    main()
