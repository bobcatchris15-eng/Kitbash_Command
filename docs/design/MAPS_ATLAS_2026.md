# Map Atlas — 12 New Skirmish Maps (Aug 2026)

A dozen new maps authored against the same `FIELD_SPEC` already used by
`noble_oaks` and `dry_ambition`. The intent: leverage the established
feature set (water_areas, shallow_water_areas, hills, cliffs, surface_zones,
terrain.features, props, environment) to ship 12 distinct *gameplay
identities*, not 12 cosmetic reskins of one layout.

All 12 use the same `map_half_extents = 400.0` (an 800×800 playpen,
matching `blask_forest` / `twin_bluffs` / `delta_blues` in the existing
roster). `world_scale = 1.0` on all of them so the per-spawn base,
harvester, and projectile speeds match the other 1.0-scale maps.

## Files

**Per map — 1 JSON + 6 PNGs (1.5–2.0 MB each on disk):**

- `prototype/data/maps/<map>.json` — the authored metadata + feature array
- `prototype/data/maps/<map>_height.png` — 16-bit heightmap, 801×801 RGBA8
- `prototype/data/maps/<map>_surface.png` — 8-bit palette-indexed surface map
- `prototype/data/maps/<map>_splat.png` — RGBA splat weight map
- `prototype/data/maps/<map>_wetness.png` — distance-to-water grayscale
- `prototype/data/maps/<map>_macro.png` — RGB macro tint variation
- `prototype/data/maps/<map>_curvature.png` — curvature ambient occlusion

**Pipeline tooling:**

- `scratch/generate_maps.py` — one-shot authoring tool. Emits the 12 JSONs.
- `scratch/bake_heightmaps.py` — invokes `prototype/tools/terrain/build_terrain.py` per map to bake the 6 PNGs and patch the JSON to reference them.
- `prototype/tools/terrain/build_terrain.py` — the existing project tool that does the actual heightfield + splat + wetness math.
- `prototype/_test_new_maps.gd` — runtime test that loads every map through `MapCatalog` and confirms the heightmap is actually being read (not the analytic fallback) and produces non-trivial terrain.

The 12 map ids:
`cinder_flats`, `the_reef`, `sentinel_gate`, `pinewatch`, `the_confluence`,
`hollow_throne`, `bitterroot`, `the_long_march`, `the_iron_square`,
`the_frostline`, `pillars_of_the_sky`, `saltpan_crossing`.

## Gameplay design matrix

| Map | Identity | Key features | Spawn-to-spawn | Heightmap span |
|---|---|---|---|---|
| **Cinder Flats** | Volcanic plain split by impassable lava | 8 hills (volcanic cones 14-18m), 8 spires, water_areas (lava), bridge, cooling shallows | 600m through bridge; 200m around via cooling | **17.9m** (cone hills) |
| **The Reef** | Maze of tall spires in a 18m-deep basin | 22 spires, 4 rim ridges (20m), 2 interior plateaus, 1 basin (-18m), oil/lumber in gaps | 600m straight; 200m of constant ambush | **38.1m** (basin to rim) |
| **Sentinel Gate** | Canyon walls bracket a long valley, central mesa | 12 cliffs, central mesa plateau 26m + 4 ramp, 2 long rim ridges (18m), south plateau (14m), small basin (-8m) | 680m down the valley; mesa controls LOS | **33.5m** (mesa to basin) |
| **Pinewatch** | Dense forest with rolling terrain | 5 hills under the canopy (14-22m), 2 cross-forest ridges (18m), 856 trees, basin (-10m) | 520m through trees; ~30m LOS | **37.0m** (forest hills) |
| **The Confluence** | 3-channel river, 2 bridges, 1 ford | 4 bank ridges (12-16m), 2 small central plateaus, 2 water_areas, 2 bridges | 640m of choice: 2 bridges, 1 ford, or long way | **11.4m** (riverbanks) |
| **Hollow Throne** | Circular bowl, central plateau w/ 4 ramps | central plateau (26m) + 4 ramps, 8 ring hills (18m), 6 inner hills (10m) | 640m into the crater; 4 chokes up to the throne | **10.9m** (rim 0m to plateau 26m, sampled) |
| **Bitterroot** | Rolling hills + marsh pockets | 6 tall hills (16-22m), 2 long ridges (14m), 4 marsh surface zones | 520m of tactical elevation play | **36.2m** (hill peaks) |
| **The Long March** | Single causeway across a wide river | 4 long bank ridges (12-18m), central island plateau (8m), bridge, 2 fords | 560m to the causeway; island is the prize | **12.7m** (banks) |
| **The Iron Square** | Urban district: civic buildings + roads | 2 district hills (14m), central basin (-6m), 2 civic plateaus (8m), 24 civic building props, road grid | 560m through alleys; ~50m LOS | **14.6m** (hills to basin) |
| **The Frostline** | Ice plain with frozen river | 2 long ice ridges (18m), 2 interior plateaus (10m), frozen river basin, boulder clusters, spires | 640m of open ground; 200m+ LOS | **10.8m** (ridges) |
| **Pillars of the Sky** | Spire field bisected by deep canyon | 3 canyons (-35m), 4 rim ridges (10-20m), 4 interior plateaus (8m), 90 spires | 560m to the gap; ravine is impassable | **54.6m** (canyon to rim) |
| **Saltpan Crossing** | Tidal flat, mostly shallow water | 2 causeway ridges (14-18m), 6 hummock plateaus (8-10m), 1 wide basin (-6m), 14 shallow patches | 560m; hummocks hold the resources | **24.3m** (causeway to basin) |

