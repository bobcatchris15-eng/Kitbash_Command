extends Control
# THE LIVERY WORKSHOP - Authoring the player's unique visual identity.
#
# Offers full customization across:
# 1. 5 visual zones (colors and 18 tactile finishes)
# 2. 13 procedural patterns (racing stripes, chevrons, digital camo, hex grid, hazard bands, etc.)
# 3. Master service weathering dial (factory fresh -> battle hardened -> scavenged relic)
# 4. Insignia crests, badge styles, tactical callsign numbers, and hazard markings
# 5. One-click curated theme presets
# 6. Multi-subject 3D turntable preview with interactive orbit and zoom

const LiveryScript = preload("res://scripts/livery.gd")
const Tokens = preload("res://scripts/ui_tokens.gd")
const UIShell = preload("res://scripts/ui_shell.gd")
const UIFeedbackScript = preload("res://scripts/ui_feedback.gd")
const HullMaterialBuilderScript = preload("res://scripts/hull_material_builder.gd")
const BlueprintManagerScript = preload("res://scripts/blueprint_manager.gd")
const ToolboxPlateScript = preload("res://scripts/ui_toolbox_plate.gd")
const StampedLabelScript = preload("res://scripts/ui_stamped_label.gd")
const StampedButtonScript = preload("res://scripts/ui_stamped_button.gd")

var _livery: Dictionary = {}
var _pickers: Dictionary = {}        # zone id -> ColorPickerButton
var _finish_btns: Dictionary = {}    # zone id -> OptionButton
var _preview_root: Node3D = null
var _preview_hull: Node3D = null
var _preview_cam: Camera3D = null
var _bp_manager: Node = null

# PREVIEW SUBJECTS. The turntable used to show four hand-written blueprints
# (a medium tank, a heavy, a scout, a bare chassis) that no player ever built.
# Judging a paint scheme on a vehicle you do not own is the wrong test: the
# whole point of a livery is how it sits on YOUR silhouette, with your armor
# plates, your weapon mix and your ride height.
#
# So the list is now the player's own saved designs, most recently saved first,
# with the built-in reference chassis kept after them - both as a fallback for
# a player who has saved nothing yet, and because a neutral hull is genuinely
# useful for judging a pattern in isolation.
#
# Each entry is {"label": String} plus EITHER "path" (load it) or "builtin"
# (an index into _builtin_blueprint).
var _subjects: Array = []

# Turntable state
var _spin: float = 0.0
var _auto_spin: bool = true
var _cam_yaw: float = 0.65
var _cam_pitch: float = 0.38
var _cam_dist: float = 8.5

# Orbit range. Was a hardcoded 3.5-16 in three places, tuned for the four
# hand-written reference vehicles; a real saved design is often larger and
# _frame_camera_to_subject was pinning at the old 16 ceiling, so framing failed
# on exactly the subjects this screen now exists to show.
const CAM_DIST_MIN := 2.5
const CAM_DIST_MAX := 44.0
var _is_dragging: bool = false
var _last_mouse_pos: Vector2 = Vector2.ZERO

# UI controls
var _tab_container: Control = null
var _tab_buttons: Array = []
var _current_tab: int = 0
var _subject_btn: OptionButton = null
var _current_subject: int = 0

# Pattern controls
var _pattern_type_btn: OptionButton = null
var _pattern_scale_slider: HSlider = null
var _pattern_angle_slider: HSlider = null
var _pattern_softness_slider: HSlider = null
var _pattern_scale_val: Label = null
var _pattern_angle_val: Label = null

# Weathering controls
var _weathering_slider: HSlider = null
var _weathering_label: Label = null

