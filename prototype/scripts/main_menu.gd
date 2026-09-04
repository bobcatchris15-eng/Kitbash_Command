extends Control
# AAA Main Menu Rearchitecture.
# Features:
#   * Live 3D Hangar Background: A SubViewport rendering a rotating 3D turntable
#     with studio key/rim lighting, SSAO, and ACES Filmic tonemapping.
#   * 30-Second Showcase Cycling: The 3D rotating object on the background turntable
#     automatically jumps between saved player blueprints and available hull chassis
#     types every 30 seconds (or on manual button click).
#   * Synchronized 2D Telemetry Placard: The right-side Procurement Specification Placard
#     updates dynamically in real-time to match the exact 3D vehicle currently showcased on the turntable!
#   * Asymmetric AAA Command Deck: Modern left-aligned navigation with animated cards,
#     glowing active indicators, and audio feedback on hover/click.

const UITheme = preload("res://scripts/ui_theme.gd")
const UIShell = preload("res://scripts/ui_shell.gd")
const Tokens = preload("res://scripts/ui_tokens.gd")
const UIFeedbackScript = preload("res://scripts/ui_feedback.gd")
const BlueprintManagerScript = preload("res://scripts/blueprint_manager.gd")
const ModuleCatalogScript = preload("res://scripts/module_catalog.gd")
const MeshAssetLoader = preload("res://scripts/mesh_asset_loader.gd")
const HullMaterialBuilderScript = preload("res://scripts/hull_material_builder.gd")
const SpecPlacardScript = preload("res://scripts/ui/spec_placard.gd")
const WordmarkScript = preload("res://scripts/ui/wordmark.gd")
const DesignStatsScript = preload("res://scripts/design_stats.gd")
# Test Range launcher (battle-system unification Phase 3). Same launcher the
# Design Lab's "Test in Arena" button uses, so the two entry points cannot
# drift on which map, which dummies, and which rule set the Test Range actually
# boots with. The card data declares a `launcher` field; the destination card's
# pressed handler routes through it instead of the legacy scene path.
const TestRangeLauncherScript = preload("res://scripts/test_range_launcher.gd")
const TwoPhaseTutorialManagerScript = preload("res://scripts/tutorial_two_phase/two_phase_tutorial_manager.gd")

const TITLE := "KITBASH COMMAND"
const TAGLINE := "Design bureau and proving ground"
const SHOWCASE_CYCLE_INTERVAL := 30.0

const FALLBACK_HULL_TYPES := [
	"brenntal_medium_a",
	"block_heavy_meridian_a",
	"wedge_scout_meridian_a",
	"flying_wing_hull",
	"super_heavy_hull",
	"kestrel_scout_a",
	"tri_hull",
	"bunker_main_meridian"
]

# UX_REDESIGN_PLAN.md's target information architecture: three activities plus
# a system layer, replacing seven equal-weight cards with none of them
# answering "which do I press first". First-run still shows exactly one card
# (see _build_left_column) regardless of what is declared here - GROUPS is the
# steady-state menu a returning player sees.
const GROUPS := [
	{
		"section": "DEPLOY",
		"items": [
			{
				"title": "SKIRMISH",
				"desc": "Select a map and a roster, then engage enemy forces.",
				"scene": "res://scenes/MatchSetup.tscn",
				"badge": "COMBAT // SKIRMISH"
			},
			{
				"title": "OPERATIONS",
				"desc": "Three to twelve engagements. Re-draft your roster between each.",
				"scene": "res://scenes/OperationsSetup.tscn",
				"badge": "TAC // CAMPAIGN"
			},
			{
				"title": "PROVING GROUND",
				"desc": "Field the current design against target dummies.",
				# launcher wins over scene: the Test Range entry point
				# resolves the player blueprint, builds a MatchRuleSet, and
				# routes through SceneRouter. The fallback below is what the
				# card lands on if `launcher` is ever removed, so it has to be
				# a scene that exists - it used to name Battlefield.tscn, which
				# was DELETED in the 2026-08-10 unification (DECISIONS.md §7),
				# making the one entry that existed to prevent a broken route
				# the only broken route in this table. Battle.tscn is both real
				# and what TestRangeLauncher routes to anyway.
				"launcher": "TestRangeLauncher",
				"scene": "res://scenes/Battle.tscn",
				"badge": "TEST // RANGE"
			},
		],
	},
	{
		"section": "DESIGN",
		"items": [
			{
				"title": "DESIGN LAB",
				"desc": "Assemble blueprints from hulls, modules and drives.",
				"scene": "res://scenes/MainLab.tscn",
				"badge": "SYS // BUILD"
			},
			{
				"title": "BLUEPRINT LIBRARY",
				"desc": "Browse, manage, and preview your vehicle designs.",
				"scene": "res://scenes/BlueprintLibrary.tscn",
				"badge": "SYS // ARCHIVE"
			},
			{
				"title": "HULL AUTHORING",
				"desc": "Shape new hull forms from primitives.",
				"scene": "res://scenes/HullBuilder.tscn",
				"badge": "CAD // MESH"
			},
			{
				"title": "BLOCK HULL BUILDER",
				"desc": "Modular grid-based brick hull suite with strict snapping and CSG weld.",
				"scene": "res://scenes/ModularHullBuilder.tscn",
				"badge": "CAD // BLOCKS (NEW)"
			},
			{
				"title": "TERRAIN SCULPT",
				"desc": "Place canyons, plateaus, ridges and ramps on a live map preview.",
				"scene": "res://scenes/TerrainSculpt.tscn",
				"badge": "CAD // TERRAIN (NEW)"
			},
		],
	},
	{
		"section": "TRAINING",
		"items": [
			{
				"title": "TUTORIAL",
				"desc": "Experience defeat with weak units, then build one that wins. Two phases.",
				"scene": "res://scenes/MainLab.tscn",
				"badge": "SYS // TRAINING",
				"tutorial": true
			},
		],
	},
]

