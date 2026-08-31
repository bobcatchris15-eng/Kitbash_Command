class_name HUDMinimap
extends Panel
# The tactical map.
#
# WHAT THIS REPLACES AND WHY. Three copies of the same code used to run at once:
# battle_hud.gd carried a full bake/fog/blip implementation so headless tests
# could read pixels back, and then built a MinimapOverlay child which carried a
# second copy, and command_console.gd built a THIRD MinimapOverlay. Every tick,
# two of them composited fog, wrote blip pixels and uploaded a texture. On top of
# that the visible one was 180 px with phosphor_display.gdshader over it, running
# a radar sweep and range rings - so the single densest piece of information in
# the HUD was also the smallest and the most obscured.
#
# THE SPLIT THAT MAKES THIS CHEAP. Terrain and fog are raster; blips, the
# selection ring and the camera frustum are vector. They used to all be pixels in
# one Image, which meant every moving unit forced a full-image rebuild and a
# texture upload every refresh.
#
#   _texture   terrain + fog. Rebuilt ONLY when VisionService.shroud_version
#              changes. On a quiet tick this costs nothing at all.
#   _overlay   a sibling Control whose _draw() puts blips, rings, the frustum
#              and alert pings down at display resolution.
#
# So blips are now drawn as crisp vector shapes rather than 1-2 px blocks in a
# low-res image scaled up, and a tick where nothing was uncovered does no image
# work whatsoever.
#
# THE THREE FOG STATES are read straight out of VisionService's shroud image,
# which already encodes them in alpha: 0.0 is visible now, EXPLORED_ALPHA is
# somewhere you have been but cannot currently see, 1.0 is never seen. This draws
# them as full-brightness terrain, dimmed terrain, and near-black.

const Style = preload("res://scripts/hud/hud_style.gd")
const TerrainBuilder = preload("res://scripts/terrain_builder.gd")
const WorldScale = preload("res://scripts/world_scale.gd")
const ResourceCatalog = preload("res://scripts/battle/economy/resource_catalog.gd")

# Baked terrain resolution. Independent of world_scale, unlike the old
# CELL * world_scale which silently gave a 60x60 image on a 240-extent map and
# then stretched it. 128 is where more samples stopped being visible at a 240 px
# display size, and it is a one-time cost at match start.
const BAKE_DIM := 128

# How dark explored-but-not-currently-visible terrain goes. Softer than the old
# 0.42 because there is no longer a phosphor shader lifting it back up, and the
# player needs to read their own base layout through it.
const FOG_EXPLORED_DARKEN := 0.55
# 1.0, so unexplored is exactly VOID with no terrain bleeding through. At 0.94 a
# little of the terrain still showed, which is a slow leak of map knowledge the
# player has not earned.
const FOG_UNEXPLORED_DARKEN := 1.0

# THE MAP PALETTE IS DELIBERATELY BRIGHTER THAN THE 3D GROUND.
#
# The first version reused near-realistic terrain colours - forest was
# (0.11, 0.20, 0.12), luminance 0.17. Composited against VOID (luminance 0.065)
# that put the three fog states at luminance 0.17 / 0.12 / 0.07: a total spread of
# 0.10, with only 0.05 between "somewhere I have been" and "somewhere I have never
# been". Measured, not guessed - tools/capture_hud.gd prints the histogram.
#
# A map is a diagram, not a photograph. These are lifted roughly 2x, which puts
# the same three states at about 0.42 / 0.23 / 0.07 and makes the distinction
# survive a 224 px panel and a dark room.
const WATER_COLOR := Color(0.16, 0.34, 0.58)
const SURFACE_COLORS := {
	"marsh": Color(0.36, 0.44, 0.28),
	"snow_mud": Color(0.68, 0.71, 0.74),
	"sand": Color(0.74, 0.66, 0.44),
	"gravel": Color(0.55, 0.54, 0.51),
	"forest": Color(0.22, 0.40, 0.24),
	"ice": Color(0.80, 0.88, 0.94),
}
# Applied to the map's own `ground_color`, which is authored for the 3D ground and
# is therefore in the same too-dark range as the surface colours used to be.
const GROUND_COLOR_LIFT := 2.0

