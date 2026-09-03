# Weapon VFX Framework Contract

**Purpose:** A minimal, data-driven common layer so 16 per-weapon Clankers can implement distinct projectile looks + impact animations without forking the framework. All per-weapon styling is data-driven; the framework owns spawn/trail/impact entry points and shared helpers only.

---

## 1. Spawn Paths per Firing Method (auto_weapon.gd)

| Firing Method | Projectile Type | Spawn Entry Point | Projectile Body Builder | Trail Hook |
|---------------|-----------------|-------------------|-------------------------|------------|
| `_fire_kinetic_projectile` / `_fire_gun_tracer` / `_fire_aa_autocannon` / `_fire_anti_materiel_rifle` / `_fire_coil_gun` | Hitscan/tracer (MeshInstance3D cylinder) | `_fire_kinetic_projectile(radius, length, duration, color, explode_on_hit, profile)` | Inline: `MunitionPool.unit_cylinder()` + emissive core/glow | Optional `profile.trail == "embers"` → `_spawn_flight_mote` |
| `_fire_arcing_shell_at` (artillery, mortar_array, spigot_mortar, rocket_artillery, grenade_launcher, plasma_lobber, napalm_mortar) | Lobbed shell (Node3D + MeshInstance3D) | `_fire_arcing_shell_at(shell_radius, arc_height, colour, blast_radius, damage, aim_offset, flight_time, profile)` | `_make_round_body(kind, radius, colour)` — `kind ∈ {"bomb","rocket"}` | `profile.trail_bulk > 0` → `VFXEffects.make_missile_trail(shell, trail_bulk)` + `_detach_trail_on_free` |
| `_spawn_missile` / `_fire_missile_projectile` / `_fire_swarm_missiles` / `_fire_hypervelocity_missile` / `_fire_sam_launcher` / `_fire_loitering_munition` / `_fire_anti_radiation_missile` / `_fire_bunker_buster` / `_fire_cruise_missile` | Interceptable missile (weapon_missile.gd) | `_spawn_missile(target, damage, seconds_to_max_range, is_top_attack, y_offset)` | `ModuleCatalog.get_missile_mesh(type_id)` → authored mesh_part else procedural fallback in `weapon_missile._ready()` | `VFXEffects.make_missile_trail(self)` in `weapon_missile._ready()` (local_coords=true) |
| `_fire_drone_swarm` / `_launch_scout_drone` | Autonomous drone (drone_unit.gd) | Inline in `_fire_drone_swarm` / `_launch_scout_drone` | `drone_unit.gd` builds its own visual | None |
| `_fire_cluster_dispenser` | Canister → bomblets | Inline in `_fire_cluster_dispenser` | `cluster_dispenser_canister.glb` fallback `BoxMesh` + `MunitionPool.unit_sphere()` bomblets | None |
| `_fire_mine_layer` | Proximity mine (proximity_mine.gd) | `ProximityMine.spawn(parent, dest, team, damage, damage_class)` | `proximity_mine.gd` builds visual | None |
| `_fire_flame_spray` | Continuous stream (ImmediateMesh) | `_update_flame_stream_mesh()` → `VFXEffects.update_flame_arc_mesh()` | `VFXEffects.get_flame_arc_material()` shader | N/A (volumetric ribbon) |
| `_fire_continuous_beam` / `_fire_railgun_beam` / `_fire_arc_projector` / `_fire_ion_cannon` / `_fire_microwave_emitter` / `_fire_particle_lance` | Hitscan beam (MeshInstance3D cylinder) | Inline per weapon | `MunitionPool.unit_cylinder()` / `unit_taper()` + `aim_beam()` | Vapor rings along path |
| `_fire_smoke_discharger` / `_fire_sensor_beacon_launcher` | Lobbed canister/beacon | Inline | `MunitionPool.unit_cylinder()` / `unit_sphere()` | None |
| `_fire_recoilless_rifle` | Kinetic projectile + backblast cone | `_fire_kinetic_projectile` + inline backblast | Same as kinetic | None |
| `_fire_flak_cannon` | Timed-fuse shell | Inline | `MunitionPool.unit_sphere()` | None |

