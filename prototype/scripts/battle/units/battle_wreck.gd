class_name BattleWreck
extends Node3D
# Manages persistent, burning vehicle wreckage after catastrophic destruction.
#
# CATASTROPHIC DESTRUCTION PIPELINE:
# 1. Violent ammo-rack cook-off & explosive burst at detonation.
# 2. Physics Turret Blow-Off: Detaches mounted turret/primary weapon as a
#    RigidBody3D with upward/rotational impulse that collides and bounces.
# 3. Persistent Carcass: Charred, blackened hull with collapsed suspension.
# 4. Volumetric Fire & Smoke: Internal firelight and billowing black diesel
#    smoke plume that drifts in the wind.
# 5. Clean lifecycle management (persists for ~60s before fading).

const VFXBurstScript = preload("res://scripts/vfx_burst.gd")
const VFXEffectsScript = preload("res://scripts/vfx_effects.gd")

const WRECK_LIFETIME := 60.0
const WRECK_FADE_START := 52.0

static var _charred_mat: StandardMaterial3D = null


static func _get_charred_material() -> StandardMaterial3D:
	if _charred_mat == null:
		_charred_mat = StandardMaterial3D.new()
		_charred_mat.albedo_color = Color(0.11, 0.10, 0.09, 1.0)
		_charred_mat.roughness = 0.88
		_charred_mat.metallic = 0.35
		_charred_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _charred_mat


static func spawn_from_unit(unit: CharacterBody3D, hit_origin: Variant = null) -> BattleWreck:
	if not is_instance_valid(unit):
		return null
	var parent := unit.get_parent()
	if parent == null:
		return null

	var wreck := BattleWreck.new()
	wreck.name = "Wreck_%s" % unit.name
	parent.add_child(wreck)
	wreck.global_transform = unit.global_transform

	var pos := unit.global_position
	# 1. Initial catastrophic explosion burst
	VFXBurstScript.spawn(parent, pos + Vector3(0, 1.0, 0), Color(1.0, 0.5, 0.15), 20, 0.35, 180.0, 3.0, 8.0)
	VFXEffectsScript.smoke_puff(parent, pos + Vector3(0, 0.8, 0), 3.0, 24, Color(0.12, 0.11, 0.10, 0.8))
	VFXEffectsScript.scorch(parent, pos, 3.8, 4.0, WRECK_LIFETIME)

	# 2. Physics Turret Blow-Off & Hull Carcass Setup
	var hull: Node3D = null
	for child in unit.get_children():
		if child is Node3D and child.has_meta("type_id"):
			hull = child
			break

	if hull != null:
		wreck._setup_carcass_and_turret(hull, parent, pos)

	# 3. Firelight & Smoke Plume
	wreck._setup_fire_and_smoke(pos)

	# 4. Lifecycle Timer
	wreck._setup_lifecycle()
	return wreck


func _setup_carcass_and_turret(hull: Node3D, scene_root: Node, spawn_pos: Vector3) -> void:
	var hull_copy := hull.duplicate() as Node3D
	add_child(hull_copy)
	hull_copy.position = hull.position
	hull_copy.rotation = hull.rotation
	# Damage-overlay subtrees do not survive into wreckage: the carcass gets
	# its own fire and plume below, and _apply_charred_material would otherwise
	# flatten each damaged-stencil card into an opaque black quad floating off
	# the charred hull (see module_damage_fx.gd's FX_CONTAINER).
	_strip_damage_overlays(hull_copy)

	# Find primary turret/weapon to pop off with physics
	var turret_to_pop: Node3D = null
	for child in hull_copy.get_children():
		if child.has_meta("module_data"):
			var data = child.get_meta("module_data")
			if data != null and data.category in ["weapon", "turret"]:
				turret_to_pop = child
				break

	if turret_to_pop != null:
		_pop_turret_physics(turret_to_pop, scene_root, spawn_pos)
		turret_to_pop.queue_free()

	# Apply blackened charred material across all carcass meshes
	_apply_charred_material(hull_copy)

	# Slight chassis tilt simulating collapsed suspension on the destroyed side
	hull_copy.rotate_z(randf_range(-0.06, 0.06))
	hull_copy.rotate_x(randf_range(-0.05, 0.05))