# Tutorial card for the TRAINING section - always visible
const TUTORIAL_CARD := {
	"title": "TUTORIAL",
	"desc": "Experience defeat with weak units, then build one that wins. Two phases.",
	"scene": "res://scenes/MainLab.tscn",
	"badge": "SYS // TRAINING",
	"tutorial": true
}

# WHICH RUNTIME EACH COMBAT DESTINATION ACTUALLY REACHES, because it is not
# obvious from the scene paths above.
#
#   SKIRMISH        MatchSetup.tscn       -> Battle.tscn -> battle/match_director.gd
#   OPERATIONS      OperationsSetup.tscn  -> Battle.tscn -> battle/match_director.gd
#   PROVING GROUND  (TestRangeLauncher)   -> Battle.tscn -> battle/match_director.gd
#
# All three reach the same battle layer (scripts/battle/), whose units are
# battle/units/unit.gd. There is no second unit script in the tree: the
# legacy battlefield.gd / battle_unit.gd / player_vehicle.gd / target_dummy.gd
# set was retired on 2026-08-10 in the unification's Phase 4. The
# per-mode gating is a MatchRuleSet that match_director.gd reads at _ready;
# see scripts/match_rule_set.gd and tests/battle/test_match_rule_set_integration.gd
# for the rules. TestRangeLauncher is a Node (not a static helper) so the
# SceneRouter routes through it the same way every other launcher does,
# and the Main Menu's PROVING GROUND card and the Design Lab's
# "Test in Arena" button share one function.
#
# This block replaces a comment describing the battle layer as a work in
# progress listed "BESIDE Skirmish" that would take its name at parity, and
# a follow-up about "THE PROVING GROUND IS THE EXCEPTION" that documented
# the now-retired Battlefield.tscn / battle_unit.gd split. Both
# superseded; the unification finished in 2026-08-10.

var _turntable_node: Node3D = null
var _turntable_model_container: Node3D = null
var _showcase_vehicle: Node3D = null
var _spec_placard: Control = null
var _showcase_items: Array = []
var _current_showcase_index: int = 0
var _showcase_timer: float = 0.0

func _ready() -> void:
	_gather_showcase_items()
	var backdrop := ColorRect.new()
	backdrop.color = Tokens.BASE_900
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)
	var frame := UIShell.screen_frame(self, Tokens.SPACE_LG, Tokens.SPACE_LG)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", Tokens.SPACE_MD)
	frame.add_child(column)
	_build_top_ribbon(column)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", Tokens.SPACE_LG)
	column.add_child(body)
	_build_destination_console(body)

	var showcase := VBoxContainer.new()
	showcase.name = "Showcase"
	showcase.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	showcase.add_theme_constant_override("separation", Tokens.SPACE_SM)
	body.add_child(showcase)
	var caption := Label.new()
	caption.text = "INSPECTION TABLE   /   LIVE ASSEMBLY"
	caption.theme_type_variation = "HeadingLabel"
	showcase.add_child(caption)
	_showcase_host = Control.new()
	_showcase_host.name = "ShowcaseViewport"
	_showcase_host.custom_minimum_size = Vector2(0, 200)
	_showcase_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_showcase_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_showcase_host.clip_contents = true
	showcase.add_child(_showcase_host)
	if DisplayServer.get_name() != "headless":
		_build_3d_background()
	_build_status_column(showcase)
	_update_showcase_display()
	UIFeedbackScript.wire_tree(self)
	var primary := find_child("DesignLabAction", true, false) as Button
	primary.grab_focus.call_deferred()
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null:
		audio.play_music("menu")

