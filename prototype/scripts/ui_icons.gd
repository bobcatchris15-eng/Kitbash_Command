class_name UIIcons
extends RefCounted

## Central icon registry mapping logical icon names to loaded Texture2D resources.

const ICON_PATHS: Dictionary = {
	"metal": "res://assets/icons/icon_metal.svg",
	"crystal": "res://assets/icons/icon_crystal.svg",
	"power": "res://assets/icons/icon_power.svg",
	"credits": "res://assets/icons/icon_credits.svg",
	"attack": "res://assets/icons/icon_attack.svg",
	"defense": "res://assets/icons/icon_defense.svg",
	"repair": "res://assets/icons/icon_repair.svg",
	"salvage": "res://assets/icons/icon_salvage.svg",
	"target": "res://assets/icons/icon_target.svg",
	"skull": "res://assets/icons/icon_skull.svg",
	"trophy": "res://assets/icons/icon_trophy.svg",
	"factory": "res://assets/icons/icon_factory.svg",
	"powerplant": "res://assets/icons/icon_powerplant.svg",
	"extractor": "res://assets/icons/icon_extractor.svg",
	"hq": "res://assets/icons/icon_hq.svg",
	"turret": "res://assets/icons/icon_turret.svg",
	"gear": "res://assets/icons/icon_gear.svg",
	"wrench": "res://assets/icons/icon_wrench.svg",
	"menu": "res://assets/icons/icon_menu.svg",
	"back": "res://assets/icons/icon_back.svg",
	"close": "res://assets/icons/icon_close.svg",
	"chevron_left": "res://assets/icons/icon_chevron_left.svg",
	"chevron_right": "res://assets/icons/icon_chevron_right.svg",
	# Dropdown arrow. bomber_theme.tres styles OptionButton's box but sets no
	# `icons/arrow`, so every dropdown in the game was drawing Godot's stock
	# triangle next to house-styled everything else - the single detail that
	# made the match setup dropdowns read as unthemed default controls.
	"chevron_down": "res://assets/icons/icon_chevron_down.svg",
	"rotate_left": "res://assets/icons/icon_rotate_left.svg",
	"rotate_right": "res://assets/icons/icon_rotate_right.svg",
	"play": "res://assets/icons/icon_play.svg",
	"pause": "res://assets/icons/icon_pause.svg",
	"undo": "res://assets/icons/icon_undo.svg",
	"redo": "res://assets/icons/icon_redo.svg",
	"check": "res://assets/icons/icon_check.svg",
	"hull": "res://assets/icons/icon_hull.svg",
	"weapon": "res://assets/icons/icon_weapon.svg",
	"engine": "res://assets/icons/icon_engine.svg",
	"armor": "res://assets/icons/icon_armor.svg",
	"info": "res://assets/icons/icon_info.svg",

	# Hull Builder primitives (VISUAL/UI plan item 0). One entry per member of
	# hull_builder.gd's PRIMITIVES table, replacing the Unicode geometry glyphs
	# that table used to carry as its button faces. Authored by
	# tools/generate_icons.py - see its PRIMITIVE_ICONS block for the visual
	# language these share.
	"prim_box": "res://assets/icons/icon_prim_box.svg",
	"prim_sphere": "res://assets/icons/icon_prim_sphere.svg",
	"prim_cylinder": "res://assets/icons/icon_prim_cylinder.svg",
	"prim_wedge": "res://assets/icons/icon_prim_wedge.svg",
	"prim_cone": "res://assets/icons/icon_prim_cone.svg",
	"prim_torus": "res://assets/icons/icon_prim_torus.svg",
	"prim_slope": "res://assets/icons/icon_prim_slope.svg",
	"prim_frustum": "res://assets/icons/icon_prim_frustum.svg",
	"prim_chamfer_box": "res://assets/icons/icon_prim_chamfer_box.svg",
	"prim_half_cylinder": "res://assets/icons/icon_prim_half_cylinder.svg",
	"prim_hemisphere": "res://assets/icons/icon_prim_hemisphere.svg",
	"prim_capsule": "res://assets/icons/icon_prim_capsule.svg",
	"prim_i_beam": "res://assets/icons/icon_prim_i_beam.svg",
	"prim_l_beam": "res://assets/icons/icon_prim_l_beam.svg",
	"prim_hex_prism": "res://assets/icons/icon_prim_hex_prism.svg",
	"prim_pyramid": "res://assets/icons/icon_prim_pyramid.svg",
	"prim_fender": "res://assets/icons/icon_prim_fender.svg",
	"prim_canopy": "res://assets/icons/icon_prim_canopy.svg",
	"prim_ring": "res://assets/icons/icon_prim_ring.svg",

	# Command bar icons — name keys match CommandRegistry.icon field values.
	"cmd_patrol": "res://assets/icons/icon_cmd_patrol.svg",
	"cmd_attack_move": "res://assets/icons/icon_cmd_attack_move.svg",
	"cmd_stop": "res://assets/icons/icon_cmd_stop.svg",
	"cmd_rally": "res://assets/icons/icon_cmd_rally.svg",
	"cmd_stance_aggressive": "res://assets/icons/icon_cmd_stance_aggressive.svg",
	"cmd_stance_return_fire": "res://assets/icons/icon_cmd_stance_return_fire.svg",
	"cmd_hold": "res://assets/icons/icon_cmd_hold.svg",
	"cmd_stance_hold": "res://assets/icons/icon_cmd_stance_hold.svg",
}

static var _cache: Dictionary = {}

static func get_icon(name: String) -> Texture2D:
	if _cache.has(name):
		return _cache[name]
	if not ICON_PATHS.has(name):
		push_warning("UIIcons: unknown icon name '%s'" % name)
		return null
	var path: String = ICON_PATHS[name]
	if ResourceLoader.exists(path):
		var tex: Texture2D = load(path) as Texture2D
		_cache[name] = tex
		return tex
	push_warning("UIIcons: icon file missing at '%s'" % path)
	return null

static func has_icon(name: String) -> bool:
	return ICON_PATHS.has(name)
