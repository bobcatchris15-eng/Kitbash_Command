class_name ModuleActionRing
extends Control

# Module action ring & radial tweak console for Design Lab parts manipulation.
# Sized ONCE, at open, to clear the module's projected silhouette - then fixed.
# Combines inner verb wedges with outer clock-face tweak dials. No centre hub
# and no spec plate: the module inspector (bottom-right) already carries the
# designation and stats.

const RingDraw = preload("res://scripts/ui/ring_draw.gd")
const Tokens = preload("res://scripts/ui_tokens.gd")
const UIAnim = preload("res://scripts/ui_anim.gd")
const ModuleVolume = preload("res://scripts/module_volume.gd")
const TweakStations = preload("res://scripts/ui/tweak_stations.gd")

signal action_invoked(action_id: String)
signal dismissed()

const FIXED_INNER_RADIUS := 84.0
const BAND_WIDTH := 44.0
const FIXED_OUTER_RADIUS := FIXED_INNER_RADIUS + BAND_WIDTH  # 128.0
const HUB_RADIUS := 28.0
const STATION_RADIAL_OFFSET := 52.0                          # Station orbit at 180.0
const STATION_TIER_OFFSET := 76.0
const ORBIT_MARGIN := 200.0

var target_node: Node3D = null
var max_zoom_distance: float = 40.0

var inner_radius: float = FIXED_INNER_RADIUS
var outer_radius: float = FIXED_OUTER_RADIUS

var _actions: Array = []  # [{id, label, icon, enabled}]
var _tweak_stations: Array = [] # [{name, label, control, angle, tier}]
var _hovered: int = -1
var _is_open: bool = false
var _target_screen_center: Vector2 = Vector2.ZERO
var _station_container: Control = null


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)
	_station_container = Control.new()
	_station_container.name = "StationContainer"
	_station_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_station_container)
	_update_canvas_size()


func _update_canvas_size() -> void:
	var span := (outer_radius + ORBIT_MARGIN) * 2.0
	custom_minimum_size = Vector2(span, span)
	size = custom_minimum_size
	pivot_offset = custom_minimum_size * 0.5
	if _station_container:
		_station_container.custom_minimum_size = size
		_station_container.size = size


func set_actions(actions: Array) -> void:
	_actions = actions
	queue_redraw()


func add_action(id: String, label: String, icon: String = "", enabled: bool = true) -> void:
	_actions.append({
		"id": id,
		"label": label.to_upper(),
		"icon": icon,
		"enabled": enabled,
	})
	queue_redraw()


func set_action_enabled(id: String, enabled: bool) -> void:
	for a in _actions:
		if a["id"] == id:
			if a["enabled"] != enabled:
				a["enabled"] = enabled
				queue_redraw()
			break


func add_tweak_station(tweak_name: String, label: String, control: Control, p_tier: int = -1) -> void:
	# Sequential claim alternating sides: 12, 1, 11, 2, 10, ... 6 o'clock, so
	# dials fan evenly rather than hugging one side. No tweak owns a position -
	# a dial's place is its authoring order. A thirteenth dial opens a second
	# radial tier back at 12 o'clock (tier = flat index / 12).
	# Optional p_tier overrides automatic tier (e.g., ammo selectors use tier 1
	# to orbit further out and avoid overlapping adjacent dials).
	var n := TweakStations.OUTER_STATIONS.size()
	var slot := _tweak_stations.size()
	var tier: int = p_tier if p_tier >= 0 else (slot / n)
	_tweak_stations.append({
		"name": tweak_name,
		"label": label,
		"control": control,
		"angle": TweakStations.OUTER_STATIONS[slot % n],
		"tier": tier,
	})
	_station_container.add_child(control)
	preload("res://scripts/ui_feedback.gd").wire_tree(control)
	_update_station_positions()


func clear_tweak_stations() -> void:
	for st in _tweak_stations:
		var ctrl: Control = st.get("control")
		if is_instance_valid(ctrl) and ctrl.get_parent() == _station_container:
			ctrl.queue_free()
	_tweak_stations.clear()


func open_for_module(module: Node3D) -> void:
	target_node = module
	_is_open = true
	visible = true
	_update_canvas_size()
	_update_screen_position()
	_update_station_positions()
	UIAnim.ring_pop(self)
	grab_focus()
	_step_action(1)


func close() -> void:
	if not _is_open:
		return
	_is_open = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	_station_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dismissed.emit()
	var tween := create_tween()
	if tween:
		tween.tween_property(self, "scale", Vector2(0.6, 0.6), Tokens.DURATION_FAST)
		tween.parallel().tween_property(self, "modulate:a", 0.0, Tokens.DURATION_FAST)
		tween.tween_callback(queue_free)
	else:
		queue_free()


func _process(delta: float) -> void:
	if not _is_open:
		return
	if not is_instance_valid(target_node) or not target_node.is_inside_tree():
		close()
		return

	_update_screen_position()
	_update_station_positions()


