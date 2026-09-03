#!/usr/bin/env -S godot --headless --script
# Validation script for TASK-0029: weapon_vfx_spigot_mortar.gd
# Target_Nodes: ["prototype/scripts/vfx/weapon_vfx_spigot_mortar.gd"]

const FILES = [
	"res://scripts/vfx/weapon_vfx_spigot_mortar.gd"
]

func _init():
	var all_ok = true
	for f in FILES:
		var err = ResourceLoader.load_threaded_get(f)
		if err != OK:
			printerr("FAIL: %s -> %s" % [f, err])
			all_ok = false
		else:
			print("OK: %s" % f)
	if not all_ok:
		OS.exit(1)
	OS.exit(0)