var _showcase_host: Control
var _destination_column: VBoxContainer

func _process(delta: float) -> void:
	if is_instance_valid(_turntable_node):
		_turntable_node.rotation.y += 0.25 * delta

	# 30-Second Showcase Cycle Timer
	_showcase_timer += delta
	if _showcase_timer >= SHOWCASE_CYCLE_INTERVAL:
		_showcase_timer = 0.0
		_next_showcase_item()

func _gather_showcase_items() -> void:
	_showcase_items.clear()

	# 1. Saved Player Blueprints, MOST RECENT FIRST - "the player's latest
	# design on the turntable rather than a stock chassis" (UX_REDESIGN_PLAN.md
	# Phase 2). Sorted by the file's own mtime rather than roster order, which
	# reflects nothing about recency.
	var mgr = BlueprintManagerScript.new()
	var roster: Array = mgr.list_blueprints(true)
	var blueprint_entries: Array = []
	for entry in roster:
		var path := str(entry.get("path", ""))
		if path != "":
			var full_bp: Dictionary = mgr.load_blueprint(path)
			if not full_bp.is_empty():
				blueprint_entries.append({
					"type": "blueprint",
					"name": entry.get("name", "UNNAMED DESIGN"),
					"blueprint": full_bp,
					"summary": entry,
					"mtime": FileAccess.get_modified_time(path),
				})
	blueprint_entries.sort_custom(func(a, b): return a["mtime"] > b["mtime"])
	_showcase_items.append_array(blueprint_entries)

	# 2. Add Standard Hull Chassis types so there is always a rich variety
	for hull_id in FALLBACK_HULL_TYPES:
		_showcase_items.append({
			"type": "hull",
			"name": _prettify(hull_id).to_upper() + " CHASSIS",
			"hull_type": hull_id
		})

	_current_showcase_index = 0

func _next_showcase_item() -> void:
	if _showcase_items.is_empty():
		return
	_current_showcase_index = (_current_showcase_index + 1) % _showcase_items.size()
	_update_showcase_display()

func _update_showcase_display() -> void:
	if _showcase_items.is_empty():
		return

	var item: Dictionary = _showcase_items[_current_showcase_index]

	# Update 3D Model on Turntable
	if is_instance_valid(_turntable_model_container):
		for child in _turntable_model_container.get_children():
			child.queue_free()
		_build_3d_showcase_model(item, _turntable_model_container)

	# Update 2D Specification Placard UI
	_update_placard_ui(item)

