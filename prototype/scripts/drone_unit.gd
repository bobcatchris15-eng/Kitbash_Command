extends Node3D
const MunitionPool = preload("res://scripts/munition_pool.gd")
const VFXBurstScript = preload("res://scripts/vfx_burst.gd")
# Section timing around the state machine. Pairs with the BattleProfiler
# sections in match_director / unit / auto_weapon so a playtest can see
# total drone cost in a swarm, not just the per-drone average.
const Profiler = preload("res://scripts/battle/battle_profiler.gd")

# WHAT THIS REPLACES, AND WHY.
# Previous drone_unit.gd had a single hardcoded attack-only state machine.
# It could not express a scout (high-speed loiter with fog reveal) or a repair
# drone (ally-seeking repair tether), both of which the deployable modules spec
# requires. The new design is type-driven: drone_type gates the state machine
# behaviour while the existing LAUNCH/ATTACK/RETURN skeleton is kept for the
# carrier-homing logic that all three share.

# A real autonomous drone launched by a drone_carrier weapon — independent
# physics-driven flight and its own launch/loiter/return state machine.
# Previously drone_carrier's "_fire_drone_swarm()" just tweened two
# throwaway MeshInstance3D prisms with damage applied in a tween callback —
# no persistent entity, no independent AI. Modeled on incoming_missile.gd's
# shape instead (own _physics_process, group self-registration so
# point-defense can shoot it down like any other projectile, self-managed
# lifecycle) rather than inventing a new pattern.

enum State { LAUNCH, LOITER, REPAIR, RETURN }

var carrier: Node3D = null
var target: Node3D = null
var speed: float = 14.0
var damage_per_hit: float = 20.0
var damage_class: String = "kinetic"
var team: int = -1
var state: State = State.LAUNCH
var is_destroyed: bool = false

# drone_type drives the state machine behaviour above.
# Set by _fire_drone_swarm() from the carrier module's tweak.
var drone_type: String = "attack"

# --- Shared timing ------------------------------------------------------
var _state_timer: float = 0.0
const RETURN_TIMEOUT: float = 8.0

# --- Attack drone -------------------------------------------------------
const ATTACK_LINGER: float = 0.35   # brief strafing loiter before returning

# --- Scout drone --------------------------------------------------------
const SCOUT_LOITER: float = 4.0     # seconds to orbit and reveal fog
const SCOUT_ORBIT_RADIUS: float = 4.0
const SCOUT_REVEAL_RADIUS: float = 24.0
const SCOUT_REVEAL_DURATION: float = 18.0
var _scout_orbit_angle: float = 0.0

# --- Repair drone --------------------------------------------------------
const REPAIR_TETHER: float = 3.0    # seconds of repair channel
const REPAIR_RATE: float = 30.0     # HP restored per second
var _repair_target: Node3D = null

const VisionService = preload("res://scripts/battle/vision/vision_service.gd")

func _ready():
	add_to_group("missiles") # reuses existing point-defense interception logic
	set_meta("team", team)

	# Mesh colour varies by drone type so they are visually distinguishable.
	var base_color: Color
	var emissive_color: Color
	match drone_type:
		"scout":
			base_color = Color(0.15, 0.35, 0.55)  # pale blue
			emissive_color = Color.CYAN
		"repair":
			base_color = Color(0.15, 0.45, 0.25)  # muted green
			emissive_color = Color.GREEN
		_:  # "attack" and any fallback
			base_color = Color.NAVY_BLUE
			emissive_color = Color.CYAN

	var mesh_inst = MeshInstance3D.new()
	mesh_inst.mesh = MunitionPool.unit_prism()
	mesh_inst.scale = Vector3(0.22, 0.1, 0.22)
	mesh_inst.material_override = MunitionPool.emissive(base_color, emissive_color)
	add_child(mesh_inst)

func _physics_process(delta):
	if is_destroyed:
		return
	var _t := Profiler.start()
	match state:
		State.LAUNCH:
			_do_launch(delta)
		State.LOITER:
			_do_loiter(delta)
		State.REPAIR:
			_do_repair(delta)
		State.RETURN:
			_do_return(delta)
	Profiler.stop("drones", _t)

# ─── LAUNCH ────────────────────────────────────────────────────────────────
func _do_launch(delta: float):
	var dest: Vector3
	match drone_type:
		"scout":
			# Scout goes to the area the carrier wanted surveyed; if no target,
			# drifts forward toward the carrier's facing direction.
			if is_instance_valid(target):
				dest = target.global_position
			else:
				var carrier_root = carrier if is_instance_valid(carrier) else self
				dest = carrier_root.global_position - carrier_root.global_transform.basis.z.normalized() * 20.0
		"repair":
			# Repair drone seeks the most-damaged ally in range.
			_repair_target = _find_damaged_ally()
			if is_instance_valid(_repair_target):
				dest = _repair_target.global_position
			else:
				# No damaged ally found; return immediately.
				state = State.RETURN
				return
		_:  # "attack"
			if not is_instance_valid(target) or ("is_dead" in target and target.is_dead):
				state = State.RETURN
				return
			dest = target.global_position + Vector3(0, 1.0, 0)

	_fly_toward(dest, delta)

	var dist_threshold := 2.5 if drone_type == "scout" else 2.0
	if global_position.distance_to(dest) < dist_threshold:
		_state_timer = 0.0
		match drone_type:
			"scout":
				state = State.LOITER
				_scout_orbit_angle = 0.0
			"repair":
				if is_instance_valid(_repair_target):
					state = State.REPAIR
				else:
					state = State.RETURN
			_:
				# Attack: deal damage once on arrival.
				if is_instance_valid(target) and target.has_method("take_damage"):
					target.take_damage(damage_per_hit, damage_class, global_position)
					if is_inside_tree():
						var parent = get_tree().current_scene if get_tree().current_scene != null else get_tree().root
						VFXBurstScript.spawn(parent, target.global_position + Vector3(0, 0.4, 0), Color.CYAN, 8, 0.15, 60.0, 2.0, 5.0)
				state = State.LOITER   # reuse LOITER for attack linger

