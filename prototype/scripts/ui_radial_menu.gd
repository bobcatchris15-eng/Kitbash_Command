class_name UIRadialMenu
extends Control
# A radial action ring that opens on the selected part in the Design Lab.
#
# WHY A RING RATHER THAN A SIDEBAR. Acting on a selected module used to mean
# travelling to the right-hand rail, finding the right row among a dozen
# permanently-visible ones, and clicking it - with the player's eyes leaving
# the model they are editing every single time. The actions are few, fixed and
# mutually exclusive, which is the exact shape a radial menu is for: every
# option is the same distance from the cursor, and after a handful of uses the
# direction becomes muscle memory and the menu stops needing to be read at all.
#
# WHY IT IS DRAWN RATHER THAN ASSEMBLED FROM BUTTONS. This is an instrument
# dial - a machined bezel with an index ring and tick marks. A ring of themed
# Buttons reads as a ring of buttons no matter what StyleBox goes on them, and
# the sector geometry (a wedge, not a rectangle) cannot be expressed as a
# StyleBox at all. Drawing also makes hover and click share one code path:
# both just ask which sector the cursor is in, which is what makes flick
# selection work for free.
#
# TONE. Legends are stencilled equipment labels - ROTATE, MIRROR, DISCARD -
# not friendly verbs, and the hub reads out the part's designation like a
# panel legend. The interface treats a googly kitbashed contraption as
# certified hardware; see scripts/blueprint_namer.gd for the rule in full.
#
# INTERACTION:
#   * Opens centred on the part, and TRACKS it - the ring stays glued to the
#     module as the camera orbits, like the callouts do.
#   * The hub is a dead zone. Releasing there cancels, which is the standard
#     escape hatch for radial menus and the reason the hub has to be large
#     enough to hit without care.
#   * Hovering a sector lights it and names it in the hub.
#   * Esc closes. So does invoking anything.

const Tokens = preload("res://scripts/ui_tokens.gd")
const UIAnim = preload("res://scripts/ui_anim.gd")
const UIIcons = preload("res://scripts/ui_icons.gd")
const RingDraw = preload("res://scripts/ui/ring_draw.gd")
const ModuleVolume = preload("res://scripts/module_volume.gd")

signal action_invoked(action_id: String)
signal action_invoked_button(action_id: String, button_index: int)
signal dismissed()

# Geometry, in pixels at 100% scale.
#
# HUB_RADIUS is deliberately generous. A small dead zone means a player who
# opens the ring and changes their mind has to aim to cancel, and aiming to
# cancel is the single most annoying thing a radial menu can ask for.
const HUB_RADIUS := 28.0
const RING_INNER := 84.0
const RING_OUTER := 128.0
# Padding beyond RING_OUTER for the legend text, which is drawn outside the
# ring so it never fights the tick marks for space.
const LABEL_GAP := 14.0
const CANVAS_PAD := 80.0

const TICK_COUNT := 48
const TICK_LEN_MINOR := 4.0
const TICK_LEN_MAJOR := 8.0

# How far the camera can get before the ring fades out. Matches
# TweakCallout.max_zoom_distance so the two annotation systems disappear
# together rather than one lingering after the other.
var max_zoom_distance: float = 40.0

# The part this ring is acting on. The ring frees itself if it goes away -
# a menu still floating over a deleted module is worse than no menu.
var target_node: Node3D = null

# Shown in the hub when nothing is hovered. The part's designation.
var subject_label: String = ""

var _actions: Array = []          # [{id, label, icon, enabled, auto_close}]
var _satellite_controls: Array[Control] = []
var _hovered: int = -1
var _is_open: bool = false


func _init() -> void:
	# The ring draws well outside its own centre, so it needs real size.
	var span := (RING_OUTER + CANVAS_PAD) * 2.0
	custom_minimum_size = Vector2(span, span)
	size = custom_minimum_size
	pivot_offset = custom_minimum_size * 0.5
	mouse_filter = Control.MOUSE_FILTER_STOP
	# Position is set in terms of the ring's CENTRE by _center_on(); the
	# control's own origin is its top-left, so everything that positions this
	# node goes through that helper rather than setting position directly.


# Registers a satellite outer control (like RadialDial) orbiting the ring
func add_satellite_control(ctrl: Control, angle_rad: float, radius: float = 180.0) -> void:
	_satellite_controls.append(ctrl)
	add_child(ctrl)
	var center := size * 0.5
	var ctrl_pos := center + Vector2(cos(angle_rad), sin(angle_rad)) * radius - ctrl.size * 0.5
	ctrl.position = ctrl_pos