# Blip radii in display pixels. Structures read bigger than units because at a
# glance "where is my base" and "where is my army" are different questions.
const BLIP_UNIT := 2.0
const BLIP_STRUCTURE := 3.5
const BLIP_RESOURCE := 2.0

const PING_LIFETIME := 2.6
const PING_MAX_RADIUS := 26.0

signal camera_jump_requested(world_pos: Vector3)
signal order_requested(world_pos: Vector3, attack_move: bool)

var _director: Node = null
var _local_team: int = 0
var _half: float = 80.0

var _terrain_image: Image = null    # baked terrain, no fog
var _display_image: Image = null    # terrain with fog blended in
var _texture: ImageTexture = null
var _fog_shade: Image = null        # derived, cached per shroud_version
var _fog_version: int = -1

var _map_rect: TextureRect = null
var _overlay: Control = null
var _dragging: bool = false

var _pings: Array = []              # [{pos: Vector3, t: float, color: Color}]


func _init() -> void:
	name = "TacticalMap"
	custom_minimum_size = Vector2(Style.MAP_SIZE, Style.MAP_SIZE)
	mouse_filter = Control.MOUSE_FILTER_STOP
	tooltip_text = "Tactical Minimap\nLeft-click: Move camera\nRight-click: Issue move/attack order"
	Style.apply_panel(self, false, Style.EDGE_BRIGHT)
	_build()


func _build() -> void:
	# The map fills the panel inside its content margin. MarginContainer rather
	# than manual offsets so the panel's own margin stays the single definition
	# of the inset.
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", Style.SP_SM)
	margin.add_theme_constant_override("margin_right", Style.SP_SM)
	margin.add_theme_constant_override("margin_top", Style.SP_SM)
	margin.add_theme_constant_override("margin_bottom", Style.SP_SM)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(margin)

	_map_rect = TextureRect.new()
	_map_rect.name = "Terrain"
	_map_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_map_rect.stretch_mode = TextureRect.STRETCH_SCALE
	# IGNORE, not STOP: the panel itself takes the clicks, so the map area and
	# the overlay can never disagree about which one the mouse is over.
	_map_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(_map_rect)

	_overlay = Control.new()
	_overlay.name = "Overlay"
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	margin.add_child(_overlay)


func setup(director: Node, local_team: int, current_map: Dictionary) -> void:
	_director = director
	_local_team = local_team
	_half = current_map.get("map_half_extents", 80.0)
	_bake_terrain(current_map)
	_composite_fog(true)
	var alerts = director.alerts if director != null and "alerts" in director else null
	if alerts != null and alerts.has_signal("alert_posted"):
		alerts.alert_posted.connect(_on_alert_posted)


# --- Bake -------------------------------------------------------------------

func _bake_terrain(current_map: Dictionary) -> void:
	var raw = current_map.get("ground_color", Color(0.2, 0.25, 0.2))
	var ground: Color = raw if raw is Color else Color(raw[0], raw[1], raw[2])
	ground = Color(minf(ground.r * GROUND_COLOR_LIFT, 1.0),
		minf(ground.g * GROUND_COLOR_LIFT, 1.0),
		minf(ground.b * GROUND_COLOR_LIFT, 1.0))
	var span := _half * 2.0
	_terrain_image = Image.create(BAKE_DIM, BAKE_DIM, false, Image.FORMAT_RGBA8)
	for gz in range(BAKE_DIM):
		var wz := -_half + (gz + 0.5) * span / BAKE_DIM
		for gx in range(BAKE_DIM):
			var wx := -_half + (gx + 0.5) * span / BAKE_DIM
			var c: Color
			if TerrainBuilder.is_water_at(current_map, wx, wz):
				c = WATER_COLOR
			else:
				var surf := TerrainBuilder.get_surface_type_at(current_map, Vector3(wx, 0, wz))
				c = SURFACE_COLORS.get(surf, ground)
			_terrain_image.set_pixel(gx, gz, c)
	_display_image = _terrain_image.duplicate()
	_texture = ImageTexture.create_from_image(_display_image)
	_map_rect.texture = _texture