func _build_3d_background() -> void:
	var vp_container = SubViewportContainer.new()
	vp_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	vp_container.stretch = true
	vp_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_showcase_host.add_child(vp_container)

	var vp = SubViewport.new()
	vp.size = Vector2i(1920, 1080)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.msaa_3d = Viewport.MSAA_4X
	vp_container.add_child(vp)

	var scene = Node3D.new()
	vp.add_child(scene)

	# DARK BENCH ENVIRONMENT (2026-08-25). Was a flat featureless studio grey
	# lit wall-to-wall by two directionals - everything equally visible,
	# nothing emphasised. Now the room is near-black with ambient disabled and
	# the only real light is one warm spot raked onto the showcased model (plus
	# a faint cool omni behind it for rim separation). The cutting mat runs to
	# the frame edges and simply disappears into the falloff, which is what
	# lets a finite slab read as an endless bench.
	var env_node = WorldEnvironment.new()
	var env := UITheme.inspection_environment()
	env_node.environment = env
	scene.add_child(env_node)

	# KEY LIGHT: one warm spot over the turntable. Energy is high because the
	# cone's inverse-square falloff has to carry the whole image now.
	var key = SpotLight3D.new()
	key.position = Vector3(-1.2, 9.5, 5.5)
	key.light_color = Tokens.INSPECTION_KEY_COLOR
	key.light_energy = Tokens.SHOWCASE_SPOT_ENERGY
	key.spot_range = 28.0
	key.spot_attenuation = 1.1
	key.spot_angle = 37.0
	key.shadow_enabled = true
	scene.add_child(key)
	key.look_at(Vector3(-3.4, 0.4, 0.0))

	# RIM: faint cool omni behind-left of the model. Range-limited so it kisses
	# the hull's trailing edges and dies before it paints the mat.
	var rim = OmniLight3D.new()
	rim.position = Vector3(-8.5, 3.0, -6.5)
	rim.light_color = Tokens.INSPECTION_FILL_COLOR
	rim.light_energy = Tokens.SHOWCASE_RIM_ENERGY
	rim.omni_range = 14.0
	rim.omni_attenuation = 2.0
	scene.add_child(rim)

	# Camera framed at center turntable - Zoomed way farther out
	var cam = Camera3D.new()
	cam.position = Vector3(5.0, 5.0, 10.0)
	cam.fov = 46.0
	scene.add_child(cam)
	cam.look_at(Vector3(-3.4, 0.6, 0.0))

	# Turntable Base & Model Container.
	# 2026-08-25: shifted left of the viewport centre (-3.4) so the showcased
	# model clears the spec placard column on the right edge instead of
	# disappearing behind it. The placard shrank to fit its content in the
	# same pass (see _build_status_column).
	_turntable_node = Node3D.new()
	_turntable_node.position = Vector3(-3.4, -0.4, 0.0)
	scene.add_child(_turntable_node)

	var platform_mesh = MeshInstance3D.new()
	var cyl = CylinderMesh.new()
	cyl.top_radius = 4.8
	cyl.bottom_radius = 5.2
	cyl.height = 0.4
	platform_mesh.mesh = cyl
	platform_mesh.position = Vector3(0, -0.2, 0)

	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.30, 0.32, 0.34, 1.0)
	mat.metallic = 0.2
	mat.roughness = 0.65
	platform_mesh.material_override = mat
	_turntable_node.add_child(platform_mesh)

	_turntable_model_container = Node3D.new()
	_turntable_node.add_child(_turntable_model_container)

	# Hobby-bench floor under the turntable: a self-healing cutting mat dressed
	# with modeller's tools. Deliberately a SIBLING of the rotating node, not a
	# child - only the vehicle turns; scattered tools stay put like a real bench.
	_build_cutting_mat(scene)


# --- Cutting-mat floor -------------------------------------------------------

# The mat slab plus the tools scattered on it. Everything here is procedural
# primitives with flat materials - the same authoring rule as the rest of the
# art pipeline, just small. The slab is far larger than any plausible tool
# layout on purpose: it runs past every edge of the frame, and the dark-bench
# lighting (see _build_3d_background) swallows it before its far corners could
# ever show. Tool positions still ring the turntable puck (radius ~5.2) so
# nothing intrudes under the showcased model.
func _build_cutting_mat(parent: Node3D) -> void:
	var root := Node3D.new()
	# x tracks the turntable so the mat reads as the floor beneath it; y puts
	# the slab's top face at -0.43, clear of the puck's underside at -0.40 so
	# the two never sit co-planar and z-fight. z is centred between a front
	# edge past the bottom of the frame (~z +10 at this camera) and a back edge
	# that dissolves into the light falloff.
	root.position = Vector3(-3.4, -0.49, -8.0)
	parent.add_child(root)

	var slab = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(56.0, 0.12, 44.0)
	slab.mesh = box
	var slab_mat := StandardMaterial3D.new()
	slab_mat.albedo_texture = _make_cutting_mat_texture()
	slab_mat.roughness = 0.93
	# Triplanar, object-local: a slab this size tiled per-face would stretch
	# one texture copy across 56 m of grid. World-scale tiling keeps each grid
	# cell ~25 cm no matter how far the slab runs.
	slab_mat.uv1_triplanar = true
	slab_mat.uv1_scale = Vector3(0.25, 0.25, 0.25)
	slab.material_override = slab_mat
	root.add_child(slab)

	_dress_cutting_mat(root)


