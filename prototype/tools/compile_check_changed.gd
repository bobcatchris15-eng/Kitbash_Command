extends SceneTree
# Quick targeted compile check for a small set of files. Bypasses the
# res:// path walking the full version does - we only care whether the
# specific files I edited in this turn still parse.

const FILES := [
	"res://scripts/hull_facets.gd",
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
	"res://scripts/roster_picker.gd",
	"res://scripts/match_setup.gd",
	"res://scripts/blueprint_manager.gd",
	"res://scripts/armor_paint_visual.gd",
	"res://scripts/drivetrain.gd",
	"res://scripts/design_stats.gd",
	"res://scripts/module_placer.gd",
	"res://scripts/lab_toolbar.gd",
	"res://scripts/auto_weapon.gd",
	"res://scripts/visual_builder.gd",
	"res://scripts/battle/units/unit.gd",
	"res://scripts/module_catalog.gd",
	"res://scripts/lab_document.gd",
	"res://tools/probe_armor_slab.gd",
	"res://tools/probe_armor_slab_look.gd",
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