# --- Fog --------------------------------------------------------------------

# Rebuilds the visible texture from terrain + the current shroud. `force` skips
# the version check, for the initial build where there is no previous version.
func _composite_fog(force: bool = false) -> void:
	if _texture == null:
		return
	var vision = _director.vision if _director != null and "vision" in _director else null
	if vision == null:
		return

	if "reveal_all" in vision and vision.reveal_all:
		# Nothing to darken. Only pay the blit once.
		if force or _fog_version != -2:
			_fog_version = -2
			_display_image.blit_rect(_terrain_image,
				Rect2i(Vector2i.ZERO, Vector2i(BAKE_DIM, BAKE_DIM)), Vector2i.ZERO)
			_texture.update(_display_image)
		return

	var version: int = vision.shroud_version
	if not force and version == _fog_version:
		return
	_fog_version = version

	var src: Image = vision.shroud_image()
	if src == null or src.get_width() == 0:
		return

	# Re-shade the shroud into the three display states. The shroud stores
	# alpha only; this turns it into the darkening factor the map wants, which
	# is not the same curve - explored terrain has to stay readable enough to
	# make out a base layout, and the shroud's own 0.74 was tuned for the 3D
	# ground plane, not for a 240 px map.
	var shade := Image.create(src.get_width(), src.get_height(), false, Image.FORMAT_RGBA8)
	for y in range(src.get_height()):
		for x in range(src.get_width()):
			var a: float = src.get_pixel(x, y).a
			var out: float = 0.0
			if a >= 0.99:
				out = FOG_UNEXPLORED_DARKEN
			elif a > 0.01:
				out = FOG_EXPLORED_DARKEN
			shade.set_pixel(x, y, Color(Style.VOID.r, Style.VOID.g, Style.VOID.b, out))
	# Bilinear: the fog grid is much coarser than the terrain bake, and a hard
	# nearest-neighbour edge on a 30x30 grid reads as a staircase.
	if shade.get_width() != BAKE_DIM:
		shade.resize(BAKE_DIM, BAKE_DIM, Image.INTERPOLATE_BILINEAR)
	_fog_shade = shade

	_display_image.blit_rect(_terrain_image,
		Rect2i(Vector2i.ZERO, Vector2i(BAKE_DIM, BAKE_DIM)), Vector2i.ZERO)
	_display_image.blend_rect(_fog_shade,
		Rect2i(Vector2i.ZERO, Vector2i(BAKE_DIM, BAKE_DIM)), Vector2i.ZERO)
	_texture.update(_display_image)


# --- Per-tick ---------------------------------------------------------------

func refresh(delta: float = 0.0) -> void:
	_composite_fog()
	if not _pings.is_empty():
		for p in _pings:
			p["t"] += delta
		_pings = _pings.filter(func(p): return p["t"] < PING_LIFETIME)
	if _overlay != null:
		_overlay.queue_redraw()


# --- Overlay drawing --------------------------------------------------------

