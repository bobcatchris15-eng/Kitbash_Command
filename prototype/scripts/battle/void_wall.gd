class_name VoidWall
extends Node3D
# Holotable void that surrounds the battlefield.
#
# Dark grey/black floor that extends to the horizon beyond the map plus four
# vertical phantom walls at the map edge. Both carry the same phosphor grid
# shader (shaders/void_wall.gdshader) — slow drift + occasional bright sweep
# so it reads as a live display, not wallpaper.
#
# Camera stop is handled in rts_camera.gd (set_map_bounds). This file is only
# visuals. Kept separate from terrain_builder.gd because it never touches
# navigation, collision or height queries — purely decorative/horizon-hiding.

const VOID_SHADER := preload("res://shaders/void_wall.gdshader")
const MapCatalogScript = preload("res://scripts/map_catalog.gd")

# How far the dark floor extends beyond the map on each side.
const VOID_EXTEND: float = 1200.0
# Vertical wall height above/below ground. 280 clears the horizon at max
# zoom (200) even on plateaus — 90 was visible over at 55° pitch. Wall stays
# well above any terrain max_height + camera height.
const WALL_HEIGHT: float = 280.0
# Floor is sunk slightly so it never z-fights the ground mesh at the seam.
const FLOOR_Y: float = -0.35


