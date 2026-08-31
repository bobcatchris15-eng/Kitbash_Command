class_name HUDRoot
extends Control
# The battle HUD. All of it.
#
# WHAT THIS REPLACES. Eleven scripts under scripts/battle/hud/ arranged as two
# parallel trees that were both alive at once:
#
#   battle_hud.gd  -> command_console.gd -> desk_instrument_bar.gd
#                                        -> production_tab_bar.gd
#                                        -> production_drawer.gd
#                                        -> context_drawer.gd
#                                        -> intel_feed.gd
#                                        -> minimap_overlay.gd
#                  -> minimap_overlay.gd   (a second one)
#                  -> (its own inlined copy of the whole minimap)
#   production_hud.gd                      (a second production interface)
#   selection_panel.gd / right_rail.gd     (a third and fourth selection panel)
#
# Two production interfaces on screen simultaneously, three minimap
# implementations of which two composited fog and uploaded a texture every tick,
# and four panels between them competing for the same corner. Every one of those
# files read the simulation correctly; the problem was that there were several of
# each and no single owner of layout.
#
# THE RULE HERE: exactly one instance of each region, one refresh clock, and
# layout in one place. A new panel goes in _build_layout() or it does not exist.
#
# MOUSE FILTERING. This root is IGNORE, so a click that is not on a panel falls
# straight through to match_director's world picking. Each region sets STOP for
# itself. Getting this backwards is how a HUD ends up eating orders near the
# bottom of the screen.

const Style = preload("res://scripts/hud/hud_style.gd")
const Minimap = preload("res://scripts/hud/hud_minimap.gd")
const Ribbon = preload("res://scripts/hud/hud_resource_ribbon.gd")
const Deck = preload("res://scripts/hud/hud_production_deck.gd")
const CommandCard = preload("res://scripts/hud/hud_command_card.gd")
const AlertLog = preload("res://scripts/hud/hud_alert_log.gd")
const BuildingCatalog = preload("res://scripts/battle/economy/building_catalog.gd")

# Refresh periods. Separate because the cost and the perceptual requirement
# differ by an order of magnitude between regions: the map's frustum has to track
# a panning camera, a queue ETA does not.
const MAP_PERIOD := 0.05      # 20 Hz - frustum tracks the camera
const PANEL_PERIOD := 0.2     # 5 Hz  - progress bars, health, ETAs

const HINT_LIFETIME := 5.0

# The HUD never gets wider than this, however wide the window is. 1920 is the
# design width - the layout was proportioned for it - so on an ultrawide the HUD
# stays a centred 1920 block and the extra pixels become battlefield.
const COLUMN_MAX_WIDTH := 1920.0

# Height reserved at the top-right of the column for the session menu, which
# match_director parents in via attach_to_column(). The alert log starts below
# it. Declared here rather than in admin_menu.gd because this file owns layout.
const MENU_STRIP_HEIGHT := 28.0

var minimap: HUDMinimap = null
var ribbon: HUDResourceRibbon = null
var deck: HUDProductionDeck = null
var command_card: HUDCommandCard = null
var alert_log: HUDAlertLog = null
var hint_label: Label = null
# The centred, width-capped container every region is parented to. Public so
# match_director can hang the session menu and the debug overlay inside the same
# column rather than against the raw viewport edge.
var column: Control = null

var _director: Node = null
var _local_team: int = 0
var _band: HBoxContainer = null
var _hint_panel: Panel = null
var _hint_age: float = 0.0

var _hover_tooltip: PanelContainer = null
var _hover_tooltip_title: Label = null
var _hover_tooltip_subtitle: Label = null

var _map_accum: float = 0.0
var _panel_accum: float = 0.0


func _init() -> void:
	name = "HUDRoot"
	# TOP_LEFT with an explicit size, not FULL_RECT. On a CanvasLayer the parent
	# has no rect, so FULL_RECT's unequal anchors make Godot recompute size from
	# a zero-sized parent after _ready() and the whole HUD collapses. This is the
	# same trap production_hud.gd documented; the fix is the same.
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_layout()


