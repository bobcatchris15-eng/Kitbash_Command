# Kitbash Command — Reconstruction Spec

> **How to use this document.** It is written to be the *only* input an
> implementing agent needs. §0-§2 are the premise and the constraints; §3-§4 are
> the data and the math (these are load-bearing — the numbers are the balance);
> §5-§8 are the systems; §9-§10 are the asset pipelines; §11-§14 are how to
> verify, what order to build in, which mistakes were already made here, and
> what the minimum viable version is. If you are cutting scope, cut from §14
> upward, never from §3-§4.

A complete, self-contained description of the project, written so an agent with
no access to this repository can rebuild it from scratch. Everything below is
distilled from the shipped implementation (Godot 4.7.1, ~206 GDScript files /
~96k lines under `prototype/scripts`, plus ~48k lines of Python/GDScript
authoring tools). Numbers quoted are the numbers the game actually uses.

---

## 0. One-paragraph summary

**Kitbash Command** is a real-time-strategy prototype whose central premise is
that *the player designs the units*. It is Spore's vehicle creator wired into a
Command & Conquer skirmish: you build blueprints in a 3D Design Lab by dropping
weapon/support modules onto an authored hull, stretching them with continuous
parametric tweaks that feed a live stat readout, painting armor onto individual
hull facets, then you field those blueprints in a base-building skirmish with
harvesters, refineries, tiered production queues, a tech tree, fog of war and a
utility-scoring AI. The simulation is deep (threshold-based armor, per-shot
alpha, directional armor, subsystem stripping, drivetrain load curves, energy
budgets); the presentation is deliberately pulpy — realistic terrain and VFX,
cartoon-bright vehicles, and ordnance that goes "kapow" in a synthesised human
voice.

**The design thesis, and the test everything is judged against:**

> Two players independently building "a heavily armored frontline anti-air unit"
> must land on functionally *distinct* units — not because they picked different
> parts off a short list, but because they set continuous tweaks differently
> (barrel length vs traverse speed vs magazine size vs where armor mass sits).

If two "same concept" builds converge, or if the only differentiation is a
discrete part swap, the design has failed. (The named failure mode is *Forged
Battalion*: four unit types per factory, weapons barely differentiated, no
tweaking, colour-only customisation.)

---

## 1. Tone and art direction — the contract

The aesthetic rests on one rule: **exactly one side of any pairing is allowed to
be funny. Never both, never neither.**

| Channel | Register | Why |
|---|---|---|
| Terrain, weather, lighting | Sincere | The straight man. If the world winks, nothing lands. |
| Unit colour and proportion | Absurd | The punchline. |
| Unit *construction quality* | Sincere | A sloppy kitbash reads as a bug, not a joke. |
| Visual effects | Sincere | Photoreal muzzle bloom, real smoke, mud kicked up. |
| Audio (ordnance only) | Absurd | Vocalised "pyoo" / "ka-PAOW". |
| Audio (everything else) | Sincere | Engines, servos, radio comms, ambience, UI. |
| Interface chrome | Sincere | "An instrument housing, not a feature." |

Supporting rules:

- **Miniature scale, 1:16, and the environment is what moves.** Units are model
  kits in a real backyard. Do *not* shrink units — Godot's Recast navmesh baker
  sizes its voxel grid from `cell_size` and voxel count scales as
  `(extent/cell_size)^2`; shrinking units to ~0.4 m needs ~256x the voxels of a
  configuration already measured as unshippable. Instead multiply *map geometry
  and dressing* by a `world_scale` constant (single source of truth in a
  `world_scale.gd`) and leave units, blueprints and all combat math untouched.
  Grids derived from the map (navmesh, flow field, vision, fog) must be
  self-bounding — cell size grows with the map so cell *count* stays flat.
- **Scale anchoring.** Every piece of environment dressing is a small real-world
  object standing in for a large one: pebbles are boulders, marsh grass is
  forest, a tire track is a ravine, a puddle is a riverbed. Test: *would a photo
  of this object with no size reference be ambiguous about its size?* Never put
  a real-scale human object (door, window, road marking, fencepost) in frame.
- **Camera optics: tilt-shift.** A horizontal band of sharpness with blur above
  and below — not a radial vignette. `CameraAttributesPractical` near+far DOF,
  distances tracked to the camera's own distance to the focal plane. Keep
  `dof_blur_amount` low (0.08); the miniature cue is the *presence* of falloff,
  and a strong blur destroys unit readability. On the RTS camera, widen the DOF
  transition with height (10 -> 50 as the camera rises) or the band reads as
  "everything blurred" at one end and "no blur" at the other. Skip near-blur on
  a panning camera (it reads as a doubled image).
- **Lighting: heavy overcast, flat diffused.** High ambient, low directional,
  soft long shadows, bright neutral-grey sky, no strong single sun. This is the
  sincere register, it keeps unit paint reading at authored saturation
  everywhere (faction identity is carried *entirely* by colour), and it
  suppresses specular noise on brushed metal.
- **Motion: rigid miniatures.** No acceleration curves, no body roll, no
  suspension travel, no settling or bobbing. What *is* present: wheels/treads/
  rotors spin, articulated running gear articulates (geometry, not physics),
  direction changes are instant but never teleported. Mass affects the numbers,
  never the animation curve.
- **Units are polished kitbashes.** However arbitrary the player's combination,
  the result must look like an injection-moulded model kit: every module
  attachment gets a transition element (collar, bolted flange, fairing, weld
  fillet, rubber boot), and all factions share panel-line/rivet/bolt grammar so
  any two random modules look like they came from the same factory.
- **Faction identity is colour and decals only, never silhouette** — because the
  player customises the silhouette, so shape can never be a reliable signal.
- **No emoji or dingbats in UI text.** Box-drawing and arrows are fine.

---

## 2. Technical baseline

- **Engine:** Godot 4.7.1, Forward+ renderer. Authored for 4.4+ (`.uid`
  sidecars, `format=4` theme resources). Viewport 1920x1080, stretch mode
  `canvas_items`, aspect `expand`, TAA + screen-space AA on.
- **Language:** GDScript throughout. No C#, no GDExtension.
- **Main scene:** `MainMenu.tscn`.
- **Autoloads** (order matters — later ones may read earlier ones):

  | Autoload | Owns |
  |---|---|
  | `WindowFit` | window sizing / fit-to-display |
  | `SceneRouter` | async scene changes, loading screen, preload warming |
  | `TutorialManager` | legacy guided tutorial |
  | `TwoPhaseTutorialManager` | the shipped 23-step two-phase tutorial |
  | `MatchConfig` | carries the `MatchRuleSet` across the scene change |
  | `OperationsManager` | campaign state (stages, itinerary, rosters) |
  | `DebugSettings` | dev toggles (infinite resources, overlays) |
  | `CursorManager` | cursor set + context cursors |
  | `AudioManager` | manifest-driven SFX banks, music state machine |
  | `SettingsService` | persisted user settings |
  | `InputService` | input mapping / abstraction |
  | `SystemLayer` | always-on-top system UI (pause, settings) |
  | `DesignRecord` | per-design usage records |
  | `CommandRegistry` | order/command definitions |

- **Scenes (18):** `MainMenu`, `MatchSetup`, `Battle`, `OperationsSetup`,
  `OperationsDraft`, `MainLab`, `UI_StatBlock`, `UI_PartsMenu`,
  `UI_ArmorStationPanel`, `Gizmo3D`, `LabEnvironment`,
  `PaintStationEnvironment`, `BlueprintLibrary`, `HullBuilder`,
  `ModularHullBuilder`, `Livery`, `Loading`, `LoadingPreview`.
- **Shaders (21, all hand-written `.gdshader`):** `terrain_ground`, `water`,
  `hull_faction_material`, `armor_surface`, `energy_shield`, `selection_ring`,
  `inworld_hp_bar`, `phosphor_display`, `crt_warmup`, `brushed_aluminum_panel`,
  `knurled_metal`, `rubber_gasket`, `rubber_stamp_ink`, `cutting_mat`,
  `wood_desktop`, `ui_material`, `ui_prop`, `red_steel`, `deploy_glass`,
  `gravitic_lens`, `pan_blur`.
- **No automated test suite.** Verification is (1) headless parse checks that
  load scripts with `CACHE_MODE_IGNORE`, (2) one-off headless "probe" SceneTree
  scripts that boot a slice of the game and print findings, (3) manual
  playtest. Build the probe habit early; it is the de-facto regression harness.

### Repo layout

```
prototype/
  project.godot
  scenes/*.tscn                 18 scenes
  scripts/                      206 .gd files, ~96k lines
    battle/                     match runtime: director, services, units, AI
      ai/ buildings/ economy/ movement/ orders/ units/ vision/ hud/
    core/                       input, settings, navigation, pointer gain
    hud/                        the ONLY in-match HUD
    ui/                         out-of-match widget/material library
    tutorial/ tutorial_two_phase/
  shaders/*.gdshader
  assets/
    models/hulls/               <id>.glb + <id>.json + <id>_collision.res
    models/parts/               ~292 authored .glb kit parts
    models/buildings/ terrain/ hull_primitives/ ui/
    audio/                      generated wavs + audio_manifest.json
    hud/icons/                  authored monochrome SVGs
    blueprints/default_roster/  built-in blueprints
  data/
    maps/                       14 map .json + baked terrain textures
    loadout/                    20 default player designs
    enemy/                      AI rosters
  tools/                        336 files: probes, bakers, generators
    blender/                    39 procedural authoring scripts
    audio/                      procedural audio synthesis package
docs/design/  docs/specs/       design + spec documents
```

### The architectural rule that shaped the codebase

Every stat has exactly **one** implementation, called by *both* the Design Lab
and the simulation. This was learned the hard way twice: the Lab once carried a
"deliberately simplified re-derivation" of weight capacity that knew 4 of 17
locomotion types, and a local armor table that displayed the *explosive*
threshold labelled as Energy. Both were fixed by deleting the copy, not by
correcting it.

So: shared static analyzers, each taking a live hull node and returning a
**fully-populated dictionary on every path** (including for a null hull), are
the backbone:

| Analyzer | Answers |
|---|---|
| `DesignStats.analyze(hull)` | the whole design's numbers, composed from the four below |
| `Drivetrain.analyze(hull)` | weight, carried/loco split, capacity, load ratio, top speed, move speed |
| `PowerBudget.analyze(hull)` | storage, generation, draw, net, endurance |
| `WeaponRange.analyze(hull)` | longest/shortest reach, vision, has_weapons |
| `WeaponAlpha.analyze(hull)` | per-shot damage and what it is worth against armor |
| `DamageResolver.resolve(...)` | threshold + reduction for a specific hit |
| `ModuleCatalog.compute_hull_*()` | hull HP / weight / cost from type, scale |
| `DesignCosting.blueprint_cost()` | credits, build time, required tech buildings |

If a new figure is wanted, add it to the analyzer — never compute it at a call
site.
---

## 3. The data model

### 3.1 Blueprint JSON (schema version 3.0)

A blueprint is the single unit of authorship. Saved designs live in
`user://blueprints/<id>.json`; the Design Lab's "Test in Arena" writes a
**scratch** file (`user://lab_scratch.json`) instead, so a trip to the proving
ground never mints a roster entry. Only an explicit Save creates a library
design. Built-in designs ship as identical JSON under `data/loadout/`,
`data/enemy/` and `assets/blueprints/default_roster/`.

