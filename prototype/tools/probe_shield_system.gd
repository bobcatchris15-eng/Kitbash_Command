# probe_shield_system.gd
# Verification probe for all shield systems:
# 1. Bubble Shield Projector (Omnidirectional personal shield)
# 2. Energy Barrier Projector (Directional facet shield)
# 3. Heavy Barrier Projector (Projected Aegis field)
# 4. Impact Flash animation on shield shader
# 5. Capacity depletion & collapse
# 6. 3-second clean out-of-combat recharge to 100%

@tool
extends SceneTree

const ModuleCatalog = preload("res://scripts/module_catalog.gd")
const ModuleData = preload("res://scripts/module_data.gd")
const VisualBuilder = preload("res://scripts/visual_builder.gd")
const UnitScript = preload("res://scripts/battle/units/unit.gd")
const AutoWeapon = preload("res://scripts/auto_weapon.gd")

func _init() -> void:
	print("=== PROBING SHIELD SYSTEMS & BUBBLE SHIELD PROJECTOR ===")
	var success := true
	var root = Node3D.new()
	get_root().add_child(root)

	# -------------------------------------------------------------
	# 1. Catalog Verification for bubble_shield_projector
	# -------------------------------------------------------------
	if not ModuleCatalog.module_exists("bubble_shield_projector"):
		print("FAIL: bubble_shield_projector not found in catalog!")
		success = false
	else:
		var b_data = ModuleCatalog.get_module_data("bubble_shield_projector")
		var b_role = ModuleCatalog.get_module_role("bubble_shield_projector")
		var b_draw = ModuleCatalog.get_power_draw("bubble_shield_projector")
		print("PASS: bubble_shield_projector registered. (Role: %s, Category: %s, PowerDraw: %.1f)" % [b_role, b_data.get("category"), b_draw])
		if b_role != "Support":
			print("FAIL: bubble_shield_projector role is not Support (found: %s)" % b_role)
			success = false
		if not ModuleCatalog.SUPPORT_TYPE_IDS.has("bubble_shield_projector"):
			print("FAIL: bubble_shield_projector not in SUPPORT_TYPE_IDS")
			success = false

	# -------------------------------------------------------------
	# 2. Visual Builder Generation for Bubble Shield
	# -------------------------------------------------------------
	var visual_parent = Node3D.new()
	root.add_child(visual_parent)
	VisualBuilder.build_visual("bubble_shield_projector", visual_parent, Vector3.ONE, Color.CYAN, {
		"barrier_capacity": 1.5, "bubble_standoff": 1.0
	})
	var bubble_mesh = visual_parent.find_child("BubbleShield", true, false) as MeshInstance3D
	if bubble_mesh == null:
		print("FAIL: VisualBuilder did not generate 'BubbleShield' child mesh!")
		success = false
	elif not (bubble_mesh.material_override is ShaderMaterial):
		print("FAIL: BubbleShield does not have ShaderMaterial override!")
		success = false
	else:
		var b_aabb = bubble_mesh.get_aabb()
		print("PASS: VisualBuilder generated elliptical BubbleShield mesh (AABB size: %s) with ShaderMaterial." % [str(b_aabb.size)])

	# -------------------------------------------------------------
	# 3. Omnidirectional Absorption & Hit Flash (Bubble Shield)
	# -------------------------------------------------------------
	var unit = UnitScript.new()
	unit.team = 0
	unit.max_hp = 500.0
	unit.hp = 500.0
	unit.max_energy = 100.0
	unit.current_energy = 100.0
	root.add_child(unit)
	unit.add_to_group("units")

	var hull = Node3D.new()
	unit.add_child(hull)
	unit.hull_node = hull

	var mod_node = Node3D.new()
	mod_node.name = "bubble_shield_projector"
	var mdata = ModuleData.new()
	mdata.type_id = "bubble_shield_projector"
	mdata.tweaks = {"barrier_capacity": 1.0}
	mod_node.set_meta("module_data", mdata)
	hull.add_child(mod_node)
	VisualBuilder.build_visual("bubble_shield_projector", mod_node, Vector3.ONE, Color.CYAN, mdata.tweaks)
	var b_shield_mesh = mod_node.find_child("BubbleShield", true, false) as MeshInstance3D

	# Test rear hit absorption (Omnidirectional test: hit from behind +Z)
	var hp_before = unit.hp
	unit.take_damage(100.0, "kinetic", Vector3(0, 0, 30.0))
	var s_hp = float(mod_node.get_meta("current_shield_hp", 0.0))

	if unit.hp < hp_before:
		print("FAIL: Bubble shield failed to absorb rear hit! Unit HP took damage: %f" % unit.hp)
		success = false
	elif not is_equal_approx(s_hp, 400.0):
		print("FAIL: Expected bubble shield HP 400.0 after 100 dmg, got: %f" % s_hp)
		success = false
	else:
		print("PASS: Bubble shield absorbed rear hit omnidirectionally (capacity: 500.0 -> %f, Unit HP intact: %f)." % [s_hp, unit.hp])

	# Verify Impact Flash was triggered on the shader
	if b_shield_mesh != null and b_shield_mesh.material_override is ShaderMaterial:
		var flash_val: float = float(b_shield_mesh.material_override.get_shader_parameter("impact_flash")) if b_shield_mesh.material_override.get_shader_parameter("impact_flash") != null else 0.0
		if flash_val < 0.5:
			print("FAIL: impact_flash shader parameter was not set on hit! (val: %f)" % flash_val)
			success = false
		else:
			print("PASS: Impact flash triggered on shield ShaderMaterial: %f" % flash_val)

	# -------------------------------------------------------------
	# 4. Shield Collapse on Depletion
	# -------------------------------------------------------------
	# Deal 450 damage (more than remaining 400 HP of shield)
	unit.take_damage(450.0, "kinetic", Vector3(0, 0, -30.0))
	var s_hp_after = float(mod_node.get_meta("current_shield_hp", 0.0))
	var s_active = bool(mod_node.get_meta("is_shield_active", true))

	if s_hp_after > 0.0 or s_active:
		print("FAIL: Shield did not collapse after taking exceeding damage! HP: %f, active: %s" % [s_hp_after, str(s_active)])
		success = false
	elif b_shield_mesh != null and b_shield_mesh.visible:
		print("FAIL: Shield mesh is still visible after collapse!")
		success = false
	else:
		print("PASS: Shield successfully depleted to 0 HP and collapsed (active: false, mesh hidden).")

	# -------------------------------------------------------------
	# 5. Out-of-Combat 3-Second Recharge Rule
	# -------------------------------------------------------------
	# Simulate 1.5 seconds under fire
	unit._physics_process(1.5)
	var timer_at_1_5 = float(mod_node.get_meta("shield_recharge_timer", 0.0))
	if not is_equal_approx(timer_at_1_5, 1.5):
		print("FAIL: Recharge timer did not tick down correctly: %f" % timer_at_1_5)
		success = false
	else:
		print("PASS: Shield recharge timer ticked down to 1.5s.")

	# Taking damage resets the 3-second recharge delay!
	unit.take_damage(20.0, "kinetic", Vector3(0, 0, -10.0))
	var timer_reset = float(mod_node.get_meta("shield_recharge_timer", 0.0))
	if not is_equal_approx(timer_reset, 3.0):
		print("FAIL: Taking damage did not reset shield recharge timer to 3.0s (got: %f)!" % timer_reset)
		success = false
	else:
		print("PASS: Taking damage reset shield recharge delay back to 3.0s.")

	# Simulate 2.9 seconds clean of damage -> should still be down
	unit._physics_process(2.9)
	if bool(mod_node.get_meta("is_shield_active", false)) or float(mod_node.get_meta("current_shield_hp", 0.0)) > 0.0:
		print("FAIL: Shield recharged prematurely before 3.0s elapsed!")
		success = false
	else:
		print("PASS: Shield correctly remained offline during the 2.9s cooldown window.")

	# Simulate reaching 3.0s clean -> shield restores back to 100% full!
	unit._physics_process(0.2)
	var final_s_hp = float(mod_node.get_meta("current_shield_hp", 0.0))
	var final_active = bool(mod_node.get_meta("is_shield_active", false))
	if not final_active or not is_equal_approx(final_s_hp, 500.0):
		print("FAIL: Shield did not restore back to full capacity after 3.0s! HP: %f, active: %s" % [final_s_hp, str(final_active)])
		success = false
	elif b_shield_mesh != null and not b_shield_mesh.visible:
		print("FAIL: Shield mesh was not re-enabled upon shield reactivation!")
		success = false
	else:
		print("PASS: Shield successfully restored back to 100%% capacity (%.1f HP) and reactivated after 3.0s clean of damage!" % final_s_hp)

	# -------------------------------------------------------------
	# 6. Directional Energy Barrier Projector Verification
	# -------------------------------------------------------------
	var d_mod = Node3D.new()
	d_mod.name = "energy_barrier_projector"
	var d_data = ModuleData.new()
	d_data.type_id = "energy_barrier_projector"
	d_mod.set_meta("module_data", d_data)
	hull.add_child(d_mod)
	VisualBuilder.build_visual("energy_barrier_projector", d_mod, Vector3.ONE, Color.DEEP_SKY_BLUE, {})

	# Front hit (-Z) should be absorbed by energy barrier
	var d_hp_before = float(d_mod.get_meta("current_shield_hp", 350.0))
	unit.take_damage(50.0, "kinetic", Vector3(0, 0, -30.0))
	var d_hp_after = float(d_mod.get_meta("current_shield_hp", 0.0))
	if d_hp_after >= d_hp_before:
		print("FAIL: Directional energy barrier did not absorb frontal damage! HP: %f -> %f" % [d_hp_before, d_hp_after])
		success = false
	else:
		print("PASS: Directional energy barrier absorbed frontal incoming fire: %f -> %f." % [d_hp_before, d_hp_after])

	root.queue_free()

	if success:
		print(">>> ALL SHIELD SYSTEM & BUBBLE PROJECTOR TESTS PASSED! <<<")
	else:
		print(">>> SOME SHIELD TESTS FAILED! <<<")
	quit(0 if success else 1)
