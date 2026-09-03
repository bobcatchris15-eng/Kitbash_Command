import json
import numpy as np
from PIL import Image
import os
import argparse
import glob

def load_height_map(map_id, map_json_path, data_dir):
    height_map_path = os.path.join(data_dir, f"{map_id}_height.png")
    if os.path.exists(height_map_path):
        img = Image.open(height_map_path).convert("RGB")
        data = np.array(img)
        heights = (data[:, :, 0].astype(np.float32) * 256.0 + data[:, :, 1].astype(np.float32)) / 65535.0
        return heights
    if os.path.exists(map_json_path):
        with open(map_json_path, "r") as f:
            data = json.load(f)
        if "terrain" in data and "sculpt_grid" in data["terrain"]:
            sculpt = data["terrain"]["sculpt_grid"]
            dim = int(sculpt["dim"])
            grid = np.array(sculpt["data"], dtype=np.float32).reshape((dim, dim))
            img = Image.fromarray(grid)
            img = img.resize((512, 512), Image.BILINEAR)
            return np.array(img, dtype=np.float32)
    return np.zeros((512, 512), dtype=np.float32)

def generate_topo(map_id, data_dir):
    try:
        map_json_path = os.path.join(data_dir, f"{map_id}.json")
        map_data = {}
        if os.path.exists(map_json_path):
            with open(map_json_path, "r") as f:
                map_data = json.load(f)

        raw_heights = load_height_map(map_id, map_json_path, data_dir)
        if raw_heights.shape != (512, 512):
            img_h = Image.fromarray(raw_heights.astype(np.float32))
            img_h = img_h.resize((512, 512), Image.BILINEAR)
            raw_heights = np.array(img_h, dtype=np.float32)

        # Normalise heights for contours and hillshade
        h_min = float(raw_heights.min())
        h_max = float(raw_heights.max())
        h_range = max(h_max - h_min, 1e-5)
        h_norm = (raw_heights - h_min) / h_range

        # Hillshade calculation (NW sun 315 deg, 45 deg elevation)
        scaled_h = h_norm * 40.0
        dy, dx = np.gradient(scaled_h)
        azimuth = 315.0 * np.pi / 180.0
        altitude = 45.0 * np.pi / 180.0
        slope = np.arctan(np.sqrt(dx**2 + dy**2))
        aspect = np.arctan2(-dy, dx)
        hillshade = np.sin(altitude) * np.cos(slope) + np.cos(altitude) * np.sin(slope) * np.cos(azimuth - aspect)
        hs_min, hs_max = float(hillshade.min()), float(hillshade.max())
        hillshade = (hillshade - hs_min) / max(hs_max - hs_min, 1e-5)

        # 1. Base paper tint: authentic USGS 7.5' quadrangle buff (#f4f1e9)
        base_paper = np.array([244.0, 241.0, 233.0], dtype=np.float32)
        shaded = (base_paper[np.newaxis, np.newaxis, :] * (0.65 + 0.35 * hillshade[:, :, np.newaxis]))

        # Map bounds for world -> pixel mapping
        he = map_data.get("map_half_extents", 400.0)
        if isinstance(he, list):
            he_x, he_z = float(he[0]), float(he[1])
        else:
            he_x, he_z = float(he), float(he)
        he_x = max(he_x, 100.0)
        he_z = max(he_z, 100.0)

        def world_to_px(wx, wz):
            col = int(np.clip((wx + he_x) / (2.0 * he_x) * 512.0, 0, 511))
            row = int(np.clip((wz + he_z) / (2.0 * he_z) * 512.0, 0, 511))
            return col, row

        # 2. Surface zones: Woodland (trees) green tint & stipple, Rocky / Gravel hashes
        woodland_color = np.array([199.0, 224.0, 183.0], dtype=np.float32)
        rock_color = np.array([140.0, 134.0, 124.0], dtype=np.float32)

        for zone in map_data.get("surface_zones", []):
            center = zone.get("center", [0, 0, 0])
            half = zone.get("half_extents", [50, 50])
            stype = str(zone.get("surface_type", zone.get("type", ""))).lower()

            c0, r0 = world_to_px(center[0] - half[0], center[2] - half[1])
            c1, r1 = world_to_px(center[0] + half[0], center[2] + half[1])
            if c0 > c1: c0, c1 = c1, c0
            if r0 > r1: r0, r1 = r1, r0
            c1 = min(512, c1 + 1)
            r1 = min(512, r1 + 1)

            if "forest" in stype or "tree" in stype or "wood" in stype:
                shaded[r0:r1, c0:c1] = shaded[r0:r1, c0:c1] * 0.4 + woodland_color * 0.6
                for rr in range(r0 + 2, r1 - 2, 8):
                    for cc in range(c0 + 2, c1 - 2, 8):
                        shaded[rr, cc-1:cc+2] = [60, 110, 50]
                        shaded[rr-1:rr+2, cc] = [60, 110, 50]
            elif "rock" in stype or "gravel" in stype:
                for rr in range(r0, r1):
                    for cc in range(c0, c1):
                        if (rr + cc) % 8 == 0:
                            shaded[rr, cc] = rock_color

        # 3. Obstacles (rocks/boulders) diagonal hash
        for obs in map_data.get("obstacles", []):
            center = obs.get("center", [0, 0, 0])
            half = obs.get("half_extents", [20, 20])
            c0, r0 = world_to_px(center[0] - half[0], center[2] - half[1])
            c1, r1 = world_to_px(center[0] + half[0], center[2] + half[1])
            if c0 > c1: c0, c1 = c1, c0
            if r0 > r1: r0, r1 = r1, r0
            c1 = min(512, c1 + 1)
            r1 = min(512, r1 + 1)
            for rr in range(r0, r1):
                for cc in range(c0, c1):
                    if (rr + cc) % 6 == 0:
                        shaded[rr, cc] = [110, 100, 90]

        # 3.5. Props: individual trees and rock formations
        props = map_data.get("props", [])
        for prop in props:
            ptype = str(prop.get("type", "")).lower()
            pos = prop.get("pos", [0, 0, 0])
            col, row = world_to_px(pos[0], pos[2])
            if "tree" in ptype:
                shaded[max(0, row-1):min(512, row+2), max(0, col-1):min(512, col+2)] = [55, 105, 45]
            elif "rock" in ptype or "boulder" in ptype:
                shaded[max(0, row-1):min(512, row+2), max(0, col-1):min(512, col+2)] = [110, 100, 90]

        # 4. REAL MATHEMATICAL TOPO CONTOUR LINES
        # Quantization into 20 intervals
        num_intervals = 20
        q = np.floor(h_norm * num_intervals)
        diff_x = np.abs(np.diff(q, axis=1, append=q[:, -1:])) > 0
        diff_y = np.abs(np.diff(q, axis=0, append=q[-1:, :])) > 0
        inter_mask = diff_x | diff_y

        # Index contours (every 4th contour = 5 index levels across map)
        q_idx = np.floor(h_norm * (num_intervals / 4.0))
        diff_idx_x = np.abs(np.diff(q_idx, axis=1, append=q_idx[:, -1:])) > 0
        diff_idx_y = np.abs(np.diff(q_idx, axis=0, append=q_idx[-1:, :])) > 0
        idx_mask = diff_idx_x | diff_idx_y
        idx_mask_2px = idx_mask | np.roll(idx_mask, 1, axis=0) | np.roll(idx_mask, 1, axis=1)

        # Apply intermediate contour lines (USGS warm brown)
        shaded[inter_mask] = [173, 112, 66]
        # Apply index contour lines (USGS bold dark brown)
        shaded[idx_mask_2px] = [122, 71, 41]

        # 5. WATER (LAKES, RIVERS, WATER TABLE, PAINTED BODIES, RECT AREAS)
        # 5a. Global / Sculpted Water Table (TerrainBuilder: submerged_at = height < water_level - 0.6)
        has_table = ("water_level" in map_data) or ("sculpt_grid" in map_data.get("terrain", {})) or (str(map_data.get("terrain", {}).get("generator", "")) == "v2")
        water_mask = np.zeros((512, 512), dtype=bool)

        if has_table:
            wl = float(map_data.get("water_level", -2.0))
            water_mask |= (raw_heights < (wl - 0.6))

        # 5b. Painted water map (*_water.png) if present
        water_png_path = os.path.join(data_dir, f"{map_id}_water.png")
        if os.path.exists(water_png_path):
            try:
                w_img = Image.open(water_png_path).convert("RGB")
                w_img = w_img.resize((512, 512), Image.NEAREST)
                w_arr = np.array(w_img)
                # Channel R is coverage (WATER_PAINT_MIN_COVER = 0.5 -> >= 128)
                water_mask |= (w_arr[:, :, 0] >= 128)
            except Exception as e_w:
                print(f"Warning reading water png {water_png_path}: {e_w}")

        # 5c. Authored rect water_areas and shallow_water_areas
        for w_key in ["water_areas", "shallow_water_areas"]:
            for water in map_data.get(w_key, []):
                center = water.get("center", [0, 0, 0])
                half = water.get("half_extents", [50, 50])
                c0, r0 = world_to_px(center[0] - half[0], center[2] - half[1])
                c1, r1 = world_to_px(center[0] + half[0], center[2] + half[1])
                if c0 > c1: c0, c1 = c1, c0
                if r0 > r1: r0, r1 = r1, r0
                water_mask[r0:min(512, r1+1), c0:min(512, c1+1)] = True

        # Render Water Bodies: USGS hydro blue with dark shoreline border
        if np.any(water_mask):
            # Water fill: USGS soft hydro blue
            shaded[water_mask] = [198, 224, 235]
            # Shoreline edge: pixels on boundary of water_mask
            edge_x = np.abs(np.diff(water_mask.astype(np.int32), axis=1, append=water_mask[:, -1:].astype(np.int32))) > 0
            edge_y = np.abs(np.diff(water_mask.astype(np.int32), axis=0, append=water_mask[-1:, :].astype(np.int32))) > 0
            shore_mask = (edge_x | edge_y) & water_mask
            shaded[shore_mask] = [50, 120, 165]

        # 6. USGS Neatline border around 512x512 edge
        shaded[0:3, :] = [45, 40, 35]
        shaded[509:512, :] = [45, 40, 35]
        shaded[:, 0:3] = [45, 40, 35]
        shaded[:, 509:512] = [45, 40, 35]

        result_img = Image.fromarray(np.clip(shaded, 0, 255).astype(np.uint8))
        out_path = os.path.join(data_dir, f"{map_id}_topo.png")
        result_img.save(out_path)
        print(f"Baked: {out_path} (Water pixels: {int(np.sum(water_mask))})")
    except Exception as e:
        import traceback
        print(f"Error baking {map_id}: {e}")
        traceback.print_exc()

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--map", help="Single map ID")
    parser.add_argument("--all", action="store_true", help="Bake all maps")
    args = parser.parse_args()
    data_dir = "e:/Kitbash-Command/prototype/data/maps"
    if args.all:
        files = glob.glob(os.path.join(data_dir, "*.json"))
        for f in files:
            map_id = os.path.basename(f).replace(".json", "")
            generate_topo(map_id, data_dir)
    elif args.map:
        generate_topo(args.map, data_dir)