---

## 2. Trail Helpers (Shared)

### `VFXEffects.make_missile_trail(parent: Node3D, bulk: float = 1.0) → GPUParticles3D`
- **Purpose:** Dense smoke plume behind missiles/rockets.
- **Contract:** `local_coords=false` (world-space trail). Caller must position at missile rear (+Z).
- **Lifecycle:** Created once, `emitting=true`. On missile death: `_detach_trail_on_free(round, plume)` reparents to scene root, stops emitting, frees after `lifetime + 0.1s`.
- **Bulk scaling:** `amount = clamp(120*bulk, 24, 600)`, `lifetime = clamp(sqrt(bulk)*1.0, 0.5, 3.0)`, scale ∝ bulk. Cache key includes bulk.
- **Draw cost:** 1 draw call per emitter (GPUParticles3D, single quad mesh, cached material).

### `VFXEffects.make_damage_smoke(parent, intensity)` — continuous leak on damaged modules (local_coords=true).

### `_spawn_flight_mote(pos, color, size, delay)` — discrete puffs along arcing shells without bulk trail.

### `_detach_trail_on_free(round_node, plume)` — standard cleanup: reparent to scene, `emitting=false`, drain+tween free.

---

## 3. Impact / Damage / Decal / Light / Audio Hooks

### Core Impact Visuals (called from weapon `_fire_*` finished handlers)

| Function | Signature | Purpose | Draw Cost |
|----------|-----------|---------|-----------|
| `VFXEffects.fire_burst` | `(parent, world_pos, radius, tint) → GPUParticles3D` | Additive flame flipbook burst | 1 draw call (one-shot, auto-free) |
| `VFXEffects.smoke_puff` | `(parent, world_pos, radius, amount, tint) → GPUParticles3D` | Grey smoke cloud | 1 draw call (one-shot, auto-free) |
| `VFXEffects.scorch` | `(parent, world_pos, radius, burn_seconds, fade_seconds) → Decal` | Ground burn mark (albedo+normal+ORM) | 1 decal draw (distance-faded) |
| `VFXEffects.crater` | `(parent, world_pos, radius, fade_seconds) → Decal` | Displaced-earth crater (normal map) | 1 decal draw |
| `VFXEffects.fire_pool` | `(parent, world_pos, radius, duration) → GPUParticles3D` | Persistent napalm pool flames (BOX emission) | 1 draw call (emits for duration) |
| `VFXBurst.spawn` | `(parent, local_pos, color, count, lifetime, spread, speed_min, speed_max, gravity, scale_min, scale_max, mesh, forward_dir, light_color, light_range, light_energy) → GPUParticles3D` | Spark/debris burst (mesh particles) | 1 draw call (one-shot, auto-free) |
| `module_damage_fx.module_destroyed` | `(unit, module)` | Module strip: burst + debris + smoke + light + SFX | 2 VFXBurst + 1 smoke_puff + 1 light |
| `module_damage_fx.module_damaged` | `(unit, module)` | Below-threshold: smoke leak + crack stencil | 1 GPUParticles3D + 2 MeshInstance3D (stickers) |

### Light Flash Pattern (used by all impacts)
```gdscript
var light = OmniLight3D.new()
light.light_color = Color(...)
light.light_energy = ...
light.omni_range = ...
light.light_bake_mode = Light3D.BAKE_DISABLED
parent.add_child(light)
light.global_position = impact_pos
var lt = parent.create_tween()
lt.tween_property(light, "light_energy", 0.0, 0.15)
lt.finished.connect(func(): if is_instance_valid(light): light.queue_free())
```