**Note on heightmap span:** the "span" column reports the min-to-max
height range found by `_test_new_maps.gd`'s 9-point sample (a 3x3
grid spanning 60% of each map's half_extents). It understates the
true span because the sample misses the deepest canyons and tallest
peaks. The on-disk heightmap uses the full height_scale range;
for example, pillars_of_the_sky has a height_scale of 60m and a
normalized range of -0.605 to +0.369, so the actual ground can be
-36m in the canyon floor and +22m on the rim ridges, even though
the 9-point sample only sees -35.8m to +18.8m.

## Heightmap pipeline (the actual terrain)

Each map's JSON now carries a `terrain` block with:

```json
{
  "generator": "v2",
  "height_scale": 40.0,           // heightmap normalization ceiling
  "pixels_per_unit": 1.0,        // 1 pixel per world unit (800x800 + 1 = 801)
  "features": [...],              // plateau/ramp/canyon/ridge/hill entries
  "post_pass": {                  // applied on top of features
    "noise": { "frequency": 0.011, "amplitude": 3.0, "octaves": 3 }
  },
  "heightmap": "res://data/maps/<map>_height.png",
  "surfacemap": "res://data/maps/<map>_surface.png"
}
```

The `heightmap` PNG is the runtime's source of truth for terrain Y
(terrain_builder.gd:height_at reads it via bilinear sampling). The
analytic path (hills[] + features[] + noise) is bypassed when a heightmap
is present. The `features[]` array is still in the JSON for two reasons:
(1) `build_terrain.py` reads it to bake the heightmap PNG, and (2) the
runtime's `_resolve_features()` uses plateau/canyon/ridge entries to
auto-emit `cliffs[]` colliders.

### Per-map height_scale

The `height_scale` is sized per map so the heightmap's pixel range
covers the actual terrain with some headroom:

| Map | height_scale | Why |
|---|---|---|
| cinder_flats | 24.0 | 8 cone hills at 14-18m + noise → 22m peak |
| the_reef | 30.0 | 18m basin + 20m rim ridges → 38m span |
| sentinel_gate | 40.0 | 26m plateau + 18m rim ridges + 8m basin → 33m span |
| pinewatch | 30.0 | 22m hills + 18m cross-ridges + 10m basin → 37m span |
| the_confluence | 24.0 | 12-18m bank ridges, central channels cut through → 20m span |
| hollow_throne | 40.0 | 26m plateau + 18m rim hills → 36m span |
| bitterroot | 36.0 | 22m peak hills + 14m ridges → 36m span |
| the_long_march | 24.0 | 12-18m bank ridges + 8m central island → 22m span |
| the_iron_square | 22.0 | 14m district hills + 6m central basin → 20m span |
| the_frostline | 24.0 | 18m ice ridges + 10m interior plateaus → 28m span |
| pillars_of_the_sky | 60.0 | 35m canyon + 20m rim ridges → 55m span |
| saltpan_crossing | 24.0 | 18m causeway ridges + 6m saltpan basin → 24m span |

A height_scale that's too low clips the heightmap at +/- height_scale and
loses detail. Too high, and the heightmap uses only a fraction of its
16-bit pixel range (which the sampler can still resolve, but it makes
shallow features harder to navmesh-bake).