func _build_layout() -> void:
	# --- The column ---
	#
	# EVERY REGION LIVES INSIDE THIS, NOT INSIDE THE VIEWPORT. The column is the
	# viewport width capped at COLUMN_MAX_WIDTH and centred, so on a 1920-wide
	# screen it is the whole screen and on anything wider it is a centred 1920 with
	# a symmetric gutter either side. Widen the monitor and the gutter grows; the
	# HUD does not.
	#
	# The alternative - anchoring each region to the viewport edges - is what the
	# first cut did, and on a 2669 px window it put the production deck at 2093 px
	# wide with the resource ribbon and the alert log a metre of screen apart. An
	# RTS HUD is read as one instrument cluster; spreading it to the corners of an
	# ultrawide makes the player track three separate places at once.
	column = Control.new()
	column.name = "Column"
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(column)

	# --- Top-left: resource ribbon ---
	ribbon = Ribbon.new()
	ribbon.set_anchors_preset(Control.PRESET_TOP_LEFT)
	ribbon.offset_left = Style.SP_MD
	ribbon.offset_top = Style.SP_MD
	# 372, measured off the content: the readouts, icons and three dividers come
	# to about 350 and 460 left a visible strip of empty panel past the clock.
	ribbon.offset_right = Style.SP_MD + 372
	ribbon.offset_bottom = Style.SP_MD + Style.RIBBON_HEIGHT
	column.add_child(ribbon)

	# --- Top-right: alert log, below wherever the session menu sits ---
	alert_log = AlertLog.new()
	alert_log.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	alert_log.offset_left = -(300 + Style.SP_MD)
	alert_log.offset_right = -Style.SP_MD
	alert_log.offset_top = Style.SP_MD + MENU_STRIP_HEIGHT + Style.SP_SM
	alert_log.offset_bottom = alert_log.offset_top + 200
	column.add_child(alert_log)

	# --- Bottom band: map | production | command card ---
	# One HBox so the three regions can never overlap each other, which is what
	# right_rail.gd existed to work around: its own header documents the old
	# panels colliding by ~150 px at 1920x1080.
	_band = HBoxContainer.new()
	_band.name = "Band"
	_band.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_band.offset_left = Style.SP_MD
	_band.offset_right = -Style.SP_MD
	_band.offset_top = -(Style.BAND_HEIGHT + Style.SP_MD)
	_band.offset_bottom = -Style.SP_MD
	_band.add_theme_constant_override("separation", Style.SP_SM)
	_band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_band)

	minimap = Minimap.new()
	minimap.custom_minimum_size = Vector2(Style.MAP_SIZE, Style.MAP_SIZE)
	minimap.size_flags_vertical = Control.SIZE_FILL
	_band.add_child(minimap)

	deck = Deck.new()
	deck.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	deck.size_flags_vertical = Control.SIZE_FILL
	_band.add_child(deck)

	command_card = CommandCard.new()
	command_card.size_flags_vertical = Control.SIZE_FILL
	_band.add_child(command_card)

	# --- Hint banner, centred above the band ---
	# match_director._flash() writes here. A panel behind it because the text
	# sits over the battlefield and white-on-anything is not readable.
	_hint_panel = Panel.new()
	_hint_panel.name = "Hint"
	Style.apply_panel(_hint_panel, false, Style.EDGE_BRIGHT)
	_hint_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint_panel.visible = false
	column.add_child(_hint_panel)

	hint_label = Style.label("", Style.SZ_BODY, Style.TEXT)
	hint_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_panel.add_child(hint_label)

	# --- Floating hover tooltip for world entities (buildings, units, resource nodes) ---
	_hover_tooltip = PanelContainer.new()
	_hover_tooltip.name = "HoverTooltip"
	_hover_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hover_tooltip.visible = false

	var sb := StyleBoxFlat.new()
	sb.bg_color = Style.PANEL
	sb.set_border_width_all(1)
	sb.border_color = Style.EDGE_BRIGHT
	sb.set_corner_radius_all(Style.RADIUS)
	sb.content_margin_left = Style.SP_MD
	sb.content_margin_right = Style.SP_MD
	sb.content_margin_top = Style.SP_XS
	sb.content_margin_bottom = Style.SP_XS
	_hover_tooltip.add_theme_stylebox_override("panel", sb)

	var tt_vbox := VBoxContainer.new()
	tt_vbox.add_theme_constant_override("separation", 1)
	tt_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hover_tooltip.add_child(tt_vbox)

	_hover_tooltip_title = Style.heading("")
	_hover_tooltip_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tt_vbox.add_child(_hover_tooltip_title)

	_hover_tooltip_subtitle = Style.label("", Style.SZ_MICRO, Style.TEXT_DIM)
	_hover_tooltip_subtitle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tt_vbox.add_child(_hover_tooltip_subtitle)

	add_child(_hover_tooltip)


