extends SceneTree
# Generates real per-terrain-type albedo/normal/roughness texture maps,
# entirely procedurally, headlessly, in pure Godot (Image + hand-rolled
# periodic value noise) - same technique as generate_faction_textures.gd
# (this project's established zero-external-asset pattern), pre-baked to
# PNGs once rather than regenerated at runtime, for the same reason: a
# per-pixel GDScript loop at usable resolution is too slow to repeat every
# game boot.
#
# Unlike the faction pipeline (which bakes a NEUTRAL grayscale mask the
# real-time shader re-tints per faction via base_color/accent_color), these
# textures bake REAL COLOR directly into the albedo PNG - terrain doesn't
# have a per-faction tint step, VISUAL_ART_DIRECTION.md section 4 already
# specifies each terrain type's exact color, and terrain geometry is never
# stretched at runtime the way a Design Lab hull is, so there's no
# world-space/triplanar UV problem to solve either - a plain tiled
# StandardMaterial3D (see terrain_builder.gd) is enough.
#
# Five special-case terrain types (matching the surface_zones/shallow_water_
# areas types TerrainBuilder/map_catalog.gd/module_catalog.gd already
# differentiate mechanically via get_terrain_speed_multiplier()): marsh,
# rocky, snow_mud, sand, shallow_water. Plus the two BASELINE types every map
# is mostly made of, which never had a get_surface_type_at() string of their
# own (they're not part of the mechanical speed-multiplier system - that's
# unaffected by this pass, this is cosmetic only): "grassland" for the flat
# Ground box mesh under everything (map_catalog.gd's per-map ground_color),
# and "blue_water" for the ordinary deep water_areas plane, as opposed to
# shallow_water's shallow, see-through, sandy-bed look.
#
# 2026-07-17: base roughness values for the organic/dirt/rock types (marsh's
# mud, rocky, snow_mud's snow, sand, grassland) raised further toward matte
# (~0.93-0.95) as part of root-causing a report that the whole game looked
# too shiny/glossy. A real-camera screenshot diagnostic (scratch/
# diagnose_glossiness.gd/_wide.gd) found the Environment/DirectionalLight3D
# setup completely unmodified from Godot's own defaults (no SSR, no glow, no
# cranked light energy) - ruling out environment/lighting as the cause -
# while these terrain roughness values, though already fairly high, weren't
# as close to true matte as real dirt/grass/rock actually are. The genuinely
# glossy hull hotspot the same diagnostic reproduced turned out to be a
# SEPARATE, unrelated issue (hardened_steel armor's roughness, see
# hull_material_builder.gd) - not a shared root cause between the two
# systems after all, just two independent values tuned lower than the
# intended matte-terrain/soft-highlight-metal look called for. Full
# reasoning logged in DECISIONS_NEEDED.md. The deliberately glossy
# exceptions (marsh's puddles, snow_mud's mud ruts, shallow_water,
# blue_water) were NOT touched - those are supposed to read as wet/glossy.
#
# Re-run after changing TERRAIN_TEX_PARAMS below:
#   ./Godot_v4.3-stable_win64_console.exe --headless --script tools/generate_terrain_textures.gd

const OUT_DIR = "res://assets/textures/terrain"
const TEX_SIZE = 256

# Same fixed "sun" as generate_faction_textures.gd's LIGHT_DIR - one baked
# lighting rig for the whole game, so terrain's painted-in shading and
# hulls' painted-in shading agree on where the light comes from.
const LIGHT_DIR = Vector3(-0.45, -0.65, 0.6)

func _init():
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	_generate("marsh", _eval_marsh)
	_generate("rocky", _eval_rocky)
	_generate("snow_mud", _eval_snow_mud)
	_generate("sand", _eval_sand)
	_generate("shallow_water", _eval_shallow_water)
	_generate("grassland", _eval_grassland)
	_generate("blue_water", _eval_blue_water)
	# RTS_CORE_ROADMAP.md B7: 3 new surface_zones types, matching
	# module_catalog.gd's TERRAIN_SPEED_MULTIPLIERS additions.
	_generate("gravel", _eval_gravel)
	_generate("forest", _eval_forest)
	_generate("ice", _eval_ice)
	quit(0)

