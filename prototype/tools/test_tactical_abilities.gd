extends SceneTree

const ModuleCatalog = preload("res://scripts/module_catalog.gd")
const BattleUnitScript = preload("res://scripts/battle/units/unit.gd")
const HUDCommandCardScript = preload("res://scripts/hud/hud_command_card.gd")
const OrderScript = preload("res://scripts/battle/orders/order.gd")

func _init() -> void:
	print("=== RUNNING TACTICAL ABILITIES TEST ===")
	var root_node = Node3D.new()
	root_node.name = "TestRoot"
	root.add_child(root_node)

	# 1. Verify deprecated nitrous_injector is completely gone
	if ModuleCatalog.module_exists("nitrous_injector"):
		print("FAIL: nitrous_injector still in catalog!")
		quit(1)
		return
	print("PASS: nitrous_injector successfully purged from catalog.")

	# 2. Test BattleUnit ability helper methods
	var unit = BattleUnitScript.new()
	var hull = Node3D.new()
	hull.name = "HullNode"
	unit.add_child(hull)
	unit.hull_node = hull
	root_node.add_child(unit)

	# Add smoke discharger child
	var smoke_w = Node3D.new()
	smoke_w.name = "SmokeDischarger"
	smoke_w.set_meta("module_data", {"type_id": "smoke_discharger"})
	hull.add_child(smoke_w)

	# Add sensor beacon launcher child
	var beacon_w = Node3D.new()
	beacon_w.name = "BeaconLauncher"
	beacon_w.set_meta("module_data", {"type_id": "sensor_beacon_launcher"})
	hull.add_child(beacon_w)

	# Add mine layer child
	var mine_w = Node3D.new()
	mine_w.name = "MineLayer"
	mine_w.set_meta("module_data", {"type_id": "mine_layer"})
	hull.add_child(mine_w)

	# Add artillery child
	var arty_w = Node3D.new()
	arty_w.name = "Artillery"
	arty_w.set_meta("module_data", {"type_id": "artillery", "fire_range": 140.0})
	hull.add_child(arty_w)

	print("PASS: BattleUnit and test weapon modules created.")

	# 3. Test HUDCommandCard ability row reflection
	var card = HUDCommandCardScript.new()
	root.add_child(card)
	card.update_selection([unit])

	if not card._ability_row.visible:
		print("FAIL: Ability row not visible for unit with tactical modules!")
		quit(1)
		return
	print("PASS: Ability row visible for equipped unit.")

	if not card._barrage_btn.visible:
		print("FAIL: Barrage button not visible for artillery!")
		quit(1)
		return
	print("PASS: Barrage button visible.")

	if not card._smoke_btn.visible:
		print("FAIL: Smoke button not visible for smoke discharger!")
		quit(1)
		return
	print("PASS: Smoke button visible.")

	if not card._beacon_btn.visible:
		print("FAIL: Beacon button not visible for sensor beacon launcher!")
		quit(1)
		return
	print("PASS: Beacon button visible.")

	if not card._mine_btn.visible:
		print("FAIL: Mine button not visible for mine layer!")
		quit(1)
		return
	print("PASS: Mine button visible.")

	# 4. Test ATTACK_GROUND order creation & BattleUnit movement handling
	var ground_order = OrderScript.attack_ground(Vector3(50, 0, 50))
	unit.current_order = ground_order
	unit._apply_movement(0.016)
	print("PASS: ATTACK_GROUND movement evaluation passed without error.")

	print(">>> ALL TACTICAL ABILITY TESTS PASSED SUCCESSFULLY! <<<")
	quit(0)
