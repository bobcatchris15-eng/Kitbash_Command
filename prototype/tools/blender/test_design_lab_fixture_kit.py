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


def read_glb(path: Path) -> dict:
    data = path.read_bytes()
    magic, version, _length = struct.unpack_from("<4sII", data, 0)
    if magic != b"glTF" or version != 2:
        raise ValueError(f"{path.name} is not a glTF 2.0 binary")
    json_length, json_type = struct.unpack_from("<I4s", data, 12)
    if json_type != b"JSON":
        raise ValueError(f"{path.name} has no JSON chunk")
    return json.loads(data[20 : 20 + json_length].decode("utf-8"))


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
            primitive = mesh["primitives"][0]
            self.assertIn("NORMAL", primitive["attributes"])
            self.assertIn("material", primitive)
            self.assertLessEqual(
                document["accessors"][primitive["indices"]]["count"] // 3,
                triangle_limit,
                fixture_name,
            )
            node = next(node for node in document["nodes"] if node["name"] == fixture_name)
            self.assertEqual(node.get("extras", {}).get("forward_axis"), "+Z")
            self.assertGreaterEqual(len(document.get("materials", [])), 2)


if __name__ == "__main__":
    unittest.main()