func show_entity_tooltip(title: String, subtitle: String = "", screen_pos: Vector2 = Vector2.ZERO) -> void:
	if _hover_tooltip == null:
		return
	if title.is_empty():
		hide_entity_tooltip()
		return
	_hover_tooltip_title.text = title
	if not subtitle.is_empty():
		_hover_tooltip_subtitle.text = subtitle
		_hover_tooltip_subtitle.visible = true
	else:
		_hover_tooltip_subtitle.visible = false
	_hover_tooltip.visible = true
	_hover_tooltip.reset_size()

	var offset := Vector2(16, 16)
	var pos := screen_pos + offset
	var vp := get_viewport()
	if vp != null:
		var vp_size := vp.get_visible_rect().size
		if pos.x + _hover_tooltip.size.x > vp_size.x - 10:
			pos.x = maxf(10, screen_pos.x - _hover_tooltip.size.x - 10)
		if pos.y + _hover_tooltip.size.y > vp_size.y - 10:
			pos.y = maxf(10, screen_pos.y - _hover_tooltip.size.y - 10)
	_hover_tooltip.position = pos


func hide_entity_tooltip() -> void:
	if _hover_tooltip != null:
		_hover_tooltip.visible = false


func setup(director: Node, local_team: int, current_map: Dictionary) -> void:
	_director = director
	_local_team = local_team

	fit_to_viewport()
	var vp := get_viewport()
	if vp != null and not vp.size_changed.is_connected(fit_to_viewport):
		vp.size_changed.connect(fit_to_viewport)

	minimap.setup(director, local_team, current_map)
	ribbon.setup(director, local_team)
	deck.setup(director, local_team)
	command_card.setup(director, local_team)
	alert_log.setup(director, local_team)

	minimap.camera_jump_requested.connect(focus_camera_on)
	minimap.order_requested.connect(_on_map_order)
	alert_log.jump_requested.connect(focus_camera_on)

	_apply_ui_scale_from_settings()


func fit_to_viewport() -> void:
	var vp := get_viewport()
	if vp == null:
		return
	# Divided by the UI scale: this root is the node that carries `scale`, so its
	# own size has to be in pre-scale units or a scaled HUD lays out against a
	# rect larger than the window and the right-hand regions walk off screen.
	layout_for(vp.get_visible_rect().size / maxf(scale.x, 0.01))


# Lays the HUD out for a given available size. Separate from fit_to_viewport so a
# headless test can drive the layout at 1280x720, 1920x1080 and 3440x1440 without
# resizing a real window - which is what the ultrawide behaviour needs asserting
# at, and which cannot be reached by reading get_viewport() alone.
func layout_for(available: Vector2) -> void:
	position = Vector2.ZERO
	size = available

	# Centre the column and cap its width. Everything else is anchored inside it,
	# so this one assignment is what makes the whole HUD ultrawide-correct.
	if column != null:
		var w: float = minf(size.x, COLUMN_MAX_WIDTH)
		column.size = Vector2(w, size.y)
		column.position = Vector2(floorf((size.x - w) * 0.5), 0.0)

	# The hint is the one thing not anchored, because it has to be centred in the
	# column and sit just above whatever height the band ended up.
	if _hint_panel != null and column != null:
		var hw: float = minf(620.0, column.size.x - Style.SP_MD * 2.0)
		_hint_panel.size = Vector2(hw, 34)
		_hint_panel.position = Vector2((column.size.x - hw) * 0.5,
			column.size.y - Style.BAND_HEIGHT - Style.SP_MD - 44)


