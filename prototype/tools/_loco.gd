extends SceneTree
func _init() -> void:
	var MC = load("res://scripts/module_catalog.gd")
	var cat: Dictionary = MC.get_catalog()
	print("=== locomotion types ===")
	for k in cat.keys():
		var d = cat[k]
		if typeof(d) == TYPE_DICTIONARY and str(d.get("category", "")) == "locomotion":
			print("  %-18s needs_running_gear=%-5s touches_ground=%s" % [
				k, MC.needs_running_gear(k), MC.locomotion_touches_ground(k)])
	quit(0)