# Decal controls
var _decal_icon_btn: OptionButton = null
var _decal_badge_btn: OptionButton = null
var _decal_serial_edit: LineEdit = null
var _decal_hazard_chk: CheckBox = null


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_livery = LiveryScript.load_player()

	UIShell.workbench(self, "cardboard")
	var frame := UIShell.screen_frame(self)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", Tokens.SPACE_MD)
	col.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.add_child(col)

	# --- Header ---
	var header := PanelContainer.new()
	header.theme_type_variation = "HeaderPanel"
	col.add_child(header)
	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", Tokens.SPACE_MD)
	header.add_child(header_row)

	var title_holder := Control.new()
	title_holder.custom_minimum_size = Vector2(250, 40)
	header_row.add_child(title_holder)
	var title: Control = StampedLabelScript.new()
	title.text = "LIVERY WORKSHOP"
	title.font_size = 26
	title.set_anchors_preset(Control.PRESET_FULL_RECT)
	title_holder.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Author custom paint schemes, tactical camouflage, tactile materials, and insignia crests for your forces."
	subtitle.theme_type_variation = "HintLabel"
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	subtitle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	subtitle.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header_row.add_child(subtitle)

	# --- Body (Tabs & Controls on Left, 3D Turntable on Right) ---
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", Tokens.SPACE_LG)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(body)

	# --- Left Column: Customization Deck ---
	var left_plate := _plated_section(body, "CUSTOMIZATION DECK", 600)
	
	# Tab selector row
	var tab_bar := HBoxContainer.new()
	tab_bar.add_theme_constant_override("separation", 6)
	left_plate.add_child(tab_bar)

	var tab_titles := ["COLORS & ZONES", "PATTERNS", "FINISHES & WEAR", "DECALS", "PRESETS", "BUILDING STYLES"]
	for i in range(tab_titles.size()):
		var t_btn := Button.new()
		t_btn.text = tab_titles[i]
		t_btn.toggle_mode = true
		t_btn.button_pressed = (i == 0)
		t_btn.custom_minimum_size = Vector2(90, 34)
		t_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UIFeedbackScript.wire(t_btn)
		t_btn.pressed.connect(_on_tab_clicked.bind(i))
		tab_bar.add_child(t_btn)
		_tab_buttons.append(t_btn)

	# Tab Container contents
	_tab_container = VBoxContainer.new()
	_tab_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tab_container.add_theme_constant_override("separation", Tokens.SPACE_MD)
	left_plate.add_child(_tab_container)

	_build_tab_colors()
	_build_tab_patterns()
	_build_tab_finishes()
	_build_tab_decals()
	_build_tab_colors()
	_build_tab_patterns()
	_build_tab_finishes()
	_build_tab_decals()
	_build_tab_presets()
	_build_tab_building_styles()

	_switch_tab(0)

	# --- Right Column: Interactive 3D Turntable Preview ---
	var right_plate := _plated_section(body, "TACTICAL PREVIEW", 500)
	
	var preview_top_bar := HBoxContainer.new()
	preview_top_bar.add_theme_constant_override("separation", Tokens.SPACE_SM)
	right_plate.add_child(preview_top_bar)

	var subj_label := Label.new()
	subj_label.text = "Subject:"
	subj_label.theme_type_variation = "HeadingLabel"
	preview_top_bar.add_child(subj_label)

	# _bp_manager is created here rather than in _build_preview_scene (which
	# runs later, at the viewport) because populating this dropdown needs to
	# list the player's saved designs first.
	_bp_manager = BlueprintManagerScript.new()
	add_child(_bp_manager)
	_build_subject_list()

	_subject_btn = OptionButton.new()
	for i in range(_subjects.size()):
		_subject_btn.add_item(str(_subjects[i]["label"]), i)
	_subject_btn.selected = 0
	_current_subject = 0
	_subject_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIFeedbackScript.wire(_subject_btn)
	_subject_btn.item_selected.connect(_on_subject_selected)
	preview_top_bar.add_child(_subject_btn)

	var spin_btn := Button.new()
	spin_btn.text = "Auto-Spin: ON"
	spin_btn.toggle_mode = true
	spin_btn.button_pressed = true
	UIFeedbackScript.wire(spin_btn)
	spin_btn.toggled.connect(func(pressed: bool):
		_auto_spin = pressed
		spin_btn.text = "Auto-Spin: ON" if pressed else "Auto-Spin: OFF"
	)
	preview_top_bar.add_child(spin_btn)

	var reset_cam_btn := Button.new()
	reset_cam_btn.text = "Reset View"
	UIFeedbackScript.wire(reset_cam_btn)
	reset_cam_btn.pressed.connect(_reset_camera)
	preview_top_bar.add_child(reset_cam_btn)

	# Recessed 3D Viewport Well
	var well := PanelContainer.new()
	well.theme_type_variation = "InsetPanel"
	well.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_plate.add_child(well)

	var preview_viewport := SubViewportContainer.new()
	preview_viewport.custom_minimum_size = Vector2(460, 360)
	preview_viewport.stretch = true
	preview_viewport.size_flags_vertical = Control.SIZE_EXPAND_FILL
	preview_viewport.gui_input.connect(_on_preview_gui_input)
	well.add_child(preview_viewport)

	var vp := SubViewport.new()
	vp.transparent_bg = true
	vp.size = Vector2i(460, 360)
	preview_viewport.add_child(vp)

	_preview_root = Node3D.new()
	vp.add_child(_preview_root)
	_build_preview_scene(vp)

	var preview_hint := Label.new()
	preview_hint.text = "Drag with Left Mouse Button to rotate turntable. Mouse Wheel to zoom in/out."
	preview_hint.theme_type_variation = "HintLabel"
	preview_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right_plate.add_child(preview_hint)

	# --- Bottom Actions Bar ---
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.SPACE_SM)
	col.add_child(row)

	var random_btn := StampedButtonScript.new()
	random_btn.legend = "RANDOMISE"
	random_btn.custom_minimum_size = Vector2(170, 44)
	UIFeedbackScript.wire(random_btn)
	random_btn.pressed.connect(_on_randomise)
	row.add_child(random_btn)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	var back_btn := StampedButtonScript.new()
	back_btn.legend = "RETURN"
	back_btn.variant = StampedButtonScript.Variant.GHOST
	back_btn.custom_minimum_size = Vector2(150, 44)
	UIFeedbackScript.wire(back_btn)
	back_btn.pressed.connect(func():
		var router = get_node_or_null("/root/SceneRouter")
		if router:
			router.goto("res://scenes/MainMenu.tscn")
		else:
			get_tree().change_scene_to_file("res://scenes/MainMenu.tscn")
	)
	row.add_child(back_btn)

	var save_btn := StampedButtonScript.new()
	save_btn.legend = "COMMIT LIVERY"
	save_btn.variant = StampedButtonScript.Variant.PRIMARY
	save_btn.custom_minimum_size = Vector2(210, 44)
	UIFeedbackScript.wire(save_btn, "confirm")
	save_btn.pressed.connect(_on_save)
	row.add_child(save_btn)


# ---------------------------------------------------------------------------
# TAB 1: COLORS & ZONES
# ---------------------------------------------------------------------------
var _tab_colors_node: Control = null