```jsonc
{
  "version": 3.0,
  "id": "default_bastion_gun_turret",
  "name": "Bastion Gun Turret",
  "hull_type": "bunker_main_meridian",     // catalog id (hull or foundation)
  "hull_scale":  {"x":1.0,"y":1.0,"z":1.0},// player scaling, 0.5 .. 2.0 per axis
  "hull_size":   {"x":3.22,"y":2.15,"z":3.0}, // resolved size, for reload fidelity
  "armor_material": "hardened_steel",      // hull baseline plate
  "armor_thickness": 1.5,                  // multiplies every threshold
  "faction": "industrialists",             // cosmetic (livery); armor_weight_mult only
  "nose_taper": 1.0,
  "locomotion": { "type_id": "tracked_treads", "settings": { ... } },
  "armor": {                               // v3.0: painted per-facet coverage
    "assignments": [
      {"facet": 7, "type_id": "reactive_armor", "material": "reactive_armor",
       "thickness": 1.0}
    ]
  },
  "modules": [
    {
      "type_id": "coil_gun",
      "name": "Coil Gun",
      "position": {"x":0,"y":1.07,"z":0},   // hull-local
      "rotation": {"x":-0.11,"y":0.002,"z":-0.046},
      "scale":    {"x":1,"y":1,"z":1},      // gizmo stretch, volume-scales stats
      "scale_flip_x": false,                // mirrored sibling flag
      "facet": "top",                       // classified facet label
      "facet_size": {},
      "mount_normal": {"x":0.045,"y":0.99,"z":-0.119},
      "mount_style": "pintle",              // turret | pintle | frame_built
      "sponson": false,                     // wall-mounted through a blister
      "yaw_offset": 0.0,
      "tweaks": {"caliber": 1.4, "barrel_length": 1.8, "ammo": "ap"},
      "stats": {"hp":90,"weight":120,"dps":88,"cost_metal":55,"cost_crystal":30}
    }
  ]
}
```

Rules:

- `stats` in a module entry is a **cache for display**, never authority. Stats
  are always recomputed from catalog + tweaks + scale at load.
- An unknown `type_id` is **skipped** on reconstruct, and therefore also skipped
  when costing — never charge for something that will not be built.
- Bump `version` only when a schema change could silently mis-load older saves
  (1.0 -> 2.0 when the hull roster was re-baked; 2.0 -> 3.0 when armor moved out
  of `modules` into the top-level `armor` block). Stamp the constant at the
  *write* site or every save is born stale.
- `reconstruct_vehicle(data, parent, is_designer, faction_override)` is the one
  function that turns JSON into a live node tree, used identically by the Lab,
  the battle spawner and the menu showcase.

### 3.2 The module catalog

One static catalog dictionary keyed by `type_id`. Weapons, modules, generators
and locomotion are literal entries in code; **hulls are data-driven** — a hull
loader scans same-stem `.glb` + `.json` sidecar pairs from
`assets/models/hulls/` (built-in) and `user://mods/hulls/` (player mods) once,
caches them, and merges them into the same dictionary shape. The merged catalog
is cached and invalidated by identity against the hull dictionary (it is read
per hit and per tick — do not rebuild it per call).

Common entry fields: `name`, `category` (`weapon|module|generator|armor|
locomotion|hull`), `hp`, `weight`, `metal`, `crystal`, `dps`, `size` (Vector3,
authoring box), `color`, plus optional `required_building`, `base_traverse`,
`pintle_min_up_alignment`, `energy_capacity`, `power_output`, `vision_bonus`,
`traits`, `base_weight_capacity`, `base_top_speed`.

**Weapons and modules.** The shipped catalog holds 67 code-authored entries —
39 `weapon`, 8 `module`, 6 `generator`, 1 `armor`, 13 `locomotion` — on top of
the 127 sidecar-loaded hulls. `hp`/`weight`/`dps` are
base values before tweaks; M/C are metal/crystal:

| id | hp | weight | dps | M | C | role |
|---|---|---|---|---|---|---|
| basic_cannon | 100 | 80 | 40 | 30 | 0 | Direct-Fire Guns |
| heavy_machine_gun | 60 | 40 | 32.5 | 15 | 0 | Direct-Fire Guns |
| rotary_cannon | 80 | 110 | 105 | 45 | 5 | Direct-Fire Guns |
| autocannon | 75 | 65 | 62 | 26 | 0 | Direct-Fire Guns |
| anti_materiel_rifle | 60 | 95 | 78 | 34 | 18 | Direct-Fire Guns |
| recoilless_rifle | 80 | 70 | 85 | 40 | 5 | Direct-Fire Guns |
| flamethrower | 70 | 50 | 112 | 35 | 15 | Direct-Fire Guns |
| ballista | 110 | 140 | 70 | 35 | 0 | Direct-Fire Guns |
| gauss_railgun | 120 | 180 | 99 | 80 | 40 | Energy & EM |
| coil_gun | 90 | 120 | 88 | 55 | 30 | Energy & EM |
| heavy_laser | 75 | 60 | 112 | 30 | 20 | Energy & EM |
| ion_cannon | 130 | 150 | 97.5 | 70 | 65 | Energy & EM |
| arc_projector | 70 | 85 | 22 | 24 | 26 | Energy & EM |
| microwave_emitter | 65 | 105 | 30 | 30 | 32 | Energy & EM |
| particle_lance | 90 | 220 | 120 | 60 | 55 | Energy & EM |
| artillery | 150 | 250 | 90 | 100 | 10 | Indirect Fire |
| mortar_array | 80 | 90 | 50 | 40 | 0 | Indirect Fire |
| spigot_mortar | 80 | 130 | 55 | 38 | 0 | Indirect Fire |
| napalm_mortar | 85 | 95 | 45 | 42 | 12 | Indirect Fire |
| rocket_artillery | 95 | 190 | 85 | 52 | 8 | Indirect Fire |
| cluster_dispenser | 90 | 100 | 65 | 45 | 10 | Indirect Fire |
| plasma_lobber | 110 | 120 | 95 | 50 | 60 | Indirect Fire |
| mk19_grenade_launcher | 70 | 55 | 58 | 28 | 0 | Indirect Fire |
| guided_missile | 70 | 60 | 55 | 30 | 15 | Missiles |
| missile_pod | 100 | 150 | 72 | 50 | 10 | Missiles |
| hypervelocity_missile | 70 | 110 | 92 | 34 | 18 | Missiles |
| sam_launcher | 75 | 130 | 70 | 40 | 20 | Missiles |
| loitering_munition | 65 | 120 | 65 | 36 | 22 | Missiles |
| anti_radiation_missile | 70 | 115 | 75 | 33 | 26 | Missiles |
| bunker_buster | 85 | 175 | 95 | 48 | 16 | Missiles |
| cruise_missile | 80 | 200 | 88 | 55 | 24 | Missiles |
| ciws | 80 | 90 | 10 | 40 | 15 | Point Defense |
| pd_laser | 50 | 35 | 5 | 20 | 30 | Point Defense |
| flak_cannon | 90 | 110 | 15 | 45 | 10 | Point Defense |
| aa_autocannon | 80 | 125 | 68 | 42 | 6 | Point Defense |
| smoke_discharger | 40 | 30 | 0 | 18 | 0 | Deployables |
| mine_layer | 90 | 85 | 40 | 45 | 5 | Deployables |
| drone_carrier | 250 | 350 | 85 | 180 | 90 | Deployables |
| sensor_beacon_launcher | 55 | 60 | 0 | 22 | 18 | Deployables |
| resource_harvester | 150 | 80 | 0 | 100 | 50 | Support |
| resource_bay | 120 | 90 | 0 | 60 | 10 | Support |
| repair_array | 100 | 70 | 0 | 40 | 20 | Support |
| sensor_suite | 60 | 45 | 0 | 25 | 20 | Support (vision +38) |
| heavy_sensor_suite | 120 | 95 | 0 | 75 | 60 | Support (vision +114) |
| directional_radar | 100 | 80 | 0 | 75 | 60 | Support (vision +230, arc-limited) |
| energy_barrier_projector | 250 | 110 | 0 | 60 | 50 | Support |
| heavy_barrier_projector | 400 | 160 | 0 | 90 | 75 | Support |
| booster_rack | 40 | 45 | 0 | 35 | 15 | Support (speed boost) |
| fusion_generator | 140 | 160 | 0 | 90 | 60 | Power (14.0 e/s) |
| diesel_generator | 110 | 110 | 0 | 60 | 10 | Power (8.5 e/s) |
| thermo_generator | 70 | 55 | 0 | 40 | 20 | Power (4.5 e/s) |
| capacitor_bank | 60 | 50 | 0 | 35 | 25 | Power (45 storage) |
| flywheel_storage | 130 | 140 | 0 | 80 | 15 | Power (85 storage) |
| solid_state_battery | 80 | 70 | 0 | 45 | 40 | Power (60 storage) |

A **structural** family (block, dome, slab, wedge, girder, I-beam) is specified
and its machinery still exists in the codebase, but no structural entry is in
the shipped catalog today — the equivalent primitives live in the Hull Builder
instead. Treat §5.6 as the design contract for any freely-scalable part.

**Weapon fire profiles** are a separate contiguous table merged into the catalog
at build time, deliberately kept as one block so a balance sweep can rewrite it
mechanically. `fire_rate` is a **shot interval in seconds** (lower = faster).
Per-shot alpha is `dps * fire_rate`, and the armor thresholds gate on *that*:

| id | interval s | reach | id | interval s | reach |
|---|---|---|---|---|---|
| basic_cannon | 1.8 | 38 | particle_lance | 5.5 | 58 |
| heavy_machine_gun | 0.66 | 26 | spigot_mortar | 5.0 | 16 |
| rotary_cannon | 0.05 | 28 | rocket_artillery | 3.0 | 100 |
| autocannon | 0.28 | 30 | hypervelocity_missile | 2.2 | 44 |
| anti_materiel_rifle | 4.5 | 66 | sam_launcher | 2.6 | 62 |
| recoilless_rifle | 3.2 | 38 | loitering_munition | 4.0 | 120 |
| gauss_railgun | 3.5 | 72 | anti_radiation_missile | 3.4 | 60 |
| coil_gun | 1.6 | 52 | bunker_buster | 4.2 | 36 |
| artillery | 4.5 | 140 | cruise_missile | 5.0 | 170 |
| mortar_array | 2.0 | 55 | aa_autocannon | 0.20 | 38 |
| guided_missile | 3.0 | 55 | sensor_beacon_launcher | 6.0 | 46 |
| missile_pod | 2.8 | 48 | ciws | 0.06 | 22 |
| drone_carrier | 5.0 | 55 | pd_laser | 0.1 | 24 |
| cluster_dispenser | 3.0 | 34 | flak_cannon | 1.2 | 40 |
| flamethrower | 0.06 | 11 | mk19_grenade_launcher | 0.5 | 30 |
| heavy_laser | 0.05 | 34 | napalm_mortar | 2.6 | 40 |
| plasma_lobber | 2.2 | 32 | mine_layer | 3.5 | 14 |
| arc_projector | 0.9 | 12 | ballista | 4.0 | 34 |
| ion_cannon | 3.2 | 50 | smoke_discharger | 2.5 | 20 |
| microwave_emitter | 0.35 | 20 | repair_array | 0.15 | 22 |

Default for anything unlisted: `{interval 1.0, reach 15.0}`.

