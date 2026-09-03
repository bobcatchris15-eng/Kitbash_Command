class_name HUDIcons
extends RefCounted
# Loader for the authored battle-HUD icon set.
#
# The icons are hand-authored SVGs under assets/hud/icons/, monochrome white,
# tinted at use site by CanvasItem.modulate. SVG rather than PNG for two
# reasons: the engine rasterises it at import to whatever scale the .import
# sidecar asks for, so one file serves every UI scale; and it stays editable in
# Inkscape without a round trip through a texture atlas.
#
# THIS IS NOT ui_icons.gd. That file generates its glyphs procedurally at
# runtime; this one loads authored art off disk. They are separate on purpose -
# see hud_style.gd for why the battle HUD stopped generating its own chrome.
#
# A missing icon is not an error. It returns null and callers fall back to a
# text label, because a HUD that refuses to build because one glyph is absent is
# worse than a HUD with one word where a picture should be.

const DIR := "res://assets/hud/icons"

# Every icon the HUD asks for by name. Listed rather than globbed so a typo at
# the call site is findable, and so `missing()` can report the gap.
const NAMES: Array[String] = [
	"metal", "crystal", "power", "income",
	"tier_light", "tier_medium", "tier_heavy", "structures", "defence",
	"move", "attack", "stop", "hold", "patrol",
	"stance_hold", "stance_return", "stance_aggressive",
	"cancel", "pause", "resume",
	"alert", "contact", "ready",
	"smoke", "barrage", "beacon", "mine", "boost",
]

static var _cache: Dictionary = {}


static func get_icon(name: String) -> Texture2D:
	if _cache.has(name):
		return _cache[name]
	var path := "%s/%s.svg" % [DIR, name]
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		var res = load(path)
		if res is Texture2D:
			tex = res
	_cache[name] = tex
	return tex


# A tinted icon sized to a square. `size` is the edge in px at 1.0 UI scale.
static func rect(name: String, size: int, color: Color = Color.WHITE) -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = get_icon(name)
	tr.custom_minimum_size = Vector2(size, size)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.modulate = color
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr


# Put an icon on a Button.
#
# `icon_max_width`, NOT `expand_icon`. The SVGs import at their authored 64 px,
# and expand_icon grows the icon to fill the button - on a 36 px tab that also
# carries a text label the icon swallows the row. icon_max_width caps it and
# leaves the Button to lay the pair out normally.
static func on_button(b: Button, name: String, color: Color = Color.WHITE,
		max_width: int = 18) -> void:
	var tex := get_icon(name)
	if tex == null:
		return
	b.icon = tex
	b.expand_icon = false
	b.add_theme_constant_override("icon_max_width", max_width)
	b.add_theme_color_override("icon_normal_color", color)
	b.add_theme_color_override("icon_hover_color", Color.WHITE)
	b.add_theme_color_override("icon_pressed_color", Color.WHITE)
	b.add_theme_color_override("icon_disabled_color", color * Color(1, 1, 1, 0.35))


# Which declared icons have no file. Used by the HUD audit tool; returning the
# list rather than pushing errors keeps this callable from a test.
static func missing() -> Array[String]:
	var out: Array[String] = []
	for n in NAMES:
		if not ResourceLoader.exists("%s/%s.svg" % [DIR, n]):
			out.append(n)
	return out


static func clear_cache() -> void:
	_cache.clear()
