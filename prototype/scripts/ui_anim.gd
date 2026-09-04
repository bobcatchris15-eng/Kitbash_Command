extends RefCounted
class_name UIAnim
# VISUAL_IMPROVEMENT_PLAN.md chunk G: a small shared motion library so the
# UI's handful of animated moments (panel slide-in, button press feedback,
# resource counter roll-up, status toast slide+fade, scene-transition fade)
# read as one consistent system - same standard durations/easings - instead
# of each call site hand-rolling its own one-off Tween with its own timing.

# The timings themselves now live in ui_tokens.gd alongside the rest of the
# visual language, because motion and appearance have to agree: a hover
# transition that outlasts the theme's hover plate swap reads as two separate
# effects. These are re-exported under their original names so the existing
# call sites (skirmish.gd, ui_dock.gd, ui_flyout.gd, ui_radial_menu.gd,
# parts_menu.gd) didn't all have to change in the same commit as the tokens.
const DURATION_INSTANT: float = UITokens.DURATION_INSTANT
const DURATION_FAST: float = UITokens.DURATION_FAST
const DURATION_NORMAL: float = UITokens.DURATION_NORMAL
const DURATION_SLOW: float = UITokens.DURATION_SLOW
const STAGGER_STEP: float = UITokens.STAGGER_STEP
const EASE_STANDARD := UITokens.EASE_STANDARD
const TRANS_STANDARD := UITokens.TRANS_STANDARD

# Scale reactions share one channel so a late hover tween cannot undo a press
# or settle. Preserve authored scale instead of assuming every control is 1:1.
static func _scale_tween(node: Control) -> Tween:
	var previous: Tween = node.get_meta(&"ui_scale_tween") if node.has_meta(&"ui_scale_tween") else null
	if previous != null and previous.is_valid():
		previous.kill()
	if not node.has_meta(&"ui_rest_scale"):
		node.set_meta(&"ui_rest_scale", node.scale)
	node.pivot_offset = node.size * 0.5
	var tween := node.create_tween()
	tween.set_trans(TRANS_STANDARD).set_ease(EASE_STANDARD)
	node.set_meta(&"ui_scale_tween", tween)
	return tween

# Slides a Control in from `from_offset` (relative to its own current/target
# position) while fading it in - a panel/card's entrance.
static func slide_in(node: Control, from_offset: Vector2, duration: float = DURATION_NORMAL) -> Tween:
	var target_pos = node.position
	node.position = target_pos + from_offset
	node.modulate.a = 0.0
	var tween = node.create_tween()
	tween.set_trans(TRANS_STANDARD)
	tween.set_ease(EASE_STANDARD)
	tween.tween_property(node, "position", target_pos, duration)
	tween.parallel().tween_property(node, "modulate:a", 1.0, duration)
	return tween

# A quick squash-then-release on press - real tactile feedback instead of
# just the theme's built-in pressed StyleBox swap.
static func button_press_feedback(button: Control) -> Tween:
	var tween := _scale_tween(button)
	var rest: Vector2 = button.get_meta(&"ui_rest_scale")
	tween.tween_property(button, "scale", rest * UITokens.PRESS_SCALE, DURATION_FAST * UITokens.PRESS_ATTACK_RATIO)
	tween.tween_property(button, "scale", rest, DURATION_FAST * (1.0 - UITokens.PRESS_ATTACK_RATIO))
	return tween

# A radial menu's entrance: scales up from small while fading in, with a
# slight overshoot.
#
# Deliberately NOT slide_in(). A ring opens AT a fixed point - the part it acts
# on - so it has nowhere to slide from; translating it would break the one
# thing the ring depends on, which is that its centre is exactly where the
# cursor already is. TRANS_BACK gives the overshoot that reads as a mechanism
# springing open, and EASE_OUT lands it without oscillation.
#
# The node must already be positioned before this is called - it animates
# `scale` about `pivot_offset` and never touches `position`.
static func ring_pop(node: Control, duration: float = DURATION_FAST) -> Tween:
	node.pivot_offset = node.size * 0.5
	node.scale = Vector2.ONE * UITokens.RING_START_SCALE
	node.modulate.a = 0.0
	var tween = node.create_tween()
	tween.set_parallel(true)
	tween.tween_property(node, "scale", Vector2.ONE, duration) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(node, "modulate:a", 1.0, duration * UITokens.RING_FADE_RATIO)
	return tween