func _build_tab_colors() -> void:
	_tab_colors_node = VBoxContainer.new()
	_tab_colors_node.add_theme_constant_override("separation", Tokens.SPACE_MD)
	_tab_container.add_child(_tab_colors_node)

	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", Tokens.SPACE_MD)
	grid.add_theme_constant_override("v_separation", Tokens.SPACE_SM)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tab_colors_node.add_child(grid)

	# EDITABLE_ZONES, not ZONES: the two weapon zones no longer drive any
	# geometry, so their pickers are omitted. See the note on EDITABLE_ZONES in
	# livery.gd. _sync_all_controls() still walks the full ZONES list and is
	# already guarded on _pickers.has()/_finish_btns.has(), so it is unaffected.
	for zone in LiveryScript.EDITABLE_ZONES:
		var zid: String = zone["id"]
		var label := Label.new()
		label.text = zone["name"]
		label.theme_type_variation = "HeadingLabel"
		label.custom_minimum_size = Vector2(160, Tokens.HIT_TARGET_MIN)
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		grid.add_child(label)

		var picker := ColorPickerButton.new()
		picker.custom_minimum_size = Vector2(90, Tokens.HIT_TARGET_MIN + 4)
		var z_data = _livery.get(zid, {})
		picker.color = z_data.get("color", Color(0.5, 0.5, 0.5))
		picker.edit_alpha = false
		UIFeedbackScript.wire(picker)
		picker.color_changed.connect(_on_color_changed.bind(zid))
		grid.add_child(picker)
		_pickers[zid] = picker

		var finish := OptionButton.new()
		finish.custom_minimum_size = Vector2(210, Tokens.HIT_TARGET_MIN + 4)
		var ids := LiveryScript.finish_ids()
		for i in range(ids.size()):
			finish.add_item(LiveryScript.finish_name(ids[i]), i)
			if ids[i] == z_data.get("finish", "matte_primer"):
				finish.selected = i
		UIFeedbackScript.wire(finish)
		finish.item_selected.connect(_on_finish_selected.bind(zid))
		grid.add_child(finish)
		_finish_btns[zid] = finish

	var hint := Label.new()
	hint.text = "Finishes feature distinct tactile micro-surfaces (Carbon Fibre weave, Hammered metal, Galvanised zinc spangles, Brushed alloy, Cerakote chalk matte)."
	hint.theme_type_variation = "HintLabel"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tab_colors_node.add_child(hint)


# ---------------------------------------------------------------------------
# TAB 2: PROCEDURAL PATTERNS
# ---------------------------------------------------------------------------
var _tab_patterns_node: Control = null

func _build_tab_patterns() -> void:
	_tab_patterns_node = VBoxContainer.new()
	_tab_patterns_node.add_theme_constant_override("separation", Tokens.SPACE_MD)
	_tab_container.add_child(_tab_patterns_node)

	var p_data: Dictionary = _livery.get("pattern", {})

	# Pattern Type selector
	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", Tokens.SPACE_MD)
	_tab_patterns_node.add_child(row1)

	var l_type := Label.new()
	l_type.text = "Pattern Type:"
	l_type.custom_minimum_size = Vector2(140, 36)
	l_type.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row1.add_child(l_type)

	_pattern_type_btn = OptionButton.new()
	_pattern_type_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var p_ids := LiveryScript.pattern_ids()
	var current_p_type := str(p_data.get("type", "stripe"))
	for i in range(p_ids.size()):
		_pattern_type_btn.add_item(LiveryScript.pattern_name(p_ids[i]), i)
		if p_ids[i] == current_p_type:
			_pattern_type_btn.selected = i
	UIFeedbackScript.wire(_pattern_type_btn)
	_pattern_type_btn.item_selected.connect(_on_pattern_type_selected)
	row1.add_child(_pattern_type_btn)

	# Pattern Scale Slider
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", Tokens.SPACE_MD)
	_tab_patterns_node.add_child(row2)

	var l_scale := Label.new()
	l_scale.text = "Pattern Scale / Density:"
	l_scale.custom_minimum_size = Vector2(170, 32)
	row2.add_child(l_scale)

	_pattern_scale_slider = HSlider.new()
	_pattern_scale_slider.min_value = 0.3
	_pattern_scale_slider.max_value = 3.0
	_pattern_scale_slider.step = 0.05
	_pattern_scale_slider.value = float(p_data.get("scale", 1.0))
	_pattern_scale_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pattern_scale_slider.value_changed.connect(func(v: float):
		_livery["pattern"]["scale"] = v
		_pattern_scale_val.text = "%.2fx" % v
		_apply_live()
	)
	row2.add_child(_pattern_scale_slider)

	_pattern_scale_val = Label.new()
	_pattern_scale_val.text = "%.2fx" % _pattern_scale_slider.value
	_pattern_scale_val.custom_minimum_size = Vector2(50, 32)
	row2.add_child(_pattern_scale_val)

	# Pattern Angle Slider
	var row3 := HBoxContainer.new()
	row3.add_theme_constant_override("separation", Tokens.SPACE_MD)
	_tab_patterns_node.add_child(row3)

	var l_angle := Label.new()
	l_angle.text = "Pattern Angle:"
	l_angle.custom_minimum_size = Vector2(170, 32)
	row3.add_child(l_angle)

	_pattern_angle_slider = HSlider.new()
	_pattern_angle_slider.min_value = -90.0
	_pattern_angle_slider.max_value = 90.0
	_pattern_angle_slider.step = 5.0
	_pattern_angle_slider.value = float(p_data.get("angle", 0.0))
	_pattern_angle_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pattern_angle_slider.value_changed.connect(func(v: float):
		_livery["pattern"]["angle"] = v
		_pattern_angle_val.text = "%d°" % int(v)
		_apply_live()
	)
	row3.add_child(_pattern_angle_slider)

	_pattern_angle_val = Label.new()
	_pattern_angle_val.text = "%d°" % int(_pattern_angle_slider.value)
	_pattern_angle_val.custom_minimum_size = Vector2(50, 32)
	row3.add_child(_pattern_angle_val)

	# Quick Angle buttons
	var quick_angles := HBoxContainer.new()
	quick_angles.add_theme_constant_override("separation", Tokens.SPACE_SM)
	_tab_patterns_node.add_child(quick_angles)
	var q_lbl := Label.new()
	q_lbl.text = "Quick Align:"
	q_lbl.theme_type_variation = "HintLabel"
	quick_angles.add_child(q_lbl)
	for ang in [0, 45, 90, -45]:
		var b := Button.new()
		b.text = "%d°" % ang
		b.custom_minimum_size = Vector2(54, 28)
		b.pressed.connect(func():
			_pattern_angle_slider.value = ang
		)
		quick_angles.add_child(b)

	# Pattern Softness Slider
	var row4 := HBoxContainer.new()
	row4.add_theme_constant_override("separation", Tokens.SPACE_MD)
	_tab_patterns_node.add_child(row4)

	var l_soft := Label.new()
	l_soft.text = "Edge Definition:"
	l_soft.custom_minimum_size = Vector2(170, 32)
	row4.add_child(l_soft)

	_pattern_softness_slider = HSlider.new()
	_pattern_softness_slider.min_value = 0.003
	_pattern_softness_slider.max_value = 0.15
	_pattern_softness_slider.step = 0.005
	_pattern_softness_slider.value = float(p_data.get("softness", 0.015))
	_pattern_softness_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pattern_softness_slider.value_changed.connect(func(v: float):
		_livery["pattern"]["softness"] = v
		_apply_live()
	)
	row4.add_child(_pattern_softness_slider)