### Audio Hook (via AudioManager autoload)
```gdscript
var am = get_node_or_null("/root/AudioManager")
if am: am.play_sfx_3d(key, position, null, max_db)
```
- Ordnance reports: mapped in `_fire_at_target()` match (cannon, artillery, missile, rocket, mortar, grenade, beam, etc.)
- Module strip: `impact_module_lost` → fallback `explosion`
- Ammo impacts: `_apply_ammo_impact()` routes to ammo profile (smoke, burn, flare, emp)

### Decal Budget
- `VFXEffects.MAX_ACTIVE_DECALS = 36` (global cap, LRU eviction)
- Scorch: `fade_seconds=14`, Crater: `fade_seconds=45`
- Distance fade: begin 90m, length 30m

---

## 4. Per-Weapon Tuning Knobs (module_catalog.gd)

| Knob | Location | Used By |
|------|----------|---------|
| `INDIRECT_FIRE_TYPES` | Line 337-341 | `auto_weapon._is_los_blocked_to()` — skips LOS for these |
| `PROJECTILE_CLASS` → `MISS_SPEED_FACTOR` | `auto_weapon.gd` line 284 | Evasion roll: `hitscan=0, ballistic=0.035, arc=0.09, guided=0` |
| `WEAPON_FIRE_PROFILES` | Line 119-192 | `fire_rate`, `fire_range`, `laser_color` per type_id |
| `MUZZLE_OFFSETS` | Line 207-245 | `get_muzzle_offset(type_id)` → `_fire_*` muzzle flash / projectile spawn |
| `MUZZLE_DIRECTIONS` | Line 253-265 | `get_muzzle_direction(type_id)` → barrel forward vector (elevated pivots) |
| `get_missile_mesh(type_id)` | ModuleCatalog line 2741 | `weapon_missile.mesh_part` for authored missile bodies |
| `AMMO_TYPES` / `get_ammo_profile()` | ModuleCatalog | `damage_class`, `damage_mult`, `light_mult`, `aoe_mult`, impact effects |

---

## 5. Required Function Signatures for Per-Weapon Clankers

### Projectile Body Builder (shared, data-driven)
```gdscript
# In auto_weapon.gd — CALL THIS, don't fork
func _make_round_body(kind: String, radius: float, colour: Color) -> Node3D:
	# kind: "bomb" (sphere + taper tail) | "rocket" (cylinder + cone nose)
	# Returns pivot Node3D with body + tail/nose children, oriented -Z forward
```

### Trail Attach (shared)
```gdscript
# In auto_weapon.gd — CALL THIS for any arcing shell that wants a plume
func _attach_trail_to_round(round_node: Node3D, trail_bulk: float, shell_radius: float) -> void:
	var plume := VFXEffects.make_missile_trail(round_node, trail_bulk)
	plume.position = Vector3(0, 0, shell_radius * 0.8)
	_detach_trail_on_free(round_node, plume)
```

### Standard Detonate/Impact Entry (shared)
```gdscript
# In auto_weapon.gd — CALL THIS from every _fire_* finished handler
func _detonate_at(position: Vector3, blast_radius: float, damage: float, color: Color = Color.ORANGE, entropy: float = 1.0) -> void:
	# 1. _deal_aoe_damage(position, blast_radius, damage)  # includes _apply_ammo_impact
	# 2. _spawn_explosion_visual(position, scale, color)   # fire_burst + smoke_puff + light
	# 3. VFXEffects.scorch/crater if blast_radius > threshold
```

### `_spawn_explosion_visual` (shared, currently inline in many _fire_*)
```gdscript
func _spawn_explosion_visual(pos: Vector3, scale: float, color: Color) -> void:
	var scene = _effects_parent()
	VFXEffects.fire_burst(scene, pos, scale, color)
	VFXEffects.smoke_puff(scene, pos, scale, 8, Color(0.2,0.19,0.18,0.6))
	var light = OmniLight3D.new()
	light.light_color = color; light.light_energy = 6*scale; light.omni_range = 5*scale
	scene.add_child(light); light.global_position = pos
	scene.create_tween().tween_property(light, "light_energy", 0.0, 0.15).finished.connect(func(): light.queue_free())
```

