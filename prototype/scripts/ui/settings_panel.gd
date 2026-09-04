extends PanelContainer
# The Settings screen, as a panel rather than a scene.
#
# NOT A SCENE, DELIBERATELY. Settings has to be reachable from inside a paused
# match, and a scene change would tear the match down to show a volume slider.
# SystemLayer instantiates this into its own CanvasLayer instead, so opening
# settings mid-match is a panel appearing over a frozen battlefield.
#
# BUILT FROM THE DEFAULTS TABLE, not hand-listed. Every row below is generated
# from SettingsService.DEFAULTS and InputService's action table. A hand-written
# list of controls is a second source of truth that falls out of step with the
# first the moment someone adds a setting - which is exactly how the interface
# ended up with readouts that disagreed before ui_tokens.gd centralised them.

signal close_requested()

const Tokens = preload("res://scripts/ui_tokens.gd")
const UIToolboxScript = preload("res://scripts/ui_toolbox.gd")
const UIFeedbackScript = preload("res://scripts/ui_feedback.gd")
const InputServiceScript = preload("res://scripts/core/input_service.gd")
const MeshIconScript = preload("res://scripts/ui/mesh_icon.gd")
const UIShell = preload("res://scripts/ui_shell.gd")

const TOGGLE_MESH := "res://assets/models/ui/ui_toggle_switch.glb"
const ROTARY_MESH := "res://assets/models/ui/ui_rotary_selector.glb"
const DIAL_MESH := "res://assets/models/ui/ui_knurled_dial.glb"

# How each setting is edited. A key absent from here is rendered read-only rather
# than guessed at, so adding a setting without deciding its widget produces a
# visible gap instead of a wrong control.
const WIDGETS := {
	"window_mode": {"kind": "option", "label": "Window mode",
		"choices": ["Windowed", "Borderless", "Fullscreen"]},
	"vsync": {"kind": "check", "label": "VSync"},
	"frame_cap": {"kind": "option", "label": "Frame cap",
		"choices": ["Uncapped", "60", "120", "144"], "values": [0, 60, 120, 144]},
	"render_scale": {"kind": "slider", "label": "Render scale", "min": 0.5, "max": 1.0, "step": 0.05},
	"quality_preset": {"kind": "option", "label": "Quality",
		"choices": ["Low", "Medium", "High"]},
	"tilt_shift_strength": {"kind": "slider", "label": "Tilt-shift strength",
		"min": 0.0, "max": 2.0, "step": 0.05},

	"audio_master": {"kind": "slider", "label": "Master", "min": 0.0, "max": 1.0, "step": 0.01, "audition": "click"},
	"audio_sfx": {"kind": "slider", "label": "Effects", "min": 0.0, "max": 1.0, "step": 0.01, "audition": "cannon"},
	# NO AUDITION, AND THAT IS CORRECT RATHER THAN AN OMISSION. Every screen the
	# Settings panel can be opened from now has music playing under it, and the
	# bus volume changes live as the slider moves - so this control already
	# demonstrates itself continuously. Firing a one-shot sample on release
	# would be strictly worse than what the player is already hearing.
	"audio_music": {"kind": "slider", "label": "Music", "min": 0.0, "max": 1.0,
		"step": 0.01},
	# ROUTED THROUGH play_voice, NOT play_sfx. The Voice audition previously
	# called play_sfx("radio_ack"), which played it on the SFX bus - so dragging
	# the Voice slider auditioned a sound the Voice slider did not control, and
	# the reading was wrong at every position except unity.
	"audio_voice": {"kind": "slider", "label": "Voice", "min": 0.0, "max": 1.0,
		"step": 0.01, "audition": "radio_ack", "audition_bus": "voice"},

	"edge_scroll_enabled": {"kind": "check", "label": "Edge scroll"},
	"edge_scroll_margin": {"kind": "slider", "label": "Edge scroll zone", "min": 4.0, "max": 64.0, "step": 1.0},
	"camera_pan_speed": {"kind": "slider", "label": "Pan speed", "min": 5.0, "max": 90.0, "step": 1.0},
	"camera_rotate_speed": {"kind": "slider", "label": "Rotate speed", "min": 15.0, "max": 240.0, "step": 5.0},
	"invert_zoom": {"kind": "check", "label": "Invert zoom"},

	"tutorial_hints": {"kind": "check", "label": "Contextual hints"},
	"reduced_motion": {"kind": "check", "label": "Reduced motion"},
	"ui_scale": {"kind": "option", "label": "Interface scale",
		"choices": ["80%", "100%", "125%", "150%"], "values": [0.8, 1.0, 1.25, 1.5]},
	"colourblind_mode": {"kind": "option", "label": "Colour vision",
		"choices": ["Standard", "Deuteranopia", "Protanopia", "Tritanopia"]},
	"damage_numbers": {"kind": "option", "label": "Damage numbers",
		"choices": ["Off", "Significant only", "All"]},
	"captions": {"kind": "check", "label": "Captions for radio and alerts"},
}