**Range tiers.** Reach is anchored to *vision*, not to an absolute band, so the
number tells you how a weapon is meant to be used. Nominal vision (a plain
medium hull, post-scale) is **38.0**:

| Tier | x vision | Meaning |
|---|---|---|
| Point Blank | ≤0.4 | self-defence; dies to anything kiting it |
| Close | ≤0.65 | has to be in the fight to contribute |
| Direct Fire | ≤1.1 | shoots what its own hull can see |
| Overwatch | ≤2.0 | out-ranges its own eyes; a spotter helps |
| Operational | >2.0 | **cannot self-acquire**; spotter-only |

The last two tiers are the point of the exercise: a T5 weapon is structurally
incapable of finding its own targets, which is what makes a scout worth
building. Before this retune, 26 of 45 weapons out-ranged their own hull's
vision and the whole 7-50 band played as one distance.

**Indirect fire** (`artillery, mortar_array, rocket_artillery, spigot_mortar,
napalm_mortar, mk19_grenade_launcher, cruise_missile, loitering_munition`) is
exempt from the line-of-sight raycast every other weapon needs — a lobbed round
arcs over obstacles, and requiring LOS at 140 units means "blocked by any rock".

**Locomotion archetypes (13).** The player never places individual wheels; they
pick an archetype and the placer computes station positions from hull size.

| id | hp | weight | M/C | capacity | top speed | traits |
|---|---|---|---|---|---|---|
| wheels | 100 | 50 | 20/0 | 360 | 15.0 | ground_contact, high_speed |
| half_track | 150 | 85 | 30/0 | 720 | 10.0 | ground_contact |
| tracked_treads | 200 | 120 | 40/0 | 1080 | 9.0 | ground_contact |
| heavy_quad_tracks | 250 | 180 | 60/10 | 1500 | 7.5 | ground_contact |
| rocker_bogie | 170 | 110 | 45/5 | 810 | 6.5 | ground_contact |
| legs | 120 | 80 | 40/10 | 468 | 7.0 | ground_contact |
| screw_drive | 160 | 150 | 55/15 | 810 | 8.0 | ground_contact, amphibious |
| hover_engine | 50 | 20 | 20/40 | 279 | 16.0 | hovering |
| air_cushion_skirt | 90 | 65 | 35/20 | 1116 | 15.0 | hovering, amphibious |
| anti_grav_plate | 60 | 30 | 20/75 | 288 | 12.0 | hovering |
| helicopter_rotors | 30 | 30 | 30/10 | 252 | 13.0 | airborne, rotary_wing, hovering |
| ornithopter_wing | 65 | 55 | 45/25 | 360 | 10.5 | airborne, flapping_wing |
| buoyant_envelope (Blimp) | 40 | 35 | 25/15 | 1260 | 4.5 | airborne, buoyant |

`legs` additionally carries a **leg-set tweak** (6 sets) that re-multiplies its
own numbers and changes where the limbs mount:

| set | mount | weight x | capacity x | speed x |
|---|---|---|---|---|
| stryker (default) | underside | 1.00 | 1.00 | 1.00 |
| apex | underside | 1.10 | 1.15 | 0.95 |
| raptor | underside | 0.90 | 0.85 | 1.25 |
| excavator | underside | 1.45 | 1.60 | 0.75 |
| mantis | flank | 1.05 | 0.95 | 1.10 |
| crawler | flank | 1.20 | 1.10 | 1.35 |

**Terrain speed multipliers** are per (surface, locomotion). Airborne and naval
traits are exempt; `anti_grav_plate` is intentionally flat 1.0 everywhere.
Excerpt (full table has 14 surfaces x 9 ground/hover locomotors):

| surface | wheels | treads | legs | screw | hover | rocker | skirt |
|---|---|---|---|---|---|---|---|
| marsh | 0.25 | 0.45 | 0.60 | 1.10 | 1.15 | 0.50 | 1.20 |
| rocky | 0.35 | 0.75 | 1.10 | 0.50 | 0.55 | 1.15 | 0.40 |
| forest | 0.30 | 0.65 | 0.95 | 0.55 | 0.45 | 1.00 | 0.35 |
| ice | 0.45 | 0.50 | 0.40 | 0.75 | 1.20 | 0.55 | 1.25 |
| mud | 0.25 | 0.60 | 0.65 | 1.05 | 1.15 | 0.55 | 1.15 |
| dirt / grass | ~1.0 | 1.0 | 1.0 | 0.9 | 1.0 | 1.0 | 1.0 |
| gravel | 1.25 | 1.10 | 1.02 | 1.00 | 0.95 | 0.80 | 0.85 |
| cobble | 1.30 | 1.15 | 1.05 | 0.90 | 0.90 | 0.90 | 0.80 |

**Ammo types (9)**, selected per weapon from a per-weapon allow-list (a CIWS has
no business firing a flare). Stored under the tweak key `"ammo"`, deliberately
outside every numeric tweak list so the string can never be multiplied:

| id | class | dmg x | vs light x | AoE x | weight x | M x | C x | gate |
|---|---|---|---|---|---|---|---|---|
| standard | — | 1.0 | 1.0 | 1.0 | 1.0 | 1.0 | 1.0 | — |
| ap | kinetic | 1.25 | 0.4 | 0.0 | 1.15 | 1.25 | 1.0 | — |
| he | explosive | 0.85 | 1.3 | 1.6 | 1.1 | 1.15 | 1.0 | — |
| incendiary | thermal | 0.7 | 1.2 | 1.2 | 1.1 | 1.1 | 1.3 | tech_lab |
| flechette | kinetic | 0.55 | 3.5 | 2.2 | 1.0 | 1.1 | 1.0 | tech_lab |
| emp | energy | 0.5 | 1.0 | 1.0 | 1.05 | 1.0 | 1.7 | exotics_lab |
| smoke | — | 0.0 | 1.0 | 1.0 | 0.95 | 0.8 | 1.0 | tech_lab |
| illumination | — | 0.0 | 1.0 | 1.0 | 0.95 | 0.8 | 1.1 | tech_lab |

Utility rounds deal no damage at all — that *is* the trade: a gun loaded with
smoke is not shooting anyone this reload. Smoke blocks sightlines and breaks
missile lock; illumination burns off fog where it lands.

### 3.3 Hulls — data-driven, 127 shipped

Each hull is three files: `<id>.glb` (mesh), `<id>.json` (stats sidecar),
`<id>_collision.res` (baked convex decomposition). The sidecar carries:

```jsonc
{
  "name": "Ballard Leviathan", "category": "hull",
  "manufacturer": "Ballard Deepworks", "hull_class": "Heavy",
  "domain": "Naval", "is_foundation": false,
  "hp": 1354.0, "weight": 990.5, "metal": 333.0, "crystal": 67.0,
  "base_energy": 124.1, "base_power": 9.52, "base_vision": 20.0,
  "size": [4.4, 2.622, 7.5], "color": [0.216,0.329,0.373,1.0],
  "visual_yaw_offset_deg": 0.0, "visual_pitch_offset_deg": 0.0,
  "visual_roll_offset_deg": 0.0,
  "facets": { /* baked segmentation, see below */ }
}
```

Roster shape: **11 manufacturers** (Ballard Deepworks, Brenntal Schwerbau,
Calder Mobility, Halvorsen Yard, Hartmann Panzerwerk, Kestrel Aeroworks, Moreau
Yards, Orrin Collective, Pillar Ironworks, Rackham Forge, Tallow & Vance) x
classes (Scout / Light / Medium / Heavy / Transport / Oddball) across three
domains (Ground 95, Naval 19, Static Defense 13 foundations). Foundations
(Pillbox / Tower / Bunker types) are what a *defense* blueprint starts from
instead of a vehicle hull — no locomotion needed, so absurd armor and oversized
weapons become affordable.

`base_vision` is authored on a 20-ish scale and multiplied by a single
**VISION_SCALE = 1.9** at the one accessor, so the whole band can be retuned
without editing 35 files.

**Baked facet segmentation** is the load-bearing part of the sidecar. Which
triangles belong to the same *face* is decided **once, offline**, not flooded
out from the clicked triangle at placement time. Measured, live flooding is not
a function of the face but of where the player let go: on one lofted hull the
same deck returned anything from a 0.22x0.15 postage stamp to the whole 3.2x5.3
deck, with 2.1 m of centre wander. Growing until a hard edge does not work
either — these hulls are smooth lofts with no crease to stop at. The sidecar
therefore stores, per hull: `facet_count`, a per-triangle `map` array,
`facet_area`, `facet_centroid`, `facet_normal`, `facet_side` (six-way label),
`facet_side_weight` (projected-area weight per side — a raked glacis is both
front and top), `sides` (side -> facet ids), `side_area`, `total_area`,
`tri_count`, `winding`.

Side classification is **weighted, not winner-take-all**: dominant-axis
classification left 15 of 94 hulls with no `front` facet at all, because a raked
glacis points more up than forward.

### 3.4 Armor materials

Armor is a `(threshold, reduction)` pair per damage class, scaled by the hull's
`armor_thickness`. Four canonical materials plus aliases:

| material | kinetic | thermal | explosive | energy | gate |
|---|---|---|---|---|---|
| hardened_steel / steel_plate | 15 / 0.70 | 5 / 0.90 | 10 / 0.80 | 8 / 0.85 | — |
| titanium_plate | 26 / 0.55 | 8 / 0.85 | 14 / 0.70 | 9 / 0.80 | exotics_lab |
| reactive_armor | 10 / 0.80 | 10 / 0.80 | **30 / 0.40** | 8 / 0.85 | tech_lab |
| composite_plate / spaced_composite | 20 / 0.65 | 18 / 0.60 | 25 / 0.45 | 15 / 0.70 | tech_lab |
| ablative_ceramic / ceramic_ablative | 8 / 0.90 | **25 / 0.30** | 10 / 0.70 | 15 / 0.60 | tech_lab |
| carbon_fiber / ballistic_nylon | 7 / 0.85 | 22 / 0.40 | 24 / 0.50 | 12 / 0.70 | tech_lab |
| energy_shielding | 10 / 0.75 | 20 / 0.50 | 20 / 0.50 | **35 / 0.30** | exotics_lab |

Reduction is a *multiplier applied to incoming damage* (0.70 = 30% mitigated).
The counter-play is legible: AP is best against ablative ceramic (kinetic 8, the
lowest) and worst against hardened steel (15, the highest); incendiary inverts
that exactly (steel's thermal 5 vs ceramic's 25); HE is walled by reactive
armor's explosive 30.

---

## 4. Combat math

### 4.1 Stat scaling from tweaks and gizmo scale

Global scaling exponents (a part scaled to 8x volume does *not* get 8x of
everything):

```
weight_scale_factor = 1.0    # linear with volume
hp_scale_factor     = 0.8
dps_scale_factor    = 0.75
cost_scale_factor   = 0.9
stat = base + base * (volume_mult - 1.0) * factor
```

All computed stats are **rounded to the nearest 0.5 at computation time**, not
at display time, so a label and the combat math can never disagree by float
noise accumulated through chained 0.1-step sliders.

Tweaks then multiply on top. The vocabulary is deliberately reused across parts
(≈70 linear names — `caliber`, `barrel_length`, `drum_size`, `motor_size`,
`lens_aperture`, `containment`, `mast_height`, `wingspan`, …) so a new weapon
gets weight/cost/dps/range/traverse scaling with no new plumbing. Rules:

- **Linear names** multiply weight, cost and (a narrower subset) dps directly.
- **Count tweaks** (`barrel_count`, `tube_count`, `grid_size`, `welder_count`,
  `nozzle_count`, `cell_layers`, …) normalise against *the module's own declared
  default*, not a literal divisor — three hardcoded divisors (/6, /2, /4) used
  to mis-scale nine weapons. Only *launcher* counts scale dps; more drone bays
  do not give the carrier hull damage.
- **Special cases that exist because the blanket rule reads wrong:**
  `optic_power` scales weight by only `1 + (v-1)*0.35` but crystal cost by
  `1 + (v-1)*1.60` (a better sight is not more steel; its price is crystal).
  `bipod_deploy` is 0..1 and therefore **additive** (`+6% base weight * v`) —
  multiplying would zero a module's mass when the bipod is up. `scan_arc`
  divides by 60 and gives directional radar `sqrt(60/arc)` vision gain — a
  narrow arc sees further.
- **Ammo** multiplies weight and cost through its own profile.
- **Leg set** multiplies weight/capacity/speed through its profile.

**Hull-level scaling.** `hull_scale` (0.5 .. 2.0 per axis) produces a volume
factor `x*y*z`, applied through the same `base + base*(v-1)*factor` form to HP,
weight and cost. Material and thickness affect *thresholds and weight*, never
HP. (Painted armor adds no HP at all: the hull's own plate is the whole pool.)

### 4.2 Per-shot alpha, and why it is the design

`dps` is the figure the Lab has always shown and the one the caliber slider
*cannot* move interestingly: caliber multiplies dps, weight and cost by the same
factor, so DPS-per-kg and DPS-per-credit are flat across the slider. The real
trade is one layer down — caliber also multiplies the shot **interval**, so a
bigger bore is fewer, harder hits, and only alpha decides which side of an armor
threshold a hit lands on. Between the chip regime and the brute-force regime
that is roughly a **6.7x swing in delivered damage off the same nominal DPS**.
Print both numbers in the Lab; their disagreement *is* the design.

### 4.3 Damage resolution

One shared static resolver used by units and structures alike (this math was
once duplicated three ways and had already drifted once).

```
compute_hull_damage(amount, threshold, reduction):
    if threshold > 0 and amount < threshold:
        return amount * reduction * CHIP_THROUGH_FACTOR      # 0.15
    eff = reduction
    if threshold > 0 and amount >= threshold * BRUTE_FORCE_RATIO:   # 4.0
        t = clamp((amount/threshold - 4.0) / 4.0, 0, 1)
        eff = lerp(reduction, 1.0, t * BRUTE_FORCE_MAX_BLEND)       # 0.75
    return amount * eff
```

- **Chip-through (0.15).** A sub-threshold hit is not fully negated. Without
  this every rapid-fire weapon (rotary, HMG, CIWS, laser, flamer) landed under
  every real threshold and dealt literally zero to any armored hull, deleting
  the entire sustained-fire archetype. At 0.15 armor still blanks ~90% of
  sub-threshold fire, but massed small guns grind.
- **Brute force.** From 4x threshold upward the reduction blends toward 1.0,
  reaching at most 75% of the way there at 8x. A 16-inch shell near a shield
  still transfers shock.
- **Subsystem stripping.** ~35% of hits target an exposed module instead of the
  hull; module damage is `0.75 * raw` and is **threshold-exempt** (exposed
  hardware is the point). Losing all locomotion immobilises the unit. This is
  the mechanic that lets a swarm that cannot penetrate a super-heavy still strip
  its treads, radars and cooling fins and leave it a stranded pillbox.
- **Directional / facet armor, three paths in descending order of knowledge:**
  1. defender + hit origin + the trace recovers the struck **triangle** -> that
     exact facet's assignment, or bare hull if that facet is unpainted. No
     blending: a hull whose front is 60% covered gives a shot into the bare 40%
     *nothing*.
  2. defender + hit origin, no usable triangle -> that side's area-weighted
     summary, blended by how much of the side is covered.
  3. no direction (AoE) -> whole-hull summary blended by total coverage.
- **Slope.** The recovered triangle's angle of incidence multiplies threshold.
- **Elevation advantage.** Shooting down from ≥2.0 units above the target
  multiplies its threshold by 0.85 — holding a hill pays in penetration as well
  as in sight.

### 4.4 Traverse, elevation, acquisition

- `base_traverse` is authored per weapon against a 1.0 anchor (basic_cannon
  1.018; HMG 1.937; gauss_railgun 0.261). Effective traverse speed degrades with
  weight (`^0.80`) and with barrel-length-ish tweaks (`^0.90`), clamped to
  0.08 .. 3.0 rad/s. This is the "death spiral" counter: scale a railgun up and
  its turret physically cannot track a circling hover-drone.
- `mount_style` (`turret` / `pintle` / `frame_built`) no longer affects *visual*
  placement, only traverse: frame-built weapons get **zero** independent
  traverse (the whole vehicle aims); turret and pintle get 360°; a **sponson**
  (wall-mounted) weapon gets a 60° half-angle (120° sweep) because it cannot
  swing back through the hull it is buried in.
- Elevation/depression cones have minimum tolerances (~0.26 rad elevation,
  0.785 rad depression) so a weapon is never geometrically unable to fire.
- Point-defense weapons (`ciws`, `pd_laser`, `flak_cannon`) intercept missiles
  and get a 3.0x damage multiplier against airborne targets.
- Miss chance scales with target speed by projectile class
  (`hitscan 0.0, ballistic 0.035, arc 0.09, guided 0.0`), capped at 0.75.

### 4.5 Energy — two layers, deliberately

**Per-unit** (the mechanic with combat teeth): a hull has `base_energy`
(storage) and `base_power` (generation, energy/sec) — two separate stats,
because before the split the refill rate was derived as `storage * 0.08` and the
two most interesting shapes (big buffer that trickles, small buffer that refills
fast) were both inexpressible. Generator modules add to one or the other, never
both. Draw is a per-module table (`sensor_suite 2.5`, `heavy_sensor_suite 6.0`,
`directional_radar 6.0`, `energy_barrier_projector 5.0`,
`heavy_barrier_projector 12.0`, `repair_array 3.5`, `drone_carrier 4.0`), plus
energy weapons spending per shot. `net = generation - draw`; `endurance` is how
long the buffer covers a deficit. Load sheds in a fixed order as the buffer
empties: **shields, then electronics, then weapons** — most recoverable first.

**Team-level** (the HUD-visible third figure): `energy_capacity` is a live
recomputed sum of every generator on that team's live units and buildings, and
every static structure drains a fixed upkeep per tick (3.0/structure against a
16.0 HQ baseline). Energy is deliberately **not** a spendable currency; instead
a team in energy deficit builds **50% slower**.

Energy-damage weapons (`arc_projector`, `ion_cannon`, `microwave_emitter`,
`particle_lance`, `heavy_laser`, `plasma_lobber`, `pd_laser`, and EMP ammo)
`drain_energy()` on hit — a target at zero energy cannot fire its own energy
weapons. That is a soft disable, not a damage multiplier reskin.

*Naming trap:* "the Energy pool" (a resource) and "energy damage" (an armor
threshold class) are unrelated. Keep them distinguished in code and UI copy.

### 4.6 Drivetrain — speed, load, overload

The locomotor is treated as a self-contained system: its rated capacity is for
what it carries *beyond* the chassis, so `load_ratio` and power-limited speed
are computed from **carried weight** (everything that is not the hull or the
locomotion), while total `weight` is still reported.

```
footprint    = child.scale.x * child.scale.z         # x/z only: y is ride height
thrust       = BASE_THRUST (100)
             + SUM over locomotion children of
                 thrust_coefficient(type) * footprint * tweak_thrust_factor
capacity     = SUM over locomotion children of
                 base_weight_capacity(type, tweaks) * footprint * tweak_cap_factor
             * propulsion_capacity_mult
power_speed  = max(SPEED_FLOOR, (thrust / carried_weight) * TW_GAIN (11.0))
               # INF when carried_weight == 0, so a bare hull is chassis-capped
chassis_top  = slowest_fitted_locomotor.base_top_speed
             * min(chassis_speed_mult, MAX_CHASSIS_SPEED_MULT 1.6)
top_speed    = min(power_speed, chassis_top)
load_ratio   = carried_weight / capacity
move_speed   = max(SPEED_FLOOR, top_speed * overload_mult * underload_mult)
```

The **slowest** locomotor fitted sets the ceiling, not the fastest or an
average: a design carrying two kinds of running gear is limited by whichever
cannot keep up. Per-locomotor tweaks resolve into multiplicative
`(value/ref)^exponent` thrust and capacity factors — e.g. wider treads trade
thrust (-0.35) for capacity (+1.0); more legs add capacity but sub-linear thrust
(-0.5); an airship's prop count adds no thrust because its lift is buoyancy.

- **Overload:** past capacity, multiply by `(capacity/weight)^1.8`, floored at
  0.2 (reached ~2.3x capacity). 10% over costs 15% of top speed, 25% over costs
  33%, 50% over costs 52%, 2x over costs 71%. An exponent of 2.5 was tried and
  rejected: because weight is *already* in the thrust/weight term, an overweight
  design is punished twice and 13 of 17 locomotors bottomed out on the floor at
  +500 kg, which is the same "every answer is the same answer" failure as a
  universal speed cap.
- **Underload:** below 0.75 load, multiply by up to 1.25 with exponent 0.7
  (concave — the first slice of slack is worth most). The deadzone is essential:
  a design at 0.95 load is not "light", it is merely legal, and paying every
  legal design a bonus makes the rating a lie.
- **Speed floor 1.5.** A unit that cannot visibly move reads as a bug.
- **Chassis speed multipliers** from propulsion parts cap at **1.6** combined —
  an unbounded multiplier makes the rest of the system optional.
- The underload bonus is applied **after** the chassis cap, so a very light
  design genuinely exceeds its chassis rating by up to 25%. That is intended:
  the cap is what a chassis does *under its rated load*, and folding the bonus
  in underneath the cap silently deletes it for exactly the designs it rewards.
- `move_speed` is the combat number (after overload/underload); `top_speed` is
  the clean rating. Anything shown to the player as "speed" should be
  `move_speed`.

---

## 5. The Design Lab

The Lab is out-of-match, zero time pressure, and it is the heart of the game.
The scene is a 3D world plus two UI sub-scenes: a left **parts bin** and a right
**telemetry rail**. There is no monolithic "main lab" script; responsibilities
are split into a document/model (`LabDocument`), a rail renderer
(`TelemetryRail`), a toolbar, a parts menu, a 3D placer, and a gizmo.

### 5.1 Screen layout

1. **Centre — the 3D canvas.** Free orbit/pan/zoom around the construct.
2. **Left — the parts bin**, a permanent vertical dock styled as a mechanic's
   steel toolbox stood on end. A 2x2 grid of *family* tabs (Hulls / Weapons /
   Support / Drives); within a family, category drawers accordion (one open at a
   time). Key rules learned the hard way:
   - **Group by ROLE, not by `category`.** `category` is the mechanical
     classification the placer and stat code run on, and 25 entries share
     `category: "weapon"` — one undifferentiated wall of buttons. Roles are
     Direct-Fire Guns / Energy & Electromagnetic / Indirect Fire / Missiles /
     Point Defense / Deployables / Armor / Power / Support (in that display
     order); hulls group by `is_foundation` + weight class; locomotion by its
     `traits`.
   - Group keys come from **data the catalog owns**, never a table of type_ids
     living in the UI script — otherwise a modded part needs a UI code change to
     appear anywhere. An unroled part falls back by category rather than
     vanishing.
   - Sort every group **light to heavy**, with weight shown inline, right
     aligned. Weight is the one stat every part has and the number the player
     budgets against.
   - **A search field at the top filters all families at once**, force-opens
     surviving drawers, hides empty groups, and fully restores the accordion on
     clear. Grouping helps browsing; only search helps retrieval. Every parts
     palette in this genre (KSP2 VAB, Trailmakers, Besiege) attracts the same
     complaint and the community answer is always an external parts list.
   - Collapsed drawers carry a **count badge**; the panel states "Drag a part
     onto the hull to place it" in-panel, because these are drag sources that
     look exactly like ordinary buttons.
3. **Right — the telemetry rail.** Live aggregate stats that flash on change:
   hull HP (and a separate module HP pool — they are *not* summed; stripping
   drains one without touching the other), weight with carried/loco split, load
   ratio against drivetrain capacity, top speed vs combat speed, total DPS
   *and* per-shot alpha with its armor regime, cost in credits with the
   metal/crystal breakdown, energy storage/generation/draw/endurance, vision,
   range band per weapon with its tier label and a "needs a spotter" warning,
   armor thresholds K/T/E per side, and a verdict line.
4. **Top — toolbar.** Blueprint name field, Save/Load, Undo/Redo, symmetry
   toggle (M), rotate mode (R), view modes.

### 5.2 Placement — freeform, never a grid

Placement is a **raycast against a real trimesh of the authored hull** (with
`backface_collision = true`), falling back to an axis-aligned box only for hulls
with no mesh. Position and orientation are continuous — no snap grid. This is
deliberate: *where* a weapon sits changes its firing arc and its exposure, and a
grid would flatten that into a handful of interchangeable slots, working against
the whole continuous-tweaking philosophy. An earlier draft specified a hex/square
surface grid; it was superseded before it was built.

**Overlap never blocks placement.** You *can* drop a weapon on top of another.
What prevents broken designs from shipping is downstream: overlapping parts are
highlighted solid red in real time, and Save / Test in Arena are both blocked
while any clipping exists.

**Clipping detection** is a merged-AABB broad phase then a **15-axis separating
axis test per mesh pair**. The single source of a module's occupied space is a
volume measurer that fits each `MeshInstance3D` into a parallelepiped (centre +
three half-edge vectors, so nested non-uniform scale shear survives), caches it
on the node, and is invalidated when the visual is rebuilt. Both the click
collider and the clip test read the *same* measurement — they used to disagree,
with the clip test using the catalog's authoring `size`.

**Red highlight is applied by swapping `material_override` to one shared red
material and restoring the part's own on clear** — never by writing colour into
the material, because part materials are shared per role+tint and mutating one
repaints every other part using it.

**Mount styles / facet behaviour** (this evolved through three models; the
current one is the third):

- Every module places **flush against the clicked facet**, rotated so its local
  up lies along that facet's real surface normal, sloped or not. Authored meshes
  already carry their own mounting post, so no procedural column or base plate
  is drawn (drawing one double-mounts the part).
- **Exception: near-vertical faces get a sponson.** Flush-mounting on a wall put
  the muzzle into the ground (front facet) or the sky (back facet), and side
  mounts were rolled 90° so the elevation cone opened sideways. On a face
  steeper than the weapon's `pintle_min_up_alignment` threshold (highest
  authored value 0.55, so a 45° glacis at dot(UP)=0.707 stays flush), the weapon
  is pushed *inboard* so its body and post sit inside the hull and only the
  barrel protrudes, through an authored blister housing. Its basis is
  `looking_at(outboard, UP)` — muzzle outboard, +Y hull-up. **Do not add a post,
  hub or base plate to the blister**; that is the moment it becomes the thing
  that was deleted.