# --- Periodic value noise (tiles seamlessly at `period` lattice cells) ---
# Identical technique to generate_faction_textures.gd - duplicated rather
# than shared, matching this project's existing convention of each
# generator tool script being a self-contained one-shot bake, not a shared
# runtime dependency.

static func _hash_periodic(ix: int, iy: int, period: int, seed: int) -> float:
	var px = ((ix % period) + period) % period
	var py = ((iy % period) + period) % period
	var h = (px * 374761393 + py * 668265263 + seed * 2246822519) & 0x7FFFFFFF
	h = (h ^ (h >> 13)) * 1274126177
	h = (h ^ (h >> 16)) & 0x7FFFFFFF
	return float(h) / float(0x7FFFFFFF)

static func _periodic_noise2d(x: float, y: float, period: int, seed: int) -> float:
	var ix = int(floor(x))
	var iy = int(floor(y))
	var fx = x - ix
	var fy = y - iy
	fx = fx * fx * (3.0 - 2.0 * fx)
	fy = fy * fy * (3.0 - 2.0 * fy)
	var n00 = _hash_periodic(ix, iy, period, seed)
	var n10 = _hash_periodic(ix + 1, iy, period, seed)
	var n01 = _hash_periodic(ix, iy + 1, period, seed)
	var n11 = _hash_periodic(ix + 1, iy + 1, period, seed)
	var nx0 = lerp(n00, n10, fx)
	var nx1 = lerp(n01, n11, fx)
	return lerp(nx0, nx1, fy)

# --- Per-terrain-type surface evaluation ---
# Each returns {"color": Color, "height": float, "roughness": float 0-1}.

# Marsh/swamp: darker/cooler/murkier green-brown mud, mottled, with glossy
# standing-water puddle pockets (sheen ONLY in the puddles, per
# VISUAL_ART_DIRECTION.md section 4 - the mud itself stays matte).
static func _eval_marsh(x: int, y: int) -> Dictionary:
	var seed = 9001
	var base = Color(0.15, 0.18, 0.125)
	var mottle = _periodic_noise2d(float(x) / 20.0, float(y) / 20.0, TEX_SIZE / 20, seed) - 0.5
	var color = base.lerp(Color(0.2, 0.21, 0.15), clamp(mottle + 0.5, 0.0, 1.0))
	var grain = _periodic_noise2d(float(x) / 6.0, float(y) / 6.0, TEX_SIZE / 6, seed + 1) - 0.5
	color = color.lightened(0.0) if grain >= 0.0 else color.darkened(-grain * 0.15)
	color = color.lightened(grain * 0.1) if grain >= 0.0 else color
	var height = mottle * 0.4 + grain * 0.15
	var roughness = 0.94 # raised from 0.88, see file header comment

	var puddle_noise = _periodic_noise2d(float(x) / 28.0, float(y) / 28.0, TEX_SIZE / 28, seed + 2)
	var puddle_mask = smoothstep(0.62, 0.8, puddle_noise)
	if puddle_mask > 0.0:
		color = color.lerp(Color(0.09, 0.16, 0.19), puddle_mask)
		roughness = lerp(roughness, 0.12, puddle_mask)
		height -= puddle_mask * 0.8
	return {"color": color, "height": height, "roughness": roughness}

