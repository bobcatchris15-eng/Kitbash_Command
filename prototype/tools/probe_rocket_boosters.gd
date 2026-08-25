# probe_rocket_boosters.gd
# Verification suite for propulsion removal and Rocket Booster support ability

@tool
extends SceneTree

const ModuleCatalog = preload("res://scripts/module_catalog.gd")
const ModuleData = preload("res://scripts/module_data.gd")
const VisualBuilder = preload("res://scripts/visual_builder.gd")
const Drivetrain = preload("res://scripts/drivetrain.gd")
const BoostController = preload("res://scripts/battle/units/boost_controller.gd")

func _init() -> void:
	print("=== PROBING ROCKET BOOSTERS & PROPULSION CLEANUP ===")
	var success := true
	var root = Node3D.new()
	get_root().add_child(root)

	# 1. Verify deprecated propulsion modules are gone
	var deprecated_ids := ["turbocharger", "hub_motor_array", "nitrous_injector"]
	for did in deprecated_ids:
		if ModuleCatalog.module_exists(did):
			print("FAIL: Deprecated propulsion module still in catalog: ", did)
			success = false
		else:
			print("PASS: Deprecated propulsion module removed: ", did)

	# Verify "Propulsion" is not in MODULE_ROLE_ORDER
	if ModuleCatalog.MODULE_ROLE_ORDER.has("Propulsion"):
		print("FAIL: 'Propulsion' still present in MODULE_ROLE_ORDER!")
		success = false
	else:
		print("PASS: 'Propulsion' cleanly removed from MODULE_ROLE_ORDER.")

	# 2. Verify Rocket Booster catalog registration and role
	if not ModuleCatalog.module_exists("booster_rack"):
		print("FAIL: booster_rack not found in catalog!")
		success = false
	else:
		var booster_data = ModuleCatalog.get_module_data("booster_rack")
		var role = ModuleCatalog.get_module_role("booster_rack")
		print("PASS: booster_rack found in catalog: ", booster_data.get("name"), " (Role: ", role, ")")
		if role != "Support":
			print("FAIL: booster_rack role is not 'Support' (found: ", role, ")")
			success = false
		else:
			print("PASS: booster_rack is correctly routed to 'Support'.")

		if not ModuleCatalog.SUPPORT_TYPE_IDS.has("booster_rack"):
			print("FAIL: booster_rack is not in SUPPORT_TYPE_IDS!")
			success = false
		else:
			print("PASS: booster_rack is in SUPPORT_TYPE_IDS.")

	# 3. Test Rocket Booster Tweaks & Stat Scaling
	# Longer -> increases length of boost
	var mod_short = ModuleData.new()
	mod_short.type_id = "booster_rack"
	mod_short.tweaks = {"booster_length": 1.0, "booster_width": 1.0, "nozzle_count": 3.0}
	var prof_short = mod_short.get_boost_profile()

	var mod_long = ModuleData.new()
	mod_long.type_id = "booster_rack"
	mod_long.tweaks = {"booster_length": 1.8, "booster_width": 1.0, "nozzle_count": 3.0}
	var prof_long = mod_long.get_boost_profile()

	if prof_long["duration"] <= prof_short["duration"]:
		print("FAIL: Longer booster did not increase duration: ", prof_short["duration"], " -> ", prof_long["duration"])
		success = false
	else:
		print("PASS: Making booster longer increases boost duration: ", prof_short["duration"], "s -> ", prof_long["duration"], "s")

	# Wider -> increases amount of boost
	var mod_narrow = ModuleData.new()
	mod_narrow.type_id = "booster_rack"
	mod_narrow.tweaks = {"booster_length": 1.0, "booster_width": 0.8, "nozzle_count": 3.0}
	var prof_narrow = mod_narrow.get_boost_profile()

	var mod_wide = ModuleData.new()
	mod_wide.type_id = "booster_rack"
	mod_wide.tweaks = {"booster_length": 1.0, "booster_width": 1.6, "nozzle_count": 3.0}
	var prof_wide = mod_wide.get_boost_profile()

	if prof_wide["speed_mult"] <= prof_narrow["speed_mult"]:
		print("FAIL: Wider booster did not increase speed multiplier: ", prof_narrow["speed_mult"], " -> ", prof_wide["speed_mult"])
		success = false
	else:
		print("PASS: Making booster wider increases boost amount: x", prof_narrow["speed_mult"], " -> x", prof_wide["speed_mult"])

	# Adding more boosters -> shortens recharge (cooldown)
	# Single booster on hull
	var hull_single = Node3D.new()
	root.add_child(hull_single)
	var loco = Node3D.new()
	hull_single.add_child(loco)
	var loco_data = ModuleData.new()
	loco_data.type_id = "wheels"
	loco_data.category = "locomotion"
	loco.set_meta("module_data", loco_data)

	var b1 = Node3D.new()
	hull_single.add_child(b1)
	var b1_data = ModuleData.new()
	b1_data.type_id = "booster_rack"
	b1_data.tweaks = {"booster_length": 1.0, "booster_width": 1.0, "nozzle_count": 3.0}
	b1.set_meta("module_data", b1_data)

	var dt_single = Drivetrain.analyze(hull_single)
	var cd_single: float = dt_single["boost"].get("cooldown", 24.0)

	# Dual booster on hull
	var b2 = Node3D.new()
	hull_single.add_child(b2)
	var b2_data = ModuleData.new()
	b2_data.type_id = "booster_rack"
	b2_data.tweaks = {"booster_length": 1.0, "booster_width": 1.0, "nozzle_count": 3.0}
	b2.set_meta("module_data", b2_data)

	var dt_dual = Drivetrain.analyze(hull_single)
	var cd_dual: float = dt_dual["boost"].get("cooldown", 24.0)

	# Triple booster on hull
	var b3 = Node3D.new()
	hull_single.add_child(b3)
	var b3_data = ModuleData.new()
	b3_data.type_id = "booster_rack"
	b3_data.tweaks = {"booster_length": 1.0, "booster_width": 1.0, "nozzle_count": 3.0}
	b3.set_meta("module_data", b3_data)

	var dt_triple = Drivetrain.analyze(hull_single)
	var cd_triple: float = dt_triple["boost"].get("cooldown", 24.0)

	if cd_dual >= cd_single or cd_triple >= cd_dual:
		print("FAIL: Adding more boosters did not shorten cooldown! single=", cd_single, ", dual=", cd_dual, ", triple=", cd_triple)
		success = false
	else:
		print("PASS: Adding more boosters shortens recharge cooldown: 1x=", cd_single, "s -> 2x=", cd_dual, "s -> 3x=", cd_triple, "s")

	# 4. Test Visual Builder Assembly
	var visual_node = Node3D.new()
	root.add_child(visual_node)
	VisualBuilder.build_visual("booster_rack", visual_node, Vector3.ONE, Color.ORANGE, {
		"booster_length": 1.5, "booster_width": 1.3, "nozzle_count": 4.0
	})
	var count = visual_node.get_child_count()
	if count == 1 and visual_node.get_child(0).name == "ModularScaleWrapper":
		count = visual_node.get_child(0).get_child_count()
	if count < 2:
		print("FAIL: Visual builder assembled too few parts for booster_rack (", count, ")")
		success = false
	else:
		print("PASS: Visual builder assembled booster_rack with ", count, " parts (frame + tubes).")

	# 5. Test BoostController Ability Lifecycle & Activation
	var bc = BoostController.new()
	bc.setup(hull_single, dt_single)
	if not bc.can_activate():
		print("FAIL: BoostController should be ready to activate initially!")
		success = false
	else:
		print("PASS: BoostController is ready to activate.")

	var act_ok = bc.activate()
	if not act_ok or bc.get_state() != BoostController.State.ACTIVE:
		print("FAIL: BoostController activation failed!")
		success = false
	else:
		print("PASS: BoostController successfully activated (State: ACTIVE).")

	# Tick through active duration
	var boost_mult = bc.tick(1.0)
	print("Active boost multiplier: x", boost_mult)
	if boost_mult <= 1.0:
		print("FAIL: Active boost multiplier is not applied!")
		success = false
	else:
		print("PASS: Active boost speed multiplier applied.")

	# Tick past duration into cooldown
	bc.tick(5.0)
	if bc.get_state() != BoostController.State.COOLDOWN:
		print("FAIL: BoostController should transition to COOLDOWN after duration expires! Current: ", bc.get_state())
		success = false
	else:
		print("PASS: BoostController transitioned to COOLDOWN after duration expired.")

	# Tick past cooldown back to IDLE
	bc.tick(30.0)
	if bc.get_state() != BoostController.State.IDLE:
		print("FAIL: BoostController should recover to IDLE after cooldown! Current: ", bc.get_state())
		success = false
	else:
		print("PASS: BoostController recharged back to IDLE and is ready to boost again.")

	# Clean up
	root.queue_free()

	if success:
		print(">>> ALL ROCKET BOOSTER AND PROPULSION CLEANUP TESTS PASSED! <<<")
	else:
		print(">>> SOME TESTS FAILED! <<<")
	quit(0 if success else 1)
