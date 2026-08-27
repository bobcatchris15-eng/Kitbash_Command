extends Camera3D
# Classic RTS camera: WASD/arrow pan (yaw-relative), Q/E rotate, mouse-wheel
# zoom, middle-mouse drag pan. Reads InputService's cam_* actions rather than
# raw keycodes - see scripts/core/input_service.gd's header for why.
#
# DOF (re-enabled): tilt-shift depth-of-field band — the miniature lens feel
# from CORE_DESIGN_LANGUAGE §2. Tilt-shift was killed 2026-08-10 due to a 3 FPS
# regression (never recovered) caused by two things:
#   1. The full-screen DOF post-process pass (Godot rendering cost — unavoidable)
#   2. Writing CameraAttributesPractical properties every frame from _process()
#
# Fix for #2: DOF distances are updated ONLY in _on_zoom(), not every frame.
# That cuts per-frame writes to zero unless the user is actively scrolling.
# The full-screen pass cost remains; kept conservative (0.06, far-blur only) so
# the battle scene stays in budget. Initialise from the scene's
# CameraAttributesPractical sub_resource if present, otherwise leave null so
# the DOF wiring becomes a no-op on scenes that don't have it.

@export var pan_speed: float = 30.0
# Multiplicative zoom: each wheel notch multiplies the camera height by this
# ratio rather than adding a fixed number of metres. The old additive step
# (zoom_speed * world_scale metres) meant one notch jumped ~32 m on a
# world_scale=4 map across a 10..160 range - about five notches for the whole
# sweep, with the bottom notch launching straight off the ground. A ratio step
# is small in metres near the floor where framing precision matters and grows
# with distance out where coverage matters, and is inherently scale-free: the
# same perceived zoom-per-notch at any world_scale, so unlike the additive
# version it must NOT be multiplied by world_scale here (pan speed below still
# tracks world_scale for traversal).
@export var zoom_step: float = 1.15
@export var rotate_speed: float = 90.0
# Narrow FOV (25°) gives near-orthographic framing while preserving rotation
# and subtle depth cueing. The old 70° showed too much sky/horizon. A narrow
# perspective FOV is the standard RTS compromise — StarCraft 2 uses ~30°.
@export var gameplay_fov: float = 25.0
@export var min_height: float = 20.0
# Skirmish refinement pass: maps grew to ~3x their original size (see
# map_catalog.gd - two scale-up passes, 1.5x then another 2x after the
# first still read as too small) and the old 45-unit cap meant you could
# never zoom out far enough to see a meaningful fraction of even the
# smallest map. Pan speed already scales with height (see _process()
# below), so raising this doesn't make traversal at max zoom-out feel
# sluggish.
@export var max_height: float = 160.0

# VISUAL_AND_UX_POLISH_PLAN.md B1: edge-scroll + zoom-to-cursor - both core
# RTS camera expectations this project had neither of. Edge margin in real
# pixels (viewport-space, not logical/stretched) - kept modest so it
# doesn't trigger from a build-bar click a few pixels off the bottom edge.
@export var edge_scroll_margin: float = 18.0

# CORE_DESIGN_LANGUAGE.md §3.2: scales pan speed and middle-drag, so
# traversing a map that's now genuinely bigger under world_scale doesn't
# get proportionally slower via keyboard/edge-scroll/middle-drag - long
# cross-map travel time is the accepted design (§3.2's own "accept long
# traversal" call), but getting there shouldn't fight the input itself.
# Set by whichever runtime loads the map (match_director.gd) - defaults to
# 1.0 so a camera with nothing setting it behaves exactly as before.
var world_scale: float = 1.0

var height: float = 26.0

# CameraAttributesPractical reference. Initialised from the scene sub_resource
# if the scene wired one (Battle.tscn does). Left null if not, so all DOF
# helpers become safe no-ops.
var _cam_attributes: CameraAttributesPractical = null


