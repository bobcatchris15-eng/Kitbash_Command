extends Camera3D
# Classic RTS camera: WASD/arrow pan (yaw-relative), Q/E rotate, mouse-wheel
# zoom, middle-mouse drag pan. Reads InputService's cam_* actions rather than
# raw keycodes - see scripts/core/input_service.gd's header for why.
#
# ADAPTIVE TERRAIN ELEVATION FOLLOWING:
# The camera dynamically and smoothly adapts its altitude to match the broad
# terrain elevation beneath the focal area (plateaus, mountain passes, valleys,
# tiered ground), while using a 5-point area filter so isolated spires or sharp
# rocks don't cause sudden jolts. It also enforces a minimum terrain clearance
# floor so the camera never clips into elevated terrain or cliffs.
#
# DOF (re-enabled): tilt-shift depth-of-field band — the miniature lens feel
# from CORE_DESIGN_LANGUAGE §2.

const TerrainBuilderScript = preload("res://scripts/terrain_builder.gd")
const PointerGainScript = preload("res://scripts/core/pointer_gain.gd")

@export var pan_speed: float = 30.0
# Multiplicative zoom: each wheel notch multiplies the camera height by this
# ratio rather than adding a fixed number of metres.
@export var zoom_step: float = 1.15
@export var rotate_speed: float = 90.0
# Total War-style camera: moderate FOV that shows the battlefield at
# strategic zoom but lets you dive in to inspect individual units.
@export var gameplay_fov: float = 40.0
@export var min_height: float = 8.0
# TW zoom-out lets you see a significant fraction of the map. 200m
# cap works for the new 1200×520 twin_streams layout.
@export var max_height: float = 200.0

# Edge-scroll margin in real pixels
@export var edge_scroll_margin: float = 18.0

# Adaptive ground tracking properties
@export var ground_follow_speed: float = 4.5
@export var min_terrain_clearance: float = 5.0

var world_scale: float = 1.0
var height: float = 26.0

# Map definition context for direct analytical terrain queries
var current_map: Dictionary = {}:
	set(value):
		current_map = value
		if not value.is_empty():
			var he: Vector2 = Vector2(float(value.get("map_half_extents", 80.0)), float(value.get("map_half_extents_z", value.get("map_half_extents", 80.0))))
			# Prefer MapCatalog.half_extents when available (handles scaling), but
			# avoid hard import loop — derive directly here.
			set_map_bounds(he)
			# Re-initialize ground elevation with valid map
			var init_ground := compute_target_ground_height()
			_ground_y_smoothed = init_ground
			_ground_initialized = true
			global_position.y = _ground_y_smoothed + height

var _ground_y_smoothed: float = 0.0
var _ground_initialized: bool = false

# CameraAttributesPractical reference for DOF
var _cam_attributes: CameraAttributesPractical = null

var _middle_drag_origin: Vector2 = Vector2.ZERO
var _middle_drag_last: Vector2 = Vector2.ZERO

var _map_half: Vector2 = Vector2.ZERO
var _clamp_enabled: bool = false
# THE WALL IS THE STOP, and until 2026-09-01 it was not.
# ---------------------------------------------------------------------------
# void_wall.gd places its four panels at exactly +/-half_x and +/-half_z. The
# hard guard below used to clamp the camera ORIGIN to
# `half + VOID_CAMERA_MARGIN + VOID_CAMERA_EXTRA_VOID` = half + 8, so the
# camera was permitted eight metres PAST the wall it was supposed to stop at -
# the comment already said "wall is the stop", the arithmetic just did not.
#
# Why it only showed up at some zooms. `get_focal_ground_pos()` puts the origin
# `height / tan(pitch)` behind whatever it is looking at: ~11 m at min_height
# (8 m, -35 deg) and ~140 m at max_height (200 m, -55 deg). Only when zoomed
# in is the origin close enough to the focal point to be pushed against the
# outer limit at all, so the overshoot was reachable near the ground and
# invisible at strategic zoom - which is exactly "in some zooms".
#
# Two separate limits, and they are not the same number:
#   FOCAL   what the player is looking at, clamped to the map proper. Looking
#           at the void is not a thing to allow.
#   ORIGIN  the eye, clamped just INSIDE the wall plane. The inset keeps the
#           near plane from poking through a panel and showing the void
#           through the back of it.
#
# Raising ORIGIN_WALL_INSET past ~4 m starts costing the player the ability to
# centre the map's own edge at high zoom, because the origin limit and the
# focal point are `forward_dist` apart and the origin limit wins.
const VOID_CAMERA_MARGIN: float = 0.0
const VOID_CAMERA_EXTRA_VOID: float = 0.0 # wall is the stop - no void cruise
const ORIGIN_WALL_INSET: float = 2.0

func set_map_bounds(half: Vector2) -> void:
	_map_half = half
	_clamp_enabled = half.x > 0.0 and half.y > 0.0

