extends Camera3D
# A follow camera for single-unit modes (Test Range). Differs from the
# RTS camera in rts_camera.gd on every dimension that matters:
#
#   * ONE subject, not a swarm. Tracks a single Node3D whose name the
#     match director knows about (`focus_unit`); never reads the group.
#   * Off-axis. A camera that sits on the unit's centre is invisible to
#     the player (a unit looking at its own antennae). Offset back and
#     up by a fixed mount so the player can SEE the unit, not be the unit.
#   * Smooth follow. Lags the unit by a fraction of remaining distance
#     per tick, not per-pixel; a unit that snaps (spawns, gets a
#     re-path) takes the camera with it smoothly, no jitter.
#   * Orbit + zoom input (right-mouse drag, mouse wheel). The first
#     Phase 3 cut had no input at all on the assumption that "the
#     player is driving their unit with mouse clicks; the camera does
#     not intercept anything" - but a chase camera the player cannot
#     rotate leaves them looking at the unit's left flank forever,
#     and that was the report that came back from the first hand-test
#     of the unified Test Range.
#
# Mount is in WORLD space rather than a parented child of the subject,
# on purpose. A parented child inherits the unit's orientation, which
# for a unit that yaws continuously to track a moving target means a
# camera that is right behind the unit's tail one second and the
# unit's wing the next. World-space mount keeps the frame stable at
# the cost of not auto-rotating with the unit, and a stable frame is
# what the player needs to read the field.
#
# NOT a portrait camera (no cinematic framing, no shake). Just a
# follow rig with orbit + zoom.
class_name ChaseCamera3D

# Default mount, used the first frame the subject shows up. The unit
# is roughly 3m wide, so 14 back + 7 up keeps the whole vehicle in
# frame at a 60° fov with the front 3/4 visible - what the player's
# "give me the room" instinct expects, not the locked-on third-person
# shooters that crop the nose.
const DEFAULT_MOUNT_OFFSET := Vector3(0.0, 7.0, 14.0)

# How far the camera can zoom out and in from the default. 6m is
# close enough to read a weapon's muzzle flash; 30m is far enough to
# pick out a quarry across the playtest field. The wheel step is
# MOUNT_ZOOM_STEP metres.
const MOUNT_OFFSET_MIN: float = 6.0
const MOUNT_OFFSET_MAX: float = 30.0
const MOUNT_ZOOM_STEP: float = 2.0

# Orbit input. Pixels per radian: how much the mouse needs to move to
# swing the camera 1 radian (~57°). 800 is what feels "right" on a
# 1080p screen - a wrist-sized drag covers the full orbit. Yaw is
# unbounded; pitch is clamped to MOUNT_PITCH_RANGE so the player
# can't drive the camera into the floor or over the unit's head.
const ORBIT_PIXELS_PER_RADIAN: float = 800.0
const MOUNT_PITCH_MIN: float = -1.2  # ~-69°, looking down hard
const MOUNT_PITCH_MAX: float = -0.05  # just below horizontal, not over the top

# How fast the camera closes on the target's position. Per-tick, not
# per-pixel. 0..1, where 1.0 is a hard follow (the camera teleports
# with the unit, which is what you DON'T want) and 0.0 is a drift
# (the camera never catches up, which is also what you don't want).
# 0.06 is what feels "right" at 60 Hz - the unit leads by about a
# quarter-second at full speed, so a moving target is in the frame
# before it stops, and a stopped target settles in ~0.7s without
# overshoot.
const FOLLOW_SMOOTHING := 0.06

# The subject. Set by the match director (or a test) after the camera
# mounts; null = no subject, the camera sits at the world origin and
# does nothing.
var focus_unit: Node3D = null

# Orbit state. Yaw is in radians around world up, pitch is the
# angle above the horizontal plane (negative = looking down at the
# subject). The mount is computed from these plus the configured
# MOUNT_OFFSET distance each frame.
var _yaw: float = 0.0
var _pitch: float = -0.4  # default look-down ~-23°; matches MOUNT_OFFSET (7 up, 14 back)

# The orbit distance from the focus_unit. Drives the size of the
# subject on screen. Default is the magnitude of DEFAULT_MOUNT_OFFSET
# so a camera that has never been zoomed still frames the unit well.
var _distance: float = 16.55  # sqrt(7^2 + 14^2), keeps first-frame framing identical

