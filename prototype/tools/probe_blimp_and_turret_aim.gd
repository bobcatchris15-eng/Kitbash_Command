extends SceneTree
# Behavioral probe for the 2026-08-25 gameplay fixes:
#
#   1. BLIMP IN BATTLE. Battle units are built from a DETACHED cached template
#      that is duplicated per spawn (unit_assembly._acquire_hull), so the
#      envelope's tree_entered deferral never fired and duplicate() dropped the
#      connection - battle copies had no gasbag. The template now parks its
#      build params as "blimp_pending" metadata and unit.gd's setup() calls
#      VisualBuilder.ensure_blimp_envelope() once the copy is inside the tree.
#
#   2. TURRET AIM COMPOSED ON REST. auto_weapon's aim used to write an ABSOLUTE
#      look-at basis onto the mount, discarding the authored orientation - a
#      belly mount's authored flip included, so the whole module swung through
#      the hull. _aim_basis_from_rest() composes the aim offset on top of rest.
#
# Run: Godot_v4.7.1-stable_win64_console.exe --headless --path . \
#          --script res://tools/probe_blimp_and_turret_aim.gd

const VisualBuilder = preload("res://scripts/visual_builder.gd")
const AutoWeapon = preload("res://scripts/auto_weapon.gd")

var _failures: int = 0

func _check(cond: bool, label: String) -> void:
	if cond:
		print("  [PASS] %s" % label)
	else:
		print("  [FAIL] %s" % label)
		_failures += 1


func _init() -> void:
	print("=== PROBING BLIMP ENVELOPE + TURRET AIM ===")
	var root_node := get_root()

	# --- Test 1: detached build parks metadata, no envelope yet --------------
	print("Test 1: detached template build defers via blimp_pending meta")
	var bp_manager = load("res://scripts/blueprint_manager.gd").new()
	var holder := Node3D.new()
	var blueprint := {
		"hull_type": "brenntal_medium_a",
		# Locomotion drives are saved as MODULES in a blueprint (see
		# bulwark_mbt.json's tracked_treads entries) - an entry here is what
		# makes reconstruct_vehicle spawn a mount node whose visual build
		# reaches _build_blimp_envelope.
		"modules": [
			{
				"type_id": "buoyant_envelope",
				"facet": "",
				"position": {"x": 0.0, "y": 0.0, "z": 0.0},
				"rotation": {"x": 0.0, "y": 0.0, "z": 0.0},
				"scale": {"x": 1.0, "y": 1.0, "z": 1.0},
				"tweaks": {},
			},
		],
		"locomotion": {"type_id": "buoyant_envelope", "settings": {}},
	}
	var built: Node3D = bp_manager.reconstruct_vehicle(blueprint, holder, false)
	if built == null:
		_check(false, "reconstruct_vehicle returned a vehicle")
		quit(1)
		return
	var pending: Array = []
	var stack: Array = [built]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.has_meta("blimp_pending"):
			pending.append(n)
		for c in n.get_children():
			stack.append(c)
	_check(pending.size() > 0, "detached template carries blimp_pending meta")
	var has_env_before: bool = built.find_child("BlimpEnvelope", true, false) != null
	_check(not has_env_before, "detached template has NOT built the envelope yet")

	# --- Test 2: in-tree copy gets the envelope via ensure -------------------
	print("Test 2: ensure_blimp_envelope builds it once the copy is in-tree")
	var copy: Node3D = built.duplicate()
	root_node.add_child(copy)
	await process_frame
	VisualBuilder.ensure_blimp_envelope(copy)
	await process_frame
	var env_copy: Node = copy.find_child("BlimpEnvelope", true, false)
	_check(env_copy != null, "in-tree copy gained a BlimpEnvelope")
	if env_copy != null:
		_check(env_copy.get_child_count() > 0, "envelope carries geometry (gasbag/rigging)")

	# --- Test 3: idempotence -------------------------------------------------
	print("Test 3: ensure is idempotent")
	var env_count: int = 0
	stack = [copy]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.name == "BlimpEnvelope":
			env_count += 1
		for c in n.get_children():
			stack.append(c)
	VisualBuilder.ensure_blimp_envelope(copy)
	await process_frame
	var env_count_after: int = 0
	stack = [copy]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.name == "BlimpEnvelope":
			env_count_after += 1
		for c in n.get_children():
			stack.append(c)
	_check(env_count == 1 and env_count_after == 1,
		"exactly one envelope before and after a second ensure pass")

	# --- Test 4: aim basis keeps the authored rest orientation ---------------
	print("Test 4: _aim_basis_from_rest composes on top of a belly flip")
	# Belly mount rest: barrel authored along -Z then flipped 180 deg about X
	# so it faces down/outward from the underside.
	var q_rest := Quaternion(Vector3(1, 0, 0), PI)
	# Target ahead-left and BELOW the hull, in hull space.
	var dir := Vector3(-0.3, -0.4, -0.85).normalized()
	var composed := AutoWeapon._aim_basis_from_rest(q_rest, dir)
	var fwd := -composed.z.normalized()
	_check(fwd.angle_to(dir) < 0.01, "composed -Z points at the target")
	# The old absolute behaviour would have produced Basis.looking_at(dir, UP),
	# whose up is world-up; composed must instead keep the rest frame's up -
	# i.e. its Y axis must be q_rest applied to the rest-space up reference,
	# NOT plain world up.
	var abs_basis := Basis.looking_at(dir, Vector3.UP)
	_check(composed.y.dot(abs_basis.y) < 0.99,
		"roll follows the authored flip, not world-up (differs from absolute look-at)")
	# Dead-ahead in rest space must reproduce rest EXACTLY: the barrel's
	# canonical forward is -Z, so parent-space dead-ahead is q_rest * (-Z).
	var rest_fwd := q_rest * Vector3(0, 0, -1)
	var back_to_rest := AutoWeapon._aim_basis_from_rest(q_rest, rest_fwd)
	_check(back_to_rest.get_rotation_quaternion().angle_to(q_rest) < 0.01,
		"target dead-ahead of the mounted barrel returns exactly to rest")

	if _failures == 0:
		print(">>> ALL BLIMP/AIM TESTS PASSED <<<")
	else:
		print(">>> %d TEST(S) FAILED <<<" % _failures)
	quit(0 if _failures == 0 else 1)