func _ready():
	height = clamp(global_position.y, min_height, max_height)
	_apply_pitch()
	# Apply narrow gameplay FOV — the scene's default is the old 70°; this
	# overrides it on load so every scene gets the tight framing.
	fov = gameplay_fov
	# Grab the scene's CameraAttributesPractical if one is wired. This avoids
	# creating a new DOF cost in scenes that don't have it configured.
	if attributes != null and attributes is CameraAttributesPractical:
		_cam_attributes = attributes
		_apply_dof_distances()


func _apply_pitch():
	# Narrow FOV benefits from a slightly steeper angle than the old 70°
	# default, but too steep flattens the depth layering and makes terrain
	# greebling vanish. Split the difference: -45 (close) to -62 (far).
	var t = (height - min_height) / (max_height - min_height)
	rotation_degrees.x = lerp(-45.0, -62.0, t)


# Updates the tilt-shift far blur to track the ground at a wide band.
# Called ONLY on zoom events — never in _process(). Far blur only: near blur
# on a panning RTS camera produces a double-blur artifact that reads as a
# lens scratch rather than depth.
#
# VISUAL polish 2026-08-23: tilt-shift lightened a lot. The previous
# (height + 30.0) / lerp(10..50) values put the focus band right at the
# playable area and made the soft falloff quite wide, which read as
# "everything past the front units is mush" at tactical zoom. Pushed
# the band well past the visible map (height + 150) and narrowed the
# transition (lerp 3..12) so the effect is a subtle hint of falloff at
# the far horizon rather than a band across the play area. If even this
# is too much, set dof_blur_far_enabled = false on the CameraAttributes
# in Battle.tscn and the camera's writes here become no-ops.
func _apply_dof_distances():
	if _cam_attributes == null:
		return
	# Ground level is always near world origin in Kitbash Command.
	# Focus on the ground plane; the far blur fades everything above it.
	_cam_attributes.dof_blur_far_distance = height + 150.0
	# Transition width: wider at max zoom so the band is legible at distance,
	# narrower when close so the units at mid-height stay sharp.
	var t = (height - min_height) / (max_height - min_height)
	_cam_attributes.dof_blur_far_transition = lerp(3.0, 12.0, t)


# Pure function (no Input/viewport reads) so it's directly testable headless -
# given where the mouse sits relative to the viewport and the margin, which
# way (if any) should the camera pan. Returns a possibly-diagonal, NOT
# normalized direction (matches keyboard pan's own union-then-normalize
# below - a corner shouldn't scroll faster than an edge).
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


# Yaw-relative pan: keyboard input is camera-relative, but world movement is
# axis-aligned. Maps a screen direction back to a world direction by rotating
# the input by the camera's current yaw so WASD always means "forward in the
# view", regardless of where the camera is pointed.
static func pan_to_world(input: Vector2, yaw_deg: float) -> Vector2:
	var yaw := deg_to_rad(yaw_deg)
	var sin_y := sin(yaw)
	var cos_y := cos(yaw)
	return Vector2(
		input.x * cos_y + input.y * sin_y,
		-input.x * sin_y + input.y * cos_y
	)


# Returns a unit direction (0,0 when nothing to do) for the camera to scroll
# toward given the current mouse position and viewport size. Pulled into a
# pure function so test_rts_camera.gd can pin the four-quadrant + corner
# behaviour without instantiating a Camera3D.
static func compute_movement(
	keyboard: Vector2, mouse_pos: Vector2, viewport_size: Vector2, margin: float,
	window_has_focus: bool
) -> Vector2:
	var move := keyboard
	if window_has_focus:
		move += compute_edge_scroll_direction(mouse_pos, viewport_size, margin)
	return move


# Yaw-up vector of a Camera3D pitched by `pitch_deg` - same algebra as
# designer_camera.gd's, kept here so the ground-stick offset this camera
# computes for ray-plane hit math doesn't depend on Godot's transform
# pipeline re-running mid-call.
static func compute_yaw_up(pitch_deg: float) -> Vector3:
	return Vector3(0.0, sin(deg_to_rad(pitch_deg)), cos(deg_to_rad(pitch_deg)))