# Rocky: cooler grey-brown, chunky faceted rock faces separated by dark
# crevices - reuses the faction pipeline's panel-grid/ink-seam technique
# (generate_faction_textures.gd's _eval_surface), themed as rock facets
# instead of hull panels, for the "hard and blocky at a glance" read
# VISUAL_ART_DIRECTION.md asks for.
static func _eval_rocky(x: int, y: int) -> Dictionary:
	var seed = 9101
	var facet_size = 32
	var base = Color(0.42, 0.4, 0.37)
	var facets_across = TEX_SIZE / facet_size

	# Domain-warp the lookup coordinates before bucketing into facets, so
	# crack lines wiggle instead of forming a perfect square grid - a plain
	# unwarped grid reads as floor tile/pavement, not broken rock. The warp
	# noise itself is sampled at the SAME period as the facet grid so it
	# still tiles seamlessly at the texture edge.
	var warp_x = float(x) + (_periodic_noise2d(float(x) / 11.0, float(y) / 11.0, TEX_SIZE / 11, seed + 9) - 0.5) * 14.0
	var warp_y = float(y) + (_periodic_noise2d(float(x) / 13.0, float(y) / 13.0, TEX_SIZE / 13, seed + 10) - 0.5) * 14.0
	var wxi = int(floor(warp_x)) % TEX_SIZE
	if wxi < 0: wxi += TEX_SIZE
	var wyi = int(floor(warp_y)) % TEX_SIZE
	if wyi < 0: wyi += TEX_SIZE

	var fi = (wxi / facet_size) % facets_across
	var fj = (wyi / facet_size) % facets_across
	var jitter = (_hash_periodic(fi, fj, facets_across, seed) - 0.5) * 2.0 * 0.14
	var color = base.lightened(jitter) if jitter >= 0.0 else base.darkened(-jitter)
	var height = jitter * 1.5
	var roughness = 0.95 # raised from 0.9, see file header comment

	var lx = wxi % facet_size
	var ly = wyi % facet_size
	var seam_width = max(facet_size * 0.16, 1.0)
	var seam_dist = min(lx, min(facet_size - lx, min(ly, facet_size - ly)))
	var seam_mask = clamp(1.0 - float(seam_dist) / seam_width, 0.0, 1.0)
	seam_mask = pow(seam_mask, 0.6)
	color = color.lerp(Color(0.08, 0.07, 0.06), seam_mask)
	height -= seam_mask * 1.4
	roughness += seam_mask * 0.08

	var grain = _periodic_noise2d(float(x) / 5.0, float(y) / 5.0, TEX_SIZE / 5, seed + 1) - 0.5
	color = color.lightened(grain * 0.1) if grain >= 0.0 else color.darkened(-grain * 0.1)
	height += grain * 0.3
	return {"color": color, "height": height, "roughness": clamp(roughness, 0.05, 0.98)}

# Snow vs. mud, combined in one surface_type per map_catalog.gd's schema:
# bright warm-white snow (never blue-white, ties to the game's warm-
# aluminum temperature target - VISUAL_ART_DIRECTION.md section 1.1) cut
# through by dark, GLOSSY mud-rut channels - the one deliberate matte-
# terrain exception the direction doc calls out, since wet mud really is
# reflective and the gloss itself reads as "this will slow you down."
static func _eval_snow_mud(x: int, y: int) -> Dictionary:
	var seed = 9201
	var color = Color(0.8, 0.78, 0.72)
	var grain = _periodic_noise2d(float(x) / 7.0, float(y) / 7.0, TEX_SIZE / 7, seed) - 0.5
	color = color.lightened(grain * 0.08) if grain >= 0.0 else color.darkened(-grain * 0.08)
	var height = grain * 0.2
	var roughness = 0.92 # raised from 0.75, see file header comment

	# Diagonal tread-rut bands: sample along a 45-degree-rotated axis so
	# ruts read as tracks cutting across the drift, not a straight grid.
	var rx = (float(x) + float(y)) * 0.7071
	var ry = (float(x) - float(y)) * 0.7071
	var rut_noise = _periodic_noise2d(rx / 30.0, ry / 4.0, TEX_SIZE / 4, seed + 1)
	var rut_mask = smoothstep(0.7, 0.86, rut_noise)
	if rut_mask > 0.0:
		color = color.lerp(Color(0.2, 0.15, 0.1), rut_mask)
		roughness = lerp(roughness, 0.18, rut_mask)
		height -= rut_mask * 1.0
	return {"color": color, "height": height, "roughness": roughness}