# Registers one wedge. Order is the order they appear, starting at the top and
# going clockwise - the reading order for a dial.
#
# `icon` is a key into UIIcons.ICON_PATHS, or "" for a text-only wedge.
func add_action(id: String, label: String, icon: String = "", enabled: bool = true, auto_close: bool = true) -> void:
	_actions.append({
		"id": id,
		"label": label.to_upper(),
		"icon": icon,
		"enabled": enabled,
		"auto_close": auto_close,
	})
	queue_redraw()


func set_action_label(id: String, new_label: String) -> void:
	for a in _actions:
		if a["id"] == id:
			a["label"] = new_label.to_upper()
			queue_redraw()
			return


func is_open() -> bool:
	return _is_open


# Opens the ring centred on `screen_pos`.
func open_at(screen_pos: Vector2) -> void:
	_is_open = true
	_hovered = -1
	visible = true
	_center_on(screen_pos)
	UIAnim.ring_pop(self)
	queue_redraw()


func close() -> void:
	if not _is_open:
		return
	_is_open = false
	_hovered = -1
	# Free rather than hide. The ring is rebuilt per selection (the action set
	# depends on the part type), so a hidden one left in the tree is just a
	# stale node waiting to be shown with the wrong buttons on it.
	dismissed.emit()
	queue_free()


func _center_on(screen_pos: Vector2) -> void:
	position = screen_pos - size * 0.5


func _ready() -> void:
	# Sit above the callouts. Both live on the same canvas and the ring is the
	# thing being actively aimed at.
	z_index = 10
	if target_node and is_instance_valid(target_node):
		var camera := get_viewport().get_camera_3d()
		if camera:
			var pos_3d := ModuleVolume.center_of_mass_world(target_node)
			_center_on(camera.unproject_position(pos_3d))


func _process(delta: float) -> void:
	if not _is_open:
		return

	# Track the part. Freeing on an invalid target mirrors TweakCallout's
	# behaviour - see its _process() for the same guard.
	if target_node != null and not is_instance_valid(target_node):
		close()
		return

	var camera := get_viewport().get_camera_3d()
	if camera == null or target_node == null:
		return

	var pos_3d := ModuleVolume.center_of_mass_world(target_node)
	if camera.is_position_behind(pos_3d):
		modulate.a = 0.0
		return

	var dist := camera.global_position.distance_to(pos_3d)
	var want_alpha := 0.0 if dist > max_zoom_distance else 1.0
	modulate.a = lerp(modulate.a, want_alpha, 10.0 * delta)

	# Lerp rather than snap so a camera orbit drags the ring smoothly instead
	# of making it judder a frame behind the model.
	var target_pos := camera.unproject_position(pos_3d) - size * 0.5
	position = position.lerp(target_pos, 20.0 * delta)


# Only the annulus belongs to this control. Without this the ring's bounding
# square swallows clicks in its corners - which, at 280px across, is most of
# its area and would make the viewport behind it feel broken.
func _has_point(point: Vector2) -> bool:
	var r := point.distance_to(size * 0.5)
	if r <= RING_OUTER:
		return true
	for sat in _satellite_controls:
		if sat and is_instance_valid(sat) and sat.visible:
			var sat_rect := Rect2(sat.position, sat.size)
			if sat_rect.has_point(point):
				return true
	return false


func _gui_input(event: InputEvent) -> void:
	if not _is_open:
		return

	if event is InputEventMouseMotion:
		var was := _hovered
		_hovered = _sector_at(event.position)
		if was != _hovered:
			queue_redraw()

	elif event is InputEventMouseButton and event.pressed:
		if event.button_index != MOUSE_BUTTON_LEFT and event.button_index != MOUSE_BUTTON_RIGHT:
			return
		accept_event()
		var idx := _sector_at(event.position)
		if idx < 0:
			# Hub or outside: cancel.
			close()
			return
		var action: Dictionary = _actions[idx]
		if not action["enabled"]:
			return
		var id: String = action["id"]
		var should_close: bool = action.get("auto_close", true)
		action_invoked.emit(id)
		action_invoked_button.emit(id, event.button_index)
		if should_close:
			close()
		else:
			queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if not _is_open:
		return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		close()


# Which wedge contains `local_pos`. Returns -1 for the hub dead zone, for
# anything past the outer edge, and when there are no actions.
func _sector_at(local_pos: Vector2) -> int:
	return RingDraw.sector_at(local_pos, size * 0.5, RING_INNER, RING_OUTER, HUB_RADIUS, _actions.size())


# Centre angle of wedge `idx`, in the same frame _sector_at() inverts.
func _sector_angle(idx: int) -> float:
	return RingDraw.sector_angle(idx, _actions.size())


func _draw() -> void:
	var font := get_theme_font("font", "Label")
	if font == null:
		font = ThemeDB.fallback_font
	RingDraw.draw_ring(
		self,
		size * 0.5,
		RING_INNER,
		RING_OUTER,
		HUB_RADIUS,
		_actions,
		_hovered,
		subject_label,
		font
	)