func _clamp_to_void() -> void:
	if not _clamp_enabled:
		return
	if not is_inside_tree():
		return
	# Clamp focal point (what the player is looking at) rather than raw camera
	# origin so the wall stays at the edge of the view at low zoom and not
	# halfway across the screen at high zoom. Then pull camera back.
	var focal := get_focal_ground_pos()
	var limit_x := _map_half.x + VOID_CAMERA_EXTRA_VOID
	var limit_z := _map_half.y + VOID_CAMERA_EXTRA_VOID
	var clamped_x := clampf(focal.x, -limit_x, limit_x)
	var clamped_z := clampf(focal.y, -limit_z, limit_z)
	var dx := clamped_x - focal.x
	var dz := clamped_z - focal.y
	if dx != 0.0 or dz != 0.0:
		global_position.x += dx
		global_position.z += dz

	# Hard position guard as well (handles MMB drag, which moves the camera
	# directly and never consults the focal clamp above). This is the one that
	# has to land inside the wall - maxf keeps it sane on a map smaller than
	# the inset, which no shipped map is, but a 4 m test map would be.
	var hard_x := maxf(_map_half.x - ORIGIN_WALL_INSET, _map_half.x * 0.5)
	var hard_z := maxf(_map_half.y - ORIGIN_WALL_INSET, _map_half.y * 0.5)
	global_position.x = clampf(global_position.x, -hard_x, hard_x)
	global_position.z = clampf(global_position.z, -hard_z, hard_z)

func _ready() -> void:
	# Keep user height relative to ground
	height = clamp(height, min_height, max_height)
	_apply_pitch()
	fov = gameplay_fov
	
	if attributes != null and attributes is CameraAttributesPractical:
		_cam_attributes = attributes
		_apply_dof_distances()

	# Initialize ground elevation immediately
	var init_ground := compute_target_ground_height()
	_ground_y_smoothed = init_ground
	_ground_initialized = true
	global_position.y = _ground_y_smoothed + height


func _apply_pitch() -> void:
	# Total War-style: shallower at close zoom (inspect units), steeper
	# at far zoom (strategic overview). -35 close / -55 far.
	var t = (height - min_height) / (max_height - min_height)
	rotation_degrees.x = lerp(-35.0, -55.0, t)


func _apply_dof_distances() -> void:
	if _cam_attributes == null:
		return
	_cam_attributes.dof_blur_far_distance = height + 150.0
	var t = (height - min_height) / (max_height - min_height)
	_cam_attributes.dof_blur_far_transition = lerp(3.0, 12.0, t)


# ==============================================================================
# ADAPTIVE TERRAIN ELEVATION SAMPLING
# ==============================================================================

func sample_terrain_height(x: float, z: float) -> float:
	if not current_map.is_empty():
		return TerrainBuilderScript.height_at(current_map, x, z)
	
	# Fallback to physics raycast if inside scene tree
	if is_inside_tree() and get_world_3d() != null:
		var space := get_world_3d().direct_space_state
		if space != null:
			var query := PhysicsRayQueryParameters3D.create(
				Vector3(x, 2000.0, z),
				Vector3(x, -2000.0, z),
				4
			)
			var res := space.intersect_ray(query)
			if not res.is_empty() and res.has("position"):
				return float(res["position"].y)
	return 0.0


func get_focal_ground_pos() -> Vector2:
	var pitch_rad: float = deg_to_rad(absf(rotation_degrees.x))
	var yaw_rad: float = deg_to_rad(rotation_degrees.y)
	var forward_dist: float = height / maxf(0.15, tan(pitch_rad))
	forward_dist = clampf(forward_dist, 5.0, 350.0)
	var focus_x: float = global_position.x - sin(yaw_rad) * forward_dist
	var focus_z: float = global_position.z - cos(yaw_rad) * forward_dist
	return Vector2(focus_x, focus_z)


func compute_target_ground_height() -> float:
	var focal_xz := get_focal_ground_pos()
	var r: float = clampf(height * 0.35, 15.0, 50.0)
	
	# 5-point area kernel: center + 4 cardinal offsets
	var h_center := sample_terrain_height(focal_xz.x, focal_xz.y)
	var h1 := sample_terrain_height(focal_xz.x + r, focal_xz.y)
	var h2 := sample_terrain_height(focal_xz.x - r, focal_xz.y)
	var h3 := sample_terrain_height(focal_xz.x, focal_xz.y + r)
	var h4 := sample_terrain_height(focal_xz.x, focal_xz.y - r)
	
	# Weighted: center 50%, surrounding 50%
	var avg_ground := h_center * 0.5 + (h1 + h2 + h3 + h4) * 0.125
	return avg_ground


# ==============================================================================
# INPUT & MOVEMENT
# ==============================================================================

