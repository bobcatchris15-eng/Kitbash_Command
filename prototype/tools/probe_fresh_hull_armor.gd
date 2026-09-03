extends SceneTree

# Regression probe: a freshly-placed hull (via ModulePlacer._place_hull_from_ui)
# must come out of the gate with its authored default armor plan applied and
# visible, not bare until the player opens Armor Station.

const ModulePlacerScript = preload("res://scripts/module_placer.gd")
const ModuleCatalog = preload("res://scripts/module_catalog.gd")

func _init():
	var placer := Node3D.new()
	placer.set_script(ModulePlacerScript)
	root.add_child(placer)

	# Any hull id present in the catalog works; pick the first one.
	var type_id := ""
	var cat: Dictionary = ModuleCatalog.get_catalog()
	for id in cat.keys():
		if cat[id].get("category", "") == "hull":
			type_id = id
			break

	if type_id == "":
		print("PROBE FAIL: no hull type found in catalog")
		quit(1)
		return

	placer._place_hull_from_ui(type_id)

	var hull: Node = placer.hull
	if hull == null:
		print("PROBE FAIL: hull not created for ", type_id)
		quit(1)
		return

	var plan: Dictionary = hull.get_meta("armor_plan", {})
	var assignments: Array = hull.get_meta("armor_assignments", [])

	if plan.is_empty():
		print("PROBE FAIL: armor_plan meta empty for ", type_id)
		quit(1)
		return
	if plan.get("empty", true):
		print("PROBE FAIL: armor_plan.empty == true for ", type_id)
		quit(1)
		return
	if assignments.is_empty():
		print("PROBE FAIL: armor_assignments meta empty for ", type_id)
		quit(1)
		return

	print("PROBE PASS: ", type_id, " armor_plan populated, empty=", plan.get("empty", true))
	quit(0)