var _settings: Node = null
var _input_svc: Node = null
var _toolbox: UIToolbox = null
var _rebinding_action: String = ""
var _rebind_button: Button = null


func _ready() -> void:
	theme_type_variation = "CardPanel"
	custom_minimum_size = Vector2(620, 560)
	_settings = get_node_or_null("/root/SettingsService")
	_input_svc = get_node_or_null("/root/InputService")
	_build()


func _build() -> void:
	# Ensure the shared 3D UI viewport exists on this panel across initial build and rebuilds.
	UIShell.stage(self)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, Tokens.SPACE_LG)
	add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", Tokens.SPACE_MD)
	margin.add_child(col)

	var header := HBoxContainer.new()
	col.add_child(header)
	var title := Label.new()
	title.text = "SETTINGS"
	title.theme_type_variation = "HeadingLabel"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close_btn := Button.new()
	close_btn.text = "CLOSE"
	UIFeedbackScript.wire(close_btn)
	close_btn.pressed.connect(func(): close_requested.emit())
	header.add_child(close_btn)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)

	_toolbox = UIToolboxScript.new()
	_toolbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_toolbox)

	if _settings == null:
		var warn := Label.new()
		warn.text = "SettingsService unavailable."
		_toolbox.add_tier("err", "UNAVAILABLE", true).add_child(warn)
		return

	for section in _settings.SECTION_ORDER:
		var label: String = _settings.SECTION_LABELS.get(section, section).to_upper()
		var body := _toolbox.add_tier(section, label, section == "display")
		if section == "controls":
			_build_controls_tier(body)
		for key in _settings.keys_in_section(section):
			_build_row(body, key)
		_add_reset(body, section)


# --- Setting rows ------------------------------------------------------------

func _build_row(parent: Control, key: String) -> void:
	if not WIDGETS.has(key):
		return
	var spec: Dictionary = WIDGETS[key]
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.SPACE_MD)
	parent.add_child(row)

	var name_label := Label.new()
	name_label.text = spec.get("label", key)
	name_label.custom_minimum_size = Vector2(200, 0)
	row.add_child(name_label)

	match spec.get("kind", ""):
		"check": _build_check(row, key)
		"slider": _build_slider(row, key, spec)
		"option": _build_option(row, key, spec)


func _build_check(row: Control, key: String) -> void:
	var icon := MeshIconScript.new()
	icon.mesh_path = TOGGLE_MESH
	icon.icon_size = Vector2i(32, 32)
	row.add_child(icon)

	var box := CheckBox.new()
	box.button_pressed = bool(_settings.get_value(key))
	icon.set_active(box.button_pressed)
	# A latched control needs to SOUND latched, and in the right direction.
	# wire() picks one role, so the direction-specific sound is played from the
	# toggled handler instead of relying on the press role.
	UIFeedbackScript.wire(box, "toggle_on")
	box.toggled.connect(func(v: bool):
		_settings.set_value(key, v)
		icon.set_active(v)
		if not v:
			UIFeedbackScript.play(box, "ui_toggle_off"))
	row.add_child(box)