# Generic tween_method driver for a numeric roll-up (resource counters,
# score tallies, etc.) - deliberately takes a Callable rather than a fixed
# label/format string, since callers often need to update more than one
# value from a single interpolation parameter (e.g. metal AND crystal
# sharing one label's text).
static func roll_up(node: Object, from_value: float, to_value: float, duration: float, on_update: Callable) -> Tween:
	var tween = node.create_tween()
	tween.set_trans(TRANS_STANDARD)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_method(on_update, from_value, to_value, duration)
	return tween

# A status toast's entrance - slides up slightly while fading in.
static func toast_slide_fade(node: Control, duration: float = DURATION_NORMAL) -> Tween:
	var start_pos = node.position
	node.position = start_pos + UITokens.ENTRANCE_OFFSET
	node.modulate.a = 0.0
	var tween = node.create_tween()
	tween.set_trans(TRANS_STANDARD)
	tween.set_ease(EASE_STANDARD)
	tween.tween_property(node, "position", start_pos, duration)
	tween.parallel().tween_property(node, "modulate:a", 1.0, duration)
	return tween

# A hover acknowledgement: a very small, very fast scale lift.
#
# DURATION_INSTANT (60ms) because hover must not feel like a delay - it is a
# readiness cue, and anything slow enough to perceive as an animation reads as
# lag on a control the player has not even committed to yet.
#
# 1.03, not 1.1. The theme already swaps to the hover plate, so this only has to
# add physicality, not carry the whole state change. A large scale on a button in
# a dense row (the parts bin, the build bar) also makes it overlap its
# neighbours, which reads as a layout bug rather than as a lift.
#
# Sets pivot_offset so the lift is about the control's centre; without it a
# Control scales from its top-left corner and appears to slide down-right.
static func hover_lift(node: Control, duration: float = DURATION_INSTANT) -> Tween:
	var tween := _scale_tween(node)
	var rest: Vector2 = node.get_meta(&"ui_rest_scale")
	tween.tween_property(node, "scale", rest * UITokens.HOVER_SCALE, duration)
	return tween


# Returns a hovered control to rest. Separate from hover_lift() rather than a
# boolean flag, so a call site reads as the event that happened.
static func hover_settle(node: Control, duration: float = DURATION_INSTANT) -> Tween:
	var tween := _scale_tween(node)
	tween.tween_property(node, "scale", node.get_meta(&"ui_rest_scale"), duration)
	return tween


# A staggered entrance for a list or grid: each child slides in slightly after
# the one before it, so the group arrives as one gesture sweeping across it
# rather than as everything appearing at once.
#
# Drives slide_in() per child rather than reimplementing it, so a card entering a
# list and a panel entering a screen move identically.
#
# The stagger is capped: at STAGGER_STEP per child a 40-row list would take 1.4s
# to finish arriving, by which point it reads as a loading bug rather than as
# polish. Past the cap the remaining children share the last delay.
const STAGGER_MAX_TOTAL := UITokens.STAGGER_MAX_TOTAL

static func stagger_in(parent: Node, from_offset: Vector2 = UITokens.ENTRANCE_OFFSET) -> void:
	var kids: Array = []
	for c in parent.get_children():
		if c is Control:
			kids.append(c)
	if kids.is_empty():
		return
	# The cap includes the last child's entrance, not just its start delay.
	var step: float = minf(STAGGER_STEP,
		maxf(0.0, STAGGER_MAX_TOTAL - DURATION_NORMAL) / maxf(1.0, kids.size() - 1.0))
	for i in range(kids.size()):
		var child: Control = kids[i]
		var delay: float = step * float(i)
		if delay <= 0.0:
			slide_in(child, from_offset)
			continue
		# Hidden until its turn, otherwise every child is visible at full alpha
		# for its delay and then jumps to the animation's start state.
		child.modulate.a = 0.0
		var t = child.create_tween()
		t.tween_interval(delay)
		t.tween_callback(func():
			if is_instance_valid(child):
				slide_in(child, from_offset)
		)