# ---------------------------------------------------------------------------
# TAB 3: FINISHES & WEAR
# ---------------------------------------------------------------------------
var _tab_finishes_node: Control = null

func _build_tab_finishes() -> void:
	_tab_finishes_node = VBoxContainer.new()
	_tab_finishes_node.add_theme_constant_override("separation", Tokens.SPACE_MD)
	_tab_container.add_child(_tab_finishes_node)

	var w_title := Label.new()
	w_title.text = "SERVICE WEATHERING & BATTLE WEAR"
	w_title.theme_type_variation = "HeadingLabel"
	_tab_finishes_node.add_child(w_title)

	var w_row := HBoxContainer.new()
	w_row.add_theme_constant_override("separation", Tokens.SPACE_MD)
	_tab_finishes_node.add_child(w_row)

	_weathering_slider = HSlider.new()
	_weathering_slider.min_value = 0.0
	_weathering_slider.max_value = 1.0
	_weathering_slider.step = 0.05
	_weathering_slider.value = float(_livery.get("weathering", 0.2))
	_weathering_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_weathering_slider.value_changed.connect(_on_weathering_changed)
	w_row.add_child(_weathering_slider)

	_weathering_label = Label.new()
	_weathering_label.custom_minimum_size = Vector2(160, 32)
	_update_weathering_label(_weathering_slider.value)
	w_row.add_child(_weathering_label)

	var w_desc := Label.new()
	w_desc.text = "Controls edge paint chipping, corner bare steel exposure, and soot/grime accumulation in crevices across all vehicle surfaces."
	w_desc.theme_type_variation = "HintLabel"
	w_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tab_finishes_node.add_child(w_desc)

	# Quick weathering buttons
	var quick_wear := HBoxContainer.new()
	quick_wear.add_theme_constant_override("separation", Tokens.SPACE_SM)
	_tab_finishes_node.add_child(quick_wear)
	for w_preset in [["Factory Fresh", 0.0], ["Field Standard", 0.25], ["Battle Hardened", 0.65], ["Scavenged Relic", 0.95]]:
		var b := Button.new()
		b.text = w_preset[0]
		b.custom_minimum_size = Vector2(120, 32)
		b.pressed.connect(func():
			_weathering_slider.value = w_preset[1]
		)
		quick_wear.add_child(b)


# ---------------------------------------------------------------------------
# TAB 4: DECALS & INSIGNIA
# ---------------------------------------------------------------------------
var _tab_decals_node: Control = null