- Every mount style wall-mounts, including turret and frame-built (a tank cannon
  in a hull side is a casemate; a railgun in the glacis should aim out of it).
  Sponson mounting narrows traverse to 120°.
- **One deliberate hard block, and only one:** an indirect-fire weapon
  (`sponson_capable: false`) is *refused* on a face steep enough to need a
  sponson. There is no orientation that makes a lobbing weapon work off a wall.
  It is enforced on both the drag path and the build bar, and reports a reason
  rather than failing silently. Everything else — including genuinely weird
  trait combinations, treads on a naval hull — is allowed. **No hard-blocking is
  the general rule**; traits compose and drive simulation behaviour, whatever
  that produces.
- Bottom-facet mounts are the inverse of top (useful for rotor mounts).

### 5.3 Tweaking — the differentiation engine

Selecting a placed module opens a contextual spec popup with that module's own
isolated stats, plus **radial tweak stations** (the module action ring) that
drive its parametric sliders. Dragging changes the mesh in real time and the
readout updates live. Stretch handles on the 3D gizmo were retired in favour of
the radial stations; the rotate ring remains.

Every weapon declares a small tweak set (`{name, label, min, max, step,
default}` or `{type: "bool"}`). Typical ranges are 0.5..2.0 in 0.1 steps.
Examples:

- `basic_cannon`: caliber, barrel_length, barrel_count (1-4)
- `rotary_cannon`: caliber, barrel_length, barrel_count (3-9, default 6),
  motor_size
- `anti_materiel_rifle`: calibre (0.6-1.8), barrel_length (0.6-2.2),
  optic_power (0.7-2.0), bipod_deploy (bool-ish 0/1) — no drum tweak at all,
  because "carry more rounds" is not a question this weapon asks
- `flamethrower`: nozzle_width, barrel_length, pressure_valve
- `heavy_laser`: lens_aperture, barrel_length (optical telescope)
- `missile_pod`: warhead_size, motor_length, grid_size (2-6)
- `drone_carrier`: drone_type (attack / scout / repair), hangar size, launch
  catapult
- `directional_radar`: scan_arc (narrow = further)
- locomotion has its own parallel tweak table (wheel size, tread width, leg
  type, pad count, envelope volume, turbine compression, …)

### 5.4 Firing-arc visualisation

Selecting a weapon draws a translucent cone from the barrel showing its traverse
and elevation limits. Where the cone intersects the hull, a mast or another
module, that section turns **red** — an instantly readable blind spot. The Lab's
arc visualiser and the combat code read the *same* sponson/traverse metadata so
they cannot drift.

### 5.5 Armor as painted coverage

Armor is **not** a placeable module (it was, and that was wrong: coverage was
binary per side, weight was flat per plate regardless of area, and the per-plate
material branch in the resolver was unreachable because nothing ever wrote one).

Instead the player **paints** facets in an Armor Bay: pick a plate type,
material and thickness, brush facets. The blueprint stores
`armor.assignments[]`; at reconstruct time an `armor_plan` is built once and
hung on the hull as metadata. The plan carries per-facet assignments, per-side
area-weighted summaries, total coverage, and the triangle->facet map so the
resolver can recover the exact facet struck. Weight scales with painted **area**,
so armoring a big flank actually costs more than armoring a small one.

### 5.6 Structural pieces — the rule for any freely-scalable part

*(Status: specified, machinery present — `struct_scale` handling in blueprint
save/load and the placer, authored hardware in the Blender tools — but no
structural entry ships in the current module catalog. The Hull Builder's
primitive set, which includes slope, frustum, chamfer box, half cylinder,
hemisphere, I-beam, L-beam, fender, canopy and ring, is where equivalent shapes
live today. The rule below is what any three-axis-scalable part must follow.)*

Six pieces (block, dome, slab, wedge, girder, I-beam) are the **only** modules
freely scalable on all three axes at once, and they are meant to be stretched
hard — which rules out the "one authored .glb scaled" approach every other part
uses (a bolt head scaled 4x on one axis is a smear).

- The **body** stays procedural and re-tessellates at its new size.
- The **detail** is authored hardware (corner brackets, bolt pads, stiffener
  ribs, gussets, splice collars, end caps, vision blocks, tie-downs) instanced
  at its **true authored size with no scaling**. Stretch a girder and you get
  *more* splice collars, not longer ones.
- **Scale isolation:** the resize is carried as a `struct_scale` meta and the
  body is rebuilt; `node.scale` stays at 1. Click target and mounting surface
  are driven by hand to match, and the value persists through save/load.
- Hardware is exempt from the faction repaint, so painted plate reads with bare
  steel fasteners.

### 5.7 Part materials — roles, not just paint

Every bolt-on part used to reach the screen through a `StandardMaterial3D` with
only `albedo_color` set — i.e. Godot's defaults of metallic 0 / roughness 1, the
PBR description of matte plastic. A barrel, a drum, a lens and a rubber tyre had
identical surface response.

Replace that with material **roles**: `steel`, `painted`, `gunmetal`,
`scorched`, `brass`, `optics`, `rubber`, `ceramic`, `energized` — each with its
own metallic/roughness/base colour plus a `tint` weight controlling how much of
the caller's colour survives. A painted housing takes faction colour in full; a
barrel stays gunmetal on a red gun and a green gun alike. Roles resolve from the
authored **filename** (the ~292 parts are already named after what they are), so
no call site changes. Texture is procedural and **triplanar** (the parts are
built in bmesh from primitives and have no useful UVs): a fine noise on
roughness so flat faces stop reading as decals, a coarse noise on detail-albedo
so paint reads as sprayed onto metal.

**Materials are shared per role+tint and must never be mutated in place.** The
battle module baker merges meshes grouped by material *identity*, so a
fresh-but-identical material per part silently defeats the merge and ships one
draw call per bolt.

### 5.8 Build legality

A design is illegal (blocked from queue/build, flagged in the Lab) if:

1. no hull/foundation at all, **or**
2. zero weapons **and** zero recognised support/utility modules (repair array,
   drone carrier, harvester, sensor suite, logistics, any generator) — it does
   nothing, not even a legitimate non-combat job, **or**
3. no locomotion **and** the hull is not a foundation — a mobile-hull-shaped
   brick that can never move.

Checked at the same point the cost walk already iterates `modules[]`.

### 5.9 Blueprint library, livery, hull authoring

- **Blueprint Library** browses/renames/deletes/previews saved designs and can
  route any of them to the Proving Ground.
- **Livery** authors a cosmetic paint scheme: five zones, each a colour plus a
  PBR finish. Purely cosmetic. It replaced a ten-faction picker whose passives
  were retired, so two identical designs fight identically whatever they wear.
  (The ten-faction catalog survives as a visual identity library; only
  `armor_weight_mult` is still read, for legacy enemy roster designs.)
- **Hull authoring** shapes new hull forms from primitives via an SDF /
  marching-cubes bake, producing the same `.glb` + sidecar pair the shipped
  roster uses.

---

## 6. The battle runtime

### 6.1 One entry point, three modes

Every mode boots the **same** `Battle.tscn` through a **`MatchRuleSet`** written
by its setup screen. The rule set is a plain value object (RefCounted, not a
Node, not a Resource) carried by the `MatchConfig` autoload. This exists because
"which mode is this" was previously implicit — it was whichever setup screen
happened to hand you there — and every per-mode flag became another
`if match_config.something` scattered through the controller.

