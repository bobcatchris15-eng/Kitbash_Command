extends SceneTree

# Targeted parse check for TASK-0025: weapon_vfx_bunker_buster.gd
const FILES := [
	"res://scripts/vfx/weapon_vfx_bunker_buster.gd",
]

func _init():
	print("TASK-0025: Targeted parse check for weapon_vfx_bunker_buster.gd")

func _after_enter_tree():
	var ok = true
	for f in FILES:
		var err = ResourceLoader.load_threaded_get(f)
		if err != OK:
			print("FAIL: %s -> %s" % [f, err])
			ok = false
		else:
			print("OK: %s" % [f])
	if ok:
		print("STAT: PASS")
		quit(0)
	else:
		print("STAT: FAIL")
		quit(1)