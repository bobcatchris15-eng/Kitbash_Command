class_name RingDraw
extends RefCounted

# Shared rendering routines for machined dial / radial menus
# (UIRadialMenu, ModuleActionRing, MarkingMenu).

const Tokens = preload("res://scripts/ui_tokens.gd")
const UIIcons = preload("res://scripts/ui_icons.gd")

const TICK_COUNT := 48
const TICK_LEN_MINOR := 4.0
const TICK_LEN_MAJOR := 8.0
const LABEL_GAP := 14.0


static func sector_angle(idx: int, total_actions: int) -> float:
	if total_actions <= 0:
		return 0.0
	var step := TAU / float(total_actions)
	return -TAU * 0.25 + step * float(idx)


static func sector_at(local_pos: Vector2, center: Vector2, inner_r: float, outer_r: float, hub_r: float, total_actions: int) -> int:
	if total_actions <= 0:
		return -1
	var offset := local_pos - center
	var r := offset.length()
	if r < hub_r or r > outer_r:
		return -1

	var step := TAU / float(total_actions)
	var angle := fposmod(atan2(offset.y, offset.x) + TAU * 0.25 + step * 0.5, TAU)
	return int(angle / step) % total_actions


static func draw_ring(
	canvas: CanvasItem,
	center: Vector2,
	inner_r: float,
	outer_r: float,
	hub_r: float,
	actions: Array,
	hovered: int,
	subject_label: String,
	font: Font,
	show_hub: bool = true
) -> void:
	if canvas == null:
		return
	if font == null:
		font = ThemeDB.fallback_font

	# --- Bezel Annulus ---
	var mid_r := (inner_r + outer_r) * 0.5
	var band := outer_r - inner_r
	canvas.draw_arc(center, mid_r, 0.0, TAU, 96, Color(Tokens.BASE_900, 0.92), band, true)

	# --- Hovered wedge ---
	if hovered >= 0 and hovered < actions.size():
		var enabled: bool = actions[hovered].get("enabled", true)
		var fill: Color = Tokens.SIGNAL_HAZARD_DIM if enabled else Tokens.BASE_700
		draw_wedge(canvas, center, inner_r, outer_r, hovered, actions.size(), Color(fill, 0.95))

	# --- Index ring and ticks ---
	canvas.draw_arc(center, outer_r, 0.0, TAU, 96, Tokens.BASE_500, 1.0, true)
	canvas.draw_arc(center, inner_r, 0.0, TAU, 96, Tokens.BASE_500, 1.0, true)

	for i in TICK_COUNT:
		var a := TAU * float(i) / float(TICK_COUNT)
		var dir := Vector2(cos(a), sin(a))
		var major := i % 4 == 0
		var length := TICK_LEN_MAJOR if major else TICK_LEN_MINOR
		var col: Color = Tokens.BASE_400 if major else Tokens.BASE_500
		canvas.draw_line(center + dir * (outer_r - length), center + dir * outer_r, col, 1.0, true)

	# --- Wedge dividers ---
	if actions.size() > 1:
		var step := TAU / float(actions.size())
		for i in actions.size():
			var a := sector_angle(i, actions.size()) - step * 0.5
			var dir := Vector2(cos(a), sin(a))
			canvas.draw_line(center + dir * inner_r, center + dir * outer_r, Tokens.BASE_500, 1.0, true)

	# --- Hub ---
	if show_hub:
		canvas.draw_circle(center, hub_r, Color(Tokens.BASE_900, 0.45))
		canvas.draw_arc(center, hub_r, 0.0, TAU, 48, Tokens.BASE_500, 1.0, true)

	# --- Hub text ---
	if show_hub and hovered >= 0 and hovered < actions.size():
		var hub_text: String = actions[hovered].get("label", "")
		var hub_size := font.get_string_size(hub_text, HORIZONTAL_ALIGNMENT_LEFT, -1, Tokens.FONT_MICRO)
		canvas.draw_string(
			font,
			center + Vector2(-hub_size.x * 0.5, hub_size.y * 0.25),
			hub_text,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			Tokens.FONT_MICRO,
			Tokens.SIGNAL_HAZARD
		)

	# --- Subject Plate ---
	if subject_label != "":
		var sz := font.get_string_size(subject_label, HORIZONTAL_ALIGNMENT_LEFT, -1, Tokens.FONT_MICRO)
		var plate := Rect2(
			center + Vector2(-sz.x * 0.5 - 8.0, outer_r + LABEL_GAP + 10.0),
			sz + Vector2(16.0, 6.0)
		)
		canvas.draw_rect(plate, Color(Tokens.BASE_900, 0.85))
		canvas.draw_rect(plate, Tokens.BASE_500, false, 1.0)
		canvas.draw_string(
			font,
			plate.position + Vector2(8.0, sz.y * 0.85),
			subject_label,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			Tokens.FONT_MICRO,
			Tokens.TEXT_SECONDARY
		)

	# --- Wedge contents ---
	for i in actions.size():
		var action: Dictionary = actions[i]
		var enabled: bool = action.get("enabled", true)
		var a := sector_angle(i, actions.size())
		var dir := Vector2(cos(a), sin(a))

		var tint: Color = Tokens.TEXT_PRIMARY if enabled else Tokens.TEXT_DISABLED
		if i == hovered and enabled:
			tint = Tokens.SIGNAL_HAZARD

		var icon_name: String = action.get("icon", "")
		var icon: Texture2D = null
		if icon_name != "" and UIIcons.has_icon(icon_name):
			icon = UIIcons.get_icon(icon_name)

		var mid := center + dir * ((inner_r + outer_r) * 0.5)

		if icon != null:
			var isz := Vector2(20, 20)
			canvas.draw_texture_rect(icon, Rect2(mid - isz * 0.5, isz), false, tint)
			var lbl: String = action.get("label", "")
			var lsz := font.get_string_size(lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, Tokens.FONT_MICRO)
			var lpos := center + dir * (outer_r + LABEL_GAP)
			canvas.draw_string(font, lpos + Vector2(-lsz.x * 0.5, lsz.y * 0.3), lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, Tokens.FONT_MICRO, tint)
		else:
			var lbl: String = action.get("label", "")
			var lsz := font.get_string_size(lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, Tokens.FONT_MICRO)
			canvas.draw_string(font, mid + Vector2(-lsz.x * 0.5, lsz.y * 0.25), lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, Tokens.FONT_MICRO, tint)


static func draw_wedge(canvas: CanvasItem, center: Vector2, inner_r: float, outer_r: float, idx: int, total_actions: int, col: Color) -> void:
	if total_actions <= 0:
		return
	var step := TAU / float(total_actions)
	var a0 := sector_angle(idx, total_actions) - step * 0.5
	var a1 := a0 + step

	var segments := 12
	var pts := PackedVector2Array()
	for i in range(segments + 1):
		var a: float = lerp(a0, a1, float(i) / float(segments))
		pts.append(center + Vector2(cos(a), sin(a)) * outer_r)
	for i in range(segments, -1, -1):
		var a: float = lerp(a0, a1, float(i) / float(segments))
		pts.append(center + Vector2(cos(a), sin(a)) * inner_r)
	canvas.draw_colored_polygon(pts, col)