### Why the noise post_pass is non-negotiable

Without `post_pass.noise`, the baked heightmap is a pure mathematical
function of the features — a 18m plateau would have a perfectly flat
top, and a 35m canyon would have a perfectly smooth bottom. Adding
3m of low-frequency noise on top of every map gives the ground an
organic, sculpted feel that the analytic primitives can't provide.

The noise amplitude is 3.0 with frequency 0.011, matching what
`sentinel_divide` ships with (post_pass.noise at the same params).
The 3m peak-to-peak at 0.011 frequency produces a ~12° slope, well
within the 35° walkable limit, so the navmesh still bakes cleanly.

## Per-map notes

### Cinder Flats

**The concept:** A dark volcanic plain split down the middle by a wide
impassable lava channel. One bridge near the south is the fast crossing;
a cooling shallows near the north is the slow one. The lava banks are
rimmed with oil. The lava itself is impassable; the cooling shallows is
walkable but slow.

**Why it plays different:** Movement is constrained to the bridge or the
ford. Whoever holds the bridge holds map control; whoever pushes through
the cooling shallows pays a real time penalty. Volcanic surface means
fire-related mechanics (if added) would interact meaningfully.

**Schemas exercised:** `water_areas` (1), `bridges` (1), `shallow_water_areas`
(1), `surface_zones` (4: volcanic, scree), `props` (8 spires),
`terrain.heightmap` (1.4m span of rolling noise).

### The Reef

**The concept:** A field of tall rock spires in a 200×300 rectangle
at the center of the map. Movement passes freely between the spires;
LOS does not. Oil and lumber fill the gaps; a high-yield metal+crystal
cluster sits dead-center.

**Why it plays different:** Pure ambush-and-counter-ambush map. Scout
gameplay is essential — without a sensor, the first engagement is a
knife-fight at point-blank range. The center is the obvious prize but
also the most dangerous ground to take.

**Schemas exercised:** `surface_zones` (3: sand, dirt, sand), `props`
(22 spires), `resource_nodes` (21 — high count for the high-LOS-loss
economy).

### Sentinel Gate

**The concept:** Two cliff walls bracket a long north-south valley. Two
narrow gates — one near each end — are the only passages between the
valley and the surrounding high ground. A central mesa plateau commands
the whole valley floor, with a single ramp on its east face.

**Why it plays different:** The mesa is the obvious chokepoint — whoever
holds it controls LOS down the entire valley. But the mesa is small and
the ramp is one, so the defender has the natural advantage. The
heightmap reads the mesa at 18.5m, giving a real elevation bonus for
the holder.

**Schemas exercised:** `cliffs` (12 face_0), `terrain.features` (plateau
+ ramp), `surface_zones` (4: forest, rocky, dirt on the mesa), `props`
(80 trees on the high ground).

### Pinewatch

**The concept:** Old-growth pine covers 80% of the map. A handful of
small clearings are the only places to see further than 30m. Lumber
economy is dense, but each node is invisible from the next.

**Why it plays different:** Infantry-and-recon only. Vehicles struggle
to path through the tree trunks and are slow even on the clearings.
Scouting is the entire game — first to spot the enemy's base wins.
Pure visibility advantage. The 2.1m heightmap variation is mostly the
ground noise; the forest density is the real mechanic.

**Schemas exercised:** `surface_zones` (5: forest, steppe_grass), `props`
(856 trees, ~2 per 5m²), `resource_nodes` (20, 16 of which are lumber).

### The Confluence

**The concept:** A wide river splits into three channels as it crosses
the map. The outer two channels have bridges; the central one is shallow
enough to ford. Asymmetric resources: lumber on the player's bank, oil
on the enemy's, metal and crystal in the central islands.

**Why it plays different:** Three crossing options create genuine
multi-axis decision-making. A team that spreads harvesters across all
three routes denies the defender a single decisive counter. The shallow
ford is a slow but real third option.

**Schemas exercised:** `water_areas` (2), `shallow_water_areas` (1),
`bridges` (2), `surface_zones` (4: forest, dry_grass, gravel), `props`
(120 trees on player side, 80 shrubs on enemy side).

### Hollow Throne

**The concept:** A circular bowl with a central plateau. The plateau is
reachable by exactly four ramps — one at each cardinal direction — and
holds the map's only high-yield metal and crystal seams. The crater
floor is wide open; the rim is wooded.