# Soft sand: warm light tan, matte, soft LOW-frequency dune-shaped ripples
# (not chunky like rock) - amplitude deliberately kept gentle so the normal
# map reads as rolling dunes, not gravel.
static func _eval_sand(x: int, y: int) -> Dictionary:
	var seed = 9301
	var color = Color(0.74, 0.65, 0.45)
	var ripple = _periodic_noise2d(float(x) / 44.0, float(y) / 14.0, TEX_SIZE / 44, seed) - 0.5
	color = color.lightened(ripple * 0.1) if ripple >= 0.0 else color.darkened(-ripple * 0.1)
	var height = ripple * 0.9
	var grain = _periodic_noise2d(float(x) / 4.0, float(y) / 4.0, TEX_SIZE / 4, seed + 1) - 0.5
	color = color.lightened(grain * 0.04) if grain >= 0.0 else color.darkened(-grain * 0.04)
	height += grain * 0.08
	return {"color": color, "height": height, "roughness": 0.93} # raised from 0.88, see file header comment

# RTS_CORE_ROADMAP.md B7: gravel - packed road-grade surface (the one
# surface type that's a genuine speed BONUS, not a penalty - see
# module_catalog.gd's TERRAIN_SPEED_MULTIPLIERS). Light warm grey, fine
# grain plus sparse small darker pebbles - reads as "hard-packed and fast"
# rather than the soft/organic look of sand or mud.
static func _eval_gravel(x: int, y: int) -> Dictionary:
	var seed = 9701
	var base = Color(0.52, 0.5, 0.46)
	var grain = _periodic_noise2d(float(x) / 5.0, float(y) / 5.0, TEX_SIZE / 5, seed) - 0.5
	var color = base.lightened(grain * 0.12) if grain >= 0.0 else base.darkened(-grain * 0.12)
	var height = grain * 0.3

	var pebble_noise = _periodic_noise2d(float(x) / 9.0, float(y) / 9.0, TEX_SIZE / 9, seed + 1)
	var pebble_mask = smoothstep(0.72, 0.86, pebble_noise)
	if pebble_mask > 0.0:
		color = color.darkened(pebble_mask * 0.35)
		height -= pebble_mask * 0.5
	return {"color": color, "height": height, "roughness": 0.8}

# Forest floor: dark, dense, mottled green-brown - dappled canopy-shadow
# blobs (soft, irregular, unlike rocky's hard-edged facets) standing in
# for broken sunlight through tree cover, per this surface's "dense
# vegetation" mechanical read (worst for wheels, best for legs).
static func _eval_forest(x: int, y: int) -> Dictionary:
	var seed = 9801
	var base = Color(0.13, 0.17, 0.1)
	var mottle = _periodic_noise2d(float(x) / 18.0, float(y) / 18.0, TEX_SIZE / 18, seed) - 0.5
	var color = base.lightened(mottle * 0.2) if mottle >= 0.0 else base.darkened(-mottle * 0.2)
	var height = mottle * 0.4

	var canopy_noise = _periodic_noise2d(float(x) / 26.0, float(y) / 26.0, TEX_SIZE / 26, seed + 1)
	var shadow_mask = smoothstep(0.45, 0.7, canopy_noise)
	color = color.darkened(shadow_mask * 0.4)
	height -= shadow_mask * 0.6

	var grain = _periodic_noise2d(float(x) / 4.0, float(y) / 4.0, TEX_SIZE / 4, seed + 2) - 0.5
	color = color.lightened(grain * 0.06) if grain >= 0.0 else color.darkened(-grain * 0.06)
	return {"color": color, "height": height, "roughness": 0.92}

# Ice: pale cool blue-white, low roughness (the one deliberately GLOSSY
# ground-plane surface besides the wet-mud/puddle exceptions elsewhere in
# this file - the sheen itself is what reads as "slippery, will cost you
# traction"), with faint jagged crack lines instead of organic mottling.
static func _eval_ice(x: int, y: int) -> Dictionary:
	var seed = 9901
	var base = Color(0.78, 0.86, 0.9)
	var grain = _periodic_noise2d(float(x) / 30.0, float(y) / 30.0, TEX_SIZE / 30, seed) - 0.5
	var color = base.lightened(grain * 0.06) if grain >= 0.0 else base.darkened(-grain * 0.06)
	var height = grain * 0.3

	# Sparse, thin crack lines: a domain-warped ridge (near-zero of a noise
	# field), not a filled region like the other surfaces' masks.
	var crack_noise = _periodic_noise2d(float(x) / 16.0, float(y) / 16.0, TEX_SIZE / 16, seed + 1)
	var crack_mask = 1.0 - smoothstep(0.0, 0.04, abs(crack_noise - 0.5))
	if crack_mask > 0.0:
		color = color.darkened(crack_mask * 0.3)
		height -= crack_mask * 0.4
	return {"color": color, "height": height, "roughness": 0.15}