# The printed face of a self-healing cutting mat: deep service-green, a fine
# 32 px grid with heavier lines every fourth, a lighter boundary frame, and
# seeded wear speckles. Drawn once into an ImageTexture at menu build.
func _make_cutting_mat_texture() -> ImageTexture:
	var w := 512
	var h := 352
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	var base := Color(0.106, 0.185, 0.153)
	var grid := Color(0.137, 0.227, 0.192)
	var major := Color(0.176, 0.278, 0.235)
	var frame := Color(0.208, 0.322, 0.275)
	img.fill(base)
	for x in range(0, w, 32):
		img.fill_rect(Rect2i(x, 0, 1, h), grid)
	for y in range(0, h, 32):
		img.fill_rect(Rect2i(0, y, w, 1), grid)
	for x in range(0, w, 128):
		img.fill_rect(Rect2i(x, 0, 2, h), major)
	for y in range(0, h, 128):
		img.fill_rect(Rect2i(0, y, w, 2), major)
	img.fill_rect(Rect2i(8, 8, 4, h - 16), frame)
	img.fill_rect(Rect2i(w - 12, 8, 4, h - 16), frame)
	img.fill_rect(Rect2i(8, 8, w - 16, 4), frame)
	img.fill_rect(Rect2i(8, h - 12, w - 16, 4), frame)
	# Seeded, not random(): regenerating the menu must stay deterministic.
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260825
	for i in range(900):
		img.set_pixelv(
			Vector2i(rng.randi_range(0, w - 1), rng.randi_range(0, h - 1)),
			base.darkened(rng.randf_range(0.05, 0.22)))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _dress_cutting_mat(root: Node3D) -> void:
	# Positions are MAT-LOCAL (mat root sits at world (-3.4, -8)). The key
	# spot's ground pool centres on the puck at about world (-3.5, -0.2) with
	# its bright band spilling forward (world z 0..+7, toward the camera), so
	# everything here is arranged in that front arc - clearly inside or on the
	# lip of the light, never behind the model where the falloff eats it. All
	# radii stay outside the puck's ~5.2 m footprint.
	var scatter := [
		[_tool_snippers(), Vector3(-4.8, 0.0, 11.6), 18.0],
		[_tool_paintbrush(Color(0.75, 0.20, 0.16)), Vector3(4.6, 0.0, 11.0), -30.0],
		[_tool_paintbrush(Color(0.20, 0.38, 0.75)), Vector3(-6.0, 0.0, 9.2), 40.0],
		[_tool_sandpaper(), Vector3(-4.2, 0.0, 13.4), 65.0],
		[_tool_glue_tube(), Vector3(5.6, 0.0, 7.2), -20.0],
		[_tool_glue_tube(), Vector3(6.3, 0.0, 5.8), 8.0],
		[_tool_paint_tin(Color(0.72, 0.16, 0.14)), Vector3(-2.8, 0.0, 14.8), 0.0],
		[_tool_paint_tin(Color(0.85, 0.65, 0.12)), Vector3(3.8, 0.0, 12.4), 0.0],
		[_tool_paint_tin(Color(0.20, 0.42, 0.62)), Vector3(-6.8, 0.0, 7.2), 0.0],
		[_tool_paint_tube(Color(0.50, 0.14, 0.50)), Vector3(1.4, 0.0, 13.6), 0.0],
	]
	for s in scatter:
		var tool_node: Node3D = s[0]
		tool_node.position = s[1]
		tool_node.rotation_degrees.y = s[2]
		root.add_child(tool_node)