**Why it plays different:** Defender's paradise. The center is a
fortress. Attackers must commit to one of 4 directions, and the rim
trees let the defender scout all four approaches from a single
position. Whoever holds the rim holds the throne. The heightmap reads
the plateau at 16.8m and the ring hills at 14m, so the central fortress
has a 2.8m elevation advantage over the rim.

**Schemas exercised:** `terrain.features` (plateau + 4 ramps), 8 ring
hills (translated to features[hill] for the bake), `surface_zones` (4:
dirt, dry_grass, forest), `props` (75 trees on the rim only).

### Bitterroot

**The concept:** Six rolling hills break up the map; marshy pockets fill
the low ground between them. The hills give real elevation bonuses for
indirect fire; the marsh slows vehicles to a crawl. Resources are spread
across every type, but no node is particularly high-yield.

**Why it plays different:** Tactician's map. Hills reward indirect fire
and good positioning; marsh forces vehicle diversions. A map where
micro and macro play matter more than the unit roster. The heightmap
reads 6 hills up to 16m plus 3m of noise, so the slope variation gives
real elevation-bonus gameplay.

**Schemas exercised:** `hills` (6 — translated to features[hill] for the
bake), `surface_zones` (5: marsh, steppe_grass), `props` (120 trees + 20
boulders/spires), `resource_nodes` (26 — even mix).

### The Long March

**The concept:** A wide deep river runs the full length of the map. A
single causeway bridges it near the south; small islands in the center
hold the only high-yield metal; shallow fords at the extreme north and
south are the slow alternative.

**Why it plays different:** The most lopsided map in the set. There's
one good crossing (the causeway) and one good prize (the central
island). Whoever holds both wins decisively. The fords are real
third options but they eat so much time they're usually scouting
detours, not real crossing options.

**Schemas exercised:** `water_areas` (1 — the river), `shallow_water_areas`
(2 — the fords), `bridges` (1 — the causeway), `surface_zones` (9: dirt,
gravel, forest, steppe_grass), `props` (140 trees on the banks).

### The Iron Square

**The concept:** A small city's commercial district, noble_oaks pushed
to its extreme. A residential district on the player's side, a
commercial district on the enemy's, and an industrial complex in the
middle. A network of dirt roads connects everything.

**Why it plays different:** Pure urban C&C. Short LOS, building cover
everywhere, ambush and counter-ambush through alleys. Vehicles can
crash through houses but are slow doing so. Bring short-range weapons
and stay indoors.

**Schemas exercised:** `surface_zones` (2: cobble, dirt), `props` (24
civic building props, 40 street trees), `roads` (4 dirt roads), `resource_nodes`
(7 — asymmetric, industrial in the middle).

### The Frostline

**The concept:** A flat ice plain. A frozen river runs the length of
the map, slightly recessed. Scattered boulders and spires are the only
cover.

**Why it plays different:** The cleanest map in the set: long sight
lines, fast movement, and nowhere to hide. Artillery and ranged favored.
Whoever gets the first good position controls the engagement range.
The 2.4m heightmap variation is the noise baseline — small enough that
nothing is hidden in the terrain, big enough to give a sense of
sculpted ice.

**Schemas exercised:** `surface_zones` (1: ice), `shallow_water_areas`
(1 — the frozen river), `props` (24 boulders + 4 spires), `resource_nodes`
(10, even spread).

### Pillars of the Sky

**The concept:** A deep canyon bisects the map. Its sheer walls are
impassable, so the only crossings are at the extreme north and south.
The high ground on either side bristles with rock spires.

**Why it plays different:** Vertical LOS. Spires block view but not
movement. The ravine is impassable. Cross the ravine and you win.
The eastern side has the higher-yield mineral seams; the western side
is the easier approach. Climb, don't try to cross the middle. The
heightmap reads the canyon floor at -35m and the rim at +3m, so the
36.7m span is the dominant visual element.

**Schemas exercised:** `terrain.features` (3 canyons), `cliffs` (8
strata_0), `surface_zones` (3: rocky, gravel), `props` (90 spires —
45 per side).

### Saltpan Crossing

**The concept:** A tidal flat where shallow water covers most of the
ground. A few dry hummocks rise above the waterline; a single elevated
causeway of dry ground runs the length of the map on its eastern edge.

**Why it plays different:** Movement through the shallows is slow but
always possible; the causeway is the express route. The hummocks hold
the resources; the causeway is the chokepoint. Hold the causeway, but
the hummocks are where the resources are — a forcing function that
rewards teams that can fight on two terrains at once.

