extends SceneTree

# Targeted compile check for TASK-0031: weapon_vfx_plasma_lobber.gd
const TARGET_SCRIPTS = [
	"res://scripts/vfx/weapon_vfx_plasma_lobber.gd",
]

func _init():
	pass

func _enter_tree():
	var all_ok = true
	for script_path in TARGET_SCRIPTS:
		var script = load(script_path)
		if script == null:
			print("FAIL: Could not load ", script_path)
			all_ok = false
		else:
			print("OK: ", script_path)
	
	if all_ok:
		print("STAT: PASS | TGT: prototype/scripts/vfx/weapon_vfx_plasma_lobber.gd | CHG: NEW file parses | STRUCT: YES | ERR: 0")
		quit(0)
	else:
		print("STAT: FAIL | TGT: prototype/scripts/vfx/weapon_vfx_plasma_lobber.gd | CHG: NEW file | STRUCT: YES | ERR: PARSE")
		quit(1)