func _flat_mat(color: Color, roughness: float = 0.85, metallic: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metallic
	return m


func _box_mesh_instance(size: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	return mi


func _cyl_mesh_instance(top_r: float, bottom_r: float, h: float, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = top_r
	mesh.bottom_radius = bottom_r
	mesh.height = h
	mi.mesh = mesh
	mi.material_override = mat
	return mi


# Side cutters: two safety-orange handles splayed into a shallow V, metal jaws
# closing the other way, one pivot block holding the pair together.
func _tool_snippers() -> Node3D:
	var root := Node3D.new()
	var plastic := _flat_mat(Color(0.85, 0.33, 0.12), 0.55)
	var metal := _flat_mat(Color(0.72, 0.74, 0.76), 0.35, 0.9)
	for side in [-1.0, 1.0]:
		var handle := _box_mesh_instance(Vector3(0.13, 0.09, 1.15), plastic)
		handle.position = Vector3(side * 0.09, 0.07, 0.42)
		handle.rotation_degrees.y = side * 7.0
		root.add_child(handle)
		var jaw := _box_mesh_instance(Vector3(0.07, 0.05, 0.55), metal)
		jaw.position = Vector3(side * 0.035, 0.07, -0.42)
		jaw.rotation_degrees.y = -side * 4.0
		root.add_child(jaw)
	var pivot := _box_mesh_instance(Vector3(0.20, 0.11, 0.24), metal)
	pivot.position = Vector3(0.0, 0.07, 0.0)
	root.add_child(pivot)
	return root


# A brush lying on its side: wooden handle, bright metal ferrule, bristles
# dipped in `tip_color`.
func _tool_paintbrush(tip_color: Color) -> Node3D:
	var root := Node3D.new()
	var handle := _cyl_mesh_instance(0.048, 0.056, 1.05,
		_flat_mat(Color(0.58, 0.42, 0.26), 0.7))
	handle.rotation_degrees.x = 90.0
	handle.position = Vector3(0.0, 0.06, -0.5)
	root.add_child(handle)
	var ferrule := _cyl_mesh_instance(0.052, 0.052, 0.24,
		_flat_mat(Color(0.75, 0.76, 0.78), 0.35, 0.85))
	ferrule.rotation_degrees.x = 90.0
	ferrule.position = Vector3(0.0, 0.06, 0.18)
	root.add_child(ferrule)
	var bristles := _cyl_mesh_instance(0.03, 0.055, 0.30, _flat_mat(tip_color, 0.9))
	bristles.rotation_degrees.x = 90.0
	bristles.position = Vector3(0.0, 0.055, 0.44)
	root.add_child(bristles)
	return root


# A small stack of grit sheets, fanned slightly so the edges read as layers.
func _tool_sandpaper() -> Node3D:
	var root := Node3D.new()
	var sheets := [
		[Color(0.77, 0.64, 0.45), 0.0],
		[Color(0.63, 0.61, 0.58), 6.0],
		[Color(0.42, 0.40, 0.37), -4.0],
	]
	for i in range(sheets.size()):
		var sheet := _box_mesh_instance(Vector3(1.05, 0.02, 0.78),
			_flat_mat(sheets[i][0], 0.95))
		sheet.position = Vector3(0.0, 0.02 + i * 0.022, 0.0)
		sheet.rotation_degrees.y = sheets[i][1]
		root.add_child(sheet)
	return root


# A glue tube on its side: amber body, tapering shoulder, nozzle with an
# orange cap - polystyrene-cement shape language.
func _tool_glue_tube() -> Node3D:
	var root := Node3D.new()
	var body := _cyl_mesh_instance(0.125, 0.125, 0.60,
		_flat_mat(Color(0.92, 0.86, 0.70), 0.5))
	body.rotation_degrees.z = -90.0
	body.position = Vector3(-0.22, 0.135, 0.0)
	root.add_child(body)
	var shoulder := _cyl_mesh_instance(0.035, 0.125, 0.14,
		_flat_mat(Color(0.92, 0.86, 0.70), 0.5))
	shoulder.rotation_degrees.z = -90.0
	shoulder.position = Vector3(0.16, 0.135, 0.0)
	root.add_child(shoulder)
	var cap := _cyl_mesh_instance(0.032, 0.032, 0.10,
		_flat_mat(Color(0.85, 0.33, 0.12), 0.55))
	cap.rotation_degrees.z = -90.0
	cap.position = Vector3(0.28, 0.135, 0.0)
	root.add_child(cap)
	return root


# An enamel paint tin: squat coloured body, silver lid.
func _tool_paint_tin(color: Color) -> Node3D:
	var root := Node3D.new()
	var body := _cyl_mesh_instance(0.17, 0.17, 0.14, _flat_mat(color, 0.45))
	body.position.y = 0.08
	root.add_child(body)
	var lid := _cyl_mesh_instance(0.175, 0.175, 0.03,
		_flat_mat(Color(0.75, 0.76, 0.78), 0.3, 0.9))
	lid.position.y = 0.165
	root.add_child(lid)
	return root


# An acrylic paint tube standing on its cap, leaning slightly.
func _tool_paint_tube(color: Color) -> Node3D:
	var root := Node3D.new()
	var body := _cyl_mesh_instance(0.095, 0.115, 0.42,
		_flat_mat(Color(0.88, 0.88, 0.86), 0.6))
	body.position.y = 0.21
	root.add_child(body)
	var cap := _cyl_mesh_instance(0.05, 0.05, 0.08, _flat_mat(color, 0.5))
	cap.position.y = 0.46
	root.add_child(cap)
	root.rotation_degrees.z = 7.0
	return root

func _build_3d_showcase_model(item: Dictionary, parent: Node3D) -> void:
	var model_root = Node3D.new()
	model_root.position = Vector3(0, 0.1, 0)

	var item_type: String = item.get("type", "hull")
	_showcase_vehicle = null

	if item_type == "blueprint":
		var bp: Dictionary = item.get("blueprint", {})
		var mgr = BlueprintManagerScript.new()
		var vehicle = mgr.reconstruct_vehicle(bp, model_root, true)
		if vehicle == null:
			var hull_id := str(bp.get("hull_type", "brenntal_medium_a"))
			_build_hull_mesh_node(hull_id, model_root)
		else:
			# Kept for the SpecPlacard sync below - the SAME live node
			# DesignStats.analyze() reads elsewhere (the Lab rail, the battle
			# selection panel), so the Front Desk placard shows the identical
			# weight/speed/dps/range figures rather than a re-derivation.
			_showcase_vehicle = vehicle
	else:
		var hull_id: String = item.get("hull_type", "brenntal_medium_a")
		_build_hull_mesh_node(hull_id, model_root)

	# Apply uniform matte greenish-grey plastic finish (unpainted scale model sprue look)
	_apply_unpainted_scale_model_material(model_root)

	parent.add_child(model_root)

func _build_hull_mesh_node(hull_id: String, parent: Node3D) -> void:
	var mesh = MeshAssetLoader.get_hull_mesh(hull_id)
	var hull_data = ModuleCatalogScript.get_module_data(hull_id)
	var dim: Vector3 = hull_data.get("dimensions", Vector3(3.8, 1.1, 5.4))

	var mesh_inst = MeshInstance3D.new()
	if mesh != null:
		mesh_inst.mesh = mesh
	else:
		var box = BoxMesh.new()
		box.size = dim
		mesh_inst.mesh = box

	mesh_inst.position = Vector3(0, dim.y * 0.5, 0)
	parent.add_child(mesh_inst)

func _apply_unpainted_scale_model_material(node: Node, mat: StandardMaterial3D = null) -> void:
	# Don't overwrite alpha-cutout greeble cards (which are quads) with a solid opaque material.
	if node.name == "HullGreebles":
		return
		
	if mat == null:
		mat = StandardMaterial3D.new()
		mat.albedo_color = Color(0.38, 0.44, 0.37, 1.0) # Unpainted scale model greenish-grey plastic
		mat.metallic = 0.0
		mat.roughness = 0.8

	if node is GeometryInstance3D:
		node.material_override = mat
		node.material_overlay = null
	if node is MeshInstance3D and node.mesh:
		for i in range(node.mesh.get_surface_count()):
			node.set_surface_override_material(i, mat)
	for child in node.get_children():
		_apply_unpainted_scale_model_material(child, mat)

# The destination table remains the route authority; layout is screen-owned.
func _build_top_ribbon(parent: Control) -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.panel_style("header"))
	parent.add_child(panel)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.SPACE_SM)
	panel.add_child(row)
	var menu_icon := UITheme.industrial_icon("nav_main_menu")
	if menu_icon != null:
		var icon_rect := TextureRect.new()
		icon_rect.name = "MainMenuNavigationIcon"
		icon_rect.texture = menu_icon
		icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon_rect.custom_minimum_size = Vector2(Tokens.SPINE_ICON, Tokens.SPINE_ICON)
		icon_rect.modulate = Tokens.TEXT_PRIMARY
		icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(icon_rect)
	var title := Label.new()
	title.text = TITLE
	title.theme_type_variation = "TitleLabel"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(title)
	var system := UIShell.action(row, "Settings", "secondary")
	system.pressed.connect(func():
		var layer := get_node_or_null("/root/SystemLayer")
		if layer: layer.open())
	var quit_button := UIShell.action(row, "Exit", "secondary")
	quit_button.pressed.connect(func(): get_tree().quit())

func _build_destination_console(parent: Control) -> void:
	var panel := PanelContainer.new()
	panel.name = "DestinationConsole"
	panel.custom_minimum_size.x = 340
	panel.add_theme_stylebox_override("panel", UITheme.panel_style("surface"))
	parent.add_child(panel)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	panel.add_child(scroll)
	_destination_column = VBoxContainer.new()
	_destination_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_destination_column.add_theme_constant_override("separation", Tokens.SPACE_SM)
	scroll.add_child(_destination_column)
	var label := Label.new()
	label.text = "DESIGN BUREAU"
	label.theme_type_variation = "HeadingLabel"
	_destination_column.add_child(label)
	var hint := Label.new()
	hint.text = "Build a machine. Put it to work."
	hint.theme_type_variation = "HintLabel"
	_destination_column.add_child(hint)
	_add_destination(GROUPS[1]["items"][0], "primary", "DesignLabAction")
	_add_destination(GROUPS[0]["items"][2], "secondary", "TestRangeAction")
	_add_destination(GROUPS[0]["items"][0], "secondary", "MatchSetupAction")
	_destination_column.add_child(HSeparator.new())
	# Secondary destinations stay one click away in a vertically scrolling console.
	for group_index in [1, 0, 2]:
		var group: Dictionary = GROUPS[group_index]
		var heading := Label.new()
		heading.text = "WORKSHOP" if group_index == 1 else ("CAMPAIGN" if group_index == 0 else "LEARN")
		heading.theme_type_variation = "HintLabel"
		_destination_column.add_child(heading)
		for item: Dictionary in group["items"]:
			if item["title"] in ["DESIGN LAB", "PROVING GROUND", "SKIRMISH"]:
				continue
			_add_destination(item)
	var livery := UIShell.action(_destination_column, "Livery", "secondary")
	livery.pressed.connect(func(): _navigate_to("res://scenes/Livery.tscn"))

func _add_destination(item: Dictionary, role: String = "secondary", node_name: String = "") -> void:
	var button := UIShell.action(_destination_column, str(item["title"]).capitalize(), role)
	if node_name != "":
		button.name = node_name
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.tooltip_text = item["desc"]
	var icon_key := ""
	match str(item.get("scene", "")):
		"res://scenes/MainLab.tscn": icon_key = "nav_design_lab"
		"res://scenes/MatchSetup.tscn": icon_key = "nav_match_setup"
	if not icon_key.is_empty():
		var icon := UITheme.industrial_icon(icon_key)
		if icon != null:
			button.icon = icon
			button.expand_icon = true
			button.add_theme_constant_override("icon_max_width", Tokens.SPINE_ICON)
			button.add_theme_constant_override("h_separation", Tokens.SPACE_SM)
	button.set_meta("destination", item["scene"])
	button.pressed.connect(func(): _activate_destination(item))
	if role == "primary":
		var description := Label.new()
		description.text = "Fit parts, tune mechanisms, save your design."
		description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		description.theme_type_variation = "HintLabel"
		_destination_column.add_child(description)

func _activate_destination(item: Dictionary) -> void:
	if item.get("tutorial", false):
		var tutorial := get_node_or_null("/root/TwoPhaseTutorialManager")
		if tutorial:
			tutorial.begin()
			return
	if item.get("launcher", "") == "TestRangeLauncher":
		var launcher := TestRangeLauncherScript.new()
		add_child(launcher)
		if launcher.launch("main_menu"):
			return
		launcher.queue_free()
		return
	_navigate_to(item["scene"])

func _navigate_to(scene_path: String) -> void:
	var router := get_node_or_null("/root/SceneRouter")
	if router:
		router.goto(scene_path)
	else:
		get_tree().change_scene_to_file(scene_path)

func _build_status_column(parent: Control) -> void:
	var heading_row := HBoxContainer.new()
	heading_row.add_theme_constant_override("separation", Tokens.SPACE_SM)
	parent.add_child(heading_row)
	var heading := Label.new()
	heading.text = "DESIGN RECORD"
	heading.theme_type_variation = "HeadingLabel"
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading_row.add_child(heading)
	var cycle := UIShell.action(heading_row, "Next design", "secondary")
	cycle.tooltip_text = "Inspect the next saved design or stock chassis"
	cycle.pressed.connect(func():
		_showcase_timer = 0.0
		_next_showcase_item())
	_spec_placard = SpecPlacardScript.new()
	_spec_placard.level = SpecPlacardScript.Level.FRONT_DESK
	parent.add_child(_spec_placard)

func _update_placard_ui(item: Dictionary) -> void:
	if _spec_placard == null:
		return

	var item_type: String = item.get("type", "hull")
	var design_name := str(item.get("name", "UNKNOWN")).to_upper()

	if item_type == "blueprint":
		var bp: Dictionary = item.get("blueprint", {})
		var stats: Dictionary = {}
		if _showcase_vehicle != null and is_instance_valid(_showcase_vehicle):
			stats = DesignStatsScript.analyze(_showcase_vehicle)
		_spec_placard.from_blueprint(design_name, "CERTIFIED PLAYER BLUEPRINT", bp, stats)
	else:
		var hull_id: String = item.get("hull_type", "brenntal_medium_a")
		_spec_placard.from_blueprint(design_name, "STANDARD BUREAU CHASSIS // READY FOR ASSEMBLY",
			{"hull_type": hull_id})

func _prettify(id: String) -> String:
	if id == "":
		return "-"
	return id.replace("_", " ").capitalize()
