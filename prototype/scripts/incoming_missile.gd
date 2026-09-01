extends Node3D
const MunitionPool = preload("res://scripts/munition_pool.gd")
const Profiler = preload("res://scripts/battle/battle_profiler.gd")

var target_node: Node3D = null
var speed: float = 9.0
var damage_amount: float = 15.0
var is_destroyed: bool = false

func _ready():
	add_to_group("missiles")
	
	# Visual rocket body
	var mesh_inst = MeshInstance3D.new()
	mesh_inst.mesh = MunitionPool.unit_box()
	mesh_inst.scale = Vector3(0.15, 0.15, 0.5)
	mesh_inst.material_override = MunitionPool.emissive(Color.RED, Color.ORANGE)
	add_child(mesh_inst)

func _physics_process(delta):
	if is_destroyed: return
	var _p := Profiler.start()

	if not is_instance_valid(target_node):
		destroy_missile(false)
		Profiler.stop("missiles", _p)
		return

	# Move towards target
	var dest = target_node.get_nearest_surface_point(global_position) if target_node.has_method("get_nearest_surface_point") else target_node.global_position + Vector3(0, 0.5, 0)
	look_at(dest, Vector3.UP)
	var dir = (dest - global_position).normalized()
	global_position += dir * speed * delta

	# Check distance
	if global_position.distance_to(dest) < 1.2:
		# Hit player!
		if target_node.has_method("take_damage"):
			target_node.take_damage(damage_amount, "explosive", global_position)
		destroy_missile(false)
	Profiler.stop("missiles", _p)

func destroy_missile(intercepted: bool):
	if is_destroyed: return
	is_destroyed = true
	
	# Spawn explosion sphere
	var exp = MeshInstance3D.new()
	exp.mesh = MunitionPool.unit_sphere()
	var exp_color = Color.ORANGE if not intercepted else Color.CYAN
	exp.material_override = MunitionPool.emissive(exp_color, exp_color)
	(get_tree().current_scene if get_tree().current_scene != null else get_tree().root).add_child(exp)
	exp.global_position = global_position
	
	var tween = create_tween()
	tween.tween_property(exp, "scale", Vector3.ZERO, 0.15)
	tween.finished.connect(func(): exp.queue_free())
	
	queue_free()