func _pop_turret_physics(turret_node: Node3D, scene_root: Node, spawn_pos: Vector3) -> void:
	var rigid := RigidBody3D.new()
	rigid.name = "BlownTurret"
	rigid.collision_layer = 0
	rigid.collision_mask = BattleLayers.TERRAIN | BattleLayers.BUILDINGS
	rigid.mass = 350.0

	var turret_copy := turret_node.duplicate() as Node3D
	_strip_damage_overlays(turret_copy)
	_apply_charred_material(turret_copy)
	rigid.add_child(turret_copy)
	turret_copy.position = Vector3.ZERO

	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.4, 0.8, 1.6)
	col.shape = box
	rigid.add_child(col)

	scene_root.add_child(rigid)
	rigid.global_transform = turret_node.global_transform

	# High-velocity explosive ejection impulse
	var impulse_up := randf_range(9.0, 16.0)
	var impulse_horiz := Vector3(randf_range(-4.0, 4.0), 0, randf_range(-4.0, 4.0))
	rigid.linear_velocity = Vector3.UP * impulse_up + impulse_horiz
	rigid.angular_velocity = Vector3(randf_range(-8.0, 8.0), randf_range(-10.0, 10.0), randf_range(-8.0, 8.0))

	# Small smoke trail on flying turret
	VFXEffectsScript.smoke_puff(rigid, Vector3.ZERO, 1.2, 10, Color(0.15, 0.14, 0.13, 0.6))

	# Clean up popped turret after settling
	var tween := rigid.create_tween()
	tween.tween_interval(WRECK_LIFETIME * 0.9)
	tween.tween_property(rigid, "scale", Vector3.ZERO, WRECK_LIFETIME * 0.1)
	tween.finished.connect(func():
		if is_instance_valid(rigid):
			rigid.queue_free())


func _setup_fire_and_smoke(pos: Vector3) -> void:
	# Persistent black diesel smoke plume
	VFXEffectsScript.wreck_smoke_column(self, pos + Vector3(0, 0.5, 0), WRECK_LIFETIME, 13.0)

	# Licking internal fire
	VFXEffectsScript.wreck_fire(self, pos + Vector3(0, 0.6, 0), WRECK_LIFETIME * 0.75, 1.4)

	# Internal flickering firelight
	var firelight := OmniLight3D.new()
	firelight.name = "Firelight"
	firelight.light_color = Color(1.0, 0.45, 0.15)
	firelight.light_energy = 2.0
	firelight.omni_range = 7.0
	firelight.omni_attenuation = 1.6
	# Distance-fade cosmetic firelight. 30-60 simultaneous wrecks have been
	# measured (light_cap.gd:13-14); fading past 5m so distant wreckage
	# doesn't pay the cluster-grid tax.
	firelight.distance_fade_enabled = true
	firelight.distance_fade_begin = 4.9
	firelight.distance_fade_length = 2.1
	firelight.shadow_enabled = false
	add_child(firelight)
	firelight.global_position = pos + Vector3(0, 0.8, 0)

	var ftween := firelight.create_tween().set_loops(int(WRECK_LIFETIME * 5))
	ftween.tween_property(firelight, "light_energy", 1.4, 0.1)
	ftween.tween_property(firelight, "light_energy", 2.4, 0.1)


func _apply_charred_material(node: Node) -> void:
	var mat := _get_charred_material()
	if node is MeshInstance3D:
		node.material_override = mat
	for child in node.get_children():
		_apply_charred_material(child)


# Removes module_damage_fx.gd's DamageFX overlay subtrees (smoke leak emitters
# and damaged-stencil cards) from a duplicated subtree. Detached before freeing
# so the charred pass below never sees them in the same call.
static func _strip_damage_overlays(node: Node) -> void:
	for child in node.get_children():
		if String(child.name).begins_with("DamageFX"):
			node.remove_child(child)
			child.queue_free()
		else:
			_strip_damage_overlays(child)


func _setup_lifecycle() -> void:
	var tween := create_tween()
	tween.tween_interval(WRECK_FADE_START)
	# Slowly sink/fade into the earth
	tween.tween_property(self, "position:y", position.y - 0.8, WRECK_LIFETIME - WRECK_FADE_START)
	tween.finished.connect(func():
		if is_instance_valid(self):
			queue_free())