func _build_slider(row: Control, key: String, spec: Dictionary) -> void:
	var icon := MeshIconScript.new()
	icon.mesh_path = DIAL_MESH
	icon.icon_size = Vector2i(32, 32)
	row.add_child(icon)

	var slider := HSlider.new()
	slider.min_value = spec.get("min", 0.0)
	slider.max_value = spec.get("max", 1.0)
	slider.step = spec.get("step", 0.01)
	slider.value = float(_settings.get_value(key))
	slider.custom_minimum_size = Vector2(240, Tokens.HIT_TARGET_MIN)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(slider)

	var readout := Label.new()
	readout.theme_type_variation = "StatLabel"
	readout.custom_minimum_size = Vector2(56, 0)
	readout.text = _format(slider.value, slider.step)
	row.add_child(readout)

	# The dial's turn tracks the slider's own fraction, not a separate state -
	# an analogue read of the exact same value the linear track shows, the way
	# a real console pairs a knob with a fader for the same channel.
	var span: float = maxf(slider.max_value - slider.min_value, 0.0001)
	icon.set_turn_fraction((slider.value - slider.min_value) / span)

	# TICK ON A STEP BOUNDARY, not on every value_changed. A slider dragged across
	# its range emits dozens of changes; playing a sound on each is a rattle. The
	# readout still updates continuously.
	var last_step := [int(round(slider.value / maxf(slider.step, 0.0001)))]
	slider.value_changed.connect(func(v: float):
		readout.text = _format(v, slider.step)
		_settings.set_value(key, v)
		icon.set_turn_fraction((v - slider.min_value) / span)
		var step_index := int(round(v / maxf(slider.step, 0.0001)))
		if step_index != last_step[0]:
			last_step[0] = step_index
			UIFeedbackScript.play(slider, "ui_tick"))

	# AUDITION ON RELEASE, NOT ON CHANGE. A volume slider that plays a sample on
	# every value_changed fires dozens of overlapping clips while being dragged,
	# which is both unpleasant and actively misleading about the level.
	var audition: String = spec.get("audition", "")
	var audition_bus: String = spec.get("audition_bus", "sfx")
	if audition != "":
		slider.drag_ended.connect(func(_changed: bool):
			var audio = get_node_or_null("/root/AudioManager")
			if audio == null:
				return
			# The bus matters: a slider must audition through the bus it
			# controls, or the demonstration is of some other slider.
			if audition_bus == "voice":
				audio.play_voice(audition)
			else:
				audio.play_sfx(audition))


func _build_option(row: Control, key: String, spec: Dictionary) -> void:
	var icon := MeshIconScript.new()
	icon.mesh_path = ROTARY_MESH
	icon.icon_size = Vector2i(32, 32)
	row.add_child(icon)

	var opt := OptionButton.new()
	var choices: Array = spec.get("choices", [])
	for i in range(choices.size()):
		opt.add_item(str(choices[i]), i)
	# `values` lets a display list map onto real stored values (frame caps, UI
	# scales). Absent, the index IS the value, which is right for enums.
	var values: Array = spec.get("values", [])
	var current = _settings.get_value(key)
	if values.is_empty():
		opt.selected = int(current)
	else:
		opt.selected = maxi(0, values.find(current))

	# The selector's pointer sweeps across the full choice set, one detent per
	# option - a 3-choice quality preset and an 8-choice roster picker both
	# read as "the same kind of control", just with fewer stops used.
	var count: int = maxi(choices.size(), 1)
	icon.set_turn_fraction(float(opt.selected) / maxf(float(count - 1), 1.0))

	UIFeedbackScript.wire(opt, "dial")
	opt.item_selected.connect(func(idx: int):
		_settings.set_value(key, idx if values.is_empty() else values[idx])
		icon.set_turn_fraction(float(idx) / maxf(float(count - 1), 1.0)))
	row.add_child(opt)


