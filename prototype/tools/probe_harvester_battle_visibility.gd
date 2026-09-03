extends SceneTree
# Regression probe for the resource_harvester mount block vanishing in
# battle (Skirmish/Proving Ground) while rendering fine in the Design Lab.
#
# Root cause: _build_frustum_block_mesh() built a non-indexed SurfaceTool
# mesh. bake_module_visual() (battle-only - the Design Lab never merges a
# module's sub-parts) groups same-material sibling meshes and merges them
# via one SurfaceTool.append_from() session per group. Mixing a non-indexed
# surface with an indexed one (every built-in PrimitiveMesh, including the
# harvester's own mounting flange, is indexed) in the same append_from()
# session silently DROPS one of the two meshes' geometry entirely - Godot
# raises no error or warning. This only manifested with an active faction
# livery, because that's what makes the mount block's and flange's tints
# resolve to the same colour (PartMaterialsScript's livery zone override
# ignores the caller's own tint once a zone applies), which is what puts
# them in the same merge group in the first place.
#
#   Godot_v4.7.1-stable_win64_console.exe --headless --path prototype \
#     --script res://tools/probe_harvester_battle_visibility.gd --quit

const VisualBuilderScript = preload("res://scripts/visual_builder.gd")
const ModuleCatalog = preload("res://scripts/module_catalog.gd")
const PartMaterialsScript = preload("res://scripts/part_materials.gd")

func _init():
	# The bug only reproduces with an active livery - it's what forces the
	# block and flange into the same bake_module_visual() merge group.
	PartMaterialsScript.set_livery("player")

	var parent_node := Node3D.new()
	parent_node.name = "HarvesterModule"
	root.add_child(parent_node)

	var catalog_data = ModuleCatalog.get_module_data("resource_harvester")
	VisualBuilderScript.build_visual("resource_harvester", parent_node,
		catalog_data.get("size", Vector3.ONE), catalog_data.color, {})
	# bake_module_visual() is what reconstruct_vehicle() calls for every
	# non-Design-Lab (is_designer=false) module - i.e. every real battle
	# spawn. The Design Lab never calls this, which is why the bug never
	# showed up there.
	VisualBuilderScript.bake_module_visual(parent_node)

	var max_y := -INF
	for c in parent_node.get_children():
		if c is MeshInstance3D and c.mesh:
			var aabb: AABB = c.mesh.get_aabb()
			max_y = max(max_y, aabb.position.y + aabb.size.y)

	# The mount block reaches y=mount_depth (~0.45 at defaults). If its
	# geometry were dropped, the tallest surviving mesh would be the thin
	# 0.04-high flange (or whatever the drill's own local offset is, which
	# starts AT the block's top rather than reaching it independently) -
	# either way max_y would fall well short of 0.4.
	var ok := parent_node.get_child_count() >= 2 and max_y > 0.4
	print("children=", parent_node.get_child_count(), " max_y=%.3f" % max_y)
	print("RESULT: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