# ─── LOITER ────────────────────────────────────────────────────────────────
func _do_loiter(delta: float):
	_state_timer += delta

	if drone_type == "scout":
		# Orbit around the target position while revealing fog of war.
		var orbit_center: Vector3
		if is_instance_valid(target):
			orbit_center = target.global_position
		else:
			orbit_center = global_position  # already at drift destination

		_scout_orbit_angle += delta * 1.2
		var orbit_dest = orbit_center + Vector3(
			cos(_scout_orbit_angle) * SCOUT_ORBIT_RADIUS,
			1.0,
			sin(_scout_orbit_angle) * SCOUT_ORBIT_RADIUS
		)
		_fly_toward(orbit_dest, delta)

		# Periodically call reveal_area on the vision service.
		# Check every ~1s to avoid flooding the call.
		if fmod(_state_timer, 1.0) < delta:
			_reveal_fog(orbit_center)

		if _state_timer >= SCOUT_LOITER:
			state = State.RETURN
	elif drone_type == "attack":
		# Brief strafing loiter (visual; damage was dealt on arrival).
		if _state_timer >= ATTACK_LINGER:
			state = State.RETURN
	else:
		# Unknown type — return immediately.
		state = State.RETURN

# ─── REPAIR ────────────────────────────────────────────────────────────────
func _do_repair(delta: float):
	if not is_instance_valid(_repair_target) or ("is_dead" in _repair_target and _repair_target.is_dead):
		state = State.RETURN
		return

	# Stay tethered to the ally.
	_fly_toward(_repair_target.global_position + Vector3(0, 1.0, 0), delta)

	# Channel repair while tethered.
	_state_timer += delta
	if _repair_target.has_method("repair_hp"):
		var hp_ticked = REPAIR_RATE * delta
		_repair_target.repair_hp(hp_ticked)

	if _state_timer >= REPAIR_TETHER:
		state = State.RETURN

# ─── RETURN ────────────────────────────────────────────────────────────────
func _do_return(delta: float):
	_state_timer += delta
	if not is_instance_valid(carrier) or _state_timer > RETURN_TIMEOUT:
		destroy_missile(false)
		return
	_fly_toward(carrier.global_position, delta)
	if global_position.distance_to(carrier.global_position) < 1.5:
		destroy_missile(false)

# ─── Helpers ────────────────────────────────────────────────────────────────
func _fly_toward(dest: Vector3, delta: float):
	var dir = dest - global_position
	if dir.length() > 0.05:
		look_at(dest, Vector3.UP)
		global_position += dir.normalized() * speed * delta

func _find_damaged_ally() -> Node3D:
	var best: Node3D = null
	var best_deficit: float = 0.0
	var search_range := 30.0
	var my_pos = global_position
	var my_team = team

	for c in get_tree().get_nodes_in_group("damageable"):
		if not is_instance_valid(c) or not c.has_method("repair_hp"):
			continue
		if "is_dead" in c and c.is_dead:
			continue
		var c_team = c.get_meta("team") if c.has_meta("team") else -1
		if c_team != my_team:
			continue
		if my_pos.distance_to(c.global_position) > search_range:
			continue
		# Pick the ally with the most HP deficit (most damaged).
		var c_hp: float = float(c.hp) if "hp" in c else 100.0
		var c_max: float = float(c.max_hp) if "max_hp" in c else 100.0
		var deficit = c_max - c_hp
		if deficit > best_deficit:
			best_deficit = deficit
			best = c
	return best

func _reveal_fog(pos: Vector3):
	var scene = get_tree().current_scene
	if scene != null and scene.has_method("reveal_area"):
		scene.reveal_area(team, pos, SCOUT_REVEAL_RADIUS, SCOUT_REVEAL_DURATION)

# Duck-typed the same way incoming_missile.gd's is — auto_weapon.gd's
# point-defense code calls this unconditionally (guarded by has_method)
# when a PD weapon shoots a drone down mid-flight.
func destroy_missile(intercepted: bool):
	if is_destroyed:
		return
	is_destroyed = true
	var exp = MeshInstance3D.new()
	exp.mesh = MunitionPool.unit_sphere()
	exp.scale = Vector3(0.6, 0.6, 0.6)
	var exp_color = Color.ORANGE if not intercepted else Color.CYAN
	exp.material_override = MunitionPool.emissive(exp_color, exp_color)
	var scene = get_tree().current_scene
	if not scene:
		scene = get_parent()
	if scene:
		scene.add_child(exp)
	exp.global_position = global_position
	var tween = create_tween()
	tween.tween_property(exp, "scale", Vector3.ZERO, 0.15)
	tween.finished.connect(func(): if is_instance_valid(exp): exp.queue_free())
	queue_free()
