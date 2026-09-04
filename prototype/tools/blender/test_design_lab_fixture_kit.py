"""Integration checks for the reproducible Design Lab fixture-kit export."""

from __future__ import annotations

import json
import os
import struct
import subprocess
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent.parent
AUTHOR_SCRIPT = SCRIPT_DIR / "build_design_lab_fixture_kit.py"
ASSET_DIR = PROJECT_DIR / "assets" / "models" / "ui"
BLENDER = Path(r"C:\Program Files\Blender Foundation\Blender 5.2\blender.exe")

EXPECTED_FIXTURES = {
    "lab_console_frame": 3_200,
    "lab_document_clamp": 1_800,
    "lab_fixture_rail": 2_400,
    "lab_inspection_lamp": 3_200,
    "lab_parts_tray": 2_400,
    "lab_service_pedestal": 3_200,
}

COMPONENT_FORMATS = {5123: "H", 5125: "I", 5126: "f"}
TYPE_COMPONENTS = {"SCALAR": 1, "VEC3": 3}


def read_glb(path: Path) -> dict:
    data = path.read_bytes()
    magic, version, _length = struct.unpack_from("<4sII", data, 0)
    if magic != b"glTF" or version != 2:
        raise ValueError(f"{path.name} is not a glTF 2.0 binary")
    json_length, json_type = struct.unpack_from("<I4s", data, 12)
    if json_type != b"JSON":
        raise ValueError(f"{path.name} has no JSON chunk")
    document = json.loads(data[20 : 20 + json_length].decode("utf-8"))
    binary_offset = 20 + json_length
    binary_length, binary_type = struct.unpack_from("<I4s", data, binary_offset)
    if binary_type != b"BIN\x00":
        raise ValueError(f"{path.name} has no binary chunk")
    document["_binary"] = data[binary_offset + 8 : binary_offset + 8 + binary_length]
    return document


def read_accessor(document: dict, accessor_index: int) -> list[tuple[float, ...] | int]:
    """Read the small, non-sparse accessors emitted by this fixture exporter."""
    accessor = document["accessors"][accessor_index]
    view = document["bufferViews"][accessor["bufferView"]]
    component_format = COMPONENT_FORMATS[accessor["componentType"]]
    component_count = TYPE_COMPONENTS[accessor["type"]]
    component_size = struct.calcsize("<" + component_format)
    stride = view.get("byteStride", component_size * component_count)
    offset = view.get("byteOffset", 0) + accessor.get("byteOffset", 0)
    values = []
    for item_index in range(accessor["count"]):
        item_offset = offset + item_index * stride
        unpacked = struct.unpack_from(
            "<" + component_format * component_count, document["_binary"], item_offset
        )
        values.append(unpacked[0] if component_count == 1 else unpacked)
    return values


def signed_volume(document: dict, primitive: dict) -> float:
    """Return the oriented volume of one closed triangle primitive in GLB space."""
    positions = read_accessor(document, primitive["attributes"]["POSITION"])
    indices = read_accessor(document, primitive["indices"])
    volume = 0.0
    for index in range(0, len(indices), 3):
        a, b, c = (positions[indices[index + offset]] for offset in range(3))
        volume += (
            a[0] * (b[1] * c[2] - b[2] * c[1])
            + a[1] * (b[2] * c[0] - b[0] * c[2])
            + a[2] * (b[0] * c[1] - b[1] * c[0])
        ) / 6.0
    return volume


class DesignLabFixtureKitTests(unittest.TestCase):
    def test_headless_export_has_bounded_named_fixture_meshes(self) -> None:
        self.assertTrue(BLENDER.is_file(), "Blender 5.2 must be installed for fixture export")
        result = subprocess.run(
            [str(BLENDER), "--background", "--python", str(AUTHOR_SCRIPT)],
            cwd=PROJECT_DIR,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("DESIGN_LAB_FIXTURE_KIT_DONE", result.stdout + result.stderr)

        for fixture_name, triangle_limit in EXPECTED_FIXTURES.items():
            document = read_glb(ASSET_DIR / f"{fixture_name}.glb")
            mesh = next(mesh for mesh in document["meshes"] if mesh["name"] == fixture_name)
            self.assertTrue(mesh["primitives"], fixture_name)
            triangle_count = 0
            for primitive in mesh["primitives"]:
                self.assertEqual(primitive.get("mode", 4), 4, fixture_name)
                self.assertIn("POSITION", primitive["attributes"])
                self.assertIn("NORMAL", primitive["attributes"])
                self.assertIn("material", primitive)
                triangle_count += document["accessors"][primitive["indices"]]["count"] // 3
                self.assertGreater(
                    signed_volume(document, primitive),
                    1e-6,
                    f"{fixture_name} has inward or degenerate winding in material primitive {primitive['material']}",
                )
            self.assertLessEqual(
                triangle_count,
                triangle_limit,
                fixture_name,
            )
            node = next(node for node in document["nodes"] if node["name"] == fixture_name)
            self.assertEqual(node.get("extras", {}).get("forward_axis"), "+Z")
            self.assertGreaterEqual(len(document.get("materials", [])), 2)


if __name__ == "__main__":
    unittest.main()
