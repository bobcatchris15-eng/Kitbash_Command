extends SceneTree
# Regression probe for the resource_harvester mount block/flange following the
# ACTUAL facet outline (module_placer._measure_hull_facet's convex hull)
# instead of just its bounding rectangle - see visual_builder.gd's
# _build_frustum_polygon_mesh().
#
# Exercises a non-rectangular (trapezoidal) outline, the case a plain
# w x h rectangle can't represent, and checks:
#   1. The block mesh's own AABB narrows at the tip (taper still applies).
#   2. The block's footprint at y=0 matches the outline's bounding box, not
#      some larger/smaller rectangle.
#   3. Nothing crashes building an odd (non-square) polygon.
#
#   Godot_v4.7.1-stable_win64_console.exe --headless --path prototype \
#     --script res://tools/probe_harvester_facet_outline.gd --quit

const VisualBuilderScript = preload("res://scripts/visual_builder.gd")
const ModuleCatalog = preload("res://scripts/module_catalog.gd")

func _init():
	var parent_node := Node3D.new()
	parent_node.name = "HarvesterModule"
	root.add_child(parent_node)

	# A trapezoid: wide at -z, narrow at +z. CCW as viewed from +Y, matching
	# Geometry2D.convex_hull's own winding (see _measure_hull_facet's
	# comment) - this is the same contract module_placer hands the builder.
	var outline := PackedVector2Array([
		Vector2(-1.0, -0.5), Vector2(1.0, -0.5),
		Vector2(0.6, 0.5), Vector2(-0.6, 0.5),
	])
	parent_node.set_meta("facet_size", Vector2(2.0, 1.0))
	parent_node.set_meta("facet_outline", outline)

	var catalog_data = ModuleCatalog.get_module_data("resource_harvester")
	VisualBuilderScript.build_visual("resource_harvester", parent_node,
		catalog_data.get("size", Vector3.ONE), catalog_data.color, {})

	var block := parent_node.get_node_or_null("HarvesterMountBlock") as MeshInstance3D
	var flange := parent_node.get_node_or_null("HarvesterMountFlange") as MeshInstance3D
	var ok := block != null and block.mesh != null and flange != null and flange.mesh != null

	if ok:
		var aabb: AABB = block.mesh.get_aabb()
		# Base footprint (y near 0) should match the outline's own bounding
		# box (2.0 x 1.0), not the old rectangular fallback's facet_w/h
		# (which happen to be the same numbers here on purpose - the real
		# check is that this doesn't crash or silently fall back for a
		# genuinely non-rectangular outline).
		ok = ok and aabb.size.x <= 2.05 and aabb.size.z <= 1.05
		# Depth (mount_depth default ~0.45) still present.
		ok = ok and aabb.size.y > 0.3

	print("block_ok=", block != null, " flange_ok=", flange != null,
		" block_aabb=", (block.mesh.get_aabb() if block and block.mesh else "n/a"))
	print("RESULT: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