static func compute_edge_scroll_direction(mouse_pos: Vector2, viewport_size: Vector2, margin: float) -> Vector2:
	var dir = Vector2.ZERO
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return dir
	if mouse_pos.x < margin:
		dir.x -= 1.0
	elif mouse_pos.x > viewport_size.x - margin:
		dir.x += 1.0
	if mouse_pos.y < margin:
		dir.y -= 1.0
	elif mouse_pos.y > viewport_size.y - margin:
		dir.y += 1.0
	return dir


static func pan_to_world(input: Vector2, yaw_deg: float) -> Vector2:
	var yaw := deg_to_rad(yaw_deg)
	var sin_y := sin(yaw)
	var cos_y := cos(yaw)
	return Vector2(
		input.x * cos_y + input.y * sin_y,
		-input.x * sin_y + input.y * cos_y
	)


static func compute_movement(
	keyboard: Vector2, mouse_pos: Vector2, viewport_size: Vector2, margin: float,
	window_has_focus: bool
) -> Vector2:
	var move := keyboard
	if window_has_focus:
		move += compute_edge_scroll_direction(mouse_pos, viewport_size, margin)
	return move


static func compute_yaw_up(pitch_deg: float) -> Vector3:
	return Vector3(0.0, sin(deg_to_rad(pitch_deg)), cos(deg_to_rad(pitch_deg)))


func _process(delta: float) -> void:
	var move := Input.get_vector("cam_pan_left", "cam_pan_right", "cam_pan_up", "cam_pan_down")

	if is_inside_tree() and get_window() and get_window().has_focus():
		var vp := get_viewport()
		var edge_dir := compute_edge_scroll_direction(vp.get_mouse_position(), vp.get_visible_rect().size, edge_scroll_margin)
		move += edge_dir

	if Input.is_action_pressed("cam_rotate_left"): rotation_degrees.y += rotate_speed * delta
	if Input.is_action_pressed("cam_rotate_right"): rotation_degrees.y -= rotate_speed * delta
	if Input.is_action_just_pressed("cam_reset_rotation"): rotation_degrees.y = 0.0

	if move != Vector2.ZERO:
		move = move.normalized() * pan_speed * world_scale * delta * (height / 26.0)
		var world_move := pan_to_world(move, rotation_degrees.y)
		global_position.x += world_move.x
		global_position.z += world_move.y
		_clamp_to_void()

	# Adaptive Ground Height Interpolation (Critically damped single-pole exponential smoothing)
	var target_ground := compute_target_ground_height()

	# Minimum clearance under camera position to prevent clipping into hills or spires
	var under_cam_h := sample_terrain_height(global_position.x, global_position.z)
	var min_ground_for_clearance := under_cam_h + min_terrain_clearance - height
	target_ground = maxf(target_ground, min_ground_for_clearance)

	if not _ground_initialized:
		_ground_y_smoothed = target_ground
		_ground_initialized = true

	var blend := 1.0 - exp(-ground_follow_speed * delta)
	_ground_y_smoothed = lerpf(_ground_y_smoothed, target_ground, blend)

	global_position.y = _ground_y_smoothed + height


func ray_plane_hit(screen_pos: Vector2, plane_y: float = -999999.0):
	if plane_y == -999999.0:
		plane_y = _ground_y_smoothed
	var origin := project_ray_origin(screen_pos)
	var dir := project_ray_normal(screen_pos)
	if absf(dir.y) < 0.0001:
		return null
	var t := (plane_y - origin.y) / dir.y
	if t < 0.0:
		return null
	return origin + dir * t


func _on_zoom(screen_pos: Vector2, notches: float) -> void:
	height = clamp(height * pow(zoom_step, notches), min_height, max_height)
	_apply_pitch()
	_apply_dof_distances()
	var before = ray_plane_hit(screen_pos, _ground_y_smoothed)
	
	# Update camera Y relative to smoothed ground
	var under_cam_h := sample_terrain_height(global_position.x, global_position.z)
	var min_allowed_cam_y := under_cam_h + min_terrain_clearance
	global_position.y = maxf(_ground_y_smoothed + height, min_allowed_cam_y)
	
	var after = ray_plane_hit(screen_pos, _ground_y_smoothed)
	if before != null and after != null:
		global_position.x += before.x - after.x
		global_position.z += before.z - after.z
		_clamp_to_void()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("cam_zoom_in"):
		_on_zoom(get_viewport().get_mouse_position(), -1.0)
	elif event.is_action_pressed("cam_zoom_out"):
		_on_zoom(get_viewport().get_mouse_position(), 1.0)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			_middle_drag_origin = event.position
			_middle_drag_last = event.position
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_MIDDLE) != 0:
		var raw_delta: Vector2 = event.position - _middle_drag_last
		_middle_drag_last = event.position
		if raw_delta.length() == 0:
			return
		var scaled_delta: Vector2 = PointerGainScript.apply_gain(raw_delta)
		var world_move := pan_to_world(scaled_delta, rotation_degrees.y) * pan_speed * world_scale * 0.01
		global_position.x -= world_move.x
		global_position.z -= world_move.y
		_clamp_to_void()