# --- Refresh ----------------------------------------------------------------
# ONE clock. Each region is polled at the rate it needs and no faster. The old
# HUD had the minimap refresh driven from match_director's vision tick, the desk
# bar running its own 5 Hz accumulator, and the production HUD a third throttle -
# three schedules for one frame's worth of work.
func _process(delta: float) -> void:
	if _director == null:
		return

	alert_log.refresh(delta)
	ribbon.refresh(delta)

	_map_accum += delta
	if _map_accum >= MAP_PERIOD:
		minimap.refresh(_map_accum)
		_map_accum = 0.0

	_panel_accum += delta
	if _panel_accum >= PANEL_PERIOD:
		deck.refresh(_panel_accum)
		command_card.refresh(_panel_accum)
		_panel_accum = 0.0

	if _hint_panel.visible:
		_hint_age += delta
		if hint_label.text == "":
			_hint_panel.visible = false
		elif _hint_age > HINT_LIFETIME:
			# Auto-clear. The old hint label had no expiry, so a message from
			# thirty seconds ago sat on screen looking like current state.
			hint_label.text = ""
			_hint_panel.visible = false
	elif hint_label.text != "":
		_hint_panel.visible = true
		_hint_age = 0.0


# Called by match_director for compatibility with the old per-tick contract.
# Deliberately a no-op: this HUD drives itself from _process, so a caller that
# also ticks it would double the work.
func refresh() -> void:
	pass


# Parents an external overlay into the HUD column so it shares the centred, width-capped
# layout instead of anchoring to the raw viewport edge. Used for the session menu
# and the debug overlay, which are built by match_director because their lifetime
# is the match, not the HUD.
func attach_to_column(c: Control) -> void:
	if column != null:
		column.add_child(c)


# --- Camera -----------------------------------------------------------------

# Centres the view on a world point. Uses the camera's own ray-plane solve
# rather than assigning position directly: the RTS camera is pitched between 42
# and 62 degrees depending on zoom and can be yawed, so "camera.x = target.x"
# lands the target well off centre - which is what made the old minimap click
# feel like it was missing.
func focus_camera_on(world_pos: Vector3) -> void:
	if _director == null or not ("camera" in _director):
		return
	var cam = _director.camera
	if not is_instance_valid(cam) or not cam.is_inside_tree():
		return
	if not cam.has_method("ray_plane_hit"):
		cam.global_position.x = world_pos.x
		cam.global_position.z = world_pos.z
		return
	var centre: Vector2 = cam.get_viewport().get_visible_rect().size * 0.5
	var current = cam.ray_plane_hit(centre)
	if current == null:
		cam.global_position.x = world_pos.x
		cam.global_position.z = world_pos.z
		return
	cam.global_position.x += world_pos.x - current.x
	cam.global_position.z += world_pos.z - current.z


# Which production queue a structure feeds, or "" if it feeds none. Used by the
# click path in match_director: clicking one of your own manufactories focuses
# its queue in the deck. Reads BuildingCatalog.CONTRIBUTORS so the mapping has
# exactly one definition - the one the simulation uses to decide what speeds a
# line up.
func queue_for_structure(structure: Node) -> String:
	if structure == null or not ("kind" in structure):
		return ""
	var kind := str(structure.kind)
	for q in BuildingCatalog.QUEUES:
		if kind in BuildingCatalog.contributors_for(q):
			return q
	return ""


