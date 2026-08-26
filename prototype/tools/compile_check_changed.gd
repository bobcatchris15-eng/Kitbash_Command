extends SceneTree
# Quick targeted compile check for a small set of files. Bypasses the
# res:// path walking the full version does - we only care whether the
# specific files I edited in this turn still parse.

const FILES := [
	"res://scripts/main_menu.gd",
	"res://scripts/auto_weapon.gd",
	"res://scripts/visual_builder.gd",
	"res://scripts/battle/units/unit.gd",
	"res://scripts/battle/units/unit_assembly.gd",
	"res://scripts/rts_camera.gd",
	"res://scripts/battle/vision/vision_service.gd",
	"res://scripts/battle/match_director.gd",
	"res://scripts/module_catalog.gd",
	"res://scripts/lab_document.gd",
	"res://scripts/auto_weapon.gd",
	"res://scripts/visual_builder.gd",
	"res://scripts/battle/ai/commander.gd",
	"res://scripts/weapon_alpha.gd",
	"res://scripts/power_budget.gd",
	"res://scripts/damage_resolver.gd",
	"res://scripts/drivetrain.gd",
	"res://scripts/module_placer.gd",
	"res://scripts/armor_paint.gd",
	"res://scripts/armor_station_panel.gd",
	"res://scripts/module_volume.gd",
	"res://scripts/ui/module_action_ring.gd",
	"res://scripts/ui_radial_menu.gd",
	"res://scripts/modular_hull_builder.gd",
	"res://scripts/tweak_callout_manager.gd",
	"res://scripts/part_materials.gd",
	"res://scripts/vfx_burst.gd",
	"res://scripts/weapon_missile.gd",
	"res://scripts/vfx_effects.gd",
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