func _build_tab_decals() -> void:
	_tab_decals_node = VBoxContainer.new()
	_tab_decals_node.add_theme_constant_override("separation", Tokens.SPACE_MD)
	_tab_container.add_child(_tab_decals_node)

	var d_data: Dictionary = _livery.get("decal", {})

	# Insignia Icon
	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", Tokens.SPACE_MD)
	_tab_decals_node.add_child(row1)

	var l_icon := Label.new()
	l_icon.text = "Insignia Emblem:"
	l_icon.custom_minimum_size = Vector2(150, 36)
	row1.add_child(l_icon)

	_decal_icon_btn = OptionButton.new()
	_decal_icon_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var current_icon := str(d_data.get("icon", "gear"))
	for i in range(LiveryScript.MASCOT_SHAPES.size()):
		var s_name: String = LiveryScript.MASCOT_SHAPES[i].capitalize().replace("_", " ")
		_decal_icon_btn.add_item(s_name, i)
		if LiveryScript.MASCOT_SHAPES[i] == current_icon:
			_decal_icon_btn.selected = i
	UIFeedbackScript.wire(_decal_icon_btn)
	_decal_icon_btn.item_selected.connect(func(idx: int):
		_livery["decal"]["icon"] = LiveryScript.MASCOT_SHAPES[idx]
		_apply_live()
	)
	row1.add_child(_decal_icon_btn)

	# Badge Style
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", Tokens.SPACE_MD)
	_tab_decals_node.add_child(row2)

	var l_badge := Label.new()
	l_badge.text = "Badge Backing:"
	l_badge.custom_minimum_size = Vector2(150, 36)
	row2.add_child(l_badge)

	_decal_badge_btn = OptionButton.new()
	_decal_badge_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_decal_badge_btn.add_item("Dark Circular Patch", 0)
	_decal_badge_btn.add_item("None (Bare Stencil)", 1)
	_decal_badge_btn.selected = 0 if d_data.get("badge", "circle") == "circle" else 1
	UIFeedbackScript.wire(_decal_badge_btn)
	_decal_badge_btn.item_selected.connect(func(idx: int):
		_livery["decal"]["badge"] = "circle" if idx == 0 else "none"
		_apply_live()
	)
	row2.add_child(_decal_badge_btn)

	# Callsign / Serial Number
	var row3 := HBoxContainer.new()
	row3.add_theme_constant_override("separation", Tokens.SPACE_MD)
	_tab_decals_node.add_child(row3)

	var l_serial := Label.new()
	l_serial.text = "Unit Callsign / Serial #:"
	l_serial.custom_minimum_size = Vector2(150, 36)
	row3.add_child(l_serial)

	_decal_serial_edit = LineEdit.new()
	_decal_serial_edit.text = str(d_data.get("serial", "101"))
	_decal_serial_edit.max_length = 4
	_decal_serial_edit.custom_minimum_size = Vector2(120, 36)
	_decal_serial_edit.text_changed.connect(func(new_text: String):
		_livery["decal"]["serial"] = new_text
		_apply_live()
	)
	row3.add_child(_decal_serial_edit)

	# Hazard chevrons toggle
	_decal_hazard_chk = CheckBox.new()
	_decal_hazard_chk.text = "Display Tail Hazard Warning Chevrons"
	_decal_hazard_chk.button_pressed = bool(d_data.get("show_hazard", true))
	UIFeedbackScript.wire(_decal_hazard_chk)
	_decal_hazard_chk.toggled.connect(func(pressed: bool):
		_livery["decal"]["show_hazard"] = pressed
		_apply_live()
	)
	_tab_decals_node.add_child(_decal_hazard_chk)


# ---------------------------------------------------------------------------
# TAB 5: PRESETS
# ---------------------------------------------------------------------------
var _tab_presets_node: Control = null

func _build_tab_presets() -> void:
	_tab_presets_node = VBoxContainer.new()
	_tab_presets_node.add_theme_constant_override("separation", Tokens.SPACE_MD)
	_tab_container.add_child(_tab_presets_node)

	var p_grid := GridContainer.new()
	p_grid.columns = 2
	p_grid.add_theme_constant_override("h_separation", Tokens.SPACE_MD)
	p_grid.add_theme_constant_override("v_separation", Tokens.SPACE_SM)
	_tab_presets_node.add_child(p_grid)

	for p_key in LiveryScript.PRESETS.keys():
		var p_info: Dictionary = LiveryScript.PRESETS[p_key]
		var b := Button.new()
		b.text = p_info["name"]
		b.custom_minimum_size = Vector2(240, 42)
		UIFeedbackScript.wire(b)
		b.pressed.connect(_apply_preset.bind(p_key))
		p_grid.add_child(b)


# ---------------------------------------------------------------------------
# TAB NAVIGATION
# ---------------------------------------------------------------------------
const BuildingMeshSets = preload("res://scripts/building_mesh_sets.gd")
var _tab_building_styles_node: Control = null

func _build_tab_building_styles() -> void:
	_tab_building_styles_node = VBoxContainer.new()
	_tab_building_styles_node.add_theme_constant_override("separation", Tokens.SPACE_MD)
	_tab_container.add_child(_tab_building_styles_node)
	
	var label := Label.new()
	label.text = "Select Architectural Set:"
	label.theme_type_variation = "HeadingLabel"
	_tab_building_styles_node.add_child(label)
	
	var opt := OptionButton.new()
	var sets := BuildingMeshSets.get_set_list()
	for i in range(sets.size()):
		opt.add_item(sets[i]["name"], i)
		if _livery.get("building_mesh_set") == sets[i]["id"]:
			opt.selected = i
	UIFeedbackScript.wire(opt)
	opt.item_selected.connect(func(idx: int):
		_livery["building_mesh_set"] = sets[idx]["id"]
		_apply_live()
	)
	_tab_building_styles_node.add_child(opt)
	
func _switch_tab(index: int) -> void:
	_current_tab = index
	for i in range(_tab_buttons.size()):
		_tab_buttons[i].button_pressed = (i == index)
	_tab_colors_node.visible = (index == 0)
	_tab_patterns_node.visible = (index == 1)
	_tab_finishes_node.visible = (index == 2)
	_tab_decals_node.visible = (index == 3)
	_tab_presets_node.visible = (index == 4)
	_tab_building_styles_node.visible = (index == 5)

func _on_tab_clicked(index: int) -> void:
	_switch_tab(index)