# Right-mouse drag state. We need the click position to compute the
# delta; release ends the drag.
var _dragging: bool = false

# Where the camera WANTS to be. Computed from focus_unit + orbit
# mount each tick; the smoothing moves `global_position` toward this.
var _target_position: Vector3 = Vector3.ZERO

# Have we computed a target_position at least once? On the first tick
# the camera snaps to the target rather than lerping from wherever the
# scene put it - "spawn into the world next to my unit" is the
# correct mental model, not "spawn behind the camera and chase for
# half a second to catch up."
var _initialized: bool = false

var _map_half: Vector2 = Vector2.ZERO
var _clamp_enabled: bool = false
const CHASE_VOID_MARGIN: float = 6.0

func set_map_bounds(half: Vector2) -> void:
	_map_half = half
	_clamp_enabled = half.x > 0.0 and half.y > 0.0

func _clamp_target(pos: Vector3) -> Vector3:
	if not _clamp_enabled:
		return pos
	var lim_x: float = _map_half.x + CHASE_VOID_MARGIN
	var lim_z: float = _map_half.y + CHASE_VOID_MARGIN
	pos.x = clampf(pos.x, -lim_x, lim_x)
	pos.z = clampf(pos.z, -lim_z, lim_z)
	return pos


func _unhandled_input(event: InputEvent) -> void:
	if focus_unit == null or not is_instance_valid(focus_unit):
		return
	# Right-mouse drag rotates the orbit. Left-mouse is reserved for
	# the match director's selection / move-order pipeline.
	#
	# NO set_input_as_handled() here. The match director also reads
	# the same mouse events to disambiguate "right-click for a move
	# order" from "right-click + drag for camera orbit" - if the
	# chase camera marked the events as handled, the match director
	# would not see the release that fires the move order. The two
	# cooperate via state flags on either side, not via event
	# suppression.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_dragging = event.pressed
		return
	if _dragging and event is InputEventMouseMotion:
		_yaw -= event.relative.x / ORBIT_PIXELS_PER_RADIAN
		_pitch = clamp(_pitch - event.relative.y / ORBIT_PIXELS_PER_RADIAN,
			MOUNT_PITCH_MIN, MOUNT_PITCH_MAX)
		return
	# Mouse wheel zooms. Each notch is MOUNT_ZOOM_STEP metres; clamped
	# at the bounds so the player cannot fly inside the unit or out
	# to the moon.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_WHEEL_UP \
			and event.pressed:
		_distance = clamp(_distance - MOUNT_ZOOM_STEP, MOUNT_OFFSET_MIN, MOUNT_OFFSET_MAX)
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_WHEEL_DOWN \
			and event.pressed:
		_distance = clamp(_distance + MOUNT_ZOOM_STEP, MOUNT_OFFSET_MIN, MOUNT_OFFSET_MAX)
		return


func _process(delta: float) -> void:
	if focus_unit == null or not is_instance_valid(focus_unit):
		return
	var sp := _spherical_to_cartesian(_yaw, _pitch, _distance)
	_target_position = focus_unit.global_position + sp
	_target_position = _clamp_target(_target_position)
	if not _initialized:
		global_position = _target_position
		_initialized = true
	else:
		global_position = global_position.lerp(_target_position, FOLLOW_SMOOTHING)
		global_position = _clamp_target(global_position)
	# Always look at the subject's centre, so as the unit moves the
	# camera also reorients. lerp at FOLLOW_SMOOTHING would feel laggy
	# on a fast yaw, so this is a hard look_at - the camera is
	# allowed to snap its facing because the rig body is smooth.
	look_at(focus_unit.global_position, Vector3.UP)


# Spherical -> cartesian. Yaw 0 + pitch 0 puts the camera straight
# above the subject looking straight down; yaw 0 + pitch -PI/2 puts
# it level with the subject on +Z. A negative pitch = look down
# (camera above the subject), which is what a "look at the unit
# from above and behind" rig needs.
func _spherical_to_cartesian(yaw: float, pitch: float, r: float) -> Vector3:
	var cy: float = cos(yaw)
	var sy: float = sin(yaw)
	var cp: float = cos(pitch)
	var sp: float = sin(pitch)
	return Vector3(sy * cp, -sp, cy * cp) * r

