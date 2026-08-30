extends RefCounted
class_name VisualTuning
# Live tuning store for the toon/comic-book unit shader
# (shaders/hull_faction_material.gdshader).
#
# Why a store rather than the debug panel setting uniforms directly: units are
# built and destroyed constantly (production, death, the Design Lab rebuilding
# a hull on every edit), and each one gets a FRESH ShaderMaterial from
# hull_material_builder.gd. A slider that only walked the current scene tree
# would be silently undone the moment anything respawned - you'd dial in a
# look, build a tank, and the new tank would ignore it.
#
# So values live here, and there are two paths that keep everything in sync:
#   1. build_hull_material()/build_structural_material() call apply() on every
#      material they create, so anything born later inherits current settings.
#   2. apply_to_tree() walks live nodes, so anything already on the field
#      updates the instant a slider moves.
#
# Defaults MUST match the shader's own uniform defaults. If they drift, the
# first slider touch would visibly jump. test_visual_tuning_defaults_match_
# shader() in run_tests.gd guards this.

# Ordered so the debug panel can build its rows straight from this table
# rather than maintaining a second parallel list that could drift.
# Each: uniform name -> {label, min, max, step, default}
const PARAMS = {
	"toon_bands": {"label": "Toon Bands", "min": 1.0, "max": 6.0, "step": 1.0, "default": 3.0},
	"toon_softness": {"label": "Band Softness", "min": 0.0, "max": 0.5, "step": 0.005, "default": 0.06},
	"toon_shadow_floor": {"label": "Shadow Floor", "min": 0.0, "max": 0.8, "step": 0.01, "default": 0.28},
	"toon_specular_strength": {"label": "Specular Blob", "min": 0.0, "max": 2.0, "step": 0.05, "default": 0.5},
	"color_saturation": {"label": "Saturation", "min": 0.0, "max": 2.5, "step": 0.05, "default": 1.35},
	"color_lift": {"label": "Black Lift", "min": 0.0, "max": 0.5, "step": 0.01, "default": 0.06},
	"edge_ink_strength": {"label": "Ink Opacity", "min": 0.0, "max": 1.0, "step": 0.05, "default": 0.95},
	"ink_width": {"label": "Ink Width", "min": 0.05, "max": 0.9, "step": 0.01, "default": 0.32},
	"ink_curvature_gain": {"label": "Ink Curvature", "min": 0.005, "max": 1.0, "step": 0.005, "default": 0.06},
	"ink_rim_strength": {"label": "Ink Rim", "min": 0.0, "max": 1.0, "step": 0.05, "default": 0.55},
	"normal_strength": {"label": "Normal Depth", "min": 0.0, "max": 2.0, "step": 0.05, "default": 1.0},
	# Micro-surface (carbon-fibre weave, hammered dimples, etc.) is the
	# procedural detail layered ON TOP of the shared panel/bolts normal. Kept
	# separate from normal_strength so the two can be tuned independently -
	# the lab's StandardMaterial3D has no micro-surface at all (it just shows
	# the shared normal), so a viewer expecting the lab's "square and bolts"
	# read in the test range was getting a 45%-strong shared normal plus a
	# 45%-strong procedural layer, which looked like a different surface.
	"micro_surface_strength": {"label": "Micro Surface", "min": 0.0, "max": 1.0, "step": 0.05, "default": 0.35},
}

# Current live values. Static so every caller shares one set - there is
# deliberately no per-scene copy.
static var _values: Dictionary = {}

static func _ensure_init() -> void:
	if _values.is_empty():
		reset()

static func reset() -> void:
	_values = {}
	for key in PARAMS:
		_values[key] = PARAMS[key]["default"]

static func get_value(key: String) -> float:
	_ensure_init()
	return _values.get(key, PARAMS.get(key, {}).get("default", 0.0))

static func set_value(key: String, value: float) -> void:
	_ensure_init()
	if not PARAMS.has(key):
		push_warning("VisualTuning: unknown parameter '%s'" % key)
		return
	_values[key] = value

# Stamp every tuned uniform onto one material. Safe to call on any
# ShaderMaterial - set_shader_parameter on a uniform the shader doesn't
# declare is a no-op in Godot, so this doesn't need to know which of the two
# hull material variants it's been handed.
static func apply(mat: ShaderMaterial) -> void:
	if mat == null:
		return
	_ensure_init()
	for key in _values:
		mat.set_shader_parameter(key, _values[key])

# Push current values onto everything already in the scene. Walks the whole
# tree from `root` looking at both material_override and per-surface
# overrides, since hull pieces use the former and some assembled meshes the
# latter.
static func apply_to_tree(root: Node) -> int:
	if root == null:
		return 0
	var count := 0
	if root is MeshInstance3D:
		var mi := root as MeshInstance3D
		if mi.material_override is ShaderMaterial:
			apply(mi.material_override)
			count += 1
		for surf in range(mi.get_surface_override_material_count()):
			var m = mi.get_surface_override_material(surf)
			if m is ShaderMaterial:
				apply(m)
				count += 1
	for child in root.get_children():
		count += apply_to_tree(child)
	return count
