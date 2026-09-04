extends SceneTree
# Standalone regression entrypoint, following prototype/tools/test_*.gd.
# Run from repository root: Godot --headless --path prototype --script res://tests/test_ui_shell_contract.gd

const Tokens = preload("res://scripts/ui_tokens.gd")
const Style = preload("res://scripts/ui_theme.gd")
const Shell = preload("res://scripts/ui_shell.gd")
const Feedback = preload("res://scripts/ui_feedback.gd")
const Anim = preload("res://scripts/ui_anim.gd")

var failures: int = 0
var checks: int = 0

func _init() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("[FAIL] ", message)

func _run() -> void:
	var host := Control.new()
	root.add_child(host)
	var style_api: RefCounted = Style.new()
	var shell_api: RefCounted = Shell.new()
	if style_api.has_method("action_style"):
		for role: String in ["primary", "secondary", "info", "warning", "error", "disabled", "selected", "active"]:
			var normal: StyleBoxFlat = style_api.call("action_style", role, "normal")
			var disabled: StyleBoxFlat = style_api.call("action_style", role, "disabled")
			check(normal != null and disabled != null, "role produces styles: " + role)
			check(disabled.bg_color == Tokens.BASE_900, "disabled takes precedence over " + role)
		var selected: StyleBoxFlat = style_api.call("action_style", "selected", "normal")
		var active: StyleBoxFlat = style_api.call("action_style", "active", "normal")
		check(selected.border_width_left != active.border_width_left, "selected and active have distinct non-color cues")
		var warning: StyleBoxFlat = style_api.call("action_style", "warning", "hover")
		check(warning.border_color == Tokens.SIGNAL_HAZARD, "hover retains warning semantics")
		var error: StyleBoxFlat = style_api.call("action_style", "error", "pressed")
		check(error.border_color == Tokens.SIGNAL_ALERT, "press retains error semantics")
	else:
		check(false, "shared action_style role/state contract is missing")

	# The real wiring entrypoint must cover non-Button and texture controls too.
	var controls: Array[Control] = [Button.new(), OptionButton.new(), CheckBox.new(),
		TextureButton.new(), LinkButton.new(), HSlider.new(), VSlider.new(),
		LineEdit.new(), TextEdit.new(), Tree.new(), ItemList.new(), TabBar.new(), SpinBox.new()]
	for ctrl in controls:
		host.add_child(ctrl)
	Feedback.wire_tree(host)
	Feedback.wire_tree(host)
	for ctrl in controls:
		var target: Control = (ctrl as SpinBox).get_line_edit() if ctrl is SpinBox else ctrl
		check(target.focus_mode == Control.FOCUS_ALL, ctrl.get_class() + " is keyboard focusable")
		check(target.has_theme_stylebox_override("focus"), ctrl.get_class() + " has shared focus styling")
		check(target.focus_entered.is_connected(target.queue_redraw), ctrl.get_class() + " redraws focus")
	var button := controls[0] as Button
	check(button.pressed.get_connections().size() == 1, "repeated wiring does not duplicate press feedback")
	check(button.mouse_entered.get_connections().size() == 1, "repeated wiring does not duplicate hover feedback")
	button.disabled = true
	button.mouse_entered.emit()
	check(button.scale == Vector2.ONE, "disabled hover does not lift")

	if shell_api.has_method("navigation_spine"):
		var requests: Array[String] = []
		var destinations: Array[Dictionary] = [
			{"id": "menu", "label": "Main Menu"}, {"id": "lab", "label": "Design Lab"},
			{"id": "launch", "label": "Launch", "disabled": true}]
		var spine: HBoxContainer = shell_api.call("navigation_spine", host,
			destinations, "lab",
			func(id: String) -> void: requests.append(id))
		check(spine.get_child_count() == 3, "navigation preserves destination order")
		var menu := spine.get_child(0) as Button
		var lab := spine.get_child(1) as Button
		var launch := spine.get_child(2) as Button
		check(lab.button_pressed and not menu.button_pressed, "navigation marks current destination")
		check(launch.disabled, "navigation preserves availability")
		menu.pressed.emit()
		check(requests == ["menu"], "navigation delegates stable destination IDs to screen owner")
		check(lab.button_pressed, "navigation request does not prematurely change current screen")
		check(menu.has_theme_stylebox_override("focus"), "navigation receives focus styling")
	else:
		check(false, "shared navigation_spine is missing")

	var frame := Shell.screen_frame(host)
	check(frame.mouse_filter == Control.MOUSE_FILTER_IGNORE, "empty shell frame does not intercept viewport input")
	if style_api.has_method("panel_style"):
		for role: String in ["surface", "inset", "header", "navigation", "floating", "modal"]:
			var panel: StyleBoxFlat = style_api.call("panel_style", role)
			check(panel != null, "shared panel role: " + role)
	else:
		check(false, "shared panel_style is missing")

	var token_script: GDScript = load("res://scripts/ui_tokens.gd")
	var constants: Dictionary = token_script.get_script_constant_map()
	for key: String in ["STAGGER_MAX_TOTAL", "HOVER_SCALE", "PRESS_SCALE", "PRESS_ATTACK_RATIO",
		"RING_START_SCALE", "RING_FADE_RATIO", "ENTRANCE_OFFSET", "SHAKE_AMPLITUDE", "SHAKE_STEPS", "SPOTLIGHT_PERIOD"]:
		check(constants.has(key), "motion paint value is centralized: " + key)
	var animated := Control.new()
	host.add_child(animated)
	var lift := Anim.hover_lift(animated)
	var settle := Anim.hover_settle(animated)
	check(not lift.is_valid(), "settle cancels competing hover tween")
	settle.custom_step(1.0)
	check(animated.scale.is_equal_approx(Vector2.ONE), "interrupted hover returns to rest")

	host.free()
	print("UI shell contract: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