# A brief signal-colour pulse on a value that changed meaningfully - resources
# spent, HP lost, power entering a bad state.
#
# Tweens font_color rather than modulate so it tints the TEXT and not the whole
# subtree, and so it composes with a variation's own colour instead of
# multiplying it. Returns to the theme colour by REMOVING the override rather
# than setting one back, which is what keeps it correct if the label's variation
# ever changes.
static func value_flash(label: Label, role_color: Color,
		duration: float = DURATION_NORMAL) -> Tween:
	label.add_theme_color_override("font_color", role_color)
	var tween = label.create_tween()
	tween.tween_interval(duration)
	tween.tween_callback(func():
		if is_instance_valid(label):
			label.remove_theme_color_override("font_color")
	)
	return tween


# A short horizontal shake for rejected input - a build that cannot be afforded,
# a slot that cannot accept a drop.
#
# Small and fast so rejection is legible without displacing the next target.
static func shake(node: Control, amplitude: float = UITokens.SHAKE_AMPLITUDE) -> Tween:
	var home := node.position
	var tween = node.create_tween()
	tween.set_trans(Tween.TRANS_SINE)
	for i in range(UITokens.SHAKE_STEPS):
		var dir := 1.0 if i % 2 == 0 else -1.0
		var falloff := 1.0 - (float(i) / float(UITokens.SHAKE_STEPS))
		tween.tween_property(node, "position",
			home + Vector2(amplitude * dir * falloff, 0.0), DURATION_FAST / float(UITokens.SHAKE_STEPS))
	# Always lands exactly back home rather than at whatever the last step left,
	# so repeated rejections cannot drift the control across the screen.
	tween.tween_property(node, "position", home, DURATION_FAST / float(UITokens.SHAKE_STEPS))
	return tween


# Scene-transition fade (e.g. a victory/defeat dimming overlay) - sets the
# starting alpha itself (like slide_in()/toast_slide_fade() set their own
# starting position) so a caller doesn't have to remember to zero out
# modulate.a first; pass `from_alpha` explicitly for a fade-OUT instead.
static func fade(node: CanvasItem, target_alpha: float, duration: float = DURATION_SLOW, from_alpha: float = 0.0) -> Tween:
	node.modulate.a = from_alpha
	var tween = node.create_tween()
	tween.tween_property(node, "modulate:a", target_alpha, duration)
	return tween


# A looping spotlight ring pulse for tutorial coaching. Oscillates a float
# property between `low` and `high` using CUBIC ease - a breathing ring that
# draws the eye without being garish. Returns the tween so the caller can kill
# it on step change.
#
# TRANS_CUBIC + EASE_OUT on the bright half, TRANS_CUBIC + EASE_IN on the dim
# half - the same mechanical language the rest of the UI uses. No overshoot,
# no bounce. The total period is `duration` (default DURATION_NORMAL = 220ms),
# but the default is overridden per call site since tutorial pulse periods
# are typically 600-800ms.
static func spotlight_pulse(node: Node, property: String, low: float, high: float,
		duration: float = UITokens.SPOTLIGHT_PERIOD) -> Tween:
	var half := duration * 0.5
	var tw := node.create_tween().set_loops()
	tw.tween_property(node, property, high, half) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tw.tween_property(node, property, low, half) \
		.set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_CUBIC)
	return tw


# Slides a card from its current position to `target_pos` without touching
# opacity. Used by the tutorial overlay to reposition the coach card smoothly
# when the step's target changes. 220ms, TRANS_CUBIC, EASE_OUT - the same
# timing as slide_in().
static func card_slide_to(card: Control, target_pos: Vector2,
		duration: float = DURATION_NORMAL) -> Tween:
	var tw := card.create_tween()
	tw.set_trans(TRANS_STANDARD).set_ease(EASE_STANDARD)
	tw.tween_property(card, "position", target_pos, duration)
	return tw
