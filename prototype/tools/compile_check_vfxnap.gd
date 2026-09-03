#!/usr/bin/env godot
# Quick parse check for weapon_vfx_napalm_mortar.gd only

const FILES = [
	"res://scripts/vfx/weapon_vfx_napalm_mortar.gd"
]

func _init():
	var ok = true
	for f in FILES:
		var err = ResourceLoader.load_threaded_get(f)
		if err != OK:
			print("FAIL: %s -> %s" % [f, err])
			ok = false
		else:
			print("OK: %s" % [f])
	if not ok:
		OS.exit(1)
	OS.exit(0)