# ---------------------------------------------------------------------------
# PREVIEW 3D SCENE & INTERACTIVITY
# ---------------------------------------------------------------------------
func _build_preview_scene(vp: SubViewport) -> void:
	_preview_cam = Camera3D.new()
	_update_camera_transform()
	_preview_root.add_child(_preview_cam)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-42.0, 38.0, 0.0)
	key.light_energy = 1.15
	_preview_root.add_child(key)

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-24.0, -128.0, 0.0)
	fill.light_energy = 0.35
	_preview_root.add_child(fill)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Tokens.BASE_900
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.68, 0.65, 0.58)
	e.ambient_light_energy = 0.80
	e.tonemap_exposure = 0.98
	env.environment = e
	_preview_root.add_child(env)

	# _bp_manager was already created when the subject dropdown was populated.
	_apply_live()

func _update_camera_transform() -> void:
	if _preview_cam == null:
		return
	var cp := Vector3(
		_cam_dist * cos(_cam_pitch) * sin(_cam_yaw),
		_cam_dist * sin(_cam_pitch) + 0.35,
		_cam_dist * cos(_cam_pitch) * cos(_cam_yaw)
	)
	_preview_cam.position = cp
	_preview_cam.look_at_from_position(cp, Vector3(0.0, 0.35, 0.0), Vector3.UP)

# Proportional, because a fixed 0.5 m step is a sensible nudge at 8 m orbit and
# uselessly slow at 40 m.
func _zoom_step() -> float:
	return clampf(_cam_dist * 0.12, 0.25, 4.0)


func _reset_camera() -> void:
	_cam_yaw = 0.65
	_cam_pitch = 0.38
	# Re-frame to the current subject rather than restoring the old fixed 8.5,
	# which on a large design would put the camera inside the hull.
	_cam_dist = 8.5
	_update_camera_transform()
	_frame_camera_to_subject()

func _on_preview_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_is_dragging = event.pressed
			_last_mouse_pos = event.position
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_cam_dist = clampf(_cam_dist - _zoom_step(), CAM_DIST_MIN, CAM_DIST_MAX)
			_update_camera_transform()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_cam_dist = clampf(_cam_dist + _zoom_step(), CAM_DIST_MIN, CAM_DIST_MAX)
			_update_camera_transform()
	elif event is InputEventMouseMotion and _is_dragging:
		var delta: Vector2 = event.position - _last_mouse_pos
		_last_mouse_pos = event.position
		_cam_yaw -= delta.x * 0.012
		_cam_pitch = clampf(_cam_pitch + delta.y * 0.012, -0.3, 1.4)
		_update_camera_transform()

func _process(delta: float) -> void:
	if _auto_spin and not _is_dragging and is_instance_valid(_preview_hull):
		_spin += delta * 0.35
		_preview_hull.rotation.y = _spin

func _on_subject_selected(index: int) -> void:
	_current_subject = index
	_rebuild_preview()

func _rebuild_preview() -> void:
	if is_instance_valid(_preview_hull):
		_preview_root.remove_child(_preview_hull)
		_preview_hull.queue_free()
		_preview_hull = null
	if _bp_manager == null:
		return

	var subj: Dictionary = _subjects[_current_subject] if _current_subject < _subjects.size() else {}
	var blueprint: Dictionary = {}
	if subj.has("path"):
		blueprint = _bp_manager.load_blueprint(str(subj["path"]))
		# A design can be deleted or corrupted between the dropdown being
		# populated and being clicked; fall back rather than showing nothing.
		if blueprint.is_empty():
			push_warning("LIVERY: could not load design '%s'; showing reference chassis." % subj.get("label", "?"))
			blueprint = _builtin_blueprint(0)
	else:
		blueprint = _builtin_blueprint(int(subj.get("builtin", 0)))

	# The 4th argument overrides the blueprint's own saved `faction`, which is
	# what makes a real design show the livery being EDITED rather than
	# whatever it happened to be saved wearing.
	_preview_hull = _bp_manager.reconstruct_vehicle(blueprint, _preview_root, false, LiveryScript.PLAYER_ID)
	_spin = 0.0
	_frame_camera_to_subject()

# Most recently SAVED first. `modified_unix` is written by
# blueprint_manager.save_blueprint(); the Design Lab's scratch file is not a
# save and deliberately does not appear here (see the scratch-vs-saved note in
# blueprint_manager.gd).
#
# read_only entries are the built-in default roster shipped in
# res://assets/blueprints/default_roster. They are not the player's designs, so
# they are excluded here and the reference chassis below serve that purpose.
func _build_subject_list() -> void:
	_subjects.clear()
	var mine: Array = []
	for entry in _bp_manager.list_blueprints():
		if bool(entry.get("read_only", false)):
			continue
		mine.append(entry)
	mine.sort_custom(func(a, b): return int(a.get("modified_unix", 0)) > int(b.get("modified_unix", 0)))
	for entry in mine:
		_subjects.append({
			"label": str(entry.get("name", "Untitled Design")),
			"path": str(entry.get("path", "")),
		})
	var builtin_labels := ["Reference: Medium Chassis", "Reference: Heavy Chassis",
		"Reference: Scout Chassis", "Reference: Bare Hull"]
	for i in range(builtin_labels.size()):
		_subjects.append({"label": builtin_labels[i], "builtin": i})