func _draw_radar_grid() -> void:
	if _overlay == null or _overlay.size.x <= 0.0 or _overlay.size.y <= 0.0:
		return
	var s := _overlay.size
	var reticle_col := Style.RETICLE
	var corner_len := 12.0
	var edge_tick := 4.0
	var inset := 2.0
	# Corner brackets — rectilinear alignment cues matching the app's shape language
	var corners := [
		[Vector2(inset, inset), Vector2(inset + corner_len, inset), Vector2(inset, inset + corner_len)],
		[Vector2(s.x - inset, inset), Vector2(s.x - inset - corner_len, inset), Vector2(s.x - inset, inset + corner_len)],
		[Vector2(inset, s.y - inset), Vector2(inset + corner_len, s.y - inset), Vector2(inset, s.y - inset - corner_len)],
		[Vector2(s.x - inset, s.y - inset), Vector2(s.x - inset - corner_len, s.y - inset), Vector2(s.x - inset, s.y - inset - corner_len)],
	]
	for c in corners:
		_overlay.draw_line(c[0], c[1], reticle_col * 0.55, 1.0, true)
		_overlay.draw_line(c[0], c[2], reticle_col * 0.55, 1.0, true)
	# Edge ticks at midpoints
	var mid_x := s.x * 0.5
	var mid_y := s.y * 0.5
	_overlay.draw_line(Vector2(mid_x, inset), Vector2(mid_x, inset + edge_tick), reticle_col * 0.40, 1.0, true)
	_overlay.draw_line(Vector2(mid_x, s.y - inset), Vector2(mid_x, s.y - inset - edge_tick), reticle_col * 0.40, 1.0, true)
	_overlay.draw_line(Vector2(inset, mid_y), Vector2(inset + edge_tick, mid_y), reticle_col * 0.40, 1.0, true)
	_overlay.draw_line(Vector2(s.x - inset, mid_y), Vector2(s.x - inset - edge_tick, mid_y), reticle_col * 0.40, 1.0, true)


func _draw_overlay() -> void:
	if _overlay == null or _overlay.size.x <= 0.0:
		return
	_draw_radar_grid()
	var vision = _director.vision if _director != null and "vision" in _director else null
	var reveal_all: bool = vision != null and "reveal_all" in vision and vision.reveal_all
	var selected: Dictionary = {}
	if _director != null and "selection" in _director and _director.selection != null:
		for u in _director.selection.selected:
			if is_instance_valid(u):
				selected[u.get_instance_id()] = true

	var tree := get_tree()
	if tree == null:
		return

	# Resource nodes first, so a unit sitting on one still reads as a unit.
	for r in tree.get_nodes_in_group("resource_nodes"):
		if not is_instance_valid(r):
			continue
		if not reveal_all and not _is_explored(vision, r.global_position):
			continue
		var rc: Color = ResourceCatalog.color(str(r.get("resource_type")))
		_overlay.draw_circle(_to_map(r.global_position), BLIP_RESOURCE, rc * Color(1, 1, 1, 0.85))

	for c in tree.get_nodes_in_group("damageable"):
		if not is_instance_valid(c) or c.is_dead:
			continue
		var team: int = c.get_meta("team") if c.has_meta("team") else -1
		var friendly: bool = team == _local_team
		# FRIENDLY UNITS ARE ALWAYS VISIBLE ON THE MAP, including inside fog you
		# do not currently have vision on - you always know where your own army
		# is. Hostiles are gated on the vision service, which is the same
		# predicate that gates their 3D rendering, so the map can never show a
		# contact the player cannot also see in the world.
		if not friendly and not reveal_all:
			if "fog_hidden" in c and c.fog_hidden:
				continue

		var is_structure: bool = c is Structure or ("kind" in c and not ("blueprint" in c))
		var radius: float = BLIP_STRUCTURE if is_structure else BLIP_UNIT
		var col: Color = Style.TEAM_FRIENDLY if friendly else Style.TEAM_HOSTILE
		if team < 0:
			col = Style.TEAM_NEUTRAL
		var at := _to_map(c.global_position)

		if is_structure:
			# Square for a structure, dot for a unit. Shape, not just size, so
			# the distinction survives a colourblind player and a small window.
			_overlay.draw_rect(Rect2(at - Vector2(radius, radius),
				Vector2(radius * 2.0, radius * 2.0)), col)
		else:
			_overlay.draw_circle(at, radius, col)

		if selected.has(c.get_instance_id()):
			_overlay.draw_arc(at, radius + 2.5, 0.0, TAU, 12, Style.SELECTED, 1.5, true)

	_draw_pings()
	_draw_frustum()


