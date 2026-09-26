"""Decode Switch .bntx textures to PNG (first mip level only).

Written from the publicly documented formats:
  * BNTX container: "NX  " header at 0x20 -> BRTI texture info -> mip offsets.
  * Tegra X1 "block linear" layout: data is stored in 64-byte x 8-row GOBs,
    stacked `1 << block_height_log2` GOBs tall. Un-tiling is plain arithmetic
    and is vectorised with numpy here.
Pixel decoding of BC1-BC7 is done by texture2ddecoder (MIT).

    python pipeline/bntx.py some.bntx [more.bntx ...]   # writes some.png next to each
"""

from __future__ import annotations

import struct
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import texture2ddecoder as t2d
from PIL import Image

# format (high byte = layout, low byte = type) -> (bytes per block, block size, decoder)
# Low byte 01 = UNORM, 06 = SRGB, 02 = SNORM; the pixels decode the same way.
FORMATS = {
    0x0B: (4, 1, None),          # R8G8B8A8
    0x1A: (8, 4, t2d.decode_bc1),
    0x1C: (16, 4, t2d.decode_bc3),   # (BC2 is unused by these models and unsupported by the decoder)
    0x1D: (8, 4, t2d.decode_bc4),
    0x1E: (16, 4, t2d.decode_bc5),
    0x20: (16, 4, t2d.decode_bc7),
}


class BntxError(ValueError):
    pass


@dataclass(frozen=True)
class Texture:
    name: str
    width: int
    height: int
    format: int
    block_height_log2: int
    mip0: bytes

    @property
    def is_srgb(self) -> bool:
        return self.format & 0xFF == 0x06


def read(data: bytes, name: str = "") -> Texture:
    if data[:4] != b"BNTX" or data[0x20:0x24] != b"NX  ":
        raise BntxError(f"{name}: not a BNTX file")
    count, info_ptrs = struct.unpack_from("<IQ", data, 0x24)
    if count != 1:
        raise BntxError(f"{name}: {count} textures in one file (expected 1)")
    brti = struct.unpack_from("<Q", data, info_ptrs)[0]
    if data[brti:brti + 4] != b"BRTI":
        raise BntxError(f"{name}: BRTI header missing")
    fmt, _access, width, height, _depth, _array, layout = struct.unpack_from("<IIiiiii", data, brti + 0x1C)
    image_size = struct.unpack_from("<I", data, brti + 0x50)[0]
    mip_ptrs = struct.unpack_from("<Q", data, brti + 0x70)[0]
    mip0 = struct.unpack_from("<Q", data, mip_ptrs)[0]
    return Texture(name, width, height, fmt, layout & 7, data[mip0:mip0 + image_size])


def untile(tex: Texture, bpp: int, block_dim: int) -> bytes:
    """Tegra block-linear -> linear, in units of `bpp`-byte blocks."""
    bw = -(-tex.width // block_dim)
    bh = -(-tex.height // block_dim)
    gob_rows = 1 << tex.block_height_log2
    width_in_gobs = -(-(bw * bpp) // 64)

    x = np.arange(bw, dtype=np.int64)[None, :] * bpp   # byte column
    y = np.arange(bh, dtype=np.int64)[:, None]          # block row
    gob = ((y // (8 * gob_rows)) * 512 * gob_rows * width_in_gobs
           + (x // 64) * 512 * gob_rows
           + (y % (8 * gob_rows) // 8) * 512)
    addr = (gob + (x % 64) // 32 * 256 + (y % 8) // 2 * 64
            + (x % 32) // 16 * 32 + (y % 2) * 16 + (x % 16))

    src = np.frombuffer(tex.mip0, dtype=np.uint8)
    index = addr[..., None] + np.arange(bpp, dtype=np.int64)
    if index.max() >= src.size:
        raise BntxError(f"{tex.name}: tiled data shorter than expected")
    return src[index].tobytes()


def to_image(tex: Texture) -> Image.Image:
    kind = tex.format >> 8
    if kind not in FORMATS:
        raise BntxError(f"{tex.name}: unsupported format 0x{tex.format:04X}")
    bpp, block_dim, decoder = FORMATS[kind]
    linear = untile(tex, bpp, block_dim)
    if decoder is None:
        return Image.frombytes("RGBA", (tex.width, tex.height), linear)
    # Decoders work on whole blocks; decode padded, then crop.
    pw = -(-tex.width // block_dim) * block_dim
    ph = -(-tex.height // block_dim) * block_dim
    bgra = decoder(linear, pw, ph)
    return Image.frombytes("RGBA", (pw, ph), bgra, "raw", "BGRA").crop((0, 0, tex.width, tex.height))


def convert(path: Path, out: Path | None = None) -> Path:
    out = out or path.with_suffix(".png")
    to_image(read(path.read_bytes(), path.name)).save(out)
    return out


if __name__ == "__main__":
    for arg in sys.argv[1:]:
        print(convert(Path(arg)))
