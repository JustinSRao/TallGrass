"""Reader for pokemon/catalog/catalog/poke_resource_table.trpmcatalog.

The catalog is the game's own species -> model map. Model folder numbers are
NOT always national dex numbers (e.g. several Gen 6-8 species live in pm1011+
folders), so the pipeline must go through this table rather than guess paths.

Layout as found in Violet 1.0.1 (verified by probing this dump; it differs
from Legends: Arceus, which has an extra unused byte field):
  root:        0 Version, 1 Table: [PokeModelConfig]   (682 entries)
  PokeModelConfig: 0 SpeciesInfo, 1 ModelPath (.trmdl), 2 MaterialTablePath
                   (.trmmt), 3 ConfigPath (.trpokecfg), 4 Animations: [NamePath]
                   (one .tracn animation container), 5 Effects: [NamePath],
                   6 icon texture (.bntx)
  SpeciesInfo: 0 Species: u16, 1 Form: u16, 2 Gender: u8 (1 = female model)
  NamePath:    0 Name (usually absent), 1 Path
"""

from __future__ import annotations

import struct
from dataclasses import dataclass

CATALOG_PATH = "pokemon/catalog/catalog/poke_resource_table.trpmcatalog"


@dataclass(frozen=True)
class CatalogEntry:
    species: int
    form: int
    gender: int
    model_path: str
    material_table_path: str | None
    config_path: str
    animations: list[str]

    @property
    def folder(self) -> str:
        """romfs folder holding this model's files."""
        return "pokemon/data/" + self.model_path.rsplit("/", 1)[0]


def parse_catalog(data: bytes, FlatBuffer) -> list[CatalogEntry]:
    fb = FlatBuffer(data)

    def table_at(ptr: int) -> int:
        return ptr + fb.u32(ptr)

    def string(table: int, field: int) -> str | None:
        ptr = fb.field_ptr(table, field)
        if ptr is None:
            return None
        s = table_at(ptr)
        return bytes(data[s + 4: s + 4 + fb.u32(s)]).decode("utf-8")

    def scalar(table: int, field: int, fmt: str) -> int:
        ptr = fb.field_ptr(table, field)
        return 0 if ptr is None else struct.unpack_from("<" + fmt, data, ptr)[0]

    def tables(table: int, field: int) -> list[int]:
        if fb.field_ptr(table, field) is None:
            return []
        start, count = fb.vector(table, field)
        return [table_at(start + i * 4) for i in range(count)]

    entries = []
    for cfg in tables(fb.root, 1):
        info = table_at(fb.field_ptr(cfg, 0))
        entries.append(CatalogEntry(
            species=scalar(info, 0, "H"),
            form=scalar(info, 1, "H"),
            gender=scalar(info, 2, "B"),
            model_path=string(cfg, 1),
            material_table_path=string(cfg, 2),
            config_path=string(cfg, 3),
            animations=[string(p, 1) for p in tables(cfg, 4)],
        ))
    return entries
