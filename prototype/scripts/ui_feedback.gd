extends RefCounted
class_name UIFeedback
# One call to give a control its full interactive response: sound AND motion.
#
# WHY BOTH IN ONE CALL. They have to fire on the same event within the same few
# milliseconds or they read as two separate effects rather than one reaction.
# Wiring them separately is how that drifts - and it already had. Before this,
# main_menu.gd was the ONLY screen with any UI audio at all, hand-rolled as
#
#     var audio = get_node_or_null("/root/AudioManager")
#     if audio: audio.play_sfx("click")
#
# duplicated at three sites in that one file, with no motion attached and no
# other screen carrying any of it. Every other screen in the game was silent.
#
# WHAT "RESPONSE" MEANS HERE. The theme already swaps the plate on hover and
# press, so the material change is handled. This adds the two things a theme
# cannot express: a sub-100ms scale/lift acknowledgement, and a sound. See
# UI_STYLE_GUIDE.md section 8 - hover is a readiness cue, press is a physical
# commitment, and neither is allowed to change signal colour.

const UIAnimScript = preload("res://scripts/ui_anim.gd")
const ThemeScript = preload("res://scripts/ui_theme.gd")

# role -> the SFX key played on activation. Hover is the same everywhere: it is a
# readiness cue, not meaningful state, so it does not vary by what the control
# does. Press does vary, because THAT is the moment the control's meaning lands.
const ROLE_SFX := {
	# Ordinary navigation and toggles.
	"default": "click",
	# A committing action - starting a match, confirming a build.
	"confirm": "radio_ack",
	# Selecting an item from a set (a part, a design, a map).
	"select": "select",
	# Placing something into the world or into a slot.
	"place": "place",
	# A rejected interaction. Pair with UIAnim.shake() at the call site if the
	# rejection needs to be unmissable.
	"reject": "error",
	# Destructive. Deliberately the warning tone rather than a click: deleting a
	# design should not sound like changing a dropdown.
	"danger": "warning_banner",
}


# Resolves the AudioManager autoload once per call rather than per screen. Kept
# as a lookup rather than a cached static because the autoload does not exist in
# a scene instantiated outside the running game - which is exactly the case in
# the headless test fixtures.
static func _audio(node: Node) -> Node:
	if not is_instance_valid(node) or not node.is_inside_tree():
		return null
	return node.get_node_or_null("/root/AudioManager")


static func play(node: Node, sfx: String) -> void:
	var audio := _audio(node)
	if audio and audio.has_method("play_sfx"):
		# The default pitch_variance of 0.12 is left alone deliberately. Identical
		# repeated UI clicks are a distinctly cheap-sounding tell, and the API
		# already varies pitch per play - it just needed to actually be called.
		audio.play_sfx(sfx)


# THE MAIN ENTRY POINT. Connects hover and press feedback to a control.
#
# Safe to call on any Control. `pressed` is only connected when the control
# actually has that signal, so this can be applied uniformly across a screen's
# controls without the caller sorting Buttons from Panels first.
static func wire(ctrl: Control, role: String = "default") -> Control:
	if not is_instance_valid(ctrl):
		return ctrl

	ctrl.set_meta(&"ui_feedback_role", role)
	if ctrl is BaseButton or ctrl is SpinBox or ctrl.focus_mode != Control.FOCUS_NONE:
		ThemeScript.ensure_focus(ctrl)

	var hover := _on_hover.bind(ctrl)
	if not ctrl.mouse_entered.is_connected(hover):
		ctrl.mouse_entered.connect(hover)
	# mouse_exited is not optional. hover_lift() leaves the control scaled up, so
	# without a settle it stays lifted permanently after the first hover and the
	# whole screen slowly inflates as the player moves the cursor over it.
	var unhover := _on_unhover.bind(ctrl)
	if not ctrl.mouse_exited.is_connected(unhover):
		ctrl.mouse_exited.connect(unhover)

	# BaseButton covers Button, CheckBox, OptionButton, TextureButton and the
	# rest; anything else gets hover feedback only, which is correct - a panel has
	# nothing to press.
	if ctrl is BaseButton:
		var btn := ctrl as BaseButton
		var pressed := _on_pressed.bind(ctrl)
		if not btn.pressed.is_connected(pressed):
			btn.pressed.connect(pressed)
	return ctrl


static func _on_hover(ctrl: Control) -> void:
	# A disabled control must not pretend to respond. Godot still emits
	# mouse_entered for a disabled button, so this has to be checked here rather
	# than assumed at connect time - a control's disabled state changes over its
	# life, the connection does not.
	if ctrl is BaseButton and (ctrl as BaseButton).disabled:
		return
	play(ctrl, "hover")
	UIAnimScript.hover_lift(ctrl)


static func _on_unhover(ctrl: Control) -> void:
	# Unconditional, unlike _on_hover's disabled check: a control that became
	# disabled WHILE hovered still has to come back down, or it stays stuck lifted.
	UIAnimScript.hover_settle(ctrl)


static func _on_pressed(ctrl: Control) -> void:
	if ctrl is BaseButton and (ctrl as BaseButton).disabled:
		return
	var role: String = ctrl.get_meta(&"ui_feedback_role", "default")
	var sfx: String = ROLE_SFX.get(role, ROLE_SFX["default"])
	play(ctrl, sfx)
	UIAnimScript.button_press_feedback(ctrl)


# Convenience for a whole screen: wires every Button-like descendant at once.
#
# Buttons receive sound/motion; other interactive controls receive focus only
# so editing text or dragging a slider never scales the value under the cursor.
# Set ui_feedback_managed metadata on a subtree that owns its own response.
static func wire_tree(root: Node, role: String = "default") -> void:
	if root.get_meta(&"ui_feedback_managed", false):
		return
	if root is BaseButton:
		wire(root as Control, str(root.get_meta(&"ui_feedback_role", role)))
	elif root is Control and (root is SpinBox or (root as Control).focus_mode != Control.FOCUS_NONE):
		ThemeScript.ensure_focus(root as Control)
	for child in root.get_children():
		wire_tree(child, role)