---

## 6. Weapon Roster Table + Hook Points

### Missiles (9) — all route through `weapon_missile.gd` via `_spawn_missile`

| Weapon | `_fire_*` Method | `seconds_to_max` | `is_top_attack` | `mesh_part` key | Trail Bulk | Impact Scale |
|--------|------------------|------------------|-----------------|-----------------|------------|--------------|
| guided_missile | `_fire_missile_projectile(false)` | 2.19 | false | `guided_missile` | 1.0 (fixed in weapon_missile) | 1.2 |
| missile_pod | `_fire_swarm_missiles()` (4×) | 1.50 | false | `missile_pod` | 1.0 | 1.0 per missile |
| hypervelocity_missile | `_fire_hypervelocity_missile()` (2-4× ripple) | 0.55 | false | `hypervelocity_missile` | 1.0 | 1.0 |
| sam_launcher | `_fire_sam_launcher()` | 1.15 | false | `sam_launcher` | 1.0 | 1.0 |
| loitering_munition | `_fire_loitering_munition()` | 2.71 | **true** | `loitering_munition` | 1.0 | 1.2 |
| anti_radiation_missile | `_fire_anti_radiation_missile()` | 1.55 | false | `anti_radiation_missile` | 1.0 | 1.0 |
| bunker_buster | `_fire_bunker_buster()` | 1.60 | **true** | `bunker_buster` | 1.0 | 1.4 |
| cruise_missile | `_fire_cruise_missile()` | 4.67 | false | `cruise_missile` | 1.0 | 1.5 |
| rocket_artillery | `_fire_rocket_artillery()` (4-8×) | — | false | N/A (uses `_fire_arcing_shell_at`) | **2.6** | 2.4×spread |

> **Note:** `rocket_artillery` is an arcing rocket, not a guided missile — uses `_fire_arcing_shell_at` with `profile={"body":"rocket","trail":"smoke","trail_bulk":2.6}`.

### Indirect / Lobbed (7) — all route through `_fire_arcing_shell_at`

| Weapon | `_fire_*` Method | `shell_radius` | `arc_height` | `blast_radius` | `flight_time` | `profile` keys |
|--------|------------------|----------------|--------------|----------------|---------------|----------------|
| artillery | `_fire_artillery()` | 0.4 | 12.0 | 6.0 | 0.8 | `{"body":"bomb"}` |
| mortar_array | `_fire_mortar_salvo()` (3×) | 0.2 | 6.0 | 4.0 | 0.6 | discrete spheres, no trail |
| spigot_mortar | `_fire_spigot_mortar()` | 0.5×payload | 0.55 | 5.5×payload | 1.1 | `{"body":"bomb","tumble":true}` |
| cluster_dispenser | `_fire_cluster_dispenser()` (canisters→bomblets) | 0.12×payload | — | 2.5×payload | 0.2 (bomblet) | canister glb + spheres |
| plasma_lobber | `_fire_plasma_lobber()` | 0.35 | 4.0 | 4.5 | 0.6 | sphere + puddle decal |
| mk19_grenade_launcher | `_fire_grenade_launcher()` | 0.16 | 1.8 | 2.2 | 0.35 | shallow arc, tight blast |
| napalm_mortar | `_fire_napalm_mortar()` | 0.3 | 7.0 | 4.0 | 0.7 | `{"body":"bomb"}` + `_spawn_burn_pool(1.7, 2.2)` |

---

## 7. Performance Budget & Draw-Call Accounting

**Target:** ~40 cosmetic draws per engagement (match_director comment).