# Shallow water: lighter, more saturated teal-blue than deep water, with
# visible sandy-bed mottling baked directly into the albedo so the tile
# itself communicates "crossable/amphibious-passable" per
# VISUAL_ART_DIRECTION.md section 4 - the actual translucency/sheen still
# comes from the StandardMaterial3D transparency terrain_builder.gd applies
# on top, same as before.
static func _eval_shallow_water(x: int, y: int) -> Dictionary:
	var seed = 9401
	var teal = Color(0.32, 0.52, 0.53)
	var sandy_bed = Color(0.55, 0.53, 0.38)
	var bed_noise = _periodic_noise2d(float(x) / 24.0, float(y) / 24.0, TEX_SIZE / 24, seed)
	var bed_mask = smoothstep(0.4, 0.75, bed_noise) * 0.55
	var color = teal.lerp(sandy_bed, bed_mask)
	var ripple = _periodic_noise2d(float(x) / 30.0, float(y) / 9.0, TEX_SIZE / 30, seed + 1) - 0.5
	var height = ripple * 0.5
	return {"color": color, "height": height, "roughness": 0.3}

# Baseline grassland: GREEN grass (2026-08-26 22:14 playtest fix).
# The previous `Color(0.32, 0.34, 0.17)` base was olive-green with a
# strong yellow tint that read as "scrubland" at RTS zoom - exactly
# what the user said: "ground looks ridiculous, the texture is all
# yellow-brown dead grass." The grassland_v1/v2/v3 photo variants
# are still scrubland plates (assets we don't ship a green plate for
# this pass), but the procedural bake - the texture that fills the
# default ground where no surface_zone overrides it - now reads as
# actual grass. The per-map `ground_color` multiplier (each map's own
# `ground_color` field, multiplied with this baked texture) still
# lets a map push warmer/cooler, but the base is no longer a
# yellow-tinted olive.
# Two-scale noise (coarse mottling + fine grain) for tread-track
# readability, per VISUAL_ART_DIRECTION.md section 4's "open ground:
# the neutral baseline" spec. No seams/facets/gloss-pockets - this
# is meant to disappear into the background most of the time. Baked
# as absolute color since terrain_builder.gd applies a light per-map
# tint on top of this one (each map's own `ground_color`) - see
# build_ground_material().
static func _eval_grassland(x: int, y: int) -> Dictionary:
	var seed = 9501
	# Green grass palette: deeper green base, brighter highlights
	# (lightened mottling), darker shadow (darkened mottling). The
	# `+grain * 0.05` clamp on the per-pixel variation prevents the
	# 0.5-amplitude grain from reading as noise speckle at RTS zoom.
	var base = Color(0.18, 0.32, 0.14)
	var highlight = Color(0.30, 0.46, 0.20)
	var shadow = Color(0.10, 0.20, 0.08)
	var mottle = _periodic_noise2d(float(x) / 40.0, float(y) / 40.0, TEX_SIZE / 40, seed) - 0.5
	var color = base.lerp(highlight, mottle + 0.5) if mottle >= 0.0 else base.lerp(shadow, -mottle + 0.5)
	var height = mottle * 0.5
	var grain = _periodic_noise2d(float(x) / 4.0, float(y) / 4.0, TEX_SIZE / 4, seed + 1) - 0.5
	color = color.lerp(highlight, grain * 0.5 + 0.5) if grain >= 0.0 else color.lerp(shadow, -grain * 0.5 + 0.5)
	height += grain * 0.2
	return {"color": color, "height": height, "roughness": 0.95} # raised from 0.87 - the material Chris specifically called out as unnaturally shiny/smooth, see file header comment

