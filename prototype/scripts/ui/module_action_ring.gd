class_name ModuleActionRing
extends Control

# Module action ring & radial tweak console for Design Lab parts manipulation.
# Sized ONCE, at open, to clear the module's projected silhouette - then fixed.
# Combines inner verb wedges with outer clock-face tweak stations and a docked 6:00 spec plate.

const RingDraw = preload("res://scripts/ui/ring_draw.gd")
const Tokens = preload("res://scripts/ui_tokens.gd")
const UIAnim = preload("res://scripts/ui_anim.gd")
const ModuleVolume = preload("res://scripts/module_volume.gd")
const TweakStations = preload("res://scripts/ui/tweak_stations.gd")

signal action_invoked(action_id: String)
signal dismissed()

const MIN_INNER_RADIUS := 42.0
const MAX_INNER_RADIUS := 400.0
const BAND_WIDTH := 44.0
const CLEARANCE_MARGIN := 16.0
const HUB_RADIUS := 28.0
const STATION_RADIAL_OFFSET := 56.0
# Radial gap between stacked stations that share a clock angle. A dial is 72 px
# tall including its caption badge, so one step clears the tier below.
const STATION_TIER_OFFSET := 76.0
# Canvas slack beyond the ring: must fit the station orbit plus two overflow
# tiers plus half a station control (56 + 2*76 + ~40).
const ORBIT_MARGIN := 250.0

var target_node: Node3D = null
var subject_label: String = ""
var spec_stats_text: String = ""
var max_zoom_distance: float = 40.0

var inner_radius: float = MIN_INNER_RADIUS
var outer_radius: float = MIN_INNER_RADIUS + BAND_WIDTH

var _actions: Array = []  # [{id, label, icon, enabled}]
var _tweak_stations: Array = [] # [{name, label, control, angle, tier}]
var _hovered: int = -1
var _is_open: bool = false
var _target_screen_center: Vector2 = Vector2.ZERO
var _station_container: Control = null
var _spec_card: PanelContainer = null


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
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


func add_tweak_station(tweak_name: String, label: String, control: Control, angle: float = -1.0) -> void:
	if angle < 0.0:
		angle = TweakStations.angle_for(tweak_name)
		if angle < 0.0:
			angle = TweakStations.CLOCK_1

	# Station claim order: the tweak's canonical clock angle when free, then
	# the nearest free FIRST-LAYER station (the eight outer-band clocks), then
	# - only once all eight are taken - a new outward tier stacked over the
	# canonical angle. Two of one module's tweaks can share an angle (the
	# rotary cannon's Barrel Count and Motor Size both live at 11 o'clock);
	# the ring used to build outward immediately, leaving half the first
	# layer empty while a second dial orbited out past it.
	var claimed := {}
	for st in _tweak_stations:
		var a := float(st.get("angle", -1.0))
		claimed[a] = int(claimed.get(a, 0)) + 1

	var tier := 0
	if claimed.has(angle):
		var best_dist := INF
		var free_angle := -1.0
		for cand: float in TweakStations.OUTER_STATIONS:
			if claimed.has(cand):
				continue
			var dist := absf(cand - angle)
			dist = minf(dist, 1.0 - dist)
			if dist < best_dist:
				best_dist = dist
				free_angle = cand
		if free_angle >= 0.0:
			angle = free_angle
		else:
			# All eight first-layer stations taken: build outward.
			tier = int(claimed.get(angle, 0))

	_tweak_stations.append({
		"name": tweak_name,
		"label": label,
		"control": control,
		"angle": angle,
		"tier": tier,
	})
	_station_container.add_child(control)
	_update_station_positions()


func clear_tweak_stations() -> void:
	for st in _tweak_stations:
		var ctrl: Control = st.get("control")
		if is_instance_valid(ctrl) and ctrl.get_parent() == _station_container:
			ctrl.queue_free()
	_tweak_stations.clear()


func set_spec_info(stats_text: String) -> void:
	spec_stats_text = stats_text
	_update_spec_card()


func _update_spec_card() -> void:
	if spec_stats_text == "":
		if is_instance_valid(_spec_card):
			_spec_card.visible = false
		return
	
	if _spec_card == null or not is_instance_valid(_spec_card):
		_spec_card = PanelContainer.new()
		_spec_card.name = "SpecPlate"
		_spec_card.theme_type_variation = "CalloutPanel"
		_station_container.add_child(_spec_card)
		
		var vbox = VBoxContainer.new()
		vbox.add_theme_constant_override("separation", 2)
		_spec_card.add_child(vbox)
		
		var title_lbl = Label.new()
		title_lbl.name = "TitleLabel"
		title_lbl.theme_type_variation = "HintLabel"
		vbox.add_child(title_lbl)
		
		var stats_lbl = Label.new()
		stats_lbl.name = "StatsLabel"
		stats_lbl.theme_type_variation = "HUDValueLabel"
		vbox.add_child(stats_lbl)
	
	_spec_card.visible = true
	var title_lbl = _spec_card.find_child("TitleLabel", true, false) as Label
	if title_lbl:
		title_lbl.text = subject_label
	var stats_lbl = _spec_card.find_child("StatsLabel", true, false) as Label
	if stats_lbl:
		stats_lbl.text = spec_stats_text