**Schemas exercised:** `shallow_water_areas` (14 patches), `surface_zones`
(10: dirt, steppe_grass, sand), `props` (60 shrubs on the causeway),
`resource_nodes` (10 — biased toward the hummocks).

## How to read the JSON

Each file is a single JSON object, top-level keys in FIELD_SPEC order
(map_catalog.gd:432–754). The schema validator at
`map_catalog.gd:_load_map_file` decodes arrays-of-numbers to real
`Vector3`/`Vector2`/`Color` types before applying `world_scale`, so the
on-disk values are pre-scale (a `map_half_extents: 400.0` is 400
regardless of the `world_scale` multiplier — see `_apply_world_scale`).

A minimal map is just `{schema_version, name, description,
map_half_extents, ground_color, spawns[]}`. We additionally author:
`base_zones` (paired with `spawns[]` — the HQ-placement zone the player
drops into), `resource_nodes[]`, `surface_zones[]`, `props[]`,
`hills[]`, `cliffs[]`, `water_areas[]`, `shallow_water_areas[]`,
`bridges[]`, `roads[]`, `terrain.{features[], heightmap, surfacemap, ...}`
(the v2 heightmap-driven authoring format with 6 baked PNGs), and
`environment` (per-map sky / sun / fog / tonemap).

## Verification

`scratch/generate_maps.py` runs a static mirror of the FIELD_SPEC
validator and the runtime's `lint_spawn_fairness` before writing each
file. `scratch/bake_heightmaps.py` then invokes
`prototype/tools/terrain/build_terrain.py` per map to bake the 6 PNGs
and patch the JSON to reference them. After the bake, the script
verifies each heightmap has real (non-flat) variation as a smoke test
for "the bake produced a uniform PNG." Then `prototype/_test_new_maps.gd`
loads every JSON through the real `MapCatalog` and confirms:

- `terrain.heightmap` is set in every JSON (the bake step ran)
- `TerrainBuilder.height_at()` returns finite values across a 9-point
  grid spanning 60% of each map's half_extents
- The min/max height span across that grid is > 0.5m (a working
  heightmap; a flat one would be ~0m)
- Every spawn has ≥ 2 resource_nodes within `0.6 * half_extents = 240`
  units (the same radius the runtime's fairness lint checks)
- Every spawn HQ sits on legal ground (not in water, not on a building
  obstacle, not on a cliff footprint)

To re-run the full pipeline from scratch:

```powershell
cd E:\Kitbash-Command\scratch
python generate_maps.py
python bake_heightmaps.py
& "E:\Kitbash-Command\prototype\Godot_v4.7.1-stable_win64_console.exe" --headless --script _test_new_maps.gd --path E:\Kitbash-Command\prototype --quit
```

Expected output: 12 `[PASS]` lines on the first test pass (finite
heights), 12 more on the second pass (heightmap span > 0.5m), and one
`[ALL PASS] all 12 new maps have real (non-flat) baked heightmaps`.

## What's intentionally NOT in these maps

- **No in-JSON `sculpt_grid` (the 36k-float embedded heightmap).**
  Twin_streams_v2 and noble_oaks embed one (sculpt_grid.dim 96 and 192
  respectively). The v2 generator path with the `_height.png` PNG
  reference makes the in-JSON grid redundant: the PNG IS the
  heightmap. noble_oaks specifically uses a sculpt_grid AND a heightmap
  PNG; sentinel_divide uses just a PNG. We follow sentinel_divide.
  Halving the JSON file size from 200KB to 25KB was an unintended
  side benefit of the v2 path.

- **No `disable_ambient_scatter` or `flat_ground_collider` overrides.**
  We accept the default ambient scatter and the subdivided heightmap
  collider; the cost is fine for a 400-half-extent map. If a
  perf profile later flags a specific map, drop the override into
  the JSON — both fields are scalar `bool` and the schema accepts
  them.

- **No per-pixel authored detail.** A hand-sculpted map's heightmap
  contains ridges, valleys, and rock outcrops the author placed
  one-pixel-at-a-time. Our heightmaps are the analytic features
  (plateau/canyon/ridge/hill) summed with low-frequency noise
  (amplitude 3, frequency 0.011, octaves 3). For "I want a hill
  exactly there" custom shape, the escape hatch is a per-map
  `sculpt_grid` in the JSON — but for the 12 maps in this set the
  features + noise combo is enough to make the terrain interesting
  to fight on.