static func build_for_map(map_def: Dictionary, parent: Node3D) -> Node3D:
	if map_def.is_empty() or parent == null:
		return null
	var half: Vector2 = MapCatalogScript.half_extents(map_def)
	var half_x: float = half.x
	var half_z: float = half.y

	# Use a single wrapper so the whole void can be freed as one subtree
	# if the match reloads.
	var root := Node3D.new()
	root.name = "VoidWall"
	parent.add_child(root)

	# Base material template — duplicated per piece so grid_scale can be
	# physical (16 m spacing) regardless of strip/wall size. Shared params
	# are copied; only grid_scale varies.
	var mat_template := ShaderMaterial.new()
	mat_template.shader = VOID_SHADER
	mat_template.set_shader_parameter("base_color", Vector3(0.055, 0.06, 0.068))
	mat_template.set_shader_parameter("grid_color", Vector3(0.16, 0.96, 0.36))
	mat_template.set_shader_parameter("scan_color", Vector3(0.22, 1.0, 0.48))
	mat_template.set_shader_parameter("grid_scale", Vector2(28.0, 28.0))
	mat_template.set_shader_parameter("line_thickness", 0.055)
	mat_template.set_shader_parameter("scan_speed", 0.09)
	mat_template.set_shader_parameter("drift_speed", 0.06)
	mat_template.set_shader_parameter("glow_strength", 0.85)
	mat_template.set_shader_parameter("sweep_speed", 0.18)
	mat_template.set_shader_parameter("sweep_width", 0.08)
	mat_template.set_shader_parameter("vignette_strength", 0.35)

	# Helper to get a per-piece material with correct physical grid density.
	# 16 m spacing matches the holotable spec — visible at tactical zoom but
	# not noisy when the player dives in.
	var make_mat := func(size: Vector2) -> ShaderMaterial:
		var m: ShaderMaterial = mat_template.duplicate() as ShaderMaterial
		var sx: float = maxf(size.x / 16.0, 4.0)
		var sy: float = maxf(size.y / 16.0, 4.0)
		m.set_shader_parameter("grid_scale", Vector2(sx, sy))
		return m

	var mat: ShaderMaterial = make_mat.call(Vector2(32.0, 32.0))

	# --- Floor: one big plane with interior discard done geometrically ---
	# Build as 4 strips + 4 corners so no fragment discard is needed (keeps
	# early-z). Each strip is a PlaneMesh sized to its exact rectangle.
	#  N strip:  x [-hx - EXT, hx + EXT]  z [ hz,  hz + EXT ]
	#  S strip:  x [-hx - EXT, hx + EXT]  z [-hz - EXT, -hz ]
	#  E strip:  x [ hx, hx + EXT]        z [-hz, hz]
	#  W strip:  x [-hx - EXT, -hx]       z [-hz, hz]
	# Corners fill the remaining squares so the donut is seamless.
	var strips: Array = [
		# x0, x1, z0, z1
		{"x0": -half_x - VOID_EXTEND, "x1": half_x + VOID_EXTEND, "z0": half_z, "z1": half_z + VOID_EXTEND}, # north
		{"x0": -half_x - VOID_EXTEND, "x1": half_x + VOID_EXTEND, "z0": -half_z - VOID_EXTEND, "z1": -half_z}, # south
		{"x0": half_x, "x1": half_x + VOID_EXTEND, "z0": -half_z, "z1": half_z}, # east
		{"x0": -half_x - VOID_EXTEND, "x1": -half_x, "z0": -half_z, "z1": half_z}, # west
	]

	for r in strips:
		var w: float = float(r.x1) - float(r.x0)
		var d: float = float(r.z1) - float(r.z0)
		var cx: float = (float(r.x0) + float(r.x1)) * 0.5
		var cz: float = (float(r.z0) + float(r.z1)) * 0.5
		var mi := MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = Vector2(w, d)
		pm.subdivide_width = maxi(1, int(ceil(w / 96.0)))
		pm.subdivide_depth = maxi(1, int(ceil(d / 96.0)))
		mi.mesh = pm
		mi.material_override = make_mat.call(Vector2(w, d))
		mi.position = Vector3(cx, FLOOR_Y, cz)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mi)

	# --- Vertical phantom walls at the exact map edge -------------------------
	# Four quads, 90 m tall, double-sided so they read from inside or slightly
	# outside the map. Sunk -6 m so bottom edge vanishes into the floor void
	# instead of floating above it when the player looks down a cliff.
	var wall_y0: float = -6.0
	var wall_y1: float = WALL_HEIGHT - 6.0
	var wall_cy: float = (wall_y0 + wall_y1) * 0.5
	var wall_h: float = wall_y1 - wall_y0

	# North / South run the full width (+ extend caps so corners meet)
	var total_w: float = half_x * 2.0 + VOID_EXTEND * 2.0
	# East / West run only the interior height so they don't double-draw corners
	var interior_h: float = half_z * 2.0

	var walls: Array = [
		{"pos": Vector3(0.0, wall_cy, half_z), "size": Vector2(total_w, wall_h), "rot": Vector3.ZERO}, # north
		{"pos": Vector3(0.0, wall_cy, -half_z), "size": Vector2(total_w, wall_h), "rot": Vector3(0.0, 180.0, 0.0)}, # south (flip so front faces inward)
		{"pos": Vector3(half_x, wall_cy, 0.0), "size": Vector2(interior_h, wall_h), "rot": Vector3(0.0, -90.0, 0.0)}, # east
		{"pos": Vector3(-half_x, wall_cy, 0.0), "size": Vector2(interior_h, wall_h), "rot": Vector3(0.0, 90.0, 0.0)}, # west
	]

	for w in walls:
		var mi := MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = w.size as Vector2
		pm.subdivide_width = maxi(1, int(ceil(w.size.x / 64.0)))
		pm.subdivide_depth = maxi(1, int(ceil(w.size.y / 64.0)))
		mi.mesh = pm
		mi.material_override = make_mat.call(w.size as Vector2)
		mi.position = w.pos as Vector3
		mi.rotation_degrees = w.rot as Vector3
		mi.rotate_object_local(Vector3(1, 0, 0), deg_to_rad(-90.0))
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mi)

	# Small lip under the map edge to kill any hairline crack between ground mesh
	# and floor strips — a thin quad bridging the seam just below the ground.
	# Invisible except when the player wedges the camera low against a wall.
	var seam := MeshInstance3D.new()
	var seam_mesh := PlaneMesh.new()
	seam_mesh.size = Vector2(half_x * 2.0 + 4.0, half_z * 2.0 + 4.0)
	seam.mesh = seam_mesh
	seam.material_override = mat
	seam.position = Vector3(0.0, FLOOR_Y - 0.05, 0.0)
	seam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(seam)
	seam.visible = false

	return root