# Baseline deep water: darker, more saturated and DESATURATED-dark than
# shallow_water (opaque/naval-only, per VISUAL_ART_DIRECTION.md section 4),
# with a subtle current-streak pattern (gentle, unlike snow_mud's bold
# ruts) plus sparse brighter glint blotches standing in for distant
# wave-crest sparkle - low uniform roughness throughout (water sheen),
# not just in pockets, since the whole surface is water here.
static func _eval_blue_water(x: int, y: int) -> Dictionary:
	var seed = 9601
	var base = Color(0.07, 0.16, 0.27)
	var current = _periodic_noise2d(float(x) / 50.0, float(y) / 9.0, TEX_SIZE / 9, seed) - 0.5
	var color = base.lightened(current * 0.12) if current >= 0.0 else base.darkened(-current * 0.12)
	var height = current * 0.6

	var glint_noise = _periodic_noise2d(float(x) / 7.0, float(y) / 7.0, TEX_SIZE / 7, seed + 1)
	var glint_mask = smoothstep(0.84, 0.95, glint_noise)
	if glint_mask > 0.0:
		color = color.lightened(glint_mask * 0.16)
		height += glint_mask * 0.15

	return {"color": color, "height": height, "roughness": 0.28}

# --- Bake: albedo (with directional shading pass) + normal + roughness ---
# Same structural approach as generate_faction_textures.gd's
# _generate_faction_textures(): build a per-pixel height field, derive a
# normal map from it via wrapped central differences (tiles seamlessly),
# and bake dot(normal, LIGHT_DIR) into the albedo as a fixed multiplier so
# terrain reads with consistent light/shadow regardless of the real-time
# light's actual direction - one baked lighting rig for the whole game.
func _generate(type_id: String, eval_fn: Callable):
	var albedo_img = Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGB8)
	var rough_img = Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGB8)
	var normal_img = Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGB8)
	var height_field = []
	var color_field = []
	height_field.resize(TEX_SIZE * TEX_SIZE)
	color_field.resize(TEX_SIZE * TEX_SIZE)

	for y in range(TEX_SIZE):
		for x in range(TEX_SIZE):
			var s = eval_fn.call(x, y)
			color_field[y * TEX_SIZE + x] = s.color
			height_field[y * TEX_SIZE + x] = s.height
			var r = clamp(s.roughness, 0.05, 0.98)
			rough_img.set_pixel(x, y, Color(r, r, r))

	var strength = 2.5
	var light_dir = LIGHT_DIR.normalized()
	for y in range(TEX_SIZE):
		for x in range(TEX_SIZE):
			var x0 = (x - 1 + TEX_SIZE) % TEX_SIZE
			var x1 = (x + 1) % TEX_SIZE
			var y0 = (y - 1 + TEX_SIZE) % TEX_SIZE
			var y1 = (y + 1) % TEX_SIZE
			var dx = (height_field[y * TEX_SIZE + x1] - height_field[y * TEX_SIZE + x0]) * strength
			var dy = (height_field[y1 * TEX_SIZE + x] - height_field[y0 * TEX_SIZE + x]) * strength
			var n = Vector3(-dx, -dy, 1.0).normalized()
			normal_img.set_pixel(x, y, Color(n.x * 0.5 + 0.5, n.y * 0.5 + 0.5, n.z * 0.5 + 0.5))

			var ndotl = n.dot(light_dir)
			var shade = clamp(0.55 + (ndotl * 0.5 + 0.5) * 0.85, 0.45, 1.35)
			var c: Color = color_field[y * TEX_SIZE + x]
			albedo_img.set_pixel(x, y, Color(clamp(c.r * shade, 0.0, 1.0), clamp(c.g * shade, 0.0, 1.0), clamp(c.b * shade, 0.0, 1.0)))

	albedo_img.save_png(OUT_DIR + "/" + type_id + "_albedo.png")
	normal_img.save_png(OUT_DIR + "/" + type_id + "_normal.png")
	rough_img.save_png(OUT_DIR + "/" + type_id + "_roughness.png")
	print("Generated textures for ", type_id)