func _process(delta):
	var move := Input.get_vector("cam_pan_left", "cam_pan_right", "cam_pan_up", "cam_pan_down")

	# Edge-scroll only while the window actually has input focus - otherwise
	# a mouse merely sitting near the edge of an unfocused window (e.g. this
	# game running behind another one) would silently drag the camera.
	if is_inside_tree() and get_window() and get_window().has_focus():
		var vp = get_viewport()
		var edge_dir = compute_edge_scroll_direction(vp.get_mouse_position(), vp.get_visible_rect().size, edge_scroll_margin)
		move += edge_dir

	if Input.is_action_pressed("cam_rotate_left"): rotation_degrees.y += rotate_speed * delta
	if Input.is_action_pressed("cam_rotate_right"): rotation_degrees.y -= rotate_speed * delta
	if Input.is_action_just_pressed("cam_reset_rotation"): rotation_degrees.y = 0.0

	if move != Vector2.ZERO:
		move = move.normalized() * pan_speed * world_scale * delta * (height / 26.0)
		var world_move := pan_to_world(move, rotation_degrees.y)
		global_position.x += world_move.x
		global_position.z += world_move.y

	global_position.y = lerp(global_position.y, height, 10.0 * delta)


# VISUAL_AND_UX_POLISH_PLAN.md B1: where the mouse ray hits a flat plane at
# world Y=`plane_y` - the same "flat ground" approximation skirmish.gd's own
# _raycast_ground() effectively assumes for cursor-driven placement/orders.
# A pure function of the camera's own transform + a screen point, so it's
# testable without a real physics world (no CollisionShape3D needed to hit).
func ray_plane_hit(screen_pos: Vector2, plane_y: float = 0.0):
	var origin = project_ray_origin(screen_pos)
	var dir = project_ray_normal(screen_pos)
	if abs(dir.y) < 0.0001:
		return null
	var t = (plane_y - origin.y) / dir.y
	if t < 0.0:
		return null
	return origin + dir * t


# Zoom-to-cursor: keep the world point under the cursor at the same screen
# position before and after the height change. Done by ray-plane hitting
# before and after and shifting the camera by the world delta.
#
# `notches` is a signed wheel-notch count: each notch scales the height by
# zoom_step (see its comment above for why this replaced the additive step).
func _on_zoom(screen_pos: Vector2, notches: float):
	height = clamp(height * pow(zoom_step, notches), min_height, max_height)
	_apply_pitch()
	_apply_dof_distances()
	var before = ray_plane_hit(screen_pos)
	# Snap y to the new target before the second hit so the after-raycast
	# is measured against the camera's REAL post-zoom transform, not a
	# stale one mid-lerp.
	global_position.y = height
	var after = ray_plane_hit(screen_pos)
	if before != null and after != null:
		global_position.x += before.x - after.x
		global_position.z += before.z - after.z


const PointerGainScript = preload("res://scripts/core/pointer_gain.gd")

var _middle_drag_origin: Vector2 = Vector2.ZERO
var _middle_drag_last: Vector2 = Vector2.ZERO


func _unhandled_input(event):
	if event.is_action_pressed("cam_zoom_in"):
		_on_zoom(get_viewport().get_mouse_position(), -1.0)
	elif event.is_action_pressed("cam_zoom_out"):
		_on_zoom(get_viewport().get_mouse_position(), 1.0)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			_middle_drag_origin = event.position
			_middle_drag_last = event.position
	elif event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
		var raw_delta: Vector2 = event.position - _middle_drag_last
		_middle_drag_last = event.position
		if raw_delta.length() == 0:
			return
		var scaled_delta: Vector2 = PointerGainScript.apply_gain(raw_delta)
		var world_move := pan_to_world(scaled_delta, rotation_degrees.y) * pan_speed * world_scale * 0.01
		global_position.x -= world_move.x
		global_position.z -= world_move.y