func _draw_pings() -> void:
	for p in _pings:
		var t: float = float(p["t"]) / PING_LIFETIME
		var col: Color = p["color"]
		col.a = 1.0 - t
		_overlay.draw_arc(_to_map(p["pos"]), 3.0 + t * PING_MAX_RADIUS,
			0.0, TAU, 24, col, 2.0, true)


# The camera's ground footprint, as a closed quad. Uses the real projection
# rather than a centred square so it stays correct under the camera's pitch,
# yaw and zoom - which a fixed rectangle does not.
func _draw_frustum() -> void:
	if _director == null or not ("camera" in _director):
		return
	var cam = _director.camera
	if not is_instance_valid(cam) or not (cam is Camera3D) or not cam.is_inside_tree():
		return
	var vp_size: Vector2 = cam.get_viewport().get_visible_rect().size
	if vp_size.x <= 0.0 or vp_size.y <= 0.0:
		return
	var pts := PackedVector2Array()
	for p in [Vector2(0, 0), Vector2(vp_size.x, 0),
			Vector2(vp_size.x, vp_size.y), Vector2(0, vp_size.y)]:
		var origin: Vector3 = cam.project_ray_origin(p)
		var dir: Vector3 = cam.project_ray_normal(p)
		# A corner ray that does not point down at all means the camera is
		# looking at the horizon; there is no finite footprint to draw.
		if dir.y >= -0.001:
			return
		var hit: Vector3 = origin + dir * (-origin.y / dir.y)
		pts.append(_to_map(hit))
	pts.append(pts[0])
	_overlay.draw_polyline(pts, Color(1, 1, 1, 0.55), 1.0, true)


# --- Coordinates ------------------------------------------------------------

func _to_map(world: Vector3) -> Vector2:
	var span := _half * 2.0
	var u := (world.x + _half) / span
	var v := (world.z + _half) / span
	return Vector2(u * _overlay.size.x, v * _overlay.size.y)


func _to_world(local: Vector2) -> Vector3:
	var span := _half * 2.0
	var u: float = clampf(local.x / maxf(_overlay.size.x, 1.0), 0.0, 1.0)
	var v: float = clampf(local.y / maxf(_overlay.size.y, 1.0), 0.0, 1.0)
	return Vector3(-_half + u * span, 0.0, -_half + v * span)


# Where the mouse is, expressed in the overlay's coordinate space. The panel
# takes input but the overlay owns the geometry, so every click has to be
# rebased through the margin.
func _overlay_local(panel_pos: Vector2) -> Vector2:
	if _overlay == null:
		return panel_pos
	return panel_pos - (_overlay.global_position - global_position)


func _is_explored(vision, at: Vector3) -> bool:
	if vision == null or not vision.has_method("cell_explored"):
		return true
	return vision.cell_explored(at.x, at.z)


# --- Input ------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_dragging = event.pressed
			if event.pressed:
				camera_jump_requested.emit(_to_world(_overlay_local(event.position)))
			accept_event()
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			# Right-click on the map issues a real order at that world point, so
			# a recall-and-send does not need a camera trip. Ctrl makes it an
			# attack-move, matching the same modifier in the 3D view.
			order_requested.emit(_to_world(_overlay_local(event.position)),
				Input.is_key_pressed(KEY_CTRL))
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		# Held-drag scrubs the camera continuously. This is the gesture that
		# makes a map usable for scanning rather than only for jumping.
		camera_jump_requested.emit(_to_world(_overlay_local(event.position)))
		accept_event()


func _on_alert_posted(type: String, world_pos: Vector3) -> void:
	var col := Style.WARN
	if type.contains("attack") or type.contains("lost"):
		col = Style.BAD
	elif type.contains("ready") or type.contains("complete"):
		col = Style.OK
	_pings.append({"pos": world_pos, "t": 0.0, "color": col})


# The composited image, for tests that want to assert on fog or terrain pixels.
# Blips and the frustum are NOT in here any more - they are vector draws on the
# overlay - so a test asserting on a blip pixel is asserting on the old
# architecture and should be reading the overlay draw list instead.
func map_image() -> Image:
	return _display_image
