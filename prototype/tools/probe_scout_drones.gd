extends SceneTree

const ModuleDataScript = preload("res://scripts/module_data.gd")
const DroneUnitScript = preload("res://scripts/drone_unit.gd")
const AutoWeaponScript = preload("res://scripts/auto_weapon.gd")
const VisualBuilderScript = preload("res://scripts/visual_builder.gd")

func _init():
	_run_probe.call_deferred()

func _run_probe():
	print("--- Running Scout Drone Probe (Unit-Level Arrangement & 3x Sight Radius) ---")
	var root = Node3D.new()
	root.name = "TestWorld"
	get_root().add_child(root)
	current_scene = root

	# Create a carrier unit with 2 separate drone bay modules
	var carrier = CharacterBody3D.new()
	carrier.name = "CarrierUnit"
	carrier.add_to_group("damageable")
	carrier.set_meta("team", 0)
	carrier.set_meta("vision_range", 30.0)
	carrier.set("vision_range", 30.0)
	root.add_child(carrier)
	carrier.position = Vector3(10.0, 0.0, 10.0)

	# Module 1: Hangar size 2
	var weapon1 = Node3D.new()
	weapon1.name = "DroneCarrierWeapon1"
	weapon1.set_script(AutoWeaponScript)
	var m_data1 = VisualBuilderScript.make_module_data("drone_carrier")
	m_data1.tweaks["drone_type"] = "scout"
	m_data1.tweaks["hangar_size"] = 2.0
	weapon1.set_meta("module_data", m_data1)
	carrier.add_child(weapon1)

	# Module 2: Hangar size 2
	var weapon2 = Node3D.new()
	weapon2.name = "DroneCarrierWeapon2"
	weapon2.set_script(AutoWeaponScript)
	var m_data2 = VisualBuilderScript.make_module_data("drone_carrier")
	m_data2.tweaks["drone_type"] = "scout"
	m_data2.tweaks["hangar_size"] = 2.0
	weapon2.set_meta("module_data", m_data2)
	carrier.add_child(weapon2)

	await process_frame

	# Simulate initial tick to deploy scout drones from both bays
	for i in range(10):
		weapon1._physics_process(0.1)
		weapon2._physics_process(0.1)

	var drones = []
	for child in root.get_children():
		if "drone_type" in child and child.get("drone_type") == "scout":
			drones.append(child)

	print("Total unit scout drones spawned across both bays: %d (expected 4)" % drones.size())
	assert(drones.size() == 4, "Expected 4 scout drones from 2 hangars of size 2")

	var parent_vision: float = float(carrier.get("vision_range")) if carrier.get("vision_range") != null else 30.0
	var scout_sight: float = drones[0].SCOUT_REVEAL_RADIUS
	print("Scout sight radius: %.1f (tripled from 24.0)" % scout_sight)
	assert(scout_sight >= 72.0, "Scout sight radius should be at least triple 24.0 (>= 72.0)")

	var expected_orbit_radius: float = parent_vision + scout_sight
	print("Parent vision: %.1f, Expected orbit radius: %.1f" % [parent_vision, expected_orbit_radius])

	# Advance physics simulation for 10 seconds
	for step in range(100):
		for d in drones:
			if is_instance_valid(d) and not d.is_destroyed:
				d._physics_process(0.1)
		weapon1._physics_process(0.1)
		weapon2._physics_process(0.1)

	# Verify all 4 drones are still alive and orbiting at the expected radius
	for i in range(4):
		var d = drones[i]
		assert(is_instance_valid(d) and not d.is_destroyed, "Drone %d should be alive" % i)
		assert(d.state == DroneUnitScript.State.LOITER, "Drone %d should be in LOITER" % i)
		var dist = carrier.global_position.distance_to(d.global_position)
		print("Drone %d distance to carrier: %.2f (expected ~%.1f)" % [i, dist, expected_orbit_radius])
		assert(absf(dist - expected_orbit_radius) < 4.0, "Drone %d orbit radius mismatch" % i)

	# Verify unit-level angular spacing among all 4 drones (should be ~90 degrees / 1.57 rad apart)
	var angles = []
	for d in drones:
		var offset = d.global_position - carrier.global_position
		var ang = atan2(offset.z, offset.x)
		if ang < 0:
			ang += TAU
		angles.append(ang)
	angles.sort()
	print("Orbit angles for 4 drones: %s" % str(angles))
	for i in range(4):
		var next_idx = (i + 1) % 4
		var diff = angles[next_idx] - angles[i]
		if diff < 0:
			diff += TAU
		print("  Angle gap %d->%d: %.2f rad (%.1f deg, expected ~90 deg)" % [i, next_idx, diff, rad_to_deg(diff)])
		assert(absf(diff - (PI / 2.0)) < 0.25, "All 4 drones across both bays should be ~90 degrees apart at unit level")

	# Test destroying 1 drone -> surviving 3 drones should re-space to 120 degrees apart
	print("\n--- Testing Drone Destruction & Unit-Level Re-spacing ---")
	drones[0].destroy_missile(true)
	# Advance 60 physics steps (6.0s) so surviving drones adjust their orbital spacing across 105m radius
	for step in range(60):
		for d in drones:
			if is_instance_valid(d) and not d.is_destroyed:
				d._physics_process(0.1)

	var surviving = []
	for d in drones:
		if is_instance_valid(d) and not d.is_destroyed:
			surviving.append(d)
	assert(surviving.size() == 3, "Expected 3 surviving drones")

	var surviving_angles = []
	for d in surviving:
		var offset = d.global_position - carrier.global_position
		var ang = atan2(offset.z, offset.x)
		if ang < 0:
			ang += TAU
		surviving_angles.append(ang)
	surviving_angles.sort()
	print("Surviving 3 drones angles: %s" % str(surviving_angles))
	for i in range(3):
		var next_idx = (i + 1) % 3
		var diff = surviving_angles[next_idx] - surviving_angles[i]
		if diff < 0:
			diff += TAU
		print("  Surviving angle gap %d->%d: %.2f rad (%.1f deg, expected ~120 deg)" % [i, next_idx, diff, rad_to_deg(diff)])
		assert(absf(diff - (TAU / 3.0)) < 0.35, "Surviving 3 drones should re-space to ~120 degrees apart")

	# Test carrier death -> all remaining drones self-destruct
	print("\n--- Testing Carrier Destruction ---")
	carrier.set_meta("is_dead", true)
	for d in surviving:
		d._physics_process(0.1)

	var alive_after_carrier_death = 0
	for child in root.get_children():
		if is_instance_valid(child) and "drone_type" in child and not child.is_destroyed:
			alive_after_carrier_death += 1
	print("Alive drones after carrier death: %d" % alive_after_carrier_death)
	assert(alive_after_carrier_death == 0, "All scout drones must self-destruct when parent carrier dies")

	print("\n[PASS] Unit-Level Scout Drone Arrangement & Expanded Sight Radius Verified Successfully!")
	quit(0)
