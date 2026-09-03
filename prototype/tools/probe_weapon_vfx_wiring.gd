extends SceneTree
# Regression probe for the Part A-D weapon VFX wiring pass (2026-09-03),
# updated when plasma_lobber and napalm_mortar were removed as standalone
# weapons (2026-09-03, later same day - see the weapon-removal commit).
#
# Part A found that artillery and plasma_lobber's impact_vfx_callback was
# being bound with extra .bind() args on top of the 4 positional args
# _fire_arcing_shell_at()'s tween.finished always supplies - Callable.bind()
# stacks call-time args and bound args together, so both targets received
# more arguments than their static function declared and errored on every
# hit, silently skipping both the impact visual AND _deal_aoe_damage (which
# only runs in the callback-absent branch). This probe fires every touched
# weapon type at a stationary dummy with real HP and asserts damage actually
# lands - the exact thing that broke silently before.
#
# plasma_lobber no longer exists (removed entirely). napalm_mortar no
# longer exists as its own weapon either - its distinct impact visual was
# folded into mortar_array's existing "incendiary" ammo option instead, so
# this probe now exercises THAT path (mortar_array + ammo="incendiary")
# rather than a standalone napalm_mortar fire call.
#
#   Godot_v4.7.1-stable_win64_console.exe --headless --path prototype \
#     --script res://tools/probe_weapon_vfx_wiring.gd
#
# NO --quit on this one, unlike every other probe in this directory. This
# script's _init() suspends on `await` (waiting on flight/impact tweens
# across many frames) before it ever calls quit() itself. --quit tells the
# engine to tear down as soon as it reasonably can, which in this Godot
# build happens the moment _init() first suspends - before the awaited
# coroutine ever resumes, so nothing after the first `await` runs and no
# output past the first print appears. Letting the script's own explicit
# quit(0 if overall else 1) at the end terminate the engine instead works
# correctly.

const AutoWeaponScript = preload("res://scripts/auto_weapon.gd")
const WeaponMissileScript = preload("res://scripts/weapon_missile.gd")
const ModuleDataScript = preload("res://scripts/module_data.gd")

# Dummy target with real HP, in "damageable" (AoE weapons search this group)
# and "targets" (get_vehicle_root() on a weapon walks up looking for this,
# though the dummy itself is never a weapon's parent here).
class Dummy extends Node3D:
	var hp: float = 500.0
	var is_dead: bool = false
	func take_damage(amount: float, _damage_type: String = "kinetic", _hit_origin = null) -> void:
		hp -= amount
		if hp <= 0.0:
			is_dead = true

const WEAPON_TYPES := ["artillery", "spigot_mortar", "mortar_array_incendiary", "bunker_buster"]


func _init():
	var results: Dictionary = {}
	for wt in WEAPON_TYPES:
		results[wt] = await _run_one(wt)

	var overall := true
	for wt in WEAPON_TYPES:
		var ok: bool = results[wt]
		print("%s: %s" % [wt.to_upper(), "PASS" if ok else "FAIL"])
		if not ok:
			overall = false

	print("RESULT: %s" % ("PASS" if overall else "FAIL"))
	quit(0 if overall else 1)


func _run_one(weapon_type: String) -> bool:
	# Shooter vehicle root: group membership is how auto_weapon.get_vehicle_root()
	# and get_team() find their owner.
	var shooter := Node3D.new()
	root.add_child(shooter)
	shooter.add_to_group("player_vehicle")
	shooter.set_meta("team", 0)

	var weapon := Node3D.new()
	weapon.set_script(AutoWeaponScript)
	shooter.add_child(weapon)
	# "mortar_array_incendiary" is a synthetic test id, not a real weapon
	# type - it drives the real "mortar_array" with incendiary ammo loaded,
	# to exercise the path napalm_mortar's distinct visual was folded into.
	weapon.type_id = "mortar_array" if weapon_type == "mortar_array_incendiary" else weapon_type
	weapon.dps = 40.0
	weapon.fire_rate = 1.0
	weapon.damage_class = "kinetic"
	if weapon_type == "mortar_array_incendiary":
		var data := ModuleDataScript.new()
		data.tweaks = {"ammo": "incendiary"}
		weapon.set_meta("module_data", data)

	var dummy := Dummy.new()
	root.add_child(dummy)
	dummy.add_to_group("damageable")
	dummy.add_to_group("targets")
	dummy.set_meta("team", 1)

	# Nodes aren't guaranteed inside the tree (get_tree()/global_position
	# usable) synchronously within the same _init() frame they were
	# add_child()'d in - await one frame before touching either.
	await process_frame

	dummy.global_position = shooter.global_position + Vector3(0, 0, -15)

	weapon.target = dummy

	var hp_before := dummy.hp

	match weapon_type:
		"artillery":
			weapon.call("_fire_artillery")
		"spigot_mortar":
			weapon.call("_fire_spigot_mortar")
		"mortar_array_incendiary":
			weapon.call("_fire_mortar_salvo")
		"bunker_buster":
			weapon.call("_fire_bunker_buster")
		_:
			push_error("unhandled weapon type in probe: %s" % weapon_type)

	# Flight + impact tweens run on real (idle) time, not the physics tick, and
	# the missile path also needs _physics_process ticks - poll both for up to
	# 6 seconds real time, which comfortably covers every touched weapon's
	# scaled flight time (longest observed ~1.6s to max range).
	var frames := 0
	const MAX_FRAMES := 360 # ~6s at 60fps, comfortably past every touched weapon's flight time
	while frames < MAX_FRAMES and dummy.hp >= hp_before and is_instance_valid(dummy):
		await process_frame
		await physics_frame
		frames += 1

	var ok: bool = is_instance_valid(dummy) and dummy.hp < hp_before
	if not ok:
		print("  [%s] hp unchanged: %.1f -> %.1f after %d frames" % [weapon_type, hp_before, dummy.hp, frames])
	else:
		print("  [%s] hp %.1f -> %.1f after %d frames" % [weapon_type, hp_before, dummy.hp, frames])

	if is_instance_valid(shooter):
		shooter.queue_free()
	if is_instance_valid(dummy):
		dummy.queue_free()
	await process_frame
	return ok