Fields: `mode` (TEST_RANGE / SKIRMISH / OPERATIONS), `map_id`, factions,
`selected_blueprint_paths` (skirmish/ops) or `player_blueprint_path` +
`enemy_blueprint_paths` (test range), explicit pre-placement lists
(`spawn_player_buildings`, `spawn_enemy_buildings`, `spawn_player_units`,
`spawn_enemy_units`, `spawn_resource_fields`), `starting_credits` (-1 = use the
director default of 1200), and independent capability flags:
`enable_economy`, `enable_production`, `enable_player_build`, `enable_ai`,
`enable_fog_of_war`, `camera_mode` (RTS / CHASE), `enable_minimap`,
`enable_production_hud`, `enable_battle_hud`, `enable_admin_menu`,
`win_condition` (KILL_ALL_ENEMIES / KILL_ALL_DUMMIES / DESTROY_HQ /
SURVIVE_TIMER / NONE), `win_timer_seconds`, `after_match_action`
(RETURN_TO_LAB / ADVANCE_TO_NEXT_STAGE / SHOW_AAR), `operation_id`,
`stage_index`, `ai_difficulty`, `ai_doctrine`, physics tick rate.

Static factories read as sentences at the call site:
`MatchRuleSet.test_range(player_path, dummy_paths)`,
`MatchRuleSet.skirmish(map, roster)`, `MatchRuleSet.operations(...)`.
`is_order_legal()` is the single chokepoint for "is this order allowed here".

### 6.2 The director is composition and nothing else

**The point of the match director file is its length.** The system it replaced
was 3,423 lines because it owned the economy ledger, fog of war, the minimap
image, the HUD, selection, building placement, navmesh baking, energy
bookkeeping and the win condition at once — none of it testable or replaceable
in isolation. The rule: the director assembles the world, holds service
references, and forwards input. Anything that could be asked a question in
isolation belongs in a service.

Units find navigation and terrain through **duck-typed contracts** on their
controller (`get_ground_nav_map()`, `get_water_nav_map()`,
`get_amphibious_nav_map()`, `get_deep_water_nav_map()`, `terrain_height_at()`,
`get_surface_type_at()`), so a unit built standalone in a probe gets no navmesh
and falls back to direct steering without knowing anything about navigation.

Services: `EconomyService`, `ProductionService`, `PlacementService`,
`SelectionService`, `OrderService`, `FormationService`, `FlowFieldService`,
`VisionService`, `AlertService`, `MatchStats`, `BattleLogger`,
`BattleProfiler`, `SimRNG`, `Commander` (+ `SquadManager`), `BattleFinish`.

### 6.3 Economy

**One credit pool, four gathered resource types** differing only by value
density and where they sit. Any harvester works any field; the decision is where
to send trucks, not what to build to reach it.

| type | credits/unit | nodes per field | field radius | respawn s |
|---|---|---|---|---|
| lumber | 1.0 | 9 | 11.0 | 20 |
| ore (alias: metal) | 1.5 | 7 | 9.0 | 35 |
| crystal | 3.0 | 5 | 8.0 | 50 |
| oil | 4.0 | 1 (a well, not a field) | 0 | 25 |

Costs are still *authored* as metal + crystal, because that pair carries design
intent (crystal is the "advanced" material and tweaks lean on it — `optic_power`
scales crystal 1.60x against metal 1.20x). Conversion happens at the till:
**credits = metal + 2 x crystal**. Advanced technology raises your price rather
than gating you on a resource the map may not offer.

Harvester loop: a finite-state machine — seek node, drive, extract (28 units per
3.0 s), return, dock at a **numbered reserved bay** (unreserved arrivals were
what jammed the old implementation), unload over 0.6 s, repeat. Hopper capacity
is `56 x tier_mult x module_scaling` with tiers `{light 0.7, medium 1.0,
heavy 1.5}`; extraction scales with it so *fill time is constant* across tiers —
a heavy hauler's advantage is fewer trips, paid for in cost and speed, not in a
longer dwell. Dock bays are **derived from the building footprint plus 6.5 m
clearance**, not hardcoded: the building carves a navmesh hole, the director
widens that hole for clearance, Recast then erodes by agent radius, and every
previously hardcoded bay position silently went off-mesh whenever any of those
three moved.

Income is tracked over a 20 s window so the HUD can show a rate and the AI can
budget over a horizon.

### 6.4 Buildings and production

| kind | HP | size | metal | crystal | build s | notes |
|---|---|---|---|---|---|---|
| hq | 3000 | 7x4x7 | — | — | — | never built; losing it loses the match; vision 34 |
| refinery | 1600 | 12x9x10 | 150 | 0 | 14 | 3 derived dock bays; vision 22 |
| light_manufactory | 1400 | 5x2.4x6 | 150 | 30 | 16 | feeds Light queue |
| medium_manufactory | 1800 | 6x3x8 | 220 | 55 | 22 | feeds Medium queue |
| heavy_manufactory | 2400 | 7.5x3.8x10 | 320 | 85 | 30 | feeds Heavy queue |
| power_plant | 1000 | 4.5x4.2x4.5 | 180 | 40 | 12 | +20 energy capacity |
| tech_lab | 900 | 4.4x2.9x4.4 | 200 | 60 | 18 | gates ~30 parts; vision 20 |
| physics_lab | 1100 | 4.8x3.8x4.8 | 280 | 110 | 26 | vision 22 |
| exotics_lab | 1300 | 5.4x4.5x5.4 | 340 | 180 | 34 | rarest tier (8 parts); vision 24 |

**Five global queues per team: Light, Medium, Heavy, Building, Defense.** One
queue per type — a second heavy manufactory does not open a second heavy line,
it makes the one heavy line **faster**. That is the Westwood macroeconomic
tension: expanding your base buys tempo, not parallelism. Speed table is Red
Alert's own, indexed by (contributors - 1) and held at the last entry:
**100 / 75 / 60 / 50 percent** of normal build time.

- Which queue a unit design lands in comes from its **hull weight tier** (light
  ≤400 kg, medium ≤690 kg, heavy above) — a small boat and a light ground hull
  both come off the Light line; the split is by weight, not domain.
- Building and Defense are two separate queues (both fed by the HQ) so a
  refinery and a turret can be under construction simultaneously.
- **Custom defenses take real build time.** In the old runtime you paid and
  placed instantly, which made walling up a pure money question rather than a
  tempo decision.
- Build time is proportional to price — `clamp(credits * 0.05, 3, 40)` seconds —
  which makes a production line draw a **flat 20 credits/s** whatever it is
  building. The whole economy balance rests on that fact.
- **The tech tree gates DESIGNS, not queues.** The three labs feed no queue at
  all; they exist to be owned. A design's prerequisites are the union of **five**
  sources: hull, armor material, locomotion, each module, and each ammo-capable
  module's *loaded round*. Counting only modules reads wrong in the obvious case
  (an ablative-ceramic hull with a basic cannon looks buildable from turn one,
  when the armor alone needs a Tech Lab). Queueing a design whose lab you lack
  fails at the door with a reason.
- **Placement legality is one function** shared by the player's ghost and the
  AI's siting. It enforces map bounds, water, structure overlap plus footprint
  clearance, and `requires_buildable_area` / `gives_buildable_area` /
  `adjacent_m` (default 24 m; defenses 84 m so a turret line can picket
  forward). Two rule sets that agree until somebody edits one is exactly the
  asymmetry to avoid.

### 6.5 Orders, stances, selection, movement

**An order is data.** `Order` carries what was asked for and nothing about how:
`IDLE, MOVE, ATTACK_MOVE, ATTACK, ATTACK_GROUND, HARVEST, PLACE_BUILDING, ...`
plus a resolved `position` (already offset by the formation service, so a unit
never needs to know it was in a group and a formation move replays identically).
A unit holds a current order and a **queue** of pending ones — shift-queueing is
`append`, cancelling is `clear`. The old runtime spread intent across five
parallel fields on the unit, many combinations of which were meaningless, and
had nowhere to put a second order.

**A stance is a standing policy that outlives every order:**

| Stance | Behaviour |
|---|---|
| HOLD_POSITION | never moves on its own initiative; weapons still fire |
| RETURN_FIRE | **default** — fires back, pursues only far enough to answer |
| AGGRESSIVE | seeks targets within vision once idle |
| HOLD_FIRE | does not fire or acquire unless ordered or attacked (dummies) |

`RETURN_FIRE` is the default rather than `AGGRESSIVE` because a group that
scatters after every passing target is worse than one that needs telling.

Movement: `NavigationAgent3D` under a real controller, direct-line steering as
fallback. Pure-function steering math (arrival ramp with a speed-scaled slow
radius; separation with radius scaled from the unit's own footprint so a
super-heavy keeps more room than a scout). A flow-field service handles large
group moves. Hull yaw rate 2.6 rad/s, gravity 24, minimum throttle 0.12 (a unit
wedged against geometry with zero throttle can never rotate out). Flyers cruise
at altitude 4.0 and lerp toward it. Repath hysteresis and final-approach epsilons
prevent path thrash near the destination.

Naval/amphibious: hull draught routes a unit onto the water or deep-water
navmesh; screw drive uses a combined amphibious mesh.

### 6.6 Vision and fog of war

Three states, not two: **unexplored / explored-but-not-currently-seen /
visible**. (A SubViewport mask was considered and rejected: it is a two-state
answer, and losing the middle state means a base you scouted an hour ago
vanishes when you look away.)

Two separate questions, both respecting terrain and obstacles:

- **Gameplay visibility** — real line-of-sight raycasts from an eye height of
  1.5 plus continuous terrain checks, so units behind ridges or structures
  cannot be *targeted* through them.
- **Visual shroud** — grid-space raymarching against terrain elevation and
  obstacle bounds, so fog contours follow hills, valleys and buildings.

Vision range = hull `base_vision` (x1.9) + sensor module bonuses, plus an
elevation bonus of 0.02 per unit of height, capped. Fog-hidden units are neither
rendered nor targetable. The scan runs on a **timer (0.6 s), not per frame** —
visibility changing twice a second is imperceptible and the scan is
O(viewers x targets) per team — with a short-TTL LOS cache on top.

Smoke volumes and illumination rounds modify vision locally; sensor beacons
reveal a radius for a duration; scout drones reveal while they orbit.

### 6.7 The AI

**Utility scoring, not timers.** The predecessor was four fixed-interval timers
driving imperative rules; nothing was weighed against anything, so the AI could
be behind on economy and not know it, and "waves" meant ordering *every* live
unit at the HQ on a clock.

Each tick, score a fixed action list with `U(a) = sum(w_i * c_i(x_i))` and take
the best affordable one. Weights are the personality; considerations are a
separate module. Actions: `EXPAND_ECONOMY, ADD_REFINERY, ADD_POWER,
ADD_PRODUCTION, BUILD_ANTI_AIR, BUILD_ANTI_ARMOR, BUILD_GENERAL, DEFEND,
BUILD_DEFENSE, PUSH`, plus damage-type-aware counter actions.

**The AI has no privileged knowledge.** It reads the same economy and vision
services the player's HUD does and issues orders through the same order service:
if it cannot see a unit, it cannot count it. That is enforced by construction —
there is no other way in. The one honest concession is a difficulty-scaled
income trickle, labelled as the handicap it is.

**Squads, up to four, each with a readable pattern the player can exploit:**

| Role | Objective | The counter it invites |
|---|---|---|
| MAIN_BATTLE_GROUP | attacks HQ/objectives by the direct route | ambush the route |
| RAIDER | harasses harvesters and refineries | PD turrets at refineries |
| BASE_GUARD | holds home, never chases far | bait it out, hit the real target |
| SCOUT | one expendable fast unit probing fog | trap it, or hide your tech |

These patterns are features. An AI with no patterns can only be out-statted.