# The hand-written reference vehicles. Kept because a player with no saves yet
# still needs something on the turntable, and because a neutral hull is the
# right subject for judging a pattern's scale without a loadout in the way.
func _builtin_blueprint(which: int) -> Dictionary:
	var blueprint: Dictionary
	match which:
		0:
			# Medium Assault Tank with Turret & Wheels
			blueprint = {
				"version": 2.0,
				"hull_type": "brenntal_medium_a",
				"hull_scale": {"x": 1.0, "y": 1.0, "z": 1.0},
				"armor_material": "hardened_steel",
				"faction": LiveryScript.PLAYER_ID,
				"modules": [
					{
						"id": "turret_gun",
						"type": "basic_cannon",
						"slot_type": "turret",
						"position": {"x": 0.0, "y": 0.55, "z": 0.1},
						"rotation": {"x": 0.0, "y": 0.0, "z": 0.0},
					},
					{
						"id": "wheels_loco",
						"type": "wheels",
						"slot_type": "locomotion",
						"position": {"x": 0.0, "y": -0.3, "z": 0.0},
						"rotation": {"x": 0.0, "y": 0.0, "z": 0.0},
					}
				],
			}
		1:
			# Heavy Combat Brawler
			blueprint = {
				"version": 2.0,
				"hull_type": "brenntal_heavy_a",
				"hull_scale": {"x": 1.0, "y": 1.0, "z": 1.0},
				"armor_material": "hardened_steel",
				"faction": LiveryScript.PLAYER_ID,
				"modules": [
					{
						"id": "heavy_gun",
						"type": "basic_cannon",
						"slot_type": "turret",
						"position": {"x": 0.0, "y": 0.65, "z": 0.2},
						"rotation": {"x": 0.0, "y": 0.0, "z": 0.0},
					}
				],
			}
		2:
			# Interceptor Scout
			blueprint = {
				"version": 2.0,
				"hull_type": "brenntal_scout_a",
				"hull_scale": {"x": 1.0, "y": 1.0, "z": 1.0},
				"armor_material": "hardened_steel",
				"faction": LiveryScript.PLAYER_ID,
				"modules": [
					{
						"id": "scout_gun",
						"type": "basic_cannon",
						"slot_type": "turret",
						"position": {"x": 0.0, "y": 0.35, "z": -0.1},
						"rotation": {"x": 0.0, "y": 0.0, "z": 0.0},
					}
				],
			}
		_:
			# Clean Chassis
			blueprint = {
				"version": 2.0,
				"hull_type": "brenntal_medium_a",
				"hull_scale": {"x": 1.0, "y": 1.0, "z": 1.0},
				"armor_material": "hardened_steel",
				"faction": LiveryScript.PLAYER_ID,
				"modules": [],
			}

	return blueprint


