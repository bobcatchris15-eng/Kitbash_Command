extends SceneTree
# Quick targeted compile check for a small set of files. Bypasses the
# res:// path walking the full version does - we only care whether the
# specific files I edited in this turn still parse.

const FILES := [
	"res://_test_cliff_spawn.gd",
	"res://_test_cliff_y_offset.gd",
	"res://_test_existing_maps.gd",
	"res://_test_features.gd",
	"res://_test_forest_los.gd",
	"res://_test_ground_rock.gd",
	"res://_test_nonsquare_smoke.gd",
	"res://_test_slope_class_call.gd",
	"res://_test_slope_speed.gd",
	"res://scripts/ambient_scatter.gd",
	"res://scripts/armor_paint.gd",
	"res://scripts/armor_station_panel.gd",
	"res://scripts/battle/buildings/structure.gd",
	"res://scripts/battle/economy/building_catalog.gd",
	"res://scripts/battle/match_director.gd",
	"res://scripts/battle/units/unit.gd",
	"res://scripts/battle/units/unit_assembly.gd",
	"res://scripts/battle/vision/vision_service.gd",
	"res://scripts/blueprint_library_screen.gd",
	"res://scripts/blueprint_manager.gd",
	"res://scripts/blueprint_namer.gd",
	"res://scripts/design_stats.gd",
	"res://scripts/drivetrain.gd",
	"res://scripts/drone_unit.gd",
	"res://scripts/hud/hud_minimap.gd",
	"res://scripts/hud/hud_resource_ribbon.gd",
	"res://scripts/hud/hud_root.gd",
	"res://scripts/hud/hud_style.gd",
	"res://scripts/hull_facets.gd",
	"res://scripts/lab_document.gd",
	"res://scripts/lab_toolbar.gd",
	"res://scripts/livery_screen.gd",
	"res://scripts/main_menu.gd",
	"res://scripts/map_catalog.gd",
	"res://scripts/module_catalog.gd",
	"res://scripts/module_placer.gd",
	"res://scripts/parts_menu.gd",
	"res://scripts/resource_node.gd",
	"res://scripts/roster_picker.gd",
	"res://scripts/rts_camera.gd",
	"res://scripts/terrain_builder.gd",
	"res://scripts/terrain_sculpt.gd",
	"res://tools/capture_screen.gd",
	"res://tools/capture_terrain_v2.gd",
	"res://tools/probe_roster_picker.gd",
	"res://tools/probe_terrain_v2.gd",
	"res://tools/probe_terrain_reach.gd",
	"res://tools/probe_terrain_ascii.gd",
	"res://scripts/terrain_greebles.gd",
	"res://scripts/terrain_visual_scatter.gd",
	"res://scripts/ui_tokens.gd",
	"res://scripts/visual_builder.gd",
	"res://scripts/locomotion_layout.gd",
	"res://scripts/locomotion_mount.gd",
	"res://scripts/tweak_callout_manager.gd",
	"res://tools/build_ui_theme.gd",
	"res://tools/generate_terrain_textures.gd",
	"res://tools/probe_armor_slab.gd",
	"res://tools/probe_armor_slab_look.gd",
	"res://tools/probe_paint_station_in_scene.gd",
	"res://tools/probe_shield_system.gd",
	"res://tools/probe_skirmish_load_breakdown.gd",
	"res://tools/verify_greebles_and_grass.gd",
	"res://scripts/auto_weapon.gd",
	"res://scripts/battle/ai/commander.gd",
	"res://scripts/battle/economy/production_service.gd",
	"res://scripts/hud/hud_production_deck.gd",
	"res://scripts/weapon_alpha.gd",
]

func _init():
	var failed: Array = []
	for f in FILES:
		var res = ResourceLoader.load(f, "", ResourceLoader.CACHE_MODE_IGNORE)
		if res == null:
			failed.append(f)
			print("[FAIL] %s" % f)
		else:
			print("[OK]   %s" % f)
	if failed.is_empty():
		print("[PASS] all %d files compiled." % FILES.size())
		quit(0)
	else:
		print("[FAIL] %d file(s) failed to compile." % failed.size())
		quit(1)