**Counter-drafting between operation stages** reorders the AI's roster pool
against what it has actually *seen fielded* (from the combat log — never the
player's library or current draft), with a recency falloff of 0.6 per round.
Threat -> answer mapping: air -> anti_air, armor -> anti_armor, each armor
material -> counter_armor, missile_spam -> point_defense, indirect ->
counter_armor. Nothing downstream changes; it is purely a reordering.

**Rate-limit AI construction.** Per-structure-type cooldown of 2.0 s, escalating
x1.75 up to 24 s when a repeated build fails to satisfy its own trigger, reset
when satisfied. Without this, a permanently-true `is_low_power` had the AI
placing a power plant every 2 s for eight minutes, each placement forcing a
navmesh sync and a multi-second frame.

### 6.8 Terrain and maps

Maps are JSON (14 shipped) plus baked terrain textures (height, surface, splat,
macro, curvature, wetness PNGs per map). Schema:

```jsonc
{
  "schema_version": 1.0,
  "name": "Close Quarters",
  "description": "...",
  "map_half_extents": 135.0,          // 135 .. 550 across the roster
  "ground_color": [r,g,b],
  "hills":          [{"center":[x,0,z], "radius":12, "falloff":16, "height":7}],
  "water_areas":    [{"center":[...], "radius":..., "depth":..., "irregularity":0.25,
                      "shore_blend":4.0}],
  "obstacles":      [{"type":"rock", "center":[...], "half_extents":[w,h]}],
  "surface_zones":  [{"surface_type":"sand", "center":[...], "half_extents":[..]}],
  "resource_nodes": [{"type":"metal", "position":[...], "amount":1000}],
  "base_zones":     [{"id":"north", "center":[...], "half_extents":[12.5,12.5]}],
  "spawns":         [{"id":"player", "hq":[...], "refinery":[...],
                      "factory":[...], "harvester":[...]}]
}
```

Terrain is heightmap-based with a **14-entry surface palette** (`marsh, rocky,
snow_mud, sand, gravel, forest, ice, dirt, steppe_grass, dry_grass, mud, cobble,
scree, volcanic`), indexed out of a baked surface map image. Hills use a
smoothstep falloff; water blobs use a deterministic two-harmonic angular wobble
seeded from the blob centre, so coastlines are organic but stable across reloads
without storing a polygon.

**Four navmeshes** are baked: ground, water, deep water, and amphibious
(ground+water combined, for screw drive). Buildings carve holes with a clearance
margin so wide hulls keep off the walls.
---

## 7. The in-match HUD

One HUD root owning layout, a single refresh clock, hotkeys and camera focus.
Its vocabulary is deliberately **not** the out-of-match toolkit skin: flat
fills, 1 px edges, no runtime texture generation, monospaced telemetry.

| Region | Owns |
|---|---|
| `hud_root` | layout, the only clock, hotkeys, camera focus |
| `hud_style` | palette, metrics, type, panel/label/button/bar factories |
| `hud_skin` | optional texture/noise overlays (defaults to nulls: flat) |
| `hud_icons` | authored SVG icons, tinted via `modulate` |
| `hud_minimap` | terrain bake, three-state fog, blips, frustum, click-to-jump, right-click orders |
| `hud_production_deck` | the five queues as five tabs, queue strip, build palette, tech gating |
| `hud_command_card` | selection aggregated by design, order buttons, stance |
| `hud_resource_ribbon` | credits, income, power, army count, clock |
| `hud_alert_log` | transient events top-right, click to jump |
| `admin_menu` | pause / abandon / quit, parented into the HUD column |

Three properties are load-bearing, each a bug in the version it replaced:

1. **One instance of each region.** The predecessor had three minimaps and two
   complete production interfaces on screen simultaneously, because three
   different parents each built one.
2. **Raster and vector are split in the minimap.** The terrain+fog texture is
   rebuilt only when a shroud version counter changes; blips, selection rings,
   the camera frustum and alert pings are `_draw()` calls on an overlay at
   display resolution. The old version wrote blips as pixels into a low-res
   image and uploaded a texture every tick whether or not anything moved.
3. **The HUD drives itself.** One `_process` is the only clock — map at 20 Hz,
   panels at 5 Hz. The match director does not refresh it.

Everything lives in a centred column capped at 1920 px wide; wider viewports get
a symmetric gutter of battlefield rather than a stretched HUD. There is a single
`layout_for(size)` entry point, and anything else that needs to sit in the
column (session menu, debug overlay) attaches through one function, never onto
the raw CanvasLayer.

Icons are **authored monochrome SVGs**, tinted with `modulate`; a missing icon
degrades to text rather than failing the build.

**Skirmish controls:** left-click / drag select; right-click move, attack target
or send a harvester to a node; Ctrl+right-click attack-ground; WASD / arrows /
middle-drag pan; wheel zoom; Esc pops the most specific open thing (placement,
then selection, then the pause menu).

---

## 8. Out-of-match flow

Main menu, two sections plus a profile row:

**DEPLOY**
1. **SKIRMISH** — pick a map and a roster (12 slots) -> `Battle.tscn`. Full
   base-building match; win by destroying the enemy HQ.
2. **OPERATIONS** — a campaign of 3-12 engagements with a re-draft between each
   from your full library. The floor is 3 because two rounds means only one
   draft, so nothing is learned twice; the ceiling is 12 because past that the
   itinerary stops fitting a screen and re-drafting stops being a decision.
   Difficulty **ramps**: the chosen tier is where the operation ends, not a flat
   setting; the first third opens one tier easier.
3. **PROVING GROUND** — drive your latest scratch design against target dummies
   behind a chase camera. Writes a scratch blueprint, never a roster entry.

**DESIGN**
4. **DESIGN LAB** (§5) — start from a vehicle hull for units or a foundation for
   static defenses.
5. **BLUEPRINT LIBRARY** — browse, manage, preview; "Test in Arena" routes
   through the same proving-ground launcher.
6. **HULL AUTHORING** — SDF / marching-cubes hull sculpting.

**Profile row:** LIVERY, RECORDS, SYSTEM. Esc opens pause/settings anywhere.

On a first run the menu shows a single card instead: a **two-phase, 23-step
tutorial** whose shape is the game's thesis in miniature —

*Phase 1 (lose):* welcome -> place your HQ -> read the battlefield -> give
orders -> engage -> watch your units die -> "DEFEAT — but the war continues".
*Phase 2 (design your way out):* the design bureau -> stronger chassis -> add
real armor -> tracks for the weight -> a turret cannon -> a co-axial MG -> read
the telemetry -> name and save -> test on the range -> drive and shoot ->
destroy the dummies -> return to the lab -> "the loop is complete".

**Scene routing** is async with a loading screen and preload warming: the router
walks a scene's script `const X = preload(...)` graph to warm the heavy targets
before the swap, with per-step labels so the loading screen says something true.

**Out-of-match UI language** is a "hobbyist toolkit": physical workbench
materials (cutting mat, cardboard, kraft, cork, chipboard desks; powdercoat,
steel, moulded, canvas, carbon, fiberglass, toolbox, bakelite, wood equipment
chrome), 3D industrial hardware controls on a prop stage, animated cards, dock
and flyout panels, control groups.

Design tokens (single source, no colour literals elsewhere):

```
BASE_900 #13130F  BASE_800 #1C1B18  BASE_700 #252420
BASE_600 #33312C  BASE_500 #4A473E  BASE_400 #676358
TEXT_PRIMARY #EFE9E5  TEXT_SECONDARY  TEXT_DISABLED
SIGNAL_HAZARD  (amber)  = attention / selection / warning
SIGNAL_ALERT   (red)    = damage / destructive
SIGNAL_GO      (green)  = ready / affordable / confirmed
SIGNAL_INFO    (blue-grey) = informational only, never an action
FONT_DISPLAY 40 / TITLE 24 / HEADING 17 / BODY 15 / SMALL 13 / MICRO 11
SPACE 4 / 8 / 12 / 20 / 32   RADIUS 2   BORDER 1-2   HIT_TARGET_MIN 32
ELEVATION flush 0 / raised 3 / floating 8 / modal 18
DURATION instant .06 / fast .12 / normal .22 / slow .4   stagger .035
```

**Signal colour is state, not decoration.** Amber is never "a colour for a
button you like". The base is a *warm* dark, not blue-black, so chrome separates
from the cool sky and water of the battlefield instead of blending into it. Text
is off-white, never pure white.

---

## 9. Art pipeline — everything is procedurally authored

Nothing is hand-modelled. Two Blender scripts (headless, `--background
--python`) own disjoint halves, and the split matters:

| Script | Owns | Outputs |
|---|---|---|
| `build_vehicle_hulls.py` (+ `hull_forge.py`) | the vehicle hull roster | `assets/models/hulls/*.glb` + `.json` sidecars |
| `build_meshes.py` | parts, foundations, buildings, terrain props | `assets/models/parts/*.glb`, foundation hulls, buildings |

~39 Blender modules in total, one per part family (`build_railgun.py`,
`build_mortar.py`, `build_sensor_modules.py`, `build_mount_kits.py`,
`build_structural.py`, …). The runtime assembles parts per weapon type and falls
back to procedural primitives for anything not yet authored.

**Hull forging.** Hulls are lofted from cross-sections. Rules found the hard
way:

- **Forward is local -Z.** Godot and Blender disagree; write down the measured
  axis chain and both winding checks, and keep them.
- An element's **vertical extent must be a function of the hull's height alone.**
  Deriving it from width makes the envelope autofit solve non-convergent, and
  normalisation should *raise* rather than silently squash the hull.
- **Prominent greebles (masts, spines, barbettes) are integrated as
  cross-section peaks**, not bolted on: each peak is a 4-vertex mesa on top of
  the chassis, active only in a small z range, with its vertices held in the
  outline at every z (collapsed flat on the deck when inactive) so the
  cross-section point count stays constant for the loft. Bolted-on greebles
  leave a "floating detail" look.
- Tumblehome (wider at the bottom, narrower at the top) is part of the outline,
  not a post-process.
- A legacy hull generator that authored through an axis helper with determinant
  -1 and then applied a *second* determinant -1 matrix after recalculating
  normals shipped **every hull inside out**. It is retired and raises if called.

**Hull collision shells.** Every hull ships `<id>_collision.res`: the convex
**decomposition** of its welded shell, mounted as one `CollisionShape3D` per
piece. Without it a unit falls back to a single convex fit that fills deck
wells, the gap under a tapered keel, and the space between sponsons. Three
non-obvious facts:

- Bake collision **without** touching hull geometry (a `--collision-only` mode).
  A full re-bake rewrites every mesh — a huge binary diff and a re-run of
  marching cubes on geometry that already shipped.
- **The weld is mandatory and is not `SurfaceTool.index()`.** That dedupes on
  the whole vertex tuple, and a faceted hull's coincident corners carry
  different normals, so it merges nothing. Weld on **position only**: measured,
  that takes the roster from ~18% to 100% shared topology. Without it the
  decomposer has no vertex adjacency and hangs.
- **`max_concavity` defaults to 1.0, which silently does nothing** — at the
  default, VHACD returns one piece for every hull, exactly reproducing a single
  convex fit. 0.05 is where real splits appear and stop changing. Also: there is
  no `Mesh.convex_decompose` in Godot 4.7.1; the only decomposition entry point
  is `MeshInstance3D.create_multiple_convex_collisions()`, which attaches a
  `StaticBody3D` of shapes rather than returning them.

**Collision layers are the other trap.** Keep the unit-module hit-volume layer
distinct from the Lab's module-picking layer (which is in the weapon LOS mask —
a hit volume must never double as an occluder), and keep the hull-surface
placement layer distinct from the resource-node layer. A battle module's hit
volume is an `Area3D` (not a `StaticBody3D`: it rides a moving unit, and the
visual rebuild only spares StaticBody children), built *before* the merge that
bakes sub-parts away, capped at 8 boxes.