func _get_target_3d_center() -> Vector3:
	if target_node == null or not is_instance_valid(target_node):
		return Vector3.ZERO
	return ModuleVolume.center_of_mass_world(target_node)


func _update_screen_position() -> void:
	if target_node == null or not is_instance_valid(target_node):
		return
	var camera := get_viewport().get_camera_3d()
	if not camera:
		return

	var center_3d := _get_target_3d_center()
	if camera.is_position_behind(center_3d):
		modulate.a = 0.0
		return

	var dist := camera.global_position.distance_to(center_3d)
	if dist > max_zoom_distance:
		modulate.a = 0.0
		return
	else:
		modulate.a = clampf(1.0 - (dist - (max_zoom_distance - 8.0)) / 8.0, 0.0, 1.0)

	_target_screen_center = camera.unproject_position(center_3d)
	position = _target_screen_center - size * 0.5


func _update_station_positions() -> void:
	var center := size * 0.5

	for st in _tweak_stations:
		var ctrl: Control = st.get("control")
		if not is_instance_valid(ctrl):
			continue
		var angle_frac: float = st.get("angle", 0.0)
		# 0.0 is 12 o'clock (-PI/2), clockwise
		var rad := angle_frac * TAU - PI * 0.5
		var dir := Vector2(cos(rad), sin(rad))
		var station_r: float = outer_radius + STATION_RADIAL_OFFSET + float(st.get("tier", 0)) * STATION_TIER_OFFSET
		ctrl.position = center + dir * station_r - ctrl.size * 0.5


func _has_point(point: Vector2) -> bool:
	var offset := point - size * 0.5
	var r := offset.length()
	if r >= inner_radius and r <= outer_radius:
		return true
	
	# Also capture if inside any orbital station control
	for st in _tweak_stations:
		var ctrl: Control = st.get("control")
		if is_instance_valid(ctrl) and ctrl.get_rect().has_point(point):
			return true

	return false


func _gui_input(event: InputEvent) -> void:
	if not _is_open:
		return
	if event.is_action_pressed("ui_right") or event.is_action_pressed("ui_down"):
		_step_action(1)
		accept_event()
		return
	if event.is_action_pressed("ui_left") or event.is_action_pressed("ui_up"):
		_step_action(-1)
		accept_event()
		return
	if event.is_action_pressed("ui_accept"):
		if _hovered >= 0 and _actions[_hovered].get("enabled", true):
			action_invoked.emit(_actions[_hovered]["id"])
		accept_event()
		return
	if event.is_action_pressed("ui_cancel"):
		accept_event()
		close()
		return

	if event is InputEventMouseMotion:
		var prev := _hovered
		_hovered = RingDraw.sector_at(event.position, size * 0.5, inner_radius, outer_radius, HUB_RADIUS, _actions.size())
		if _hovered != prev:
			queue_redraw()
		accept_event()

	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var hit := RingDraw.sector_at(event.position, size * 0.5, inner_radius, outer_radius, HUB_RADIUS, _actions.size())
		if hit >= 0 and hit < _actions.size():
			var action: Dictionary = _actions[hit]
			if action.get("enabled", true):
				action_invoked.emit(action["id"])
				accept_event()


func _unhandled_input(event: InputEvent) -> void:
	if not _is_open:
		return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		close()

func _step_action(direction: int) -> void:
	if _actions.is_empty():
		return
	for i in range(_actions.size()):
		_hovered = posmod(_hovered + direction, _actions.size())
		if _actions[_hovered].get("enabled", true):
			break
	queue_redraw()


func _draw() -> void:
	var font := get_theme_font("font", "Label")
	if font == null:
		font = ThemeDB.fallback_font
	
	var center := size * 0.5
	if has_focus():
		draw_arc(center, outer_radius + 4.0, 0, TAU, 96, Tokens.TEXT_PRIMARY, 2.0, true)
	
	# Draw spoke connector lines to active tweak stations
	for st in _tweak_stations:
		var ctrl: Control = st.get("control")
		if not is_instance_valid(ctrl):
			continue
		var angle_frac: float = st.get("angle", 0.0)
		var rad := angle_frac * TAU - PI * 0.5
		var dir := Vector2(cos(rad), sin(rad))
		var station_r: float = outer_radius + STATION_RADIAL_OFFSET + float(st.get("tier", 0)) * STATION_TIER_OFFSET
		var p_ring := center + dir * outer_radius
		var p_station := center + dir * (station_r - 8.0)
		draw_line(p_ring, p_station, Color(Tokens.BASE_600, 0.7), 1.0, true)
		# Spoke node dot on outer bezel
		draw_circle(p_ring, 2.5, Tokens.SIGNAL_HAZARD)

	RingDraw.draw_ring(
		self,
		center,
		inner_radius,
		outer_radius,
		HUB_RADIUS,
		_actions,
		_hovered,
		"",
		font,
		false
	)