func _add_reset(parent: Control, section: String) -> void:
	var btn := Button.new()
	btn.text = "RESET %s" % section.to_upper()
	btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	UIFeedbackScript.wire(btn)
	btn.pressed.connect(func():
		_settings.reset_section(section)
		_rebuild())
	parent.add_child(btn)


# --- Controls tier -----------------------------------------------------------

func _build_controls_tier(parent: Control) -> void:
	if _input_svc == null:
		return
	var note := Label.new()
	note.text = "Click a binding, then press the key you want."
	note.theme_type_variation = "HintLabel"
	parent.add_child(note)

	for group in _input_svc.GROUP_ORDER:
		var heading := Label.new()
		heading.text = _input_svc.GROUP_LABELS.get(group, group).to_upper()
		heading.theme_type_variation = "HeadingLabel"
		parent.add_child(heading)

		for action in _input_svc.actions_in_group(group):
			_build_binding_row(parent, action)

		var reset := Button.new()
		reset.text = "RESET %s" % _input_svc.GROUP_LABELS.get(group, group).to_upper()
		reset.size_flags_horizontal = Control.SIZE_SHRINK_END
		UIFeedbackScript.wire(reset)
		reset.pressed.connect(func():
			_input_svc.reset_group(group)
			_rebuild())
		parent.add_child(reset)


func _build_binding_row(parent: Control, action: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.SPACE_MD)
	parent.add_child(row)

	var label := Label.new()
	label.text = _input_svc.all_actions()[action].get("label", action)
	label.custom_minimum_size = Vector2(220, 0)
	row.add_child(label)

	var btn := Button.new()
	btn.text = _input_svc.binding_label_all(action)
	btn.custom_minimum_size = Vector2(180, Tokens.HIT_TARGET_MIN)
	UIFeedbackScript.wire(btn, "select")
	btn.pressed.connect(func(): _begin_rebind(action, btn))
	row.add_child(btn)

	# Conflicts are shown, never blocked - Chris's direction is that players
	# remap individually, and a mid-swap state is conflicting by definition.
	var warn := Label.new()
	warn.theme_type_variation = "HintLabel"
	warn.add_theme_color_override("font_color", Tokens.SIGNAL_HAZARD)
	warn.text = _conflict_text(action)
	row.add_child(warn)


func _conflict_text(action: String) -> String:
	var names: Array = []
	for d in _input_svc.events_for(action):
		for other in _input_svc.conflicts_for(d, action):
			if other not in names:
				names.append(other)
	if names.is_empty():
		return ""
	return "also: %s" % ", ".join(names)


func _begin_rebind(action: String, btn: Button) -> void:
	_rebinding_action = action
	_rebind_button = btn
	btn.text = "PRESS A KEY"
	set_process_input(true)


func _input_event_captured(event: InputEvent) -> void:
	var descriptor = InputServiceScript.descriptor_from_event(event)
	if descriptor == null:
		return
	# Escape aborts rather than binding itself. Binding Escape to a game action
	# is how a player loses the ability to leave a menu.
	if event.is_action_pressed("ui_cancel"):
		_end_rebind()
		return
	_input_svc.rebind(_rebinding_action, [descriptor])
	_end_rebind()
	_rebuild()


func _end_rebind() -> void:
	_rebinding_action = ""
	_rebind_button = null
	set_process_input(false)


func _input(event: InputEvent) -> void:
	if _rebinding_action == "":
		return
	if event is InputEventKey and event.pressed and not event.echo:
		get_viewport().set_input_as_handled()
		_input_event_captured(event)


func _rebuild() -> void:
	for child in get_children():
		child.queue_free()
	# Deferred: queue_free() takes effect at end of frame, so building
	# immediately would stack the new tree on top of the dying one.
	call_deferred("_build")


static func _format(value: float, step: float) -> String:
	if step >= 1.0:
		return str(int(round(value)))
	return "%.2f" % value