**Textures** are procedural too: a shared hull surface set (panel seams, rivets,
grain, corrosion) authored in **pure value, no hue**, so livery zone colours
multiply over it cleanly; terrain PBR sets; UI plates and props; icons; cursors.

After regenerating anything, reimport once so Godot writes its `.import`
sidecars. The `.godot` import cache is gitignored and goes stale whenever a new
autoload or `class_name` lands, which breaks headless runs with a misleading
`Identifier "X" not declared` — reimport first.

---

## 10. Audio pipeline — fully procedural, deterministic

No recorded samples, no soundfonts, no impulse responses anywhere. A layered
Python package, strictly downward-dependent:

| Module | Owns |
|---|---|
| `dsp.py` | numpy/scipy primitives: oscillators, filters, envelopes, saturation, reverb, tape |
| `instruments.py` | music patches (guitar, bass, brass, kit, modal metal) |
| `sequencer.py` | tracker-style patterns and timing |
| `tracks/` | one module per song |
| `voice.py` | formant synthesis — the vocalised ordnance **and** the radio comms |
| `sfx.py` | every non-music sound, and the manifest of what exists |
| `render.py` | file output and pruning |

**`audio_manifest.json` is the contract.** The generator writes it; the runtime
audio manager loads it at boot to build variant banks. Adding a sound is a
one-line edit to the manifest function plus a re-run — **no engine-code change**.
This exists because a hand-maintained path dictionary drifted from the UI
feedback role table and left eight UI roles silently playing nothing.

66 SFX banks ship, each with multiple seeded variants: ordnance (`cannon`,
`machine_gun`, `laser`, `missile`, `explosion`, `hit`), impact taxonomy
(`impact_chip`, `impact_penetrate`, `impact_module_lost`,
`impact_immobilised`, `impact_catastrophic`), engines and locomotion loops
(`engine_diesel/electric/heavy/turbine`, `tread_loop`, `wheel_loop`,
`rotor_loop`, `screw_loop`, `servo_loop`, `hydraulic_loop`), economy
(`harvest`, `harvester_dock`, `harvester_full`, `construct*`, `unit_rollout`),
radio comms (`radio_ack/affirm/engaging/negative/ready/static/unit_lost/
structure_lost/low_power`), UI (`click`, `hover`, `select`, `place`, `error`,
`ui_dial/drawer/latch/plate/tick/toggle_on/toggle_off/mode/menu_open/
menu_close`, `warning_banner`, `order_ping`), and nine per-surface ambience
beds (`ambience_marsh/rocky/sand/snow_mud/ice/forest/gravel/lab/artillery`).

**The sincere/absurd split is enforced by module.** Ordnance banks come from
`voice.py` (a Rosenberg glottal pulse train through a **cascade** — not parallel
— of moving formant resonators, with plosive bursts and post-release aspiration
on a separate noise branch). Everything authored in `sfx.py` is sincere. If a
sound in `sfx.py` wants to be funny, it is in the wrong module. Pitch and timbre
still differentiate weapon class so the audio stays informative: a 78 Hz
"ka-POW" versus a 400 Hz "pyoo" is identifiable before it parses as a word.

**Determinism is required.** Every generator takes a seed and re-running must
produce byte-identical output, or each regeneration is a multi-megabyte binary
diff. Never introduce an unseeded random call in the audio tools.

Music has six states (`menu, lab, operations, skirmish, victory, defeat`) with
**skirmish as a rotation pool of 8 tracks** that auto-advances without repeating
consecutively, so a long match does not loop one bed. A complete from-scratch
procedural soundtrack engine exists and works; the shipped set is currently
curated files copied in by a separate module. One consequence of curated single
masters: the combat-intensity layer mixing (raising a rhythm/lead stem under a
real engagement) has no stems to act on and simply lets the track play.

---

## 11. Verification

There is **no automated test suite** (one existed and was deleted during a
battle-system unification; do not try to revive it without asking). Three
mechanisms replace it:

1. **Parse checks.** A targeted script that loads an edited file list with
   `CACHE_MODE_IGNORE` after every edit; a full-tree variant for structural
   changes (new autoload, new `class_name`). The full check loads 200+
   interdependent scripts and has been observed running 20+ minutes — it is not
   a "quick" check. Godot block-buffers stdout when piped, so expect no output
   until exit; always pass `--quit` and `--path`.
2. **Headless probe scripts** — one-off `SceneTree` scripts that boot a slice of
   the game (navmesh, economy, AI, placement, vision, drivetrain, ranges,
   streaming) and print findings. This is the de-facto regression harness. Write
   one whenever a measurement decides a design question; several constants in
   this document exist because a probe measured the alternative.
3. **Manual playtest** for anything visual or interactive.

A balance-report tool scores every catalog entry:
`value = dps*3.0 + hp*0.3 + energy_capacity*1.2 + energy_regen*4.0`,
`cost = metal + crystal*2.0 + weight*0.05`, ratio flagged at >1.5x or <0.5x its
category average. Treat it as a candidate generator for a human, never an
authority: it cannot see interception capability (PD weapons score 0.37-1.02),
economy throughput (harvester 0.22), vision (sensors 0.19) or mobility, and it
prints those caveats every run.

---

## 12. Suggested build order

Rebuilding this in dependency order, with a playable checkpoint at each stage:

1. **Catalog + stat math, headless.** Module catalog, `ModuleData` tweak
   scaling, global scale factors, hull loader reading `.json` sidecars,
   `DamageResolver`, `Drivetrain`, `PowerBudget`, `WeaponRange`, `WeaponAlpha`,
   `DesignStats`, `DesignCosting`. Verify with a probe that prints a design's
   numbers. *Everything else depends on this and nothing here depends on a
   scene.*
2. **Blueprint serialisation + reconstruction.** JSON in, node tree out, plus
   the visual builder's procedural-primitive fallback path. Verify by
   reconstructing the bundled designs headlessly.
3. **Design Lab, minimum viable.** Orbit camera, hull load, parts bin, raycast
   placement, clipping test, gizmo rotate, tweak sliders, live telemetry rail,
   save/load. This is the point at which the game's thesis is testable.
4. **Proving Ground.** `Battle.tscn` with a `MatchRuleSet` that has economy, AI
   and production off; chase camera; dummies; `auto_weapon` firing, damage
   resolution, subsystem stripping, wrecks. First real combat feedback.
5. **Terrain and maps.** JSON maps, heightmap terrain, surface palette, water,
   obstacles, navmesh baking (all four meshes), terrain speed multipliers.
6. **Skirmish core.** Economy service, resource fields, harvester FSM,
   refinery + docks, structures, placement service, the five production queues,
   build bar, HQ win condition.
7. **HUD.** Resource ribbon, production deck, command card, minimap with
   three-state fog, alert log. One instance of each.
8. **Fog of war + vision**, then range tiers become meaningful and spotting
   starts to matter.
9. **AI.** Utility commander, then squads, then counter-drafting.
10. **Operations**, after-action reports, records.
11. **Art and audio pipelines.** Procedural Blender authoring, collision bakes,
    procedural audio + manifest.
12. **Tutorial**, livery, hull authoring, polish.

---

## 13. Traps — every one of these was a real bug here

- **Two implementations of one stat will drift.** The Lab's simplified
  re-derivation of weight capacity knew 4 of 17 locomotion types; its local
  armor table displayed the explosive threshold labelled Energy. Delete copies;
  never correct them.
- **A stat that is free is a solved dominant choice.** Armor material and
  thickness once multiplied HP for free (no cost, no weight in combat), and hull
  scale affected only mounting area. Both were auto-picks — the exact failure
  the design vision warns about.
- **Per-shot damage, not DPS, is what armor gates on.** A rapid-fire weapon at
  `dps*fire_rate ≈ 5.5` sits permanently under every threshold and deals 15% of
  reduced damage to anything armored. Check every weapon's alpha against the
  threshold table when tuning.
- **`fire_rate` is an interval, not a rate.** Name it accordingly or every
  balance tool reads it backwards.
- **Range that exceeds vision is range the game cannot use.** Anchor reach to
  vision in explicit tiers, or a 7x range spread plays as one distance.
- **Analyzers must return a full key set on every path, including for a null
  hull.** Returning `{}` for an invalid hull broke the Lab on load, because the
  clear path calls the same update with null.
- **Never mutate a shared material in place.** Part materials are shared per
  role+tint, and the battle mesh merge groups by material identity.
- **Facet segmentation must be baked.** Flooding coplanar neighbours at click
  time is a function of where the player let go, not of the face.
- **Side classification must be area-weighted.** Dominant-axis classification
  left 15 of 94 hulls with no front facet.
- **Derive dock bays and building exits from the footprint.** Building holes,
  clearance widening and Recast agent-radius erosion all move the walkable edge;
  every hardcoded position went off-mesh the next time any of the three changed.
- **Rate-limit anything that triggers a navmesh rebake**, and escalate the
  cooldown when the trigger does not clear.
- **Scan on a timer, not per frame,** for anything O(viewers x targets).
- **Godot 4.7 specifics:** no `Mesh.convex_decompose`; VHACD `max_concavity`
  defaults to a no-op; Recast voxel counts explode with map extent and the baker
  segfaults past a threshold; headless Godot cannot simulate held mouse-button
  state (so movement math must be pure functions to be testable at all).
- **Blender -> Godot winding:** two determinant -1 transforms and a normal
  recalculation between them ships an entire roster inside out.
- **Don't let the "polished" requirement slip.** It is the expensive one, and
  the moment attachments stop getting transition geometry the whole thing reads
  as a bug rather than a joke.

---

## 14. Scope calibration

| Area | Size |
|---|---|
| Runtime GDScript | 206 files, ~96,000 lines |
| Authoring tools (Python + GDScript) | ~48,000 lines, 336 files |
| Largest files | visual builder 7.5k, match director 4.8k, module catalog 4.0k, terrain builder 3.6k, auto weapon 3.4k, module placer 3.3k |
| Scenes / shaders | 18 / 21 |
| Hulls | 127 (11 manufacturers, 6 classes, 3 domains) |
| Authored part meshes | ~292 |
| Catalog entries | 67 (39 weapon, 8 module, 6 generator, 1 armor, 13 locomotion) |
| Maps | 14 |
| SFX banks / music states | 66 / 6 |
| Bundled blueprints | 20 loadout + 9 default roster + enemy rosters |

### A minimum viable clone

If the goal is the thesis rather than the whole game, the irreducible core is:

- the catalog + tweak scaling + the four analyzers (§4),
- the threshold/chip/brute-force damage model with directional facets (§4.3),
- freeform placement with live clipping and a live telemetry rail (§5),
- one map, one enemy, harvester -> refinery -> one production queue (§6.3-6.4),
- fog of war with vision-anchored weapon ranges (§6.6).

Everything else — 127 hulls, operations, counter-drafting, the audio synthesis
package, hull authoring, livery, the tutorial — is depth layered on top of that
loop, and can be added in any order without changing its shape.
