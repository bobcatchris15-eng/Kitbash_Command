extends SceneTree

func _init():
	# Target_Nodes from task TASK-0019
	var files = [
		"res://scripts/vfx/weapon_vfx_missile_pod.gd",
	]
	var failed = []
	for f in files:
		var script = load(f)
		if script == null:
			failed.append(f + " -> load returned null")
		else:
			# Force parse by accessing a member
			var ok = true
			var class_name = ""
			# Using has_method to check if we can call it
			if script.has_method("get_script_class_name"):
				class_name = script.get_script_class_name()
			if failed.size() == 0 and class_name == "":
				# Still ok, might just not have class_name
				pass
	if failed.size() > 0:
		print("PARSE FAIL:")
		for e in failed:
			print("  " + e)
		quit(1)
	else:
		print("PARSE OK: all target nodes loaded")
		quit(0)

func _ready():
	pass