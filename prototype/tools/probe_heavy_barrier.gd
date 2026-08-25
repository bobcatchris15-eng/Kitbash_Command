# probe_heavy_barrier.gd
# Verification suite for two-sided energy shields and Heavy Barrier Projector (Aegis Field)

@tool
extends SceneTree

const ModuleCatalog = preload("res://scripts/module_catalog.gd")
const ModuleData = preload("res://scripts/module_data.gd")
const VisualBuilder = preload("res://scripts/visual_builder.gd")
const AutoWeapon = preload("res://scripts/auto_weapon.gd")
const UnitScript = preload("res://scripts/battle/units/unit.gd")

func _init() -> void:
	print("=== PROBING TWO-SIDED SHIELDS & HEAVY BARRIER PROJECTOR ===")
	var success := true
	var root = Node3D.new()
	get_root().add_child(root)

	# 1. Verify two-sided shield shader configuration
	var shader = load("res://shaders/energy_shield.gdshader")
	if shader == null:
		print("FAIL: energy_shield.gdshader could not be loaded!")
		success = false
	else:
		var code = shader.code
		if "cull_disabled" in code:
			print("PASS: energy_shield.gdshader has cull_disabled (visible from front and behind).")
		else:
			print("FAIL: energy_shield.gdshader missing cull_disabled!")
			success = false

	# 2. Verify heavy_barrier_projector catalog entry & support role
	if not ModuleCatalog.module_exists("heavy_barrier_projector"):
		print("FAIL: heavy_barrier_projector not found in catalog!")
		success = false
	else:
		var data = ModuleCatalog.get_module_data("heavy_barrier_projector")
		var role = ModuleCatalog.get_module_role("heavy_barrier_projector")
		print("PASS: heavy_barrier_projector registered: ", data.get("name"), " (Role: ", role, ", Category: ", data.get("category"), ")")
		if role != "Support":
			print("FAIL: heavy_barrier_projector role is not 'Support' (found: ", role, ")")
			success = false
		else:
			print("PASS: heavy_barrier_projector is assigned Support role.")

		if not ModuleCatalog.SUPPORT_TYPE_IDS.has("heavy_barrier_projector"):
			print("FAIL: heavy_barrier_projector not in SUPPORT_TYPE_IDS!")
			success = false
		else:
			print("PASS: heavy_barrier_projector in SUPPORT_TYPE_IDS.")

	# 3. Test Tweaks Scaling
	var mod_std = ModuleData.new()
	mod_std.type_id = "heavy_barrier_projector"
	mod_std.tweaks = {"field_width": 1.0, "barrier_capacity": 1.0, "projection_distance": 25.0}

	var mod_wide = ModuleData.new()
	mod_wide.type_id = "heavy_barrier_projector"
	mod_wide.tweaks = {"field_width": 1.8, "barrier_capacity": 1.0, "projection_distance": 25.0}

	var mod_heavy = ModuleData.new()
	mod_heavy.type_id = "heavy_barrier_projector"
	mod_heavy.tweaks = {"field_width": 1.0, "barrier_capacity": 2.0, "projection_distance": 25.0}

	if mod_wide.get_weight() <= mod_std.get_weight():
		print("FAIL: Wider field did not increase module weight!")
		success = false
	else:
		print("PASS: Wider field increases module mass & cost: ", mod_std.get_weight(), "kg -> ", mod_wide.get_weight(), "kg")

	if mod_heavy.get_weight() <= mod_std.get_weight():
		print("FAIL: Higher capacity did not increase module weight!")
		success = false
	else:
		print("PASS: Higher barrier capacity increases module mass & cost: ", mod_std.get_weight(), "kg -> ", mod_heavy.get_weight(), "kg")

	# 4. Test Visual Builder Assembly
	var visual_parent = Node3D.new()
	root.add_child(visual_parent)
	VisualBuilder.build_visual("heavy_barrier_projector", visual_parent, Vector3.ONE, Color.CYAN, {
		"field_width": 1.4, "barrier_capacity": 1.2, "projection_distance": 25.0
	})

	var visual_root = visual_parent
	if visual_parent.get_child_count() == 1 and visual_parent.get_child(0).name == "ModularScaleWrapper":
		visual_root = visual_parent.get_child(0)

	var turret_body = visual_root.find_child("TurretBody", true, false)
	var emitter_horn = visual_root.find_child("EmitterHorn", true, false)
	var aegis_field = visual_root.find_child("ProjectedAegisField", true, false)

	if turret_body == null or emitter_horn == null or aegis_field == null:
		print("FAIL: Visual builder missing required components for heavy_barrier_projector! turret=", turret_body != null, " emitter=", emitter_horn != null, " aegis=", aegis_field != null)
		success = false
	else:
		print("PASS: Visual builder successfully assembled mount, traversing TurretBody, EmitterHorn, and ProjectedAegisField.")

	# 5. Test Aiming & Projector Behavior in AutoWeapon
	var carrier_unit = UnitScript.new()
	carrier_unit.team = 0
	root.add_child(carrier_unit)
	carrier_unit.add_to_group("units")
	var c_hull = Node3D.new()
	carrier_unit.add_child(c_hull)
	carrier_unit.hull_node = c_hull

	var weapon_node = AutoWeapon.new()
	weapon_node.name = "heavy_barrier_projector"
	weapon_node.set_meta("module_data", mod_std)
	c_hull.add_child(weapon_node)
	weapon_node._ready()

	# Initially no target -> should face forward (0 local yaw)
	weapon_node._tick_heavy_barrier(0.1)
	var field_info = weapon_node.get_aegis_field_info()
	if not field_info.get("is_active", false):
		print("FAIL: Aegis field is not active initially!")
		success = false
	else:
		var center: Vector3 = field_info.get("center", Vector3.ZERO)
		print("PASS: Aegis field projected at center: ", center, " (approx 25m ahead). Radius: ", field_info.get("radius"), "m")

	# 6. Test Damage Absorption & Sheltering Friendly Units
	# Test absorption directly
	var initial_hp = field_info.get("barrier_hp", 600.0)
	var remaining_dmg = weapon_node.absorb_aegis_damage(200.0)
	var after_hp = weapon_node.barrier_current_hp
	if remaining_dmg > 0.0 or after_hp != (initial_hp - 200.0):
		print("FAIL: Barrier did not correctly absorb damage! remaining=", remaining_dmg, " after_hp=", after_hp)
		success = false
	else:
		print("PASS: Aegis field absorbed 200 damage directly (pool: ", initial_hp, " -> ", after_hp, ").")

	# Friendly sheltered unit placed 25m ahead inside the projected field
	var ally_unit = UnitScript.new()
	ally_unit.team = 0
	ally_unit.max_hp = 500.0
	ally_unit.hp = 500.0
	root.add_child(ally_unit)
	ally_unit.add_to_group("units")
	var a_hull = Node3D.new()
	ally_unit.add_child(a_hull)
	ally_unit.hull_node = a_hull
	ally_unit.global_position = field_info.get("center", Vector3(0, 0, -25.0))

	var hp_before = ally_unit.hp
	var pool_before = weapon_node.barrier_current_hp
	ally_unit.take_damage(150.0, "kinetic", Vector3(0, 0, -40.0))

	if ally_unit.hp < hp_before:
		print("FAIL: Sheltered ally took damage when Aegis field had capacity! HP: ", ally_unit.hp)
		success = false
	elif weapon_node.barrier_current_hp >= pool_before:
		print("FAIL: Aegis barrier pool did not decrease when sheltering ally!")
		success = false
	else:
		print("PASS: Friendly unit inside projected field sheltered! Ally HP remained ", ally_unit.hp, ", barrier pool absorbed damage to ", weapon_node.barrier_current_hp)

	root.queue_free()

	if success:
		print(">>> ALL HEAVY BARRIER PROJECTOR TESTS PASSED! <<<")
	else:
		print(">>> SOME TESTS FAILED! <<<")
	quit(0 if success else 1)