func _on_map_order(world_pos: Vector3, attack_move: bool) -> void:
	if _director == null or _director.orders == null or _director.selection == null:
		return
	var units: Array = _director.selection.selected
	if units.is_empty():
		return
	# Snap to the navmesh first. A map click can land on a cliff face or inside
	# a building footprint, and an unsnapped destination makes the whole group
	# stall against geometry instead of moving.
	var dest := world_pos
	if _director.has_method("snap_to_navmesh"):
		dest = _director.snap_to_navmesh(world_pos)
	if attack_move:
		_director.orders.attack_move(units, dest)
	else:
		_director.orders.move(units, dest)


# --- Hotkeys ----------------------------------------------------------------
# _unhandled_input, so anything a focused control wants (a tooltip, a scroll)
# takes priority and the world still sees clicks the HUD did not consume.
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_BRACKETLEFT:
			deck.cycle(-1)
			get_viewport().set_input_as_handled()
		KEY_BRACKETRIGHT:
			deck.cycle(1)
			get_viewport().set_input_as_handled()
		KEY_M:
			minimap.visible = not minimap.visible
			get_viewport().set_input_as_handled()
		KEY_F1, KEY_F2, KEY_F3, KEY_F4, KEY_F5:
			# Direct access to each queue. F-keys rather than 1-9 because the
			# number row is control groups, and rather than a chord because
			# switching build tab is something you do constantly.
			var i: int = event.keycode - KEY_F1
			if i < BuildingCatalog.QUEUES.size():
				deck.set_active(BuildingCatalog.QUEUES[i])
				get_viewport().set_input_as_handled()


# --- UI scale ---------------------------------------------------------------

func _apply_ui_scale_from_settings() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var settings = tree.get_first_node_in_group("settings_service")
	if settings == null:
		return
	if settings.has_signal("settings_changed") \
			and not settings.settings_changed.is_connected(_on_settings_changed):
		settings.settings_changed.connect(_on_settings_changed)
	# get_value(), NOT Object.get(). SettingsService keeps its values in its own
	# `_values` dictionary behind get_value(key) - they are not node properties -
	# and Object.get() takes exactly one argument, so the two-argument
	# `settings.get("ui_scale", 1.0)` inherited from the old command_console.gd
	# is a parse error, not a defaulted read.
	var scale_value: float = 1.0
	if settings.has_method("get_value"):
		var v = settings.get_value("ui_scale")
		if v != null:
			scale_value = float(v)
	_apply_ui_scale(scale_value)


func _on_settings_changed(key: String, value) -> void:
	if key == "ui_scale":
		_apply_ui_scale(value)


func _apply_ui_scale(s: float) -> void:
	# Scaling the root and then re-fitting, rather than scaling each region: the
	# band is anchored to the bottom edge, and scaling a child of a scaled parent
	# moves the anchor as well as the size.
	var f: float = clampf(float(s), 0.8, 1.5)
	scale = Vector2(f, f)
	fit_to_viewport()


# --- Test Range mode ---------------------------------------------------------
#
# DIM EVERYTHING THAT IS NOT THE TEST UNIT. The Test Range is the player's
# sandbox for one design at a time; every chrome element that is game-wide
# (resource ribbon, alert log) gets pulled to a low alpha so the eye lands
# on the unit under test first. Per-unit chrome (HP bars, selection rings)
# lives in the 3D world, not here, and is untouched.
#
# WHY ONLY ribbon AND alert_log, not the whole HUD. The production deck and
# minimap are already .visible = false in test range (match_rule_set.gd:336-338),
# so dimming them would do nothing. The command card reflects the selected
# unit's actions, which IS the unit under test in the test range - the
# whole point of the panel is to show that unit's orders. The hint banner
# is a momentary flash, not persistent chrome.
#
# ALPHA 0.42 matches the production deck's "future" disabled state
# (hud_production_deck.gd:474) - one dim value across the HUD so the eye
# reads "this is the same dim treatment, applied to non-test chrome" rather
# than three different greys fighting each other.
const TEST_RANGE_DIM_ALPHA := 0.42


func set_test_range_mode(enabled: bool) -> void:
	var dim: float = TEST_RANGE_DIM_ALPHA if enabled else 1.0
	if ribbon != null:
		ribbon.modulate.a = dim
	if alert_log != null:
		alert_log.modulate.a = dim