| Effect Type | Max Concurrent | Draw Calls Each | Notes |
|-------------|----------------|-----------------|-------|
| `VFXEffects.make_missile_trail` | 16 (8 missiles × 2 teams) | 1 | GPUParticles3D, pooled by cache key |
| `VFXEffects.fire_burst` / `smoke_puff` | 20/engagement | 1 | One-shot, auto-free on `finished` |
| `VFXBurst.spawn` | 30/engagement | 1 | Mesh particles, cached material per (color,mesh) |
| `VFXEffects.scorch` / `crater` | 36 global cap | 1 decal | Distance-faded, LRU eviction |
| `VFXEffects.fire_pool` | 4 | 1 | BOX emission, emits for duration |
| Module strip (`module_destroyed`) | 10 | 4 | 2×VFXBurst + smoke_puff + light |
| Continuous beams/flamethrower | 4 | 2-3 | MeshInstance3D (core+glow+rings) — reused per weapon |

**Rules from godot-particles skill (enforced):**
- Trails: `local_coords=false` (world space) — already done in `make_missile_trail`.
- Volumetric explosions: `EMISSION_SHAPE_SPHERE` or `BOX`, never `POINT` — `fire_pool` uses BOX, `fire_burst` uses sphere emission via process material.
- One-shots: `emitting=false` initially, position **before** `emitting=true` — all `VFXEffects.*_puff/_burst` and `VFXBurst.spawn` do this.
- Pool/reuse one-shots: cached materials in `VFXEffects._billboard_cache`, `VFXEffects._process_cache`, `VFXBurst._material_cache`, `VFXBurst._override_cache`. No per-frame `new()` of materials.

---

## 8. Minimal Framework Extensions (Added)

No per-weapon look code. Only these shared helpers:

1. **`auto_weapon._attach_trail_to_round(round_node, trail_bulk, shell_radius)`** — wrapper for trail attach + detach (NEW).
2. **`auto_weapon._detonate_at(position, blast_radius, damage, color, entropy)`** — single impact entry combining AoE damage + ammo impact + visual + decal decision (NEW).
3. **`ModuleCatalog.get_missile_mesh(type_id)`** — already existed, returns `mesh_part` key for authored missile GLBs.
4. **`auto_weapon._spawn_explosion_visual(pos, custom_scale, color)`** — already existed, factors out fire_burst/smoke_puff/light pattern.

All are **internal shared helpers**; per-weapon Clankers only tune data (catalog entries, profile dicts) and call the standard entry points.

---

## 9. Validation Checklist for Per-Weapon Work

- [ ] Uses `_make_round_body` for arcing shells (no inline MeshInstance3D construction).
- [ ] Uses `_attach_trail_to_round` if trail wanted (no inline `make_missile_trail` + detach logic).
- [ ] Calls `_detonate_at` or `_spawn_explosion_visual` for impact (no inline VFXEffect/VFXBurst/light code).
- [ ] Missile types set `mesh_part` via `ModuleCatalog.get_missile_mesh(type_id)`.
- [ ] All new emitters use cached materials (no `StandardMaterial3D.new()` / `ParticleProcessMaterial.new()` in hot path).
- [ ] One-shots: `emitting=false` → position → `emitting=true` → `finished.connect(queue_free)`.
- [ ] Decals go through `VFXEffects.scorch/crater` (respects global cap).
- [ ] Audio via `AudioManager.play_sfx_3d(key, pos)`.

---

## 10. Structural Changes (STRUCT: YES)

**New symbols added:**
- `auto_weapon._attach_trail_to_round(round_node: Node3D, trail_bulk: float, shell_radius: float) → void` (new private method)
- `auto_weapon._detonate_at(position: Vector3, blast_radius: float, damage: float, color: Color, entropy: float) → void` (new private method)

**Existing symbols (no change):**
- `ModuleCatalog.get_missile_mesh(type_id: String) → String` (already existed at line 2741)
- `auto_weapon._spawn_explosion_visual(pos: Vector3, custom_scale: float, color: Color)` (already existed)

**No deleted/renamed symbols.** Topology rebuild not required (no new autoloads, no class_name changes). Reimport not required.

---

*End of contract. Per-weapon Clankers consume this document + catalog data; they do not modify framework files.*