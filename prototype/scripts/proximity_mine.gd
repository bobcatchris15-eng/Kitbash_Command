extends Area3D
const Profiler = preload("res://scripts/battle/battle_profiler.gd")

# Persistent proximity mine, laid by the mine_layer weapon.
#
# This is the roster's first weapon effect that genuinely HOLDS GROUND.
# Every other weapon has to keep firing to keep denying space; a mine sits
# there and punishes a chokepoint indefinitely, and - importantly - it
# outlives the vehicle that laid it. Its whole lifecycle is self-contained
# for exactly that reason: it must not be a child of, or depend on, the
# weapon or the unit that placed it.
#
# Modelled on smoke_volume.gd's shape (self-owned Area3D, own layer, own
# lifecycle) since that's the established pattern in this project for "a
# thing a weapon leaves behind in the world". Unlike smoke, a mine DOES
# monitor - it has to notice something driving over it - so it runs a
# cheap distance poll rather than physics body-entered signals, which
# would require the mine and every unit to agree on layers/masks that
# aren't currently set up for it.

const MunitionPool = preload("res://scripts/munition_pool.gd")

# Same dedicated-layer reasoning as smoke_volume.gd: never on layer 1,
# because a mine that physically blocked movement would be a bollard.
const MINE_COLLISION_LAYER := 64

# Mines arm shortly after landing rather than instantly - otherwise a mine
# layer could be driven into a crowd and used as a contact weapon, which is
# not what it's for.
const ARM_TIME: float = 1.0
const TRIGGER_RADIUS: float = 2.6
const BLAST_RADIUS: float = 4.5
# Long, but not forever - an unbounded minefield would accumulate across a
# long match until the map was impassable and the node count silly.
const MINE_LIFETIME: float = 90.0
# Poll rather than every frame; a mine is not a precision instrument and
# this keeps a large field cheap.
const POLL_INTERVAL: float = 0.2

var team: int = -1
var damage: float = 40.0
var damage_class: String = "explosive"

var _age: float = 0.0
var _armed: bool = false
var _poll_timer: float = 0.0
var _detonated: bool = false
var _light: OmniLight3D = null

static func spawn(parent: Node, pos: Vector3, mine_team: int, mine_damage: float, dclass: String) -> Area3D:
	var mine = new()
	mine.team = mine_team
	mine.damage = mine_damage
	mine.damage_class = dclass
	parent.add_child(mine)
	mine.global_position = pos
	return mine

func _ready():
	add_to_group("proximity_mines")
	collision_layer = MINE_COLLISION_LAYER
	collision_mask = 0
	monitoring = false
	monitorable = true

	# Low, squat casing sitting on the ground.
	var casing = MeshInstance3D.new()
	casing.mesh = MunitionPool.unit_cylinder()
	casing.scale = Vector3(0.55, 0.14, 0.55)
	casing.material_override = MunitionPool.albedo(Color(0.30, 0.29, 0.20))
	add_child(casing)
	casing.position = Vector3(0, 0.07, 0)

	# A small blinking indicator once armed - a minefield the player cannot
	# see at all is a frustration, not a mechanic. Deliberately visible to
	# both sides: spotting and avoiding mines is the counterplay.
	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.25, 0.15)
	_light.light_energy = 0.0
	_light.omni_range = 3.0
	# Distance-fade cosmetic indicator. 200+ mines in a field is a real
	# case (mine-spam strategies) and each one currently holds a cluster-
	# grid slot. Self-cull past 2.1m so a distant mine shows the casing,
	# not the dot.
	_light.distance_fade_enabled = true
	_light.distance_fade_begin = 2.1
	_light.distance_fade_length = 0.9
	_light.shadow_enabled = false
	add_child(_light)
	_light.position = Vector3(0, 0.25, 0)

func _process(delta):
	if _detonated:
		return
	var _p := Profiler.start()
	_age += delta
	if _age >= MINE_LIFETIME:
		queue_free()
		Profiler.stop("mines", _p)
		return

	if not _armed:
		if _age >= ARM_TIME:
			_armed = true
		Profiler.stop("mines", _p)
		return

	# Slow pulse on the indicator light.
	if is_instance_valid(_light):
		_light.light_energy = 0.6 + 0.5 * sin(_age * 3.0)

	_poll_timer -= delta
	if _poll_timer > 0.0:
		Profiler.stop("mines", _p)
		return
	_poll_timer = POLL_INTERVAL

	for c in get_tree().get_nodes_in_group("damageable"):
		if not is_instance_valid(c) or not c.has_method("take_damage"):
			continue
		if "is_dead" in c and c.is_dead:
			continue
		var c_team = c.get_meta("team") if c.has_meta("team") else -1
		if team >= 0 and c_team == team:
			continue
		# Flying units pass safely overhead - a ground mine has no business
		# catching an aircraft, and this gives air a genuine reason to exist
		# against a heavily mined approach.
		if "is_flying" in c and c.is_flying:
			continue
		if global_position.distance_to(c.global_position) <= TRIGGER_RADIUS:
			_detonate()
			Profiler.stop("mines", _p)
			return
	Profiler.stop("mines", _p)

func _detonate():
	if _detonated:
		return
	_detonated = true

	var my_pos = global_position
	var parent = get_parent()

	for c in get_tree().get_nodes_in_group("damageable"):
		if not is_instance_valid(c) or not c.has_method("take_damage"):
			continue
		if "is_dead" in c and c.is_dead:
			continue
		var c_team = c.get_meta("team") if c.has_meta("team") else -1
		if team >= 0 and c_team == team:
			continue
		if "is_flying" in c and c.is_flying:
			continue
		var dist = my_pos.distance_to(c.global_position)
		if dist > BLAST_RADIUS:
			continue
		c.take_damage(damage * clamp(1.0 - dist / BLAST_RADIUS, 0.0, 1.0), damage_class, my_pos)

	# Blast visual is parented to the SCENE, not to this node - the mine
	# frees itself immediately below, and a child would be torn down with it
	# before it ever rendered.
	if parent and is_instance_valid(parent):
		var burst = MeshInstance3D.new()
		burst.mesh = MunitionPool.unit_sphere()
		burst.scale = Vector3.ONE * 0.5
		burst.material_override = MunitionPool.emissive(Color.ORANGE, Color(1.0, 0.7, 0.2))
		parent.add_child(burst)
		burst.global_position = my_pos
		var t = burst.create_tween()
		t.tween_property(burst, "scale", Vector3.ONE * (BLAST_RADIUS * 1.4), 0.12)
		t.tween_property(burst, "scale", Vector3.ZERO, 0.2)
		t.finished.connect(func(): if is_instance_valid(burst): burst.queue_free())

	queue_free()
