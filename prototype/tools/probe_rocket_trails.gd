extends SceneTree
# ROCKET ARTILLERY MUST OUT-SMOKE THE ROCKET POD
# ---------------------------------------------------------------------------
# The two weapons reach their trails by completely different routes, which is
# how they ended up the wrong way round:
#
#   missile_pod       guided -> weapon_missile.gd -> VFXEffects
#                     .make_missile_trail(), a 120-particle GPU plume
#   rocket_artillery  arcing -> auto_weapon._fire_arcing_shell_at() with
#                     {"trail": "smoke"}, which emitted ONE mote per 0.16 of
#                     flight - about six puffs for the whole arc
#
# So the short-range 48 m pod had the heavier signature and the long-range
# saturation MLRS had the lighter one. This asserts the ordering directly off
# the emitters both paths actually build, rather than off the constants, so
# that a future change to either route has to keep the relationship.
#
#   Godot_v4.7.1-stable_win64_console.exe --headless --path prototype \
#     --script res://tools/probe_rocket_trails.gd --quit

const VFXEffectsScript = preload("res://scripts/vfx_effects.gd")
const AutoWeaponScript = preload("res://scripts/auto_weapon.gd")

# Must match auto_weapon._fire_rocket_artillery()'s profile.
const ARTILLERY_BULK := 2.6
const POD_BULK := 1.0


var _done := false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	_run()
	return true


func _run() -> void:
	var host := Node3D.new()
	root.add_child(host)

	var pod: GPUParticles3D = VFXEffectsScript.make_missile_trail(host, POD_BULK)
	var art: GPUParticles3D = VFXEffectsScript.make_missile_trail(host, ARTILLERY_BULK)

	var pod_scale: float = pod.process_material.scale_max
	var art_scale: float = art.process_material.scale_max

	print("  %-22s %8s %10s %10s" % ["trail", "amount", "lifetime", "scale_max"])
	print("  %-22s %8d %10.2f %10.2f"
		% ["missile_pod (bulk 1.0)", pod.amount, pod.lifetime, pod_scale])
	print("  %-22s %8d %10.2f %10.2f"
		% ["rocket_artillery (2.6)", art.amount, art.lifetime, art_scale])

	var fail := false
	if art.amount <= pod.amount:
		print("  [FAIL] artillery is not denser (amount %d vs %d)" % [art.amount, pod.amount])
		fail = true
	if art_scale <= pod_scale:
		print("  [FAIL] artillery puffs are not larger (%.2f vs %.2f)" % [art_scale, pod_scale])
		fail = true
	if art.lifetime <= pod.lifetime:
		print("  [FAIL] artillery trail is not longer-lived (%.2f vs %.2f)"
			% [art.lifetime, pod.lifetime])
		fail = true
	# The regression that would make all of the above pass while nothing
	# changed on screen: _process_material() memoises on its key string, so if
	# `bulk` ever stops being part of that key both calls get one shared
	# material and the two emitters are literally the same object.
	if pod.process_material == art.process_material:
		print("  [FAIL] both trails share one cached process material -"
			+ " bulk is missing from the _process_material cache key.")
		fail = true

	# And the artillery round must actually ASK for a plume. This is the line
	# that connects the VFX above to the weapon; without it the tuning is dead
	# code and the round still emits six motes.
	var src := FileAccess.get_file_as_string("res://scripts/auto_weapon.gd")
	if not src.contains('"trail_bulk": %.1f' % ARTILLERY_BULK):
		print("  [FAIL] _fire_rocket_artillery() does not request trail_bulk %.1f"
			% [ARTILLERY_BULK])
		fail = true
	if not src.contains("_detach_trail_on_free"):
		print("  [FAIL] no trail detach on round free - the plume would be"
			+ " cut off at the impact point.")
		fail = true

	if fail:
		quit(1)
	else:
		print("  [PASS] rocket artillery out-smokes the rocket pod on every axis.")
		quit(0)