# A real design can be anything from a scout to a heavy with sponsons, so the
# fixed 8.5 m orbit the hand-written subjects were tuned for would clip a large
# hull and leave a small one as a dot. Frames to the assembled silhouette.
func _frame_camera_to_subject() -> void:
	if not is_instance_valid(_preview_hull):
		return
	var span := 0.0
	var stack: Array = [[_preview_hull as Node3D, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var entry: Array = stack.pop_back()
		var node: Node = entry[0]
		var xf: Transform3D = entry[1]
		for child in node.get_children():
			if child is Node3D:
				stack.append([child, xf * (child as Node3D).transform])
		if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
			var ab: AABB = (node as MeshInstance3D).mesh.get_aabb()
			for i in range(8):
				span = maxf(span, (xf * ab.get_endpoint(i)).length())
	if span <= 0.0:
		return
	# Solve the fit from the camera's real FOV rather than a guessed multiplier.
	# A guessed 2.6x radius put a saved design at about 60% too far - a dot in
	# the middle of the viewport - because for Godot's default 75 deg vertical
	# FOV the distance needed to just contain a sphere of radius r is
	# r / tan(fov/2), which is ~1.3r, not 2.6r.
	#
	# `span` is the bounding-sphere radius about the hull ORIGIN, not about the
	# mesh centre, which is deliberate: the origin is what the turntable
	# rotates around, so a sphere about it is the volume the subject sweeps
	# through while spinning. Framing to the mesh centre instead would let a
	# vehicle whose origin sits off-centre swing out of shot mid-rotation.
	var fov_rad: float = deg_to_rad(_preview_cam.fov if _preview_cam != null else 75.0)
	var fit: float = span / maxf(tan(fov_rad * 0.5), 0.01)
	# 1.15 leaves a little air around the silhouette rather than pressing it
	# against the frame edge.
	_cam_dist = clampf(fit * 1.15, CAM_DIST_MIN, CAM_DIST_MAX)
	_update_camera_transform()


func _apply_live() -> void:
	LiveryScript._cache[LiveryScript.PLAYER_ID] = _livery.duplicate(true)
	_rebuild_preview()


# ---------------------------------------------------------------------------
# UI EVENT HANDLERS
# ---------------------------------------------------------------------------
func _on_color_changed(color: Color, zone_id: String) -> void:
	if not _livery.has(zone_id):
		_livery[zone_id] = {}
	_livery[zone_id]["color"] = color
	_check_livery_contrast(color, zone_id)
	_apply_live()


# Livery contrast validation: warn if the picked color is too close to the
# average terrain luminance. Uses WCAG contrast ratio; warns below 1.5:1
# (the "barely distinguishable" threshold for adjacent same-size elements).
# Terrain reference: average ground albedo ≈ 0.28 luminance (green/brown mix).
const _TERRAIN_LUMINANCE := 0.28
const _CONTRAST_WARN_THRESHOLD := 1.5

func _check_livery_contrast(color: Color, zone_id: String) -> void:
	var luma := color.get_luminance()
	var lighter: float = max(luma, _TERRAIN_LUMINANCE)
	var darker: float = min(luma, _TERRAIN_LUMINANCE)
	var ratio: float = (lighter + 0.05) / (darker + 0.05)
	if ratio < _CONTRAST_WARN_THRESHOLD:
		var zone_label := zone_id.replace("_", " ").capitalize()
		push_warning("LIVERY: %s color (luminance %.2f) has low contrast against terrain (%.1f:1). Consider a lighter or darker pick." % [zone_label, luma, ratio])

func _on_finish_selected(index: int, zone_id: String) -> void:
	var ids := LiveryScript.finish_ids()
	if index < 0 or index >= ids.size():
		return
	if not _livery.has(zone_id):
		_livery[zone_id] = {}
	_livery[zone_id]["finish"] = ids[index]
	_apply_live()

func _on_pattern_type_selected(index: int) -> void:
	var ids := LiveryScript.pattern_ids()
	if index < 0 or index >= ids.size():
		return
	_livery["pattern"]["type"] = ids[index]
	_apply_live()

func _on_weathering_changed(val: float) -> void:
	_livery["weathering"] = val
	_update_weathering_label(val)
	_apply_live()

func _update_weathering_label(val: float) -> void:
	if val < 0.15:
		_weathering_label.text = "Showroom Fresh (%d%%)" % int(val * 100)
	elif val < 0.45:
		_weathering_label.text = "Field Standard (%d%%)" % int(val * 100)
	elif val < 0.75:
		_weathering_label.text = "Battle Hardened (%d%%)" % int(val * 100)
	else:
		_weathering_label.text = "Scavenged Relic (%d%%)" % int(val * 100)

func _apply_preset(preset_key: String) -> void:
	if not LiveryScript.PRESETS.has(preset_key):
		return
	# The flat-preset -> runtime-shape conversion lives in
	# LiveryScript.from_preset so that this screen and for_id() (which is what
	# a battle goes through) cannot disagree about what a preset means.
	_livery = LiveryScript.from_preset(preset_key)
	_sync_all_controls()
	_apply_live()

func _sync_all_controls() -> void:
	# Sync zone pickers
	for zone in LiveryScript.ZONES:
		var zid: String = zone["id"]
		if _pickers.has(zid):
			_pickers[zid].color = _livery[zid]["color"]
		if _finish_btns.has(zid):
			var ids := LiveryScript.finish_ids()
			var idx := ids.find(_livery[zid]["finish"])
			if idx >= 0:
				_finish_btns[zid].selected = idx
	
	# Sync pattern
	var p_data: Dictionary = _livery.get("pattern", {})
	if _pattern_type_btn != null:
		var p_ids := LiveryScript.pattern_ids()
		var p_idx := p_ids.find(p_data.get("type", "stripe"))
		if p_idx >= 0:
			_pattern_type_btn.selected = p_idx
	if _pattern_scale_slider != null:
		_pattern_scale_slider.value = float(p_data.get("scale", 1.0))
		_pattern_scale_val.text = "%.2fx" % _pattern_scale_slider.value
	if _pattern_angle_slider != null:
		_pattern_angle_slider.value = float(p_data.get("angle", 0.0))
		_pattern_angle_val.text = "%d°" % int(_pattern_angle_slider.value)
	if _pattern_softness_slider != null:
		_pattern_softness_slider.value = float(p_data.get("softness", 0.015))

	# Sync weathering
	if _weathering_slider != null:
		_weathering_slider.value = float(_livery.get("weathering", 0.2))
		_update_weathering_label(_weathering_slider.value)

	# Sync decal
	var d_data: Dictionary = _livery.get("decal", {})
	if _decal_icon_btn != null:
		var d_idx := LiveryScript.MASCOT_SHAPES.find(d_data.get("icon", "gear"))
		if d_idx >= 0:
			_decal_icon_btn.selected = d_idx
	if _decal_badge_btn != null:
		_decal_badge_btn.selected = 0 if d_data.get("badge", "circle") == "circle" else 1
	if _decal_serial_edit != null:
		_decal_serial_edit.text = str(d_data.get("serial", "101"))
	if _decal_hazard_chk != null:
		_decal_hazard_chk.button_pressed = bool(d_data.get("show_hazard", true))

func _on_randomise() -> void:
	_livery = LiveryScript.random_livery()
	_sync_all_controls()
	_apply_live()

func _on_save() -> void:
	LiveryScript.save_player(_livery)
	LiveryScript.invalidate(LiveryScript.PLAYER_ID)
	_apply_live()

func _plated_section(parent: Control, heading: String, min_width: int) -> VBoxContainer:
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(min_width, 0)
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(holder)

	var plate: Control = ToolboxPlateScript.new()
	plate.set_anchors_preset(Control.PRESET_FULL_RECT)
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(plate)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", Tokens.SPACE_LG)
	margin.add_theme_constant_override("margin_right", Tokens.SPACE_LG)
	margin.add_theme_constant_override("margin_top", Tokens.SPACE_MD)
	margin.add_theme_constant_override("margin_bottom", Tokens.SPACE_MD)
	holder.add_child(margin)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", Tokens.SPACE_MD)
	margin.add_child(content)

	var stamp_holder := Control.new()
	stamp_holder.custom_minimum_size = Vector2(0, 24)
	content.add_child(stamp_holder)
	var stamp: Control = StampedLabelScript.new()
	stamp.text = heading
	stamp.font_size = 17
	stamp.set_anchors_preset(Control.PRESET_FULL_RECT)
	stamp_holder.add_child(stamp)

	return content