func open_for_module(module: Node3D, label_text: String = "") -> void:
	target_node = module
	subject_label = label_text
	_is_open = true
	visible = true
	_size_to_module()
	_update_screen_position()
	_update_station_positions()
	UIAnim.ring_pop(self)


func close() -> void:
	if not _is_open:
		return
	_is_open = false
	dismissed.emit()
	var tween := create_tween()
	if tween:
		tween.tween_property(self, "scale", Vector2(0.6, 0.6), 0.1)
		tween.parallel().tween_property(self, "modulate:a", 0.0, 0.1)
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


# Measured once when the ring opens: the hole clears the module it was opened
# on, and the geometry stays put from then on. The ring used to re-project the
# module's silhouette every frame and breathe with camera zoom, which shrank
# and grew the station orbit under a player's cursor mid-drag.
func _size_to_module() -> void:
	if target_node == null or not is_instance_valid(target_node):
		return
	var camera := get_viewport().get_camera_3d()
	if not camera or camera.is_position_behind(target_node.global_position):
		return

	var half_diag := _compute_projected_half_diagonal(camera, target_node)
	var vp_size: Vector2 = get_viewport().get_visible_rect().size
	var viewport_cap: float = minf(vp_size.x, vp_size.y) * 0.40
	inner_radius = clampf(half_diag + CLEARANCE_MARGIN, MIN_INNER_RADIUS, minf(MAX_INNER_RADIUS, viewport_cap))

	outer_radius = inner_radius + BAND_WIDTH
	_update_canvas_size()
	queue_redraw()


func _compute_projected_half_diagonal(camera: Camera3D, node: Node3D) -> float:
	var aabb: AABB = ModuleVolume.bounds(node)
	if aabb.size == Vector3.ZERO:
		aabb = AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)

	var center_3d: Vector3 = node.global_position
	var center_2d: Vector2 = camera.unproject_position(center_3d)

	var max_dist: float = MIN_INNER_RADIUS
	var corners := _aabb_corners(aabb)
	for c in corners:
		var world_pos: Vector3 = node.global_transform * c
		if not camera.is_position_behind(world_pos):
			var screen_pos: Vector2 = camera.unproject_position(world_pos)
			var d := (screen_pos - center_2d).length()
			if d > max_dist:
				max_dist = d

	var box_list: Array = ModuleVolume.boxes(node)
	if box_list.size() > 1:
		for box in box_list:
			var c: Vector3 = box.get("c", Vector3.ZERO)
			var h0: Vector3 = box.get("h0", Vector3.ZERO)
			var h1: Vector3 = box.get("h1", Vector3.ZERO)
			var h2: Vector3 = box.get("h2", Vector3.ZERO)
			for sx in [-1.0, 1.0]:
				for sy in [-1.0, 1.0]:
					for sz in [-1.0, 1.0]:
						var local_pt: Vector3 = c + h0 * sx + h1 * sy + h2 * sz
						var world_pos: Vector3 = node.global_transform * local_pt
						if not camera.is_position_behind(world_pos):
							var screen_pos: Vector2 = camera.unproject_position(world_pos)
							var d := (screen_pos - center_2d).length()
							if d > max_dist:
								max_dist = d

	return max_dist


static func _aabb_corners(aabb: AABB) -> Array:
	return [
		Vector3(aabb.position.x, aabb.position.y, aabb.position.z),
		Vector3(aabb.end.x, aabb.position.y, aabb.position.z),
		Vector3(aabb.position.x, aabb.end.y, aabb.position.z),
		Vector3(aabb.position.x, aabb.position.y, aabb.end.z),
		Vector3(aabb.end.x, aabb.end.y, aabb.position.z),
		Vector3(aabb.end.x, aabb.position.y, aabb.end.z),
		Vector3(aabb.position.x, aabb.end.y, aabb.end.z),
		Vector3(aabb.end.x, aabb.end.y, aabb.end.z),
	]


func _update_screen_position() -> void:
	if target_node == null or not is_instance_valid(target_node):
		return
	var camera := get_viewport().get_camera_3d()
	if not camera:
		return

	var dist := camera.global_position.distance_to(target_node.global_position)
	if dist > max_zoom_distance or camera.is_position_behind(target_node.global_position):
		modulate.a = 0.0
		return
	else:
		modulate.a = clampf(1.0 - (dist - (max_zoom_distance - 8.0)) / 8.0, 0.0, 1.0)

	_target_screen_center = camera.unproject_position(target_node.global_position)
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

	if is_instance_valid(_spec_card) and _spec_card.visible:
		# Docked at 6:00 (bottom)
		var spec_pos := center + Vector2(-_spec_card.size.x * 0.5, outer_radius + 18.0)
		_spec_card.position = spec_pos


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
	
	if is_instance_valid(_spec_card) and _spec_card.visible and _spec_card.get_rect().has_point(point):
		return true

	return false


func _gui_input(event: InputEvent) -> void:
	if not _is_open:
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


func _draw() -> void:
	var font := get_theme_font("font", "Label")
	if font == null:
		font = ThemeDB.fallback_font
	
	var center := size * 0.5
	
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
		subject_label if (_spec_card == null or not _spec_card.visible) else "",
		font
	)
