extends Button
## Shared out-of-match button primitive.
##
## Keeps native Button semantics (keyboard/controller activation, accessibility,
## theme state resolution) while centralizing sizing, role, cursor and feedback.

const Tokens = preload("res://scripts/ui_tokens.gd")
const UIFeedbackScript = preload("res://scripts/ui_feedback.gd")

var feedback_role: String = "default"

func configure(label: String, role: String = "default",
		variation: String = "", minimum_size: Vector2 = Vector2.ZERO,
		hint: String = "") -> Button:
	text = label
	feedback_role = role
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	custom_minimum_size = Vector2(
		maxf(minimum_size.x, 0.0),
		maxf(minimum_size.y, Tokens.HIT_TARGET_MIN))
	if variation != "":
		theme_type_variation = variation
	tooltip_text = hint
	UIFeedbackScript.wire(self, feedback_role)
	